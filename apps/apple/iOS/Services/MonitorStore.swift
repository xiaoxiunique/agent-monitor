import Foundation
import Observation
import UIKit
import UserNotifications

struct ServerMonitorState: Equatable {
    let profileID: String
    let profileIdentity: String
    var connectionState: String
    var errorMessage: String?
    var snapshot: Snapshot?
    var lastSeenAt: Date?
    var isLoading: Bool
}

@MainActor
@Observable
final class MonitorStore {
    var snapshot: Snapshot?
    var isLoading = false
    var connectionState = "connecting"
    var errorMessage: String?
    var selectedFilter: StatusFilter = .all
    var selectedPane: Pane?
    var serverStates: [String: ServerMonitorState] = [:]

    private let settings: AppSettings
    private let snapshotDecodeQueue = DispatchQueue(label: "dev.hcg.AgentMonitor.snapshotDecode", qos: .userInitiated)
    private var webSocketTask: URLSessionWebSocketTask?
    private var refreshTask: Task<Void, Never>?
    private var serverRefreshTask: Task<Void, Never>?
    private var commandRefreshTask: Task<Void, Never>?
    private var pendingOfflineTask: Task<Void, Never>?
    private var pendingOfflineMessage: String?
    private var hasConfirmedConnection = false
    private var isRunning = false
    private var latestSnapshotAt = Date.distantPast
    private var activeServerIdentity = ""
    private var activeServerProfileID = ""
    private var lastPaneStatusesByServer: [String: [String: PaneStatus]] = [:]
    private var lastNotificationKeys: [String: Date] = [:]
    private let notificationCooldownSeconds: TimeInterval = 120

    private struct ServerRequestContext {
        let identity: String
        let client: AgentMonitorClient
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    var panes: [Pane] {
        (snapshot?.panes ?? []).filter { selectedFilter.matches($0) }
    }

    var allPanes: [Pane] {
        snapshot?.panes ?? []
    }

    var priorityPane: Pane? {
        let panes = snapshot?.panes ?? []
        return panes.first(where: { $0.status == .waiting })
            ?? panes.first(where: { $0.status == .failed })
            ?? panes.first(where: { $0.status == .running })
    }

    func count(for filter: StatusFilter) -> Int {
        switch filter {
        case .all:
            allPanes.count
        default:
            allPanes.filter(filter.matches).count
        }
    }

    func start() {
        stop()
        isRunning = true
        resetIfServerChanged()
        AgentStatusNotifications.requestAuthorizationIfNeeded()
        if settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markUnconfigured()
        } else if !hasConfirmedConnection {
            connectionState = "connecting"
            errorMessage = nil
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            await connectWebSocket()

            while !Task.isCancelled {
                let seconds = max(10.0, settings.refreshInterval)
                try? await Task.sleep(for: .seconds(seconds))
                await refresh(showLoading: false)
            }
        }

        serverRefreshTask = Task { [weak self] in
            guard let self else { return }
            await refreshAllServerStates(showLoading: true)

            while !Task.isCancelled {
                let seconds = max(12.0, settings.refreshInterval * 3)
                try? await Task.sleep(for: .seconds(seconds))
                await refreshAllServerStates(showLoading: false)
            }
        }
    }

    func stop() {
        isRunning = false
        isLoading = false
        refreshTask?.cancel()
        refreshTask = nil
        serverRefreshTask?.cancel()
        serverRefreshTask = nil
        commandRefreshTask?.cancel()
        commandRefreshTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        cancelPendingOffline()
    }

    func refresh(showLoading: Bool = true) async {
        resetIfServerChanged()
        guard let context = makeServerRequestContext() else {
            markUnconfigured()
            return
        }

        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading, isCurrentServer(context.identity) {
                isLoading = false
            }
        }

