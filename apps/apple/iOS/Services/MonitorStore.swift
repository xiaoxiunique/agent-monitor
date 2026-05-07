import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class MonitorStore {
    var snapshot: Snapshot?
    var isLoading = false
    var connectionState = "offline"
    var errorMessage: String?
    var selectedFilter: StatusFilter = .all
    var selectedPane: Pane?

    private let settings: AppSettings
    private var webSocketTask: URLSessionWebSocketTask?
    private var refreshTask: Task<Void, Never>?

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
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            await connectWebSocket()

            while !Task.isCancelled {
                let seconds = max(1.0, settings.refreshInterval)
                try? await Task.sleep(for: .seconds(seconds))
                await refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    func refresh(showLoading: Bool = true) async {
        guard let client = makeClient() else {
            errorMessage = "Configure service URL in Settings"
            connectionState = "unconfigured"
            return
        }

        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading {
                isLoading = false
            }
        }

        do {
            snapshot = try await client.snapshot()
            errorMessage = nil
            connectionState = "live"
        } catch {
            errorMessage = error.localizedDescription
            connectionState = "offline"
        }
    }

    func connectWebSocket() async {
        guard let client = makeClient() else { return }

        do {
            let url = try client.snapshotWebSocketURL()
            let task = URLSession.shared.webSocketTask(with: url)
            webSocketTask = task
            task.resume()
            connectionState = "live"
            Task { await receiveLoop(task) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendText(_ text: String, to pane: Pane, vimMode: Bool) async {
        guard let client = makeClient(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await client.sendText(text, to: pane, vimMode: vimMode)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendKey(_ key: String, to pane: Pane) async {
        guard let client = makeClient() else { return }
        do {
            try await client.sendKey(key, to: pane)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func killSession(_ sessionName: String) async {
        guard let client = makeClient() else { return }
        do {
            try await client.killSession(sessionName)
            selectedPane = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func terminalURL(for pane: Pane) -> URL? {
        guard let client = makeClient() else { return nil }
        return try? client.terminalURL(for: pane)
    }

    func makeClient() -> AgentMonitorClient? {
        guard let baseURL = settings.baseURL else { return nil }
        return AgentMonitorClient(baseURL: baseURL, token: settings.accessToken)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .data(data):
                    handleWebSocketData(data)
                case let .string(text):
                    handleWebSocketData(Data(text.utf8))
                @unknown default:
                    break
                }
            } catch {
                connectionState = "reconnecting"
                try? await Task.sleep(for: .seconds(1.5))
                await connectWebSocket()
                return
            }
        }
    }

    private func handleWebSocketData(_ data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(SnapshotEnvelope.self, from: data),
              let snapshot = envelope.snapshot else {
            return
        }
        self.snapshot = snapshot
        errorMessage = nil
        connectionState = "live"
    }
}