        do {
            let nextSnapshot = try await context.client.snapshot()
            guard isCurrentServer(context.identity) else { return }
            updateSnapshotIfNeeded(nextSnapshot)
            markConnectionLive()
        } catch {
            guard isCurrentServer(context.identity) else { return }
            markConnectionUncertain(error.localizedDescription)
        }
    }

    func connectWebSocket() async {
        resetIfServerChanged()
        guard let context = makeServerRequestContext() else {
            markUnconfigured()
            return
        }

        do {
            let request = try context.client.snapshotWebSocketRequest()
            guard isCurrentServer(context.identity) else { return }
            let task = URLSession.shared.webSocketTask(with: request)
            webSocketTask = task
            task.resume()
            if connectionState != "live", errorMessage == nil {
                connectionState = "connecting"
            }
            Task { await receiveLoop(task, serverIdentity: context.identity) }
        } catch {
            guard isCurrentServer(context.identity) else { return }
            markConnectionUncertain(error.localizedDescription)
        }
    }

    func sendText(_ text: String, to pane: Pane, vimMode: Bool) async -> PaneCommandResponse? {
        guard let context = makeServerRequestContext(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let response = try await context.client.sendText(text, to: pane, vimMode: vimMode)
            guard isCurrentServer(context.identity) else { return nil }
            scheduleSnapshotRefreshAfterCommand(for: context.identity)
            return response
        } catch {
            guard isCurrentServer(context.identity) else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func refineText(_ text: String) async -> String {
        let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context = makeServerRequestContext(), !fallback.isEmpty else { return fallback }

        do {
            let response = try await context.client.refineText(fallback)
            guard isCurrentServer(context.identity) else { return fallback }
            return response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallback
                : response.text
        } catch {
            return fallback
        }
    }

    func uploadImage(_ imageData: Data, to pane: Pane) async throws -> UploadedImageResponse {
        guard let context = makeServerRequestContext(), !imageData.isEmpty else {
            throw AgentMonitorError.invalidResponse
        }

        do {
            let response = try await context.client.uploadImage(imageData, to: pane, contentType: "image/jpeg")
            guard isCurrentServer(context.identity) else { throw CancellationError() }
            return response
        } catch {
            guard isCurrentServer(context.identity) else { throw error }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func sendKey(_ key: String, to pane: Pane) async -> PaneCommandResponse? {
        guard let context = makeServerRequestContext() else { return nil }
        do {
            let response = try await context.client.sendKey(key, to: pane)
            guard isCurrentServer(context.identity) else { return nil }
            scheduleSnapshotRefreshAfterCommand(for: context.identity)
            return response
        } catch {
            guard isCurrentServer(context.identity) else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func closePane(_ pane: Pane) async -> Bool {
        guard let context = makeServerRequestContext() else { return false }
        do {
            try await context.client.closePane(pane)
            guard isCurrentServer(context.identity) else { return false }
            selectedPane = nil
            await refresh(for: context.identity)
            return true
        } catch {
            guard isCurrentServer(context.identity) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadPaneContext(_ pane: Pane, lines: Int) async throws -> PaneContextResponse {
        guard let context = makeServerRequestContext() else {
            throw AgentMonitorError.invalidServerURL
        }
        let response = try await context.client.paneContext(for: pane, lines: lines)
        guard isCurrentServer(context.identity) else { throw CancellationError() }
        return response
    }

    func makeClient() -> AgentMonitorClient? {
        guard let baseURL = settings.baseURL else { return nil }
        return AgentMonitorClient(baseURL: baseURL, token: settings.accessToken)
    }

    func serverMonitorState(for profile: ServerProfile) -> ServerMonitorState {
        if profile.id == settings.activeServerID {
            let cached = cachedState(for: profile)
            let displaySnapshot = snapshot ?? cached?.snapshot
            return ServerMonitorState(
                profileID: profile.id,
                profileIdentity: profile.monitorIdentity,
                connectionState: connectionState,
                errorMessage: errorMessage,
                snapshot: displaySnapshot,
                lastSeenAt: displaySnapshot?.now ?? cached?.lastSeenAt,
                isLoading: isLoading
            )
        }

        if let state = cachedState(for: profile) {
            return state
        }

        return ServerMonitorState(
            profileID: profile.id,
            profileIdentity: profile.monitorIdentity,
            connectionState: profile.trimmedURL.isEmpty ? "unconfigured" : "unknown",
            errorMessage: profile.trimmedURL.isEmpty ? "Configure service URL in Settings" : nil,
            snapshot: nil,
            lastSeenAt: nil,
            isLoading: false
        )
    }

    func refreshAllServerStates(showLoading: Bool = true) async {
        let profiles = settings.serverProfiles
        let activeID = settings.activeServerID
        pruneServerStates(validProfiles: profiles)

        for profile in profiles where profile.id != activeID {
            guard !Task.isCancelled else { return }
            await refreshServerState(profile, showLoading: showLoading)
        }
    }

    private func makeServerRequestContext() -> ServerRequestContext? {
        guard let baseURL = settings.baseURL else { return nil }
        return ServerRequestContext(
            identity: settings.activeServerIdentity,
            client: AgentMonitorClient(baseURL: baseURL, token: settings.accessToken)
        )
    }

    private func isCurrentServer(_ identity: String) -> Bool {
        activeServerIdentity == identity && settings.activeServerIdentity == identity
    }

    private func resetIfServerChanged() {
        let nextIdentity = settings.activeServerIdentity
        let nextProfileID = settings.activeServerID
        guard activeServerIdentity != nextIdentity else {
            activeServerProfileID = nextProfileID
            return
        }
        cacheActiveServerStateBeforeSwitch()
        activeServerIdentity = nextIdentity
        activeServerProfileID = nextProfileID
        snapshot = nil
        selectedPane = nil
        isLoading = false
        errorMessage = nil
        hasConfirmedConnection = false
        latestSnapshotAt = Date.distantPast
        cancelPendingOffline()
    }

    private func cacheActiveServerStateBeforeSwitch() {
        guard !activeServerProfileID.isEmpty,
              !activeServerIdentity.isEmpty,
              settings.serverProfiles.contains(where: { $0.id == activeServerProfileID })
        else { return }

        serverStates[activeServerProfileID] = ServerMonitorState(
            profileID: activeServerProfileID,
            profileIdentity: activeServerIdentity,
            connectionState: connectionState,
            errorMessage: errorMessage,
            snapshot: snapshot,
            lastSeenAt: snapshot?.now,
            isLoading: false
        )
    }

    private func cachedState(for profile: ServerProfile) -> ServerMonitorState? {
        guard let state = serverStates[profile.id],
              state.profileIdentity == profile.monitorIdentity
        else { return nil }
        return state
    }

    private func isInactiveProfileCurrent(_ profile: ServerProfile, identity: String) -> Bool {
        guard settings.activeServerID != profile.id else { return false }
        return settings.serverProfiles.first(where: { $0.id == profile.id })?.monitorIdentity == identity
    }

    private func pruneServerStates(validProfiles: [ServerProfile]? = nil) {
        let profiles = validProfiles ?? settings.serverProfiles
        var identitiesByID: [String: String] = [:]
        for profile in profiles {
            identitiesByID[profile.id] = profile.monitorIdentity
        }
        let validIdentities = Set(profiles.map(\.monitorIdentity))
        serverStates = serverStates.filter { id, state in
            identitiesByID[id] == state.profileIdentity
        }
        lastPaneStatusesByServer = lastPaneStatusesByServer.filter { validIdentities.contains($0.key) }
        lastNotificationKeys = lastNotificationKeys.filter { key, _ in
            guard let serverIdentity = key.split(separator: "\n", maxSplits: 1).first else { return false }
            return validIdentities.contains(String(serverIdentity))
        }
    }

    private func refreshServerState(_ profile: ServerProfile, showLoading: Bool) async {
        let profileIdentity = profile.monitorIdentity
        guard isInactiveProfileCurrent(profile, identity: profileIdentity) else { return }
        let existing = cachedState(for: profile)
        let trimmedURL = profile.trimmedURL
        guard let baseURL = URL(string: trimmedURL), !trimmedURL.isEmpty else {
            serverStates[profile.id] = ServerMonitorState(
                profileID: profile.id,
                profileIdentity: profileIdentity,
                connectionState: "unconfigured",
                errorMessage: "Configure service URL in Settings",
                snapshot: existing?.snapshot,
                lastSeenAt: existing?.lastSeenAt,
                isLoading: false
            )
            return
        }

        if showLoading {
            serverStates[profile.id] = ServerMonitorState(
                profileID: profile.id,
                profileIdentity: profileIdentity,
                connectionState: existing?.connectionState ?? "connecting",
                errorMessage: existing?.errorMessage,
                snapshot: existing?.snapshot,
                lastSeenAt: existing?.lastSeenAt,
                isLoading: true
            )
        }

        do {
            let client = AgentMonitorClient(baseURL: baseURL, token: profile.token)
            let nextSnapshot = try await client.snapshot()
            guard isInactiveProfileCurrent(profile, identity: profileIdentity) else { return }
            observeStatusTransitions(
                in: nextSnapshot,
                serverIdentity: profileIdentity,
                serverName: profile.displayName
            )
            serverStates[profile.id] = ServerMonitorState(
                profileID: profile.id,
                profileIdentity: profileIdentity,
                connectionState: "live",
                errorMessage: nil,
                snapshot: nextSnapshot,
                lastSeenAt: nextSnapshot.now,
                isLoading: false
            )
        } catch {
            guard isInactiveProfileCurrent(profile, identity: profileIdentity) else { return }
            serverStates[profile.id] = ServerMonitorState(
                profileID: profile.id,
                profileIdentity: profileIdentity,
                connectionState: "offline",
                errorMessage: error.localizedDescription,
                snapshot: existing?.snapshot,
                lastSeenAt: existing?.lastSeenAt,
                isLoading: false
            )
        }
    }

    private func scheduleSnapshotRefreshAfterCommand(for serverIdentity: String) {
        commandRefreshTask?.cancel()
        commandRefreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, isCurrentServer(serverIdentity) else { return }
            await refresh(for: serverIdentity, showLoading: false)
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, serverIdentity: String) async {
        var retryDelay: Duration = .seconds(1.5)
        let maxDelay: Duration = .seconds(30)

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard isCurrentServer(serverIdentity), webSocketTask === task else { return }
                retryDelay = .seconds(1.5) // reset on success
                switch message {
                case let .data(data):
                    handleWebSocketData(data, from: task, serverIdentity: serverIdentity)
                case let .string(text):
                    handleWebSocketData(Data(text.utf8), from: task, serverIdentity: serverIdentity)
                @unknown default:
                    break
                }
            } catch {
                guard isRunning, webSocketTask === task, isCurrentServer(serverIdentity) else { return }
                markConnectionUncertain(error.localizedDescription)
                try? await Task.sleep(for: retryDelay)
                retryDelay = min(retryDelay * 2, maxDelay)
                guard isCurrentServer(serverIdentity), webSocketTask === task else { return }
                await connectWebSocket()
                return
            }
        }
    }

    private func refresh(for serverIdentity: String, showLoading: Bool = true) async {
        guard isCurrentServer(serverIdentity) else { return }
        await refresh(showLoading: showLoading)
    }

    private nonisolated func decodeSnapshotEnvelope(from data: Data) async -> Snapshot? {
        await withCheckedContinuation { continuation in
            snapshotDecodeQueue.async {
                let envelope = try? AgentMonitorClient.decode(SnapshotEnvelope.self, from: data)
                continuation.resume(returning: envelope?.snapshot)
            }
        }
    }

    private func handleWebSocketData(_ data: Data, from task: URLSessionWebSocketTask, serverIdentity: String) {
        Task { [weak self] in
            guard let snapshot = await self?.decodeSnapshotEnvelope(from: data) else { return }
            await MainActor.run {
                guard let self,
                      self.isCurrentServer(serverIdentity),
                      self.webSocketTask === task
                else { return }
                self.updateSnapshotIfNeeded(snapshot)
                self.markConnectionLive()
            }
        }
    }

    private func updateSnapshotIfNeeded(_ nextSnapshot: Snapshot) {
        guard nextSnapshot.now >= latestSnapshotAt else {
            return
        }
        latestSnapshotAt = nextSnapshot.now

        guard snapshot != nextSnapshot else {
            return
        }
        snapshot = nextSnapshot
        observeStatusTransitions(
            in: nextSnapshot,
            serverIdentity: settings.activeServerIdentity,
            serverName: settings.activeServerDisplayName
        )
    }

    private func markConnectionLive() {
        hasConfirmedConnection = true
        cancelPendingOffline()
        errorMessage = nil
        connectionState = "live"
    }

    private func markUnconfigured() {
        isLoading = false
        hasConfirmedConnection = false
        cancelPendingOffline()
        errorMessage = "Configure service URL in Settings"
        connectionState = "unconfigured"
    }

    private func markConnectionUncertain(_ message: String) {
        pendingOfflineMessage = message

        if hasConfirmedConnection || snapshot != nil {
            if connectionState != "live" {
                connectionState = "reconnecting"
            }
        } else {
            connectionState = "connecting"
        }

        guard pendingOfflineTask == nil else { return }
        let delay: Duration = (hasConfirmedConnection || snapshot != nil) ? .seconds(6) : .seconds(3)
        pendingOfflineTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.confirmPendingOffline()
        }
    }

    private func confirmPendingOffline() {
        errorMessage = pendingOfflineMessage
        connectionState = "offline"
        hasConfirmedConnection = false
        pendingOfflineTask = nil
    }

    private func cancelPendingOffline() {
        pendingOfflineTask?.cancel()
        pendingOfflineTask = nil
        pendingOfflineMessage = nil
    }

    private func observeStatusTransitions(in snapshot: Snapshot, serverIdentity: String, serverName: String) {
        var previous = lastPaneStatusesByServer[serverIdentity] ?? [:]
        let hadPreviousSnapshot = lastPaneStatusesByServer[serverIdentity] != nil

        for pane in snapshot.panes {
            let oldStatus = previous[pane.id]
            if hadPreviousSnapshot, oldStatus != pane.status {
                notifyIfActionableStatusChanged(pane, serverIdentity: serverIdentity, serverName: serverName)
            }
            previous[pane.id] = pane.status
        }

        let currentIDs = Set(snapshot.panes.map(\.id))
        previous = previous.filter { currentIDs.contains($0.key) }
        lastPaneStatusesByServer[serverIdentity] = previous
    }

    private func notifyIfActionableStatusChanged(_ pane: Pane, serverIdentity: String, serverName: String) {
        switch pane.status {
        case .waiting, .failed, .done:
            let key = "\(serverIdentity)\n\(pane.id)\n\(pane.status.rawValue)"
            if let lastSentAt = lastNotificationKeys[key],
               Date().timeIntervalSince(lastSentAt) < notificationCooldownSeconds {
                return
            }
            lastNotificationKeys[key] = Date()
            AgentStatusNotifications.notifyStatusChange(pane: pane, serverIdentity: serverIdentity, serverName: serverName)
        case .running, .idle:
            break
        }
    }
}

@MainActor
private enum AgentStatusNotifications {
    private static var didRequestAuthorization = false

    static func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    static func notifyStatusChange(pane: Pane, serverIdentity: String, serverName: String) {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: pane.status, project: AppSettings.projectName(from: pane.session))
        content.body = notificationBody(for: pane, serverName: serverName)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: notificationIdentifier(serverIdentity: serverIdentity, pane: pane),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func notificationIdentifier(serverIdentity: String, pane: Pane) -> String {
        "pane-status-\(stableHash(serverIdentity))-\(stableHash(pane.id))-\(pane.status.rawValue)"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func notificationTitle(for status: PaneStatus, project: String) -> String {
        switch status {
        case .waiting:
            "\(project) needs your input"
        case .failed:
            "\(project) needs attention"
        case .done:
            "\(project) finished"
        case .running:
            "\(project) is running"
        case .idle:
            "\(project) is idle"
        }
    }

    private static func notificationBody(for pane: Pane, serverName: String) -> String {
        let message = pane.messages?.first(where: { $0.priority == .high || $0.kind == .done || $0.kind == .error })?.body
            ?? pane.reason
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(serverName) · \(pane.status.title)"
        }
        return "\(serverName) · \(trimmed)"
    }
}
