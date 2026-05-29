import SwiftUI
import UIKit
import PhotosUI
import ImageIO

struct PaneDetailView: View {
    let pane: Pane
    let isLiveServer: Bool
    let serverName: String

    @Environment(MonitorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showKillConfirmation = false
    @State private var showInfo = false
    @State private var actionPane: Pane
    @State private var inputText = ""
    @State private var vimMode = false

    init(pane: Pane, isLiveServer: Bool = true, serverName: String = "Server") {
        self.pane = pane
        self.isLiveServer = isLiveServer
        self.serverName = serverName
        _actionPane = State(initialValue: pane)
    }

    private var projectName: String {
        AppSettings.projectName(from: pane.session)
    }

    var body: some View {
        terminalContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isLiveServer {
                StaleServerBanner(serverName: serverName)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InputBar(
                pane: actionPane,
                isEnabled: isLiveServer,
                inputText: $inputText,
                vimMode: $vimMode,
                showKillConfirmation: $showKillConfirmation,
                onSendText: { text in
                    guard isLiveServer else { return false }
                    let response = await store.sendText(text, to: actionPane, vimMode: vimMode)
                    return response?.ok == true
                },
                onUserMessageSent: { _ in },
                onRefineText: { text in
                    await store.refineText(text)
                },
                onSendKey: { key in
                    guard isLiveServer else { return false }
                    let response = await store.sendKey(key, to: actionPane)
                    return response?.ok == true
                },
                onUploadImage: { imageData in
                    guard isLiveServer else { throw CancellationError() }
                    return try await store.uploadImage(imageData, to: actionPane)
                }
            )
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    Button(role: .destructive) {
                        showKillConfirmation = true
                    } label: {
                        Image(systemName: "xmark.rectangle")
                            .font(.system(size: 16))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!isLiveServer)
                    .accessibilityLabel("Close pane")

                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Open pane info")
                }
            }
        }
        .confirmationDialog(
            "Close pane \(actionPane.id)?",
            isPresented: $showKillConfirmation,
            titleVisibility: .visible
        ) {
            Button("Close Pane", role: .destructive) {
                Task {
                    guard isLiveServer else {
                        Haptics.sent(success: false)
                        return
                    }
                    if await store.closePane(actionPane) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This closes this tmux pane. Other panes in the same project stay available.")
        }
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                PaneInfoView(pane: actionPane)
                    .navigationTitle("Info")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showInfo = false }
                        }
                    }
            }
        }
        .background {
            PaneActionSync(initialPane: pane, actionPane: $actionPane, isLiveServer: isLiveServer)
        }
    }

    @ViewBuilder
    private var terminalContent: some View {
        if isLiveServer {
            TerminalPaneView(pane: actionPane)
                .background(Color.black)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
        } else {
            ContentUnavailableView {
                Label("Terminal paused", systemImage: "terminal")
            } description: {
                Text("Switch to \(serverName) before opening an interactive terminal.")
            }
            .foregroundStyle(.white)
            .background(
                AgentMonitorTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()
            )
        }
    }
}

private struct PaneActionSync: View {
    let initialPane: Pane
    @Binding var actionPane: Pane
    let isLiveServer: Bool

    @Environment(MonitorStore.self) private var store

    private var currentPane: Pane {
        guard isLiveServer else { return initialPane }
        return store.allPanes.first(where: { $0.id == initialPane.id }) ?? initialPane
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                updateActionPaneIfNeeded(from: currentPane)
            }
            .onChange(of: currentPane) { _, pane in
                updateActionPaneIfNeeded(from: pane)
            }
    }

    private func updateActionPaneIfNeeded(from pane: Pane) {
        if actionPane != pane {
            actionPane = pane
        }
    }
}

private struct StaleServerBanner: View {
    let serverName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("Waiting for \(serverName) to become active. Actions are paused for this snapshot.")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct PaneLogRefreshHint: Equatable {
    let id = UUID()
    let paneId: String
    let tail: String
    let capturedAt: Date

    static func == (lhs: PaneLogRefreshHint, rhs: PaneLogRefreshHint) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Agent Chat Timeline

private struct AgentChatTimelineContainer: View {
    let initialPane: Pane
    let isLiveServer: Bool
    let userMessages: [UserInteractionMessage]
    let onOpenTerminal: () -> Void
    let onSendAction: (String) async -> Bool

    @Environment(MonitorStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var transcriptEvents: [AgentEvent] = []
    @State private var transcriptSource: AgentEventSource?
    @State private var eventsRefreshTask: Task<Void, Never>?
    @State private var isUserNearTail = true
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var tailMinY: CGFloat = .infinity
    @State private var lastAutoScrolledEventFingerprint = ""

    private static let scrollCoordinateSpaceName = "agent-chat-scroll"
    private static let tailAutoScrollThreshold: CGFloat = 140

    private var currentPane: Pane {
        guard isLiveServer else { return initialPane }
        return store.allPanes.first(where: { $0.id == initialPane.id }) ?? initialPane
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ConversationStatusLine(
                        session: currentPane.session,
                        status: currentPane.status,
                        isLiveServer: isLiveServer,
                        sourceAgent: transcriptSource?.agent,
                        hasTranscript: !transcriptEvents.isEmpty
                    )

                    ForEach(Array(chatEvents.enumerated()), id: \.element.id) { index, event in
                        if shouldShowTimeDivider(before: event, at: index, in: chatEvents) {
                            ChatTimeDivider(date: event.createdAt)
                        }

                        switch event {
                        case let .agent(message):
                            AgentMessageBubble(
                                session: currentPane.session,
                                status: currentPane.status,
                                kind: message.kind,
                                title: message.title,
                                message: message.body,
                                actions: message.actions,
                                actionsEnabled: isLiveServer,
                                onOpenTerminal: onOpenTerminal,
                                onSendAction: onSendAction
                            )
                        case let .transcript(message):
                            switch message.role {
                            case .user:
                                TranscriptUserBubble(event: message)
                            case .agent:
                                switch message.kind {
                                case .toolCall, .toolResult:
                                    TranscriptToolEventRow(event: message)
                                default:
                                    TranscriptAgentBubble(
                                        session: currentPane.session,
                                        status: currentPane.status,
                                        event: message
                                    )
                                }
                            case .system:
                                TranscriptSystemEventRow(event: message)
                            }
                        case let .user(message):
                            UserMessageBubble(message: message)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ChatTailPositionPreferenceKey.self,
                                    value: geometry.frame(in: .named(Self.scrollCoordinateSpaceName)).minY
                                )
                            }
                        )
                        .id("chat-tail")
                }
                .padding(.bottom, 12)
            }
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ChatViewportHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .background(Color.clear)
            .onPreferenceChange(ChatViewportHeightPreferenceKey.self) { height in
                scrollViewportHeight = height
                updateNearTail(viewportHeight: height)
            }
            .onPreferenceChange(ChatTailPositionPreferenceKey.self) { minY in
                tailMinY = minY
                updateNearTail(tailMinY: minY)
            }
            .onAppear {
                scrollToTail(proxy, animated: false)
                lastAutoScrolledEventFingerprint = eventFingerprint(for: chatEvents)
                startTranscriptRefreshLoop()
            }
            .onDisappear {
                eventsRefreshTask?.cancel()
                eventsRefreshTask = nil
            }
            .onChange(of: chatEvents) { _, events in
                let fingerprint = eventFingerprint(for: events)
                defer { lastAutoScrolledEventFingerprint = fingerprint }
                guard shouldAutoScrollToTail(for: events, fingerprint: fingerprint) else { return }
                scrollToTail(proxy, animated: true)
            }
            .onChange(of: currentPane.updatedAt) { _, _ in
                guard isUserNearTail else { return }
                refreshTranscriptEvents()
                scrollToTail(proxy, animated: true)
            }
        }
    }

    private var chatEvents: [AgentChatEvent] {
        if !transcriptEvents.isEmpty {
            let transcript = transcriptEvents.map(AgentChatEvent.transcript)
            let localUserEvents = userMessages
                .filter { message in
                    !transcriptEvents.contains(where: { event in
                        event.role == .user && event.localMatchId == message.eventMatchId
                    })
                }
                .map(AgentChatEvent.user)
            return (transcript + localUserEvents).sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
                return lhs.id < rhs.id
            }
        }

        let agentMessages = conversationMessages(for: currentPane)
        let agentEvents = agentMessages.map(AgentChatEvent.agent)
        let userEvents = userMessages.map(AgentChatEvent.user)
        return (agentEvents + userEvents).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
            return lhs.id < rhs.id
        }
    }

    private func startTranscriptRefreshLoop() {
        guard isLiveServer else { return }
        guard eventsRefreshTask == nil else { return }
        refreshTranscriptEvents()
        eventsRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    refreshTranscriptEvents()
                }
            }
        }
    }

    private func refreshTranscriptEvents() {
        guard isLiveServer else { return }
        let pane = currentPane
        Task {
            do {
                let response = try await store.loadPaneEvents(pane)
                guard response.paneId == initialPane.id else { return }
                await MainActor.run {
                    transcriptEvents = response.events
                    transcriptSource = response.source
                }
            } catch {
                return
            }
        }
    }

    private func conversationMessages(for pane: Pane) -> [InteractionMessage] {
        var messages = visibleAgentMessages(from: pane.messages ?? [])
        if messages.isEmpty {
            messages = visibleAgentMessages(from: fallbackInteractionMessages(for: pane))
        }

        if let checkpoint = checkpointMessage(for: pane),
           !messages.contains(where: { isDuplicateConversationMessage($0, checkpoint) }) {
            messages.append(checkpoint)
        }

        return messages
            .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return messageOrder(lhs.kind) < messageOrder(rhs.kind)
            }
    }

    private func visibleAgentMessages(from messages: [InteractionMessage]) -> [InteractionMessage] {
        messages.compactMap { message in
            guard let body = LocalSummary.displayBody(
                for: message,
                status: currentPane.status,
                title: cleanTaskTitle(currentPane.title),
                reason: currentPane.reason,
                tail: currentPane.tail,
                latestUserMessage: message.kind == .summary ? nil : userMessages.last?.text
            ) else { return nil }
            return InteractionMessage(
                id: message.id,
                paneId: message.paneId,
                role: message.role,
                kind: message.kind,
                priority: message.priority,
                title: message.title,
                body: body,
                actions: message.actions,
                source: message.source,
                createdAt: message.createdAt
            )
        }
    }

    private func checkpointMessage(for pane: Pane) -> InteractionMessage? {
        let lines = LocalSummary.liveActivity(from: pane.tail)
        guard let latest = lines.last, !latest.isEmpty else { return nil }

        let body: String
        let title: String
        let kind: InteractionMessageKind
        let priority: InteractionMessagePriority

        switch pane.status {
        case .running:
            title = "Working"
            body = "正在处理：\(latest)"
            kind = .progress
            priority = .normal
        case .waiting:
            title = "Needs your input"
            body = latest
            kind = .question
            priority = .high
        case .failed:
            title = "Needs follow-up"
            body = pane.reason.isEmpty ? latest : pane.reason
            kind = .error
            priority = .high
        case .done:
            title = "Done"
            body = pane.reason.isEmpty ? "已完成：\(latest)" : pane.reason
            kind = .done
            priority = .normal
        case .idle:
            title = "Ready"
            body = pane.reason.isEmpty ? "空闲中，可以发送下一条指令。" : pane.reason
            kind = .status
            priority = .low
        }

        return InteractionMessage(
            id: "checkpoint-\(pane.id)-\(pane.status.rawValue)-\(tailHashInput(latest))-\(pane.updatedAt.timeIntervalSince1970)",
            paneId: pane.id,
            role: .agent,
            kind: kind,
            priority: priority,
            title: title,
            body: body,
            actions: nil,
            source: nil,
            createdAt: pane.updatedAt
        )
    }

    private func isDuplicateConversationMessage(_ lhs: InteractionMessage, _ rhs: InteractionMessage) -> Bool {
        let left = lhs.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return left == right || left.contains(right) || right.contains(left)
    }

    private func messageOrder(_ kind: InteractionMessageKind) -> Int {
        switch kind {
        case .summary: 0
        case .status, .progress: 1
        case .notification: 2
        case .question, .permissionRequest: 3
        case .error: 4
        case .done: 5
        }
    }

    private func tailHashInput(_ value: String) -> String {
        String(value.unicodeScalars.map { String($0.value, radix: 36) }.joined().prefix(24))
    }

    private func fallbackInteractionMessages(for pane: Pane) -> [InteractionMessage] {
        let body = LocalSummary.feedback(status: pane.status, title: cleanTaskTitle(pane.title), reason: pane.reason, tail: pane.tail)
        return [
            InteractionMessage(
                id: "local-\(pane.id)-\(pane.status.rawValue)-\(pane.updatedAt.timeIntervalSince1970)",
                paneId: pane.id,
                role: .agent,
                kind: fallbackKind(for: pane.status),
                priority: pane.status == .waiting || pane.status == .failed ? .high : .normal,
                title: LocalSummary.feedbackTitle(status: pane.status),
                body: body,
                actions: nil,
                source: nil,
                createdAt: pane.updatedAt
            )
        ]
    }

    private func fallbackKind(for status: PaneStatus) -> InteractionMessageKind {
        switch status {
        case .waiting: .question
        case .failed: .error
        case .done: .done
        case .running: .progress
        case .idle: .status
        }
    }

    private func scrollToTail(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("chat-tail", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("chat-tail", anchor: .bottom)
            }
        }
    }

    private func shouldAutoScrollToTail(for events: [AgentChatEvent], fingerprint: String) -> Bool {
        guard fingerprint != lastAutoScrolledEventFingerprint else { return false }
        guard let newestEvent = events.max(by: { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
            return lhs.id < rhs.id
        }) else { return false }
        return newestEvent.isUserMessage || isUserNearTail
    }

    private func updateNearTail(tailMinY nextTailMinY: CGFloat? = nil, viewportHeight nextViewportHeight: CGFloat? = nil) {
        let effectiveTailMinY = nextTailMinY ?? tailMinY
        let effectiveViewportHeight = nextViewportHeight ?? scrollViewportHeight
        guard effectiveViewportHeight > 0 else { return }
        isUserNearTail = effectiveTailMinY <= effectiveViewportHeight + Self.tailAutoScrollThreshold
    }

    private func eventFingerprint(for events: [AgentChatEvent]) -> String {
        events.map(\.fingerprint).joined(separator: "\u{1f}")
    }

    private func shouldShowTimeDivider(before event: AgentChatEvent, at index: Int, in events: [AgentChatEvent]) -> Bool {
        guard index > 0 else { return true }
        let previous = events[index - 1]
        if !Calendar.current.isDate(previous.createdAt, inSameDayAs: event.createdAt) {
            return true
        }
        return event.createdAt.timeIntervalSince(previous.createdAt) >= 10 * 60
    }
}

private struct ChatTailPositionPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum AgentChatEvent: Identifiable, Equatable {
    case agent(InteractionMessage)
    case transcript(AgentEvent)
    case user(UserInteractionMessage)

    var id: String {
        switch self {
        case let .agent(message): "agent-\(message.id)"
        case let .transcript(message): "transcript-\(message.id)"
        case let .user(message): "user-\(message.id)"
        }
    }

    var createdAt: Date {
        switch self {
        case let .agent(message): message.createdAt
        case let .transcript(message): message.createdAt
        case let .user(message): message.sentAt
        }
    }

    var sortRank: Int {
        switch self {
        case let .transcript(message):
            switch message.role {
            case .system: 0
            case .agent: 1
            case .user: 2
            }
        case .agent: 0
        case .user: 2
        }
    }

    var isUserMessage: Bool {
        if case .user = self { return true }
        if case let .transcript(message) = self, message.role == .user { return true }
        return false
    }

    var fingerprint: String {
        switch self {
        case let .agent(message):
            [
                id,
                message.kind.rawValue,
                message.priority.rawValue,
                message.title,
                message.body,
                message.createdAt.timeIntervalSince1970.description
            ].joined(separator: "\u{1e}")
        case let .transcript(message):
            [
                id,
                message.role.rawValue,
                message.kind.rawValue,
                message.title,
                message.body,
                message.createdAt.timeIntervalSince1970.description
            ].joined(separator: "\u{1e}")
        case let .user(message):
            [
                id,
                message.text,
                message.sentAt.timeIntervalSince1970.description
            ].joined(separator: "\u{1e}")
        }
    }
}

// MARK: - Realtime Log

private struct PaneRealtimeLogContainer: View {
    private static let realtimeLogLineLimit = 800

    let initialPane: Pane
    let refreshHint: PaneLogRefreshHint?

    @Environment(MonitorStore.self) private var store
    @State private var paneLogService = PaneLogWebSocketService()
    @State private var displayStatus: PaneStatus
    @State private var displayReason: String
    @State private var displayLogText: String
    @State private var displayUpdatedAt: Date
    @State private var logRuntime: PaneRealtimeLogRuntime
    @State private var isLogUserScrolling = false
    @State private var isLogFollowingTail = true
    @State private var followTailRequest = 0

    init(initialPane: Pane, refreshHint: PaneLogRefreshHint? = nil) {
        self.initialPane = initialPane
        self.refreshHint = refreshHint
        _displayStatus = State(initialValue: initialPane.status)
        _displayReason = State(initialValue: initialPane.reason)
        _displayLogText = State(initialValue: LogText.compact(initialPane.tail, limit: Self.realtimeLogLineLimit))
        _displayUpdatedAt = State(initialValue: initialPane.updatedAt)
        _logRuntime = State(initialValue: PaneRealtimeLogRuntime(latestLogCapturedAt: initialPane.updatedAt))
    }

    private var currentPane: Pane {
        store.allPanes.first(where: { $0.id == initialPane.id }) ?? initialPane
    }

    var body: some View {
        RealtimeLogPanel(
            status: displayStatus,
            reason: displayReason,
            logText: displayLogText,
            followTailRequest: followTailRequest,
            isUserScrolling: $isLogUserScrolling,
            isFollowingTail: $isLogFollowingTail
        )
        .onAppear {
            updateDisplayState(from: currentPane)
            connectPaneLogStreamIfPossible()
        }
        .onChange(of: currentPane) { _, pane in
            updateDisplayState(from: pane)
        }
        .onChange(of: refreshHint) { _, hint in
            applyRefreshHint(hint)
        }
        .onDisappear {
            logRuntime.cancelTasks()
            paneLogService.onEvent = nil
            paneLogService.onStateChange = nil
            paneLogService.disconnect()
        }
    }

    private func updateDisplayState(from pane: Pane) {
        if pane.status != displayStatus {
            displayStatus = pane.status
        }
        if pane.reason != displayReason { displayReason = pane.reason }
        if !logRuntime.hasFreshRealtimeLogStream {
            let nextLogText = LogText.compact(pane.tail, limit: Self.realtimeLogLineLimit)
            applyIncomingLogText(nextLogText, capturedAt: pane.updatedAt)
            if pane.updatedAt >= displayUpdatedAt {
                displayUpdatedAt = pane.updatedAt
            }
        }
    }

    private func connectPaneLogStreamIfPossible() {
        guard let client = store.makeClient() else { return }
        logRuntime.reconnectTask?.cancel()
        paneLogService.onEvent = { event in
            guard event.paneId == initialPane.id else { return }
            logRuntime.hasRealtimeLogStream = true
            logRuntime.lastRealtimeLogEventAt = Date()
            applyRealtimeLogEvent(event)
        }
        paneLogService.onStateChange = { state in
            switch state {
            case .disconnected:
                logRuntime.hasRealtimeLogStream = false
                refreshLogFallbackSoon(after: 120)
                schedulePaneLogReconnect()
            case .error:
                logRuntime.hasRealtimeLogStream = false
                refreshLogFallbackSoon(after: 120)
                schedulePaneLogReconnect()
            case .connecting, .connected:
                break
            }
        }
        paneLogService.connect(with: .init(
            baseURL: client.baseURL,
            token: client.token,
            paneId: initialPane.id,
            lines: Self.realtimeLogLineLimit
        ))
    }

    private func applyRefreshHint(_ hint: PaneLogRefreshHint?) {
        guard let hint, hint.paneId == initialPane.id else { return }
        requestImmediateLogRefresh()
        let nextLogText = LogText.compact(hint.tail, limit: Self.realtimeLogLineLimit)
        guard !shouldIgnoreCommandLogHint(nextLogText) else { return }
        applyIncomingLogText(nextLogText, capturedAt: hint.capturedAt)
    }

    private func shouldIgnoreCommandLogHint(_ nextLogText: String) -> Bool {
        guard !displayLogText.isEmpty, !nextLogText.isEmpty else { return false }
        if LogText.looksOlder(nextLogText, than: displayLogText) {
            return true
        }

        let currentLineCount = LogText.lineCount(displayLogText)
        let nextLineCount = LogText.lineCount(nextLogText)
        return currentLineCount >= 420 && nextLineCount + 160 < currentLineCount
    }

    private func applyRealtimeLogEvent(_ event: PaneLogWebSocketService.Event) {
        guard event.paneId == initialPane.id else { return }
        let nextLogText = LogText.compact(event.tail, limit: Self.realtimeLogLineLimit)
        applyIncomingLogText(nextLogText, capturedAt: event.capturedAt)
    }

    private func schedulePaneLogReconnect() {
        logRuntime.reconnectTask?.cancel()
        logRuntime.reconnectTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                connectPaneLogStreamIfPossible()
            }
        }
    }

    private func refreshLogFallbackSoon(after delayMilliseconds: Int) {
        logRuntime.fallbackRefreshTask?.cancel()
        logRuntime.fallbackRefreshTask = Task {
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            guard !Task.isCancelled else { return }
            await refreshLogFallback()
        }
    }

    private func requestImmediateLogRefresh() {
        logRuntime.fallbackRefreshTask?.cancel()
        paneLogService.requestRefresh()
        if !logRuntime.hasFreshRealtimeLogStream {
            refreshLogFallbackSoon(after: 120)
            schedulePaneLogReconnect()
        }
    }

    private func refreshLogFallback() async {
        guard let response = try? await store.loadPaneContext(currentPane, lines: Self.realtimeLogLineLimit) else {
            return
        }
        guard response.paneId == initialPane.id else { return }
        let nextLogText = LogText.compact(response.tail, limit: Self.realtimeLogLineLimit)
        await MainActor.run {
            applyIncomingLogText(nextLogText, capturedAt: response.capturedAt)
        }
    }

    private func applyIncomingLogText(_ incomingLogText: String, capturedAt: Date, force: Bool = false) {
        if !force, incomingLogText.isEmpty, !displayLogText.isEmpty {
            return
        }
        applyLogText(incomingLogText, capturedAt: capturedAt, force: force)
    }

    private func applyLogText(_ nextLogText: String, capturedAt: Date, force: Bool = false) {
        let textChanged = nextLogText != displayLogText

        if !textChanged {
            return
        }

        if !force, capturedAt < logRuntime.latestLogCapturedAt {
            guard LogText.looksNewer(nextLogText, than: displayLogText) else {
                return
            }
        }

        if capturedAt > logRuntime.latestLogCapturedAt {
            logRuntime.latestLogCapturedAt = capturedAt
        }
        if capturedAt >= displayUpdatedAt, displayUpdatedAt != capturedAt {
            displayUpdatedAt = capturedAt
        }

        let shouldFollowTail = force || (isLogFollowingTail && !isLogUserScrolling)
        displayLogText = nextLogText
        if shouldFollowTail {
            followTailRequest &+= 1
        }
    }
}

@MainActor
private final class PaneRealtimeLogRuntime {
    var hasRealtimeLogStream = false
    var lastRealtimeLogEventAt = Date.distantPast
    var latestLogCapturedAt: Date
    var reconnectTask: Task<Void, Never>?
    var fallbackRefreshTask: Task<Void, Never>?

    init(latestLogCapturedAt: Date) {
        self.latestLogCapturedAt = latestLogCapturedAt
    }

    var hasFreshRealtimeLogStream: Bool {
        hasRealtimeLogStream && Date().timeIntervalSince(lastRealtimeLogEventAt) < 4
    }

    func cancelTasks() {
        reconnectTask?.cancel()
        fallbackRefreshTask?.cancel()
        reconnectTask = nil
        fallbackRefreshTask = nil
    }
}

private struct RealtimeLogPanel: View {
    let status: PaneStatus
    let reason: String
    let logText: String
    let followTailRequest: Int
    @Binding var isUserScrolling: Bool
    @Binding var isFollowingTail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)

                Text(status.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(statusColor(status))

                if !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.56))
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(red: 0.055, green: 0.055, blue: 0.06))

            TerminalLogTextView(
                text: logText,
                deferUpdatesWhileAwayFromTail: true,
                followTailRequest: followTailRequest,
                isUserScrolling: $isUserScrolling,
                isFollowingTail: $isFollowingTail
            )
                .contextMenu {
                    Button {
                        copyToPasteboard(logText)
                    } label: {
                        Label("Copy Visible Log", systemImage: "doc.on.doc")
                    }
                }
                .overlay(alignment: .topLeading) {
                    if logText.isEmpty {
                        Text("No runtime output yet.")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.46))
                            .padding(12)
                            .allowsHitTesting(false)
                    }
            }
            .background(Color.black)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

@MainActor
private enum LogPanelDiagnostics {
    private static var lastLoggedAt = Date.distantPast
    private static var skippedCount = 0

    static func logApply(mode: String, characters: Int, forceBottom: Bool, nearBottom: Bool) {
        #if DEBUG
        let now = Date()
        if mode == "append" || mode == "replace" || now.timeIntervalSince(lastLoggedAt) > 1.0 {
            let skippedSuffix = skippedCount > 0 ? " skipped=\(skippedCount)" : ""
            print("[LogPanelTiming] mode=\(mode) chars=\(characters) forceBottom=\(forceBottom) nearBottom=\(nearBottom)\(skippedSuffix)")
            lastLoggedAt = now
            skippedCount = 0
        } else {
            skippedCount += 1
        }
        #endif
    }
}

private struct TerminalLogTextView: UIViewRepresentable {
    let text: String
    let deferUpdatesWhileAwayFromTail: Bool
    let followTailRequest: Int
    @Binding var isUserScrolling: Bool
    @Binding var isFollowingTail: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .black
        textView.textColor = UIColor(red: 0.82, green: 0.95, blue: 0.82, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 14, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.adjustsFontForContentSizeCategory = false
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.isUserScrolling = $isUserScrolling
        context.coordinator.isFollowingTail = $isFollowingTail
        context.coordinator.deferUpdatesWhileAwayFromTail = deferUpdatesWhileAwayFromTail
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.isUserScrolling = $isUserScrolling
        context.coordinator.isFollowingTail = $isFollowingTail
        context.coordinator.deferUpdatesWhileAwayFromTail = deferUpdatesWhileAwayFromTail
        context.coordinator.followTailRequest = followTailRequest

        if context.coordinator.didAppear == false {
            context.coordinator.applyText(text, to: textView, forceBottom: true)
            context.coordinator.didAppear = true
            return
        }

        if context.coordinator.lastFollowTailRequest == nil {
            context.coordinator.lastFollowTailRequest = followTailRequest
        }

        if followTailRequest != context.coordinator.lastFollowTailRequest {
            context.coordinator.lastFollowTailRequest = followTailRequest
            if context.coordinator.isUserInteracting(with: textView) {
                if text != context.coordinator.lastAppliedText {
                    context.coordinator.queueIncomingText(text, to: textView)
                }
            } else {
                context.coordinator.applyText(text, to: textView, forceBottom: true)
            }
        } else if text != context.coordinator.lastAppliedText {
            if context.coordinator.shouldDeferIncomingText(for: textView) {
                context.coordinator.queueIncomingText(text, to: textView)
            } else {
                context.coordinator.applyText(text, to: textView)
            }
        } else {
            context.coordinator.updateFollowingState(for: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private static let postScrollUpdateDelay: TimeInterval = 0.32
        private static let awayFromTailCoalesceDelay: TimeInterval = 0.7
        var didAppear = false
        var isTrackingUserScroll = false
        var isUserScrolling: Binding<Bool>?
        var isFollowingTail: Binding<Bool>?
        var deferUpdatesWhileAwayFromTail = false
        var followTailRequest = 0
        var lastFollowTailRequest: Int?
        var lastAppliedText = ""
        var pendingText: String?
        var deferIncomingTextUntil = Date.distantPast
        var pendingApplyTask: Task<Void, Never>?
        private var isApplyingProgrammaticUpdate = false
        weak var textView: UITextView?

        deinit {
            pendingApplyTask?.cancel()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pendingApplyTask?.cancel()
            setUserScrolling(true)
            updateFollowingState(for: scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isApplyingProgrammaticUpdate else { return }
            updateFollowingState(for: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                finishUserScroll()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishUserScroll()
        }

        func isUserInteracting(with scrollView: UIScrollView) -> Bool {
            scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating || isTrackingUserScroll
        }

        func applyText(_ text: String, to textView: UITextView, forceBottom: Bool = false) {
            if text == lastAppliedText {
                if forceBottom {
                    performProgrammaticUpdate {
                        textView.layoutIfNeeded()
                        textView.scrollToBottom(animated: false)
                    }
                }
                pendingText = nil
                updateFollowingState(for: textView)
                return
            }

            let shouldStickToBottom = forceBottom || textView.isNearBottom
            let previousOffset = textView.contentOffset
            let previousContentHeight = textView.contentSize.height
            let visibleAnchor = shouldStickToBottom ? nil : textView.visibleTextAnchor()
            let appendDelta = appendedSuffix(from: lastAppliedText, to: text)
            let slideDelta = slidingWindowDelta(from: lastAppliedText, to: text)
            let replaceMode = shouldReplaceVisibleWindow(from: lastAppliedText, to: text)
            let canAppendText = !replaceMode && !appendDelta.isEmpty && textView.text == lastAppliedText
            let canSlideText = !replaceMode && slideDelta != nil && textView.text == lastAppliedText
            let updateMode = canAppendText ? "append" : canSlideText ? "slide" : replaceMode ? "replace" : "patch"

            performProgrammaticUpdate {
                if canAppendText {
                    appendText(appendDelta, to: textView)
                } else if let slideDelta, canSlideText {
                    slideWindow(using: slideDelta, in: textView)
                } else if replaceMode {
                    textView.textStorage.setAttributedString(attributedLogString(text, for: textView))
                } else {
                    patchText(from: lastAppliedText, to: text, in: textView)
                }
                textView.layoutIfNeeded()
                if shouldStickToBottom {
                    textView.scrollToBottom(animated: false)
                } else if let visibleAnchor {
                    textView.restoreVisibleTextAnchor(visibleAnchor)
                } else {
                    textView.restoreContentAnchor(previousOffset, previousContentHeight: previousContentHeight)
                }
            }

            if !shouldStickToBottom {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.performProgrammaticUpdate {
                        if let visibleAnchor {
                            textView.restoreVisibleTextAnchor(visibleAnchor)
                        } else {
                            textView.restoreContentAnchor(previousOffset, previousContentHeight: previousContentHeight)
                        }
                    }
                }
            }

            lastAppliedText = text
            pendingText = nil
            updateFollowingState(for: textView)
            LogPanelDiagnostics.logApply(mode: updateMode, characters: text.count, forceBottom: forceBottom, nearBottom: textView.isNearBottom)
        }

        private func performProgrammaticUpdate(_ updates: () -> Void) {
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = false }
            UIView.performWithoutAnimation(updates)
        }

        private func appendText(_ text: String, to textView: UITextView) {
            guard !text.isEmpty else { return }
            textView.textStorage.append(attributedLogString(text, for: textView))
        }

        private func patchText(from previousText: String, to nextText: String, in textView: UITextView) {
            guard textView.text == previousText, !previousText.isEmpty else {
                textView.textStorage.setAttributedString(attributedLogString(nextText, for: textView))
                return
            }

            let diff = diffRange(from: previousText, to: nextText)
            textView.textStorage.beginEditing()
            textView.textStorage.replaceCharacters(
                in: diff.range,
                with: attributedLogString(diff.replacement, for: textView)
            )
            textView.textStorage.endEditing()
        }

        private func attributedLogString(_ text: String, for textView: UITextView) -> NSAttributedString {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: textView.textColor ?? UIColor(red: 0.82, green: 0.95, blue: 0.82, alpha: 1)
            ]
            return NSAttributedString(string: text, attributes: attributes)
        }

        private func appendedSuffix(from previousText: String, to nextText: String) -> String {
            guard !previousText.isEmpty, nextText.hasPrefix(previousText) else { return "" }
            return String(nextText.dropFirst(previousText.count))
        }

        private func slidingWindowDelta(from previousText: String, to nextText: String) -> (removeLength: Int, appendText: String)? {
            guard !previousText.isEmpty, !nextText.isEmpty else { return nil }
            let previousLines = previousText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let nextLines = nextText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard previousLines.count > 40, nextLines.count > 40 else { return nil }

            let overlap = LogText.suffixPrefixOverlap(previousLines, nextLines)
            let minimumOverlap = min(previousLines.count, nextLines.count) * 2 / 3
            guard overlap >= minimumOverlap,
                  overlap < previousLines.count,
                  overlap < nextLines.count
            else { return nil }

            let removedLineCount = previousLines.count - overlap
            let removedPrefix = previousLines.prefix(removedLineCount).joined(separator: "\n")
            var removeLength = removedPrefix.utf16.count
            if previousLines.count > removedLineCount {
                removeLength += 1
            }

            let appendedLines = nextLines.dropFirst(overlap)
            guard !appendedLines.isEmpty else { return nil }
            return (removeLength, "\n" + appendedLines.joined(separator: "\n"))
        }

        private func slideWindow(using delta: (removeLength: Int, appendText: String), in textView: UITextView) {
            textView.textStorage.beginEditing()
            textView.textStorage.deleteCharacters(in: NSRange(location: 0, length: min(delta.removeLength, textView.textStorage.length)))
            textView.textStorage.append(attributedLogString(delta.appendText, for: textView))
            textView.textStorage.endEditing()
        }

        private func shouldReplaceVisibleWindow(from previousText: String, to nextText: String) -> Bool {
            guard !previousText.isEmpty, !nextText.isEmpty else { return false }
            if nextText.hasPrefix(previousText) || previousText.hasPrefix(nextText) {
                return false
            }

            let previousLines = previousText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let nextLines = nextText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !previousLines.isEmpty, !nextLines.isEmpty else { return true }

            let sharedPrefix = commonPrefixLineCount(previousLines, nextLines)
            let sharedSuffix = LogText.suffixPrefixOverlap(previousLines, nextLines)
            let lineDelta = abs(previousLines.count - nextLines.count)
            let nextTailMatches = nextLines.suffix(min(12, previousLines.count)).elementsEqual(previousLines.suffix(min(12, nextLines.count)))
            let previousTailMatches = previousLines.suffix(min(12, nextLines.count)).elementsEqual(nextLines.suffix(min(12, previousLines.count)))

            return sharedPrefix < 2 &&
                sharedSuffix == 0 &&
                lineDelta > 24 &&
                !nextTailMatches &&
                !previousTailMatches
        }

        private func commonPrefixLineCount(_ lhs: [String], _ rhs: [String]) -> Int {
            let limit = min(lhs.count, rhs.count)
            var count = 0
            while count < limit, lhs[count] == rhs[count] {
                count += 1
            }
            return count
        }

        private func diffRange(from previousText: String, to nextText: String) -> (range: NSRange, replacement: String) {
            var previousStart = previousText.startIndex
            var nextStart = nextText.startIndex

            while previousStart < previousText.endIndex,
                  nextStart < nextText.endIndex,
                  previousText[previousStart] == nextText[nextStart] {
                previousText.formIndex(after: &previousStart)
                nextText.formIndex(after: &nextStart)
            }

            var previousEnd = previousText.endIndex
            var nextEnd = nextText.endIndex
            while previousStart < previousEnd,
                  nextStart < nextEnd {
                let previousBeforeEnd = previousText.index(before: previousEnd)
                let nextBeforeEnd = nextText.index(before: nextEnd)
                guard previousText[previousBeforeEnd] == nextText[nextBeforeEnd] else {
                    break
                }
                previousEnd = previousBeforeEnd
                nextEnd = nextBeforeEnd
            }

            let location = previousText[..<previousStart].utf16.count
            let length = previousText[previousStart..<previousEnd].utf16.count
            return (
                NSRange(location: location, length: length),
                String(nextText[nextStart..<nextEnd])
            )
        }

        func cancelPendingTextApply() {
            pendingApplyTask?.cancel()
            pendingApplyTask = nil
        }

        func shouldDeferIncomingText(for textView: UITextView) -> Bool {
            return isUserInteracting(with: textView)
                || Date() < deferIncomingTextUntil
                || (deferUpdatesWhileAwayFromTail && !textView.isNearBottom)
        }

        func queueIncomingText(_ text: String, to textView: UITextView) {
            pendingText = text
            LogPanelDiagnostics.logApply(mode: "defer", characters: text.count, forceBottom: false, nearBottom: textView.isNearBottom)
            if !isUserInteracting(with: textView) {
                if deferUpdatesWhileAwayFromTail && !textView.isNearBottom {
                    deferIncomingTextUntil = maxDate(
                        deferIncomingTextUntil,
                        Date().addingTimeInterval(Self.awayFromTailCoalesceDelay)
                    )
                }
                schedulePendingTextApply(to: textView)
            }
        }

        func updateFollowingState(for scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            let following = textView.isNearBottom
            if isFollowingTail?.wrappedValue != following {
                isFollowingTail?.wrappedValue = following
            }
            if following, pendingText != nil, !isUserInteracting(with: textView) {
                schedulePendingTextApply(to: textView)
            }
        }

        private func finishUserScroll() {
            guard let textView else { return }
            deferIncomingTextUntil = Date().addingTimeInterval(Self.postScrollUpdateDelay)
            updateFollowingState(for: textView)
            defer { setUserScrolling(false) }
            if pendingText != nil {
                schedulePendingTextApply(to: textView)
            }
        }

        private func schedulePendingTextApply(to textView: UITextView) {
            pendingApplyTask?.cancel()
            let delayMilliseconds = max(0, Int(ceil(deferIncomingTextUntil.timeIntervalSinceNow * 1_000)))
            pendingApplyTask = Task { [weak self, weak textView] in
                if delayMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, let textView else { return }
                    self.applyPendingTextIfIdle(to: textView)
                }
            }
        }

        private func applyPendingTextIfIdle(to textView: UITextView) {
            guard !isUserInteracting(with: textView), Date() >= deferIncomingTextUntil else {
                schedulePendingTextApply(to: textView)
                return
            }

            guard let pendingText else { return }
            applyText(pendingText, to: textView)
        }

        private func setUserScrolling(_ scrolling: Bool) {
            guard isTrackingUserScroll != scrolling else { return }
            isTrackingUserScroll = scrolling
            isUserScrolling?.wrappedValue = scrolling
        }

        private func maxDate(_ lhs: Date, _ rhs: Date) -> Date {
            lhs >= rhs ? lhs : rhs
        }
    }
}

private struct TerminalLogTextAnchor {
    let line: String
    let characterOffset: Int
}

private extension Character {
    var isLogSeparator: Bool {
        "-─━═—–_=".contains(self)
    }
}

private extension String {
    func trimmingTrailingWhitespaceAndNewlines() -> String {
        var result = self
        while let last = result.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            result.removeLast()
        }
        return result
    }
}

private extension UITextView {
	    var isNearBottom: Bool {
	        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
	        guard visibleHeight > 0 else { return true }
	        let maxOffsetY = max(-adjustedContentInset.top, contentSize.height - visibleHeight + adjustedContentInset.bottom)
	        return contentOffset.y >= maxOffsetY - 96
	    }

    var isAtBottom: Bool {
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        guard visibleHeight > 0 else { return true }
        let maxOffsetY = max(-adjustedContentInset.top, contentSize.height - visibleHeight + adjustedContentInset.bottom)
        return contentOffset.y >= maxOffsetY - 4
    }

    func scrollToBottom(animated: Bool) {
        layoutIfNeeded()
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        let maxOffsetY = max(-adjustedContentInset.top, contentSize.height - visibleHeight + adjustedContentInset.bottom)
        setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: animated)
    }

    func restoreContentOffset(_ offset: CGPoint) {
        layoutIfNeeded()
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        let maxOffsetY = max(-adjustedContentInset.top, contentSize.height - visibleHeight + adjustedContentInset.bottom)
        let y = min(max(offset.y, -adjustedContentInset.top), maxOffsetY)
        setContentOffset(CGPoint(x: offset.x, y: y), animated: false)
    }

    func restoreContentAnchor(_ offset: CGPoint, previousContentHeight: CGFloat) {
        layoutIfNeeded()
        let heightDelta = contentSize.height - previousContentHeight
        restoreContentOffset(CGPoint(x: offset.x, y: offset.y + max(heightDelta, 0)))
    }

    func visibleTextAnchor() -> TerminalLogTextAnchor? {
        layoutIfNeeded()
        let point = CGPoint(x: textContainerInset.left + 2, y: contentOffset.y + adjustedContentInset.top + textContainerInset.top + 2)
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length else { return nil }

        let fullText = textStorage.string as NSString
        let lineRange = fullText.lineRange(for: NSRange(location: characterIndex, length: 0))
        let line = fullText.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : TerminalLogTextAnchor(line: line, characterOffset: lineRange.location)
    }

    func restoreVisibleTextAnchor(_ anchor: TerminalLogTextAnchor) {
        layoutIfNeeded()
        let fullText = textStorage.string as NSString
        let range = rangeForVisibleAnchor(anchor, in: fullText)
        guard range.location != NSNotFound else { return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 0), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let y = rect.origin.y - adjustedContentInset.top - textContainerInset.top - 2
        restoreContentOffset(CGPoint(x: contentOffset.x, y: y))
    }

    private func rangeForVisibleAnchor(_ anchor: TerminalLogTextAnchor, in fullText: NSString) -> NSRange {
        guard fullText.length > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }

        let preferredLocation = min(max(anchor.characterOffset, 0), fullText.length - 1)
        let nearbyStart = max(0, preferredLocation - 20_000)
        let nearbyEnd = min(fullText.length, preferredLocation + 20_000)
        let nearbyRange = NSRange(location: nearbyStart, length: nearbyEnd - nearbyStart)
        let nearbyMatch = fullText.range(of: anchor.line, options: [], range: nearbyRange)
        if nearbyMatch.location != NSNotFound {
            return nearbyMatch
        }

        return fullText.range(of: anchor.line, options: [], range: NSRange(location: 0, length: fullText.length))
    }
}

private struct PaneActionIdentity: Equatable {
    let id: String
    let session: String
    let command: String
    let title: String
}

private extension Pane {
    var identityForActions: PaneActionIdentity {
        PaneActionIdentity(id: id, session: session, command: command, title: title)
    }
}

private enum LogText {
    static func compact(_ tail: String, limit: Int) -> String {
        var lines: [String] = []
        var previousWasBlank = false
        var skipPermissionContinuation = false

        for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let line = normalize(String(rawLine), skipPermissionContinuation: &skipPermissionContinuation) else {
                continue
            }

            if line.isEmpty {
                if !previousWasBlank && !lines.isEmpty {
                    lines.append("")
                    previousWasBlank = true
                }
                continue
            }

            previousWasBlank = false
            if lines.last != line {
                lines.append(line)
            }
        }

        return lines.suffix(limit).joined(separator: "\n").trimmingTrailingWhitespaceAndNewlines()
    }

    static func looksNewer(_ candidate: String, than current: String) -> Bool {
        guard candidate != current else { return false }
        guard !candidate.isEmpty else { return false }
        if current.isEmpty { return true }
        if candidate.hasPrefix(current) {
            return true
        }
        if current.contains(candidate) {
            return false
        }
        if candidate.contains(current) {
            return !candidate.hasSuffix(current)
        }

        let currentTail = comparableTail(from: current)
        let candidateTail = comparableTail(from: candidate)
        if !currentTail.isEmpty, candidate.contains(currentTail) {
            return !candidate.hasSuffix(currentTail)
        }
        if !candidateTail.isEmpty, current.contains(candidateTail) {
            return false
        }

        return candidate.count >= current.count
    }

    static func looksOlder(_ candidate: String, than current: String) -> Bool {
        guard candidate != current else { return false }
        guard !candidate.isEmpty, !current.isEmpty else { return false }
        if current.hasPrefix(candidate) || current.contains(candidate) {
            return true
        }

        let candidateTail = comparableTail(from: candidate)
        return !candidateTail.isEmpty && current.contains(candidateTail)
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    static func mergedWindow(current: String, incoming: String, limit: Int) -> String {
        guard !current.isEmpty, !incoming.isEmpty else { return incoming.isEmpty ? current : incoming }
        if current == incoming || current.contains(incoming) {
            return current
        }
        if incoming.contains(current) || incoming.hasPrefix(current) {
            return incoming
        }

        let currentLines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let incomingLines = incoming.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let overlap = suffixPrefixOverlap(currentLines, incomingLines)
        guard overlap > 0 else { return incoming }

        return (currentLines + incomingLines.dropFirst(overlap))
            .suffix(limit)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clean(_ line: String) -> String {
        let value = line
            .replacingOccurrences(of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .trimmingTrailingWhitespaceAndNewlines()

        var promptValue = value.trimmingCharacters(in: .whitespaces)
        while let first = promptValue.first,
              "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(first) {
            promptValue.removeFirst()
            promptValue = promptValue.trimmingCharacters(in: .whitespaces)
        }

        if promptValue == "›" || promptValue == "❯" {
            return ""
        }
        if promptValue.hasPrefix("›") || promptValue.hasPrefix("❯") {
            promptValue.removeFirst()
            return promptValue.trimmingCharacters(in: .whitespaces)
        }

        return value
    }

    private static func normalize(_ line: String, skipPermissionContinuation: inout Bool) -> String? {
        var value = clean(line)

        if skipPermissionContinuation {
            let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
            skipPermissionContinuation = false
            if lower == "to cycle)" || lower.contains("shift+tab") || lower.contains("bypass permissions") {
                return nil
            }
        }

        let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("-- insert") ||
            lower.hasPrefix("-- normal") ||
            lower.hasPrefix("-- visual") ||
            lower.hasPrefix("-- replace") {
            skipPermissionContinuation = lower.contains("shift+tab") ||
                lower.contains("to cycle") ||
                lower.contains("bypass permissions")
            return nil
        }
        if lower.contains("bypass permissions") && lower.contains("shift+tab") {
            return nil
        }

        guard let normalized = normalizeSeparatorLine(value) else {
            return nil
        }
        value = normalized

        return value
    }

    private static func normalizeSeparatorLine(_ line: String) -> String? {
        guard !isSeparatorOnly(line) else { return nil }

        let value = removeTrailingSeparatorRun(
            from: removeLeadingSeparatorRun(from: line)
        ).trimmingTrailingWhitespaceAndNewlines()

        return value.isEmpty ? nil : value
    }

    private static func isSeparatorOnly(_ line: String) -> Bool {
        line.allSatisfy { character in
            character.isLogSeparator ||
                character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
    }

    private static func removeLeadingSeparatorRun(from line: String) -> String {
        var index = line.startIndex
        var separatorCount = 0

        while index < line.endIndex {
            let character = line[index]
            if character.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
                line.formIndex(after: &index)
                continue
            }
            guard character.isLogSeparator else { break }
            separatorCount += 1
            line.formIndex(after: &index)
        }

        guard separatorCount >= 8 else { return line }
        return String(line[index...]).trimmingCharacters(in: .whitespaces)
    }

    private static func removeTrailingSeparatorRun(from line: String) -> String {
        var index = line.endIndex
        var separatorCount = 0

        while index > line.startIndex {
            let previous = line.index(before: index)
            let character = line[previous]
            if character.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
                index = previous
                continue
            }
            guard character.isLogSeparator else { break }
            separatorCount += 1
            index = previous
        }

        guard separatorCount >= 8 else { return line }
        return String(line[..<index]).trimmingTrailingWhitespaceAndNewlines()
    }

    private static func comparableTail(from text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(24)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func suffixPrefixOverlap(_ currentLines: [String], _ incomingLines: [String]) -> Int {
        let maxOverlap = min(currentLines.count, incomingLines.count)
        guard maxOverlap > 0 else { return 0 }

        for count in stride(from: maxOverlap, through: 1, by: -1) {
            if currentLines.suffix(count).elementsEqual(incomingLines.prefix(count)) {
                return count
            }
        }

        return 0
    }
}

// MARK: - Conversation Header

private struct ConversationStatusLine: View {
    let session: String
    let status: PaneStatus
    let isLiveServer: Bool
    let sourceAgent: String?
    let hasTranscript: Bool

    private var agentLabel: String {
        if sourceAgent == "claude" { return "Claude Code" }
        if sourceAgent == "codex" { return "Codex" }
        if session.hasPrefix("cc_") { return "Claude Code" }
        if session.hasPrefix("cx_") { return "Codex" }
        return "Agent"
    }

    private var stateTitle: String {
        switch status {
        case .running: return "Working"
        case .waiting: return "Needs input"
        case .idle: return "Ready"
        case .failed: return "Needs follow-up"
        case .done: return "Done"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(session: session, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(agentLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                HStack(spacing: 5) {
                    Text(isLiveServer ? "Live status" : "Snapshot")
                    if hasTranscript {
                        Text("transcript")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 7, height: 7)
                Text(isLiveServer ? stateTitle : "Snapshot")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isLiveServer ? statusColor(status) : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((isLiveServer ? statusColor(status) : Color.secondary).opacity(0.10), in: Capsule())
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}

// MARK: - Chat Messages

private struct UserInteractionMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let sentAt: Date

    var eventMatchId: String {
        normalizedEventMatchText(text)
    }
}

private struct AgentMessageBubble: View {
    let session: String
    let status: PaneStatus
    let kind: InteractionMessageKind?
    let title: String?
    let message: String
    var actions: [InteractionAction]?
    var actionsEnabled = true
    var onOpenTerminal: () -> Void
    var onSendAction: (String) async -> Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(session: session, size: 36)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                    Text(title?.isEmpty == false ? title! : status.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(tint)
                }

                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !visibleActions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(visibleActions.enumerated()), id: \.offset) { _, action in
                                Button {
                                    perform(action)
                                } label: {
                                    Text(action.label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(action.style == .destructive ? .red : .accentColor)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .frame(minHeight: 36)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(!actionsEnabled)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer(minLength: 28)
        }
    }

    private var tint: Color {
        kind == .summary ? .secondary : statusColor(status)
    }

    private var visibleActions: [InteractionAction] {
        (actions ?? []).filter { $0.payload != "open_long_context" }
    }

    private func perform(_ action: InteractionAction) {
        guard actionsEnabled else {
            Haptics.sent(success: false)
            return
        }
        switch action.payload {
        case "open_terminal":
            onOpenTerminal()
            Haptics.sent(success: true)
        default:
            Task {
                let sent = await onSendAction(action.payload)
                await MainActor.run {
                    Haptics.sent(success: sent)
                }
            }
        }
    }
}

private struct TranscriptAgentBubble: View {
    let session: String
    let status: PaneStatus
    let event: AgentEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(session: session, size: event.kind == .text ? 36 : 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(tint)
                    Text(event.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(tint)
                        .lineLimit(1)
                }

                Text(event.body)
                    .font(.system(size: event.kind == .text ? 15 : 13))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, event.kind == .text ? 14 : 12)
            .padding(.vertical, event.kind == .text ? 12 : 9)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer(minLength: 28)
        }
    }

    private var tint: Color {
        switch event.kind {
        case .toolCall:
            return .blue
        case .toolResult:
            return event.status == "error" ? .red : .secondary
        case .turn, .status:
            return statusColor(status)
        case .text:
            return statusColor(status)
        }
    }

    private var background: Color {
        switch event.kind {
        case .toolCall, .toolResult:
            return Color(.secondarySystemBackground)
        default:
            return Color(.systemBackground)
        }
    }

    private var iconName: String {
        switch event.kind {
        case .toolCall: "terminal"
        case .toolResult: event.status == "error" ? "exclamationmark.triangle" : "checkmark.circle"
        case .turn: "arrow.triangle.2.circlepath"
        case .status: "info.circle"
        case .text: "message"
        }
    }
}

private struct TranscriptToolEventRow: View {
    let event: AgentEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                    .lineLimit(1)

                if !event.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(event.body)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(event.status == "error" ? 6 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 46)
        .padding(.trailing, 18)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        if event.status == "error" {
            return .red
        }
        switch event.kind {
        case .toolCall:
            return .secondary
        case .toolResult:
            return .green
        default:
            return .secondary
        }
    }

    private var iconName: String {
        switch event.kind {
        case .toolCall:
            return "terminal"
        case .toolResult:
            return event.status == "error" ? "exclamationmark.triangle" : "checkmark.circle"
        default:
            return "info.circle"
        }
    }
}

private struct TranscriptUserBubble: View {
    let event: AgentEvent

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 44)

            VStack(alignment: .trailing, spacing: 5) {
                Text(event.body)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct TranscriptSystemEventRow: View {
    let event: AgentEvent

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 5, height: 5)
                Text(systemText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            Spacer()
        }
    }

    private var systemText: String {
        event.body.isEmpty ? event.title : "\(event.title) · \(event.body)"
    }
}

private struct UserMessageBubble: View {
    let message: UserInteractionMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 44)

            VStack(alignment: .trailing, spacing: 5) {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct ChatTimeDivider: View {
    let date: Date

    var body: some View {
        HStack {
            Spacer()
            Text(ChatTimeFormatter.dividerText(for: date))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private enum ChatTimeFormatter {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func dividerText(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(timeFormatter.string(from: date))"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return dayFormatter.string(from: date)
        }
        return yearFormatter.string(from: date)
    }
}

private enum AgentPromptText {
    static func extract(from tail: String) -> String {
        for line in LocalSummary.cleanLines(from: tail, limit: 80).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isMeaningfulLine(trimmed) {
                return String(trimmed)
            }
        }
        return ""
    }

    static func isMeaningfulLine(_ line: String) -> Bool {
        if line.isEmpty { return false }
        if line.allSatisfy({ "─━═— ".contains($0) }) { return false }
        if line.hasPrefix("--") { return false }
        if line.first.map({ (0x2800...0x28FF).contains($0.unicodeScalars.first?.value ?? 0) }) == true { return false }
        if isLowInformationLine(line) { return false }
        return true
    }

    static func isLowInformationLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower == "i" { return true }
        if lower.contains("esc to interrupt") { return true }
        if lower.contains("tab to queue message") { return true }
        if lower.contains("context left") || lower.contains("context used") { return true }
        if lower.contains("working (") || lower.contains("thinking (") || lower.contains("running (") { return true }
        if lower.hasPrefix("latest checkpoint: tab to queue message") { return true }
        if lower.hasPrefix("working on ") && lower.split(separator: " ").count <= 4 { return true }
        return false
    }
}

private extension AgentEvent {
    var localMatchId: String {
        normalizedEventMatchText(body)
    }
}

private func normalizedEventMatchText(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

private enum LocalSummary {
    static func liveActivity(from tail: String) -> [String] {
        meaningfulLines(from: tail, limit: 5)
            .map(shortLine)
    }

    static func displayBody(
        for message: InteractionMessage,
        status: PaneStatus,
        title: String,
        reason: String,
        tail: String,
        latestUserMessage: String?
    ) -> String? {
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if !isLowValueMessage(body, title: title) {
            return body
        }

        switch message.kind {
        case .summary:
            return recentWork(from: tail, latestUserMessage: latestUserMessage)
        case .progress, .status:
            return currentState(status: status, title: title, reason: reason, tail: tail, latestUserMessage: latestUserMessage)
        case .notification:
            return feedback(status: status, title: title, reason: reason, tail: tail)
        case .question, .permissionRequest, .error, .done:
            let fallback = currentState(status: status, title: title, reason: reason, tail: tail, latestUserMessage: latestUserMessage)
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fallback
        }
    }

    static func recentWork(from tail: String, latestUserMessage: String? = nil) -> String {
        if let request = latestUserRequest(latestUserMessage) {
            return "User asked: \(request)"
        }

        let keywordLines = meaningfulLines(from: tail, limit: 32)
            .filter { line in
                let lower = line.lowercased()
                return [
                    "succeeded", "passed", "finished", "completed", "done", "fixed",
                    "updated", "created", "generated", "built", "compiled", "checked",
                    "installed", "launched", "failed", "error", "bug", "issue", "problem",
                    "warning", "修", "改", "问题", "不合理", "详情", "列表", "展示",
                    "实现", "添加", "删除", "切换"
                ].contains { lower.contains($0) }
            }
            .suffix(4)
            .map(shortLine)

        let lines = keywordLines.isEmpty
            ? meaningfulLines(from: tail, limit: 4).suffix(4).map(shortLine)
            : keywordLines

        if lines.isEmpty {
            return "No recent work has been captured yet."
        }

        return lines.map { "- \($0)" }.joined(separator: "\n")
    }

    static func currentState(status: PaneStatus, title: String, reason: String, tail: String, latestUserMessage: String? = nil) -> String {
        switch status {
        case .running:
            if let actionable = actionableLine(from: tail) {
                return "Working through: \(actionable)"
            }
            if let request = latestUserRequest(latestUserMessage) {
                return "Working through your request: \(request)"
            }
            return reason.isEmpty ? "Working on the current task." : reason
        case .waiting:
            let prompt = AgentPromptText.extract(from: tail)
            return prompt.isEmpty ? "Waiting for your input before it can continue." : prompt
        case .idle:
            return reason.isEmpty ? "Idle and ready for a new instruction." : reason
        case .failed:
            return reason.isEmpty ? "The last phase needs attention." : reason
        case .done:
            return reason.isEmpty ? "Recent work is complete." : reason
        }
    }

    static func feedbackTitle(status: PaneStatus) -> String {
        switch status {
        case .running: "Phase feedback"
        case .waiting: "Blocked"
        case .idle: "Ready"
        case .failed: "Needs follow-up"
        case .done: "Ready for next instruction"
        }
    }

    static func feedback(status: PaneStatus, title: String, reason: String, tail: String) -> String {
        switch status {
        case .running:
            let latest = actionableLine(from: tail) ?? meaningfulLines(from: tail, limit: 1).last
            return latest.map { "Latest checkpoint: \($0)" }
                ?? "The agent is still working. Feedback will update when the next checkpoint appears."
        case .waiting:
            return "The agent is waiting for your reply before it can continue."
        case .idle:
            return "No active work is running. Send a new instruction below when you want the agent to continue."
        case .failed:
            return reason.isEmpty ? "The last phase needs attention before work can continue." : reason
        case .done:
            return "Recent work appears complete. You can send a follow-up instruction below."
        }
    }

    static func cleanLines(from tail: String, limit: Int) -> [String] {
        var lines: [String] = []
        for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = cleanDisplayLine(String(rawLine))
                .replacingOccurrences(of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if lines.last != line {
                lines.append(line)
            }
        }
        return Array(lines.suffix(limit))
    }

    private static func meaningfulLines(from tail: String, limit: Int) -> [String] {
        cleanLines(from: tail, limit: limit)
            .filter(AgentPromptText.isMeaningfulLine)
    }

    private static func actionableLine(from tail: String) -> String? {
        meaningfulLines(from: tail, limit: 40)
            .reversed()
            .first { line in
                let lower = line.lowercased()
                return [
                    "bug", "fix", "修", "问题", "不合理", "列表", "详情", "展示",
                    "implement", "update", "change", "build", "test", "check",
                    "error", "failed", "warning", "commit"
                ].contains { lower.contains($0) }
            }
            .map(shortLine)
    }

    private static func latestUserRequest(_ message: String?) -> String? {
        guard let message else { return nil }
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return shortLine(value)
    }

    private static func isLowValueMessage(_ body: String, title: String) -> Bool {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerBody = normalizedBody.lowercased()
        let lowerTitle = title.lowercased()
        if AgentPromptText.isLowInformationLine(normalizedBody) { return true }
        if !lowerTitle.isEmpty && lowerBody == "working on \(lowerTitle)." { return true }
        if !lowerTitle.isEmpty && lowerBody == "finished \(lowerTitle)." { return true }
        if lowerBody == "working on the current task." { return true }
        if lowerBody == "latest checkpoint: tab to queue message" { return true }
        return false
    }

    private static func cleanDisplayLine(_ line: String) -> String {
        var value = line
            .replacingOccurrences(of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = value.first,
              "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("›") || value.hasPrefix("❯") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func shortLine(_ line: String) -> String {
        if line.count <= 150 { return line }
        return String(line.prefix(147)) + "..."
    }
}

private func cleanTaskTitle(_ value: String) -> String {
    var title = value
    while let first = title.unicodeScalars.first,
          (0x2800...0x28FF).contains(first.value) || first.value == 0x2733 || first == " " {
        title = String(title.unicodeScalars.dropFirst())
    }
    return title.trimmingCharacters(in: .whitespaces)
}

// MARK: - Input Bar

private struct InputBar: View {
    let pane: Pane
    let isEnabled: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(BackgroundAudioKeepAlive.self) private var backgroundAudio
    @Binding var inputText: String
    @Binding var vimMode: Bool
    @Binding var showKillConfirmation: Bool
    let onSendText: (String) async -> Bool
    let onUserMessageSent: (String) -> Void
    let onRefineText: (String) async -> String
    let onSendKey: (String) async -> Bool
    let onUploadImage: (Data) async throws -> UploadedImageResponse
    @State private var voiceInput = VoiceInputController()
    @State private var voiceRuntime = VoiceInputRuntimeState()
    @State private var voiceDisplayState = VoiceDisplayState()
    @State private var voiceOverlayRuntime = VoiceRecordingOverlayRuntime()
    @State private var isCancelingVoice = false
    @State private var isFinalizingVoice = false
    @State private var isVoicePressing = false
    @State private var inputMode: ComposerInputMode = .voice
    @State private var composerTextHeight: CGFloat = 22
    @State private var floatingDraftTextHeight: CGFloat = 44
    @State private var shouldRefineBeforeSend = false
    @State private var isGoalModeEnabled = false
    @State private var isRefiningText = false
    @State private var isSendingText = false
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var imageFeedback: ImageSendFeedback?
    @State private var isShowingDraftEditor = false
    @State private var voicePrepareTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    private var voiceStatusMessage: String? {
        if let message = voiceDisplayState.errorMessage {
            return message
        }
        if isCancelingVoice {
            return "松手取消本次语音"
        }
        if isFinalizingVoice {
            return "正在收尾，等待最后的识别结果..."
        }
        return voiceDisplayState.statusText
    }

    private var isShowingVoiceHoldPanel: Bool {
        isEnabled && inputMode == .voice && (isVoicePressing || voiceDisplayState.isActive || isFinalizingVoice)
    }

    private var isShowingFloatingTextDraft: Bool {
        isEnabled &&
            inputMode == .voice &&
            !isShowingVoiceHoldPanel &&
            !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var quickMessages: [String] {
        settings.visibleQuickActionButtons
    }

    private let quickKeys: [(String, String)] = [
        ("Enter", "Enter"),
        ("Esc", "C-["),
        ("C-c", "C-c")
    ]

    private var isLongDraft: Bool {
        inputText.count > 120 || inputText.filter(\.isNewline).count >= 2
    }

    private var composerMaxLines: Int {
        isLongDraft ? 10 : 4
    }

    private var floatingDraftMaxLines: Int {
        isLongDraft ? 12 : 8
    }

    private var canSendText: Bool {
        isEnabled && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInputBusy
    }

    private var isTextSendBusy: Bool {
        isRefiningText || isSendingText
    }

    private var isInputBusy: Bool {
        !isEnabled || isTextSendBusy || isUploadingImage
    }

    private var isShowingBottomInteractionPanel: Bool {
        isShowingVoiceHoldPanel || isShowingFloatingTextDraft
    }

    private var isVoiceInteractionActive: Bool {
        isVoicePressing || voiceDisplayState.isActive || isFinalizingVoice
    }

    var body: some View {
        normalInputStack
            .allowsHitTesting(!isShowingBottomInteractionPanel || isShowingVoiceHoldPanel)
            .overlay(alignment: .bottom) {
                bottomInteractionPanel
            }
	        .frame(maxWidth: .infinity)
	        .animation(.agentThemeChange, value: colorScheme)
        .onDisappear {
            voicePrepareTask?.cancel()
            voicePrepareTask = nil
            isVoicePressing = false
            voiceDisplayState.detach(from: voiceInput)
            voiceOverlayRuntime.hide()
            voiceRuntime.reset()
            voiceRuntime.isPressing = false
            isCancelingVoice = false
            isFinalizingVoice = false
            inputMode = .voice
            voiceInput.stop(backgroundAudio: backgroundAudio, keepTencentWarm: false)
        }
        .onAppear {
            guard isEnabled else { return }
            Haptics.prepareVoicePress()
            voiceDisplayState.attach(to: voiceInput)
            prepareVoiceInputIfIdle(force: true)
        }
        .onChange(of: isEnabled) { _, enabled in
            if enabled {
                Haptics.prepareVoicePress()
                voiceDisplayState.attach(to: voiceInput)
                prepareVoiceInputIfIdle(force: true)
            } else {
                resetVoiceInteractionState(hideOverlay: true, keepTencentWarm: false)
                voiceDisplayState.detach(from: voiceInput)
                inputMode = .voice
            }
        }
        .onChange(of: voiceDisplayState.phase) { _, _ in
            syncVoiceOverlayRuntimeFromState()
        }
        .onChange(of: selectedImageItem) { _, item in
            guard let item else { return }
            Task {
                await sendSelectedImage(item)
                selectedImageItem = nil
            }
        }
        .sheet(isPresented: $isShowingDraftEditor) {
            DraftEditorSheet(
                text: $inputText,
                isSending: isInputBusy,
                onSend: {
                    isShowingDraftEditor = false
                    sendCurrentText()
                }
            )
        }
    }

    private var normalInputStack: some View {
        VStack(spacing: 10) {
            accessoryActionTray

            composerSurface

            if !isEnabled {
                Label("Snapshot only. Switch to this machine before sending commands.", systemImage: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            } else if let message = voiceStatusMessage, !isShowingVoiceHoldPanel {
                Label(message, systemImage: voiceDisplayState.errorMessage == nil ? "waveform" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(voiceDisplayState.errorMessage == nil ? .secondary : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            if let feedback = imageFeedback {
                Label(feedback.message, systemImage: feedback.systemImage)
                    .font(.system(size: 12))
                    .foregroundColor(feedback.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var bottomInteractionPanel: some View {
        ZStack(alignment: .bottom) {
            VoiceRecordingOverlay(
                isVisible: inputMode == .voice && isShowingVoiceHoldPanel,
                isCanceling: isCancelingVoice,
                isFinalizing: isFinalizingVoice,
                isStarting: isVoicePressing || voiceDisplayState.isStarting,
                isListening: voiceDisplayState.isListening,
                pageBackgroundColor: UIColor(AgentMonitorTheme.pageBackground(for: colorScheme)),
                runtime: voiceOverlayRuntime,
                voiceInput: voiceInput
            )
            .frame(height: 190)
            .allowsHitTesting(false)

            if isShowingFloatingTextDraft {
                FloatingVoiceTextDraft(
                    text: $inputText,
                    measuredHeight: $floatingDraftTextHeight,
                    maxLines: floatingDraftMaxLines,
                    isSending: isInputBusy,
                    onCancel: clearFloatingDraft,
                    onSend: sendCurrentText
                )
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var accessoryActionTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                goalModeButton

                if pane.session.hasPrefix("cc_") {
                    Button {
                        vimMode.toggle()
                    } label: {
                        Text(vimMode ? "vim on" : "vim off")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(vimMode ? .white : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minHeight: 36)
                            .background(vimMode ? Color.accentColor : AgentMonitorTheme.softFill(for: colorScheme), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isInputBusy)
                }

                ForEach(quickMessages, id: \.self) { message in
                    Button(message) {
                        Task { await sendPresetText(message) }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .background(AgentMonitorTheme.softFill(for: colorScheme), in: Capsule())
                    .buttonStyle(.plain)
                    .disabled(isInputBusy)
                }

                ForEach(quickKeys, id: \.0) { title, key in
                    Button(title) {
                        Task { _ = await onSendKey(key) }
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .background(AgentMonitorTheme.softFill(for: colorScheme), in: Capsule())
                    .buttonStyle(.plain)
                    .disabled(isInputBusy)
                }

                Button(role: .destructive) {
                    showKillConfirmation = true
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .disabled(isInputBusy)
            }
            .padding(.horizontal, 18)
        }
    }

    private var goalModeButton: some View {
        Button {
            toggleGoalMode()
        } label: {
            Label(isGoalModeEnabled ? "Goal on" : "Goal", systemImage: "target")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isGoalModeEnabled ? .white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: 36)
                .background(
                    isGoalModeEnabled
                        ? Color.accentColor
                        : AgentMonitorTheme.softFill(for: colorScheme),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(isInputBusy)
        .accessibilityLabel(isGoalModeEnabled ? "Disable goal mode" : "Enable goal mode")
    }

    @ViewBuilder
    private var composerSurface: some View {
        switch inputMode {
        case .voice:
            voiceComposerSurface
        case .text:
            textComposerSurface
        }
    }

    private var voiceComposerSurface: some View {
        HStack(spacing: 6) {
            imagePickerButton(isUploading: isUploadingImage, isDisabled: isInputBusy || voiceDisplayState.isActive)

            if isEnabled {
                HoldToSpeakButton(
                    isActive: isVoiceInteractionActive,
                    isStarting: voiceDisplayState.isStarting || isVoicePressing,
                    isListening: voiceDisplayState.isListening,
                    isPressing: isVoicePressing,
                    isCanceling: isCancelingVoice,
                    isFinalizing: isFinalizingVoice,
                    onPressStart: { touchStartedAt in
                        beginVoiceInput(touchStartedAt: touchStartedAt)
                    },
                    onPressEnd: endVoiceInput,
                    onCancelStateChange: updateVoiceCancelVisualState,
                    onEnterCancelZone: triggerCancelZoneHaptic,
                    onPressCancel: cancelVoiceInput
                )
                .disabled(isInputBusy)
            } else {
                Label("Read only", systemImage: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }

            Button {
                toggleInputMode()
            } label: {
                ComposerIconLabel(systemImage: "keyboard", isLoading: false)
            }
            .buttonStyle(.plain)
            .disabled(isVoiceInteractionActive || isInputBusy)
            .accessibilityLabel("Switch to keyboard input")
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(AgentMonitorTheme.elevatedSurface(for: colorScheme).opacity(0.92), in: Capsule())
        .overlay(
            Capsule()
                .stroke(AgentMonitorTheme.separator(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: AgentMonitorTheme.cardShadow(for: colorScheme), radius: colorScheme == .dark ? 14 : 10, x: 0, y: 4)
        .padding(.horizontal, 18)
        .onAppear {
            guard isEnabled else { return }
            scheduleVoiceInputPrepare(force: true, after: .zero)
        }
    }

    private var textComposerSurface: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                toggleInputMode()
            } label: {
                ComposerIconLabel(systemImage: "waveform.circle", isLoading: false)
            }
            .buttonStyle(.plain)
            .disabled(isInputBusy)
            .accessibilityLabel("Switch to voice input")

            AutoScrollingComposerTextView(
                text: $inputText,
                measuredHeight: $composerTextHeight,
                maxLines: composerMaxLines,
                isEditable: isEnabled
            )
            .frame(height: composerTextHeight)
            .padding(.horizontal, 2)
            .padding(.vertical, 12)

            if isLongDraft {
                Button {
                    isShowingDraftEditor = true
                } label: {
                    ComposerIconLabel(systemImage: "arrow.up.left.and.arrow.down.right", isLoading: false)
                }
                .buttonStyle(.plain)
                .disabled(isInputBusy)
                .accessibilityLabel("Review full draft")
            }

            imagePickerButton(isUploading: isUploadingImage, isDisabled: isInputBusy || voiceDisplayState.isActive)

            Button {
                sendCurrentText()
            } label: {
                ComposerIconLabel(systemImage: "arrow.up.circle.fill", isLoading: isTextSendBusy)
                    .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray.opacity(0.38) : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!canSendText)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 52)
        .background(AgentMonitorTheme.elevatedSurface(for: colorScheme).opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AgentMonitorTheme.separator(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: AgentMonitorTheme.cardShadow(for: colorScheme), radius: colorScheme == .dark ? 14 : 10, x: 0, y: 4)
        .padding(.horizontal, 18)
    }

    private func imagePickerButton(isUploading: Bool, isDisabled: Bool) -> some View {
        PhotosPicker(selection: $selectedImageItem, matching: .images, photoLibrary: .shared()) {
            ComposerIconLabel(systemImage: "camera", isLoading: isUploading)
        }
        .disabled(isDisabled)
        .accessibilityLabel("Choose image")
    }

    private func sendCurrentText() {
        guard isEnabled else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !isInputBusy else { return }
        let needsRefinement = shouldRefineBeforeSend
        let sendsAsGoal = isGoalModeEnabled
        let restoreInputMode = inputMode
        resetVoiceInteractionState(hideOverlay: true, keepTencentWarm: false)
        inputMode = .voice
        inputText = ""
        shouldRefineBeforeSend = false
        isGoalModeEnabled = false
        isSendingText = true
        dismissKeyboard()
        Task {
            let textToSend: String
            if needsRefinement {
                await MainActor.run { isRefiningText = true }
                textToSend = await onRefineText(text)
                await MainActor.run { isRefiningText = false }
            } else {
                textToSend = text
            }

            let payload = sendsAsGoal ? goalModeText(for: textToSend) : textToSend
            let sent = await onSendText(payload)
            await MainActor.run {
                isRefiningText = false
                isSendingText = false
                Haptics.sent(success: sent)
                if !sent {
                    inputText = textToSend
                    shouldRefineBeforeSend = false
                    isGoalModeEnabled = sendsAsGoal
                    inputMode = restoreInputMode
                } else {
                    onUserMessageSent(textToSend)
                    inputMode = .voice
                    scheduleVoiceInputPrepare(after: .milliseconds(40))
                }
            }
        }
    }

    private func clearFloatingDraft() {
        resetVoiceInteractionState(hideOverlay: true)
        inputText = ""
        shouldRefineBeforeSend = false
        isGoalModeEnabled = false
        inputMode = .voice
        dismissKeyboard()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func sendPresetText(_ text: String) async {
        let shouldSend = await MainActor.run {
            guard isEnabled, !isInputBusy else { return false }
            isSendingText = true
            return true
        }
        guard shouldSend else { return }
        let sent = await onSendText(text)
        await MainActor.run {
            isSendingText = false
            Haptics.sent(success: sent)
            if sent {
                onUserMessageSent(text)
            }
        }
    }

    private func sendSelectedImage(_ item: PhotosPickerItem) async {
        guard isEnabled, !isInputBusy else { return }
        isUploadingImage = true
        setImageFeedback(.progress("正在读取图片..."))
        defer { isUploadingImage = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                setImageFeedback(.failure("无法读取这张图片"))
                Haptics.sent(success: false)
                return
            }

            setImageFeedback(.progress("正在压缩图片..."))
            guard let jpegData = await Task.detached(priority: .userInitiated, operation: {
                ImageUploadCompressor.compressedJPEGData(from: data)
            }).value else {
                setImageFeedback(.failure("图片压缩失败"))
                Haptics.sent(success: false)
                return
            }

            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(jpegData.count), countStyle: .file)
            setImageFeedback(.progress("正在上传压缩图片（\(sizeText)）..."))
            let uploaded = try await onUploadImage(jpegData)
            resetVoiceInteractionState(hideOverlay: true, keepTencentWarm: false)
            inputMode = .text
            inputText = mergedDraftText(base: inputText, addition: imagePrompt(for: uploaded.path))
            shouldRefineBeforeSend = false
            let feedback = ImageSendFeedback.success("图片已生成文字草稿，可编辑后发送（\(sizeText)）")
            setImageFeedback(feedback)
            hideImageFeedbackAfterDelay(feedback.id)
            Haptics.sent(success: true)
        } catch {
            setImageFeedback(.failure("图片发送失败：\(error.localizedDescription)"))
            Haptics.sent(success: false)
        }
    }

    private func setImageFeedback(_ feedback: ImageSendFeedback?) {
        withAnimation(.easeInOut(duration: 0.18)) {
            imageFeedback = feedback
        }
    }

    private func hideImageFeedbackAfterDelay(_ id: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                guard imageFeedback?.id == id else { return }
                setImageFeedback(nil)
            }
        }
    }

    private func toggleInputMode() {
        guard isEnabled else { return }
        if inputMode == .text {
            resetVoiceInteractionState(hideOverlay: true)
            inputMode = .voice
            dismissKeyboard()
            prepareVoiceInputIfIdle(force: true)
        } else {
            resetVoiceInteractionState(hideOverlay: true, keepTencentWarm: false)
            inputMode = .text
        }
    }

    private func toggleGoalMode() {
        guard isEnabled else { return }
        isGoalModeEnabled.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if isGoalModeEnabled {
            resetVoiceInteractionState(hideOverlay: true, keepTencentWarm: false)
            inputMode = .text
        }
    }

    private func goalModeText(for text: String) -> String {
        """
        /goal
        请使用 goal 模式，先创建一个 goal，然后持续推进直到完成或明确阻塞：

        \(text)
        """
    }

    private func syncVoiceOverlayRuntimeFromState() {
        guard inputMode == .voice else {
            voiceOverlayRuntime.hide()
            return
        }

        if isVoicePressing || voiceDisplayState.isActive || isFinalizingVoice {
            voiceOverlayRuntime.show(
                canceling: isCancelingVoice,
                finalizing: isFinalizingVoice,
                starting: voiceDisplayState.isStarting || isVoicePressing,
                listening: voiceDisplayState.isListening
            )
        } else {
            voiceOverlayRuntime.hide()
        }
    }

    @discardableResult
    private func beginVoiceInput(touchStartedAt: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard isEnabled else { return false }
        guard !voiceRuntime.isPressing else { return false }
        guard !voiceDisplayState.isActive else { return false }

        voiceRuntime.reset()
        voiceRuntime.isPressing = true
        voiceRuntime.pressStartedAt = touchStartedAt
        logVoiceTiming("press-callback")
        voicePrepareTask?.cancel()
        voicePrepareTask = nil

        guard voiceRuntime.isPressing, !voiceRuntime.hasStartedSession else { return true }
        let didStart = startVoiceInputAfterTouchFeedback()
        logVoiceTiming("press-start-returned")
        guard didStart else { return false }

        scheduleVoicePressUIAfterStart(pressStartedAt: touchStartedAt)
        return didStart
    }

    private func scheduleVoicePressUIAfterStart(pressStartedAt: CFTimeInterval) {
        DispatchQueue.main.async {
            guard voiceRuntime.pressStartedAt == pressStartedAt,
                  voiceRuntime.isPressing,
                  voiceRuntime.hasStartedSession
            else { return }

            applyVoicePressUIAfterStart(pressStartedAt: pressStartedAt)
        }
    }

    private func applyVoicePressUIAfterStart(pressStartedAt: CFTimeInterval) {
        voiceOverlayRuntime.show(
            canceling: false,
            finalizing: false,
            starting: true,
            listening: false,
            pressStartedAt: pressStartedAt
        )
        logVoiceTiming("overlay-visible-after-start")

        let shouldClearRefineBeforeSend = shouldRefineBeforeSend
        let shouldClearVoiceEndState = isFinalizingVoice || isCancelingVoice
        let needsSwiftUIPressState = !inputText.isEmpty ||
            shouldClearRefineBeforeSend ||
            shouldClearVoiceEndState
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            if needsSwiftUIPressState {
                isVoicePressing = true
            }
            if shouldClearRefineBeforeSend {
                shouldRefineBeforeSend = false
            }
            if shouldClearVoiceEndState {
                isFinalizingVoice = false
                isCancelingVoice = false
            }
        }
        logVoiceTiming("press-ui-state-finished")
    }

    @discardableResult
    private func startVoiceInputAfterTouchFeedback() -> Bool {
        // Preparing on every touch blocks the perceived press path. The controller
        // keeps a prepared/warm session from onAppear and the previous recording.
        let didStart = voiceInput.start(
            settings: settings,
            backgroundAudio: backgroundAudio,
            diagnosticStartTime: voiceRuntime.pressStartedAt,
            notifyStartingImmediately: false,
            notifyLifecycleState: false
        ) { transcript in
            voiceRuntime.transcriptText = transcript
            voiceRuntime.hasNonEmptyTranscript = !transcript.isEmpty
            logFirstVoiceTranscriptIfNeeded()
        } onListening: {
            voiceOverlayRuntime.show(canceling: false, finalizing: false, starting: false, listening: true)
            logVoiceTiming("record-listening")
        }
        if didStart {
            voiceRuntime.hasStartedSession = true
            logVoiceTiming("sdk-start-called")
        } else {
            resetVoiceInteractionState(hideOverlay: true)
        }
        return didStart
    }

    private func resetVoiceInteractionState(hideOverlay: Bool = false, keepTencentWarm: Bool = true) {
        voiceRuntime.reset()
        voicePrepareTask?.cancel()
        voicePrepareTask = nil
        voiceInput.stop(backgroundAudio: backgroundAudio, keepTencentWarm: keepTencentWarm)
        clearVoiceGestureState()
        if hideOverlay {
            voiceOverlayRuntime.hide()
        }
    }

    private func clearVoiceGestureState() {
        isVoicePressing = false
        if isFinalizingVoice || isCancelingVoice {
            isFinalizingVoice = false
            isCancelingVoice = false
        }
    }

    private func endVoiceInput() {
        guard voiceRuntime.isPressing || voiceDisplayState.isActive else { return }

        if voiceRuntime.isPressing, !voiceRuntime.hasStartedSession, !voiceDisplayState.isActive {
            voiceRuntime.reset()
            clearVoiceGestureState()
            voiceOverlayRuntime.hide()
            return
        }

        voiceRuntime.isPressing = false
        isVoicePressing = false
        isCancelingVoice = false
        isFinalizingVoice = true
        voiceOverlayRuntime.show(canceling: false, finalizing: true, starting: false, listening: false)
        voiceRuntime.finalizeTask?.cancel()
        let finalizeDelay: Duration = voiceRuntime.hasTranscript ? .milliseconds(260) : .milliseconds(760)
        voiceRuntime.finalizeTask = Task {
            try? await Task.sleep(for: finalizeDelay)
            await MainActor.run {
                finalizeVoiceInput()
            }
        }
    }

    private func finalizeVoiceInput() {
        let transcript = (voiceRuntime.transcriptText.isEmpty ? voiceInput.latestTranscript : voiceRuntime.transcriptText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            inputText = mergedVoiceText(base: inputText, transcript: transcript)
            shouldRefineBeforeSend = settings.voiceRecognitionProvider == .apple
            inputMode = .voice
        }
        voiceRuntime.reset()
        clearVoiceGestureState()
        voiceInput.stop(backgroundAudio: backgroundAudio)
        voiceOverlayRuntime.hide()
        scheduleVoiceInputPrepare(force: true, after: .milliseconds(40))
    }

    private func cancelVoiceInput() {
        voiceRuntime.reset()
        clearVoiceGestureState()
        voiceInput.stop(backgroundAudio: backgroundAudio, keepTencentWarm: true)
        voiceOverlayRuntime.hide()
        scheduleVoiceInputPrepare(after: .milliseconds(40))
        triggerVoiceCanceledHaptic()
    }

    private func scheduleVoiceInputPrepare(force: Bool = false, after delay: Duration = .milliseconds(40)) {
        voicePrepareTask?.cancel()
        voicePrepareTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                voicePrepareTask = nil
                prepareVoiceInputIfIdle(force: force)
            }
        }
    }

    private func prepareVoiceInputIfIdle(force: Bool = false) {
        guard isEnabled else { return }
        guard !voiceRuntime.isPressing, !voiceDisplayState.isActive, inputMode == .voice else { return }
        voiceInput.prepare(settings: settings, force: force)
    }

    private func updateVoiceCancelVisualState(_ isCanceling: Bool) {
        voiceOverlayRuntime.show(canceling: isCanceling, finalizing: false, starting: false, listening: true)
    }

    private func triggerCancelZoneHaptic() {
        Haptics.cancelZoneEntered()
    }

    private func triggerVoiceCanceledHaptic() {
        Haptics.voiceCanceled()
    }

    private func logFirstVoiceTranscriptIfNeeded() {
        guard !voiceRuntime.didLogFirstTranscript,
              !voiceRuntime.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        voiceRuntime.didLogFirstTranscript = true
        logVoiceTiming("first-transcript")
    }

    private func logVoiceTiming(_ event: String) {
        guard voiceRuntime.pressStartedAt > 0 else { return }
        let elapsedMilliseconds = Int((CACurrentMediaTime() - voiceRuntime.pressStartedAt) * 1_000)
        VoiceInputDiagnostics.timing(event, elapsedMilliseconds: elapsedMilliseconds)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func mergedVoiceText(base: String, transcript: String) -> String {
        let speechText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speechText.isEmpty else { return base }

        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return speechText
        }

        let separator = base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : "\n"
        return base + separator + speechText
    }

    private func mergedDraftText(base: String, addition: String) -> String {
        let draft = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return base }

        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return draft
        }

        let separator = base.hasSuffix("\n") ? "\n" : "\n\n"
        return base + separator + draft
    }

    private func imagePrompt(for path: String) -> String {
        """
        我从手机上传了一张图片，已经保存到这台 Mac 的本地路径：
        \(path)

        请先读取并查看这张图片，然后根据图片内容继续处理。
        """
    }
}

private enum ImageUploadCompressor {
    private static let maxPixelSize = 1600
    private static let targetBytes = 1_100_000
    private static let qualities: [CGFloat] = [0.78, 0.7, 0.62, 0.54, 0.46, 0.38]

    static func compressedJPEGData(from data: Data) -> Data? {
        guard let image = downsampledImage(from: data) else { return nil }

        var smallest: Data?
        for quality in qualities {
            guard let jpeg = image.jpegData(compressionQuality: quality) else { continue }
            smallest = jpeg
            if jpeg.count <= targetBytes {
                return jpeg
            }
        }

        return smallest
    }

    private static func downsampledImage(from data: Data) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(data: data)
        }

        return UIImage(cgImage: cgImage)
    }
}

private struct ImageSendFeedback: Identifiable, Equatable {
    enum State: Equatable {
        case progress
        case success
        case failure
    }

    let id = UUID()
    let state: State
    let message: String

    static func progress(_ message: String) -> ImageSendFeedback {
        ImageSendFeedback(state: .progress, message: message)
    }

    static func success(_ message: String) -> ImageSendFeedback {
        ImageSendFeedback(state: .success, message: message)
    }

    static func failure(_ message: String) -> ImageSendFeedback {
        ImageSendFeedback(state: .failure, message: message)
    }

    var systemImage: String {
        switch state {
        case .progress: "photo.badge.arrow.down"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch state {
        case .progress: .secondary
        case .success: .green
        case .failure: .red
        }
    }
}

private struct AutoScrollingComposerTextView: View {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let maxLines: Int
    let isEditable: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            AutoScrollingTextView(
                text: $text,
                measuredHeight: $measuredHeight,
                minLines: 1,
                maxLines: maxLines,
                isEditable: isEditable
            )

            if text.isEmpty {
                Text(isEditable ? "Send to agent..." : "Read only")
                    .font(.system(size: 16))
                    .foregroundColor(Color(.placeholderText))
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct DraftEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                AutoScrollingTextView(
                    text: $text,
                    measuredHeight: .constant(0),
                    minLines: 12,
                    maxLines: 12
                )
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentMonitorTheme.elevatedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AgentMonitorTheme.separator(for: colorScheme), lineWidth: 1)
                )

                HStack {
                    Text("\(text.count) chars")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)

                    Spacer()

                    Button {
                        onSend()
                    } label: {
                        Label(isSending ? "Sending" : "Send", systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                }
            }
            .padding(16)
            .background(AgentMonitorTheme.backgroundGradient(for: colorScheme))
            .navigationTitle("Review Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct FloatingVoiceTextDraft: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let maxLines: Int
    let isSending: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        BottomInteractionBackdrop {
            ZStack(alignment: .bottomTrailing) {
                AutoScrollingTextView(
                    text: $text,
                    measuredHeight: $measuredHeight,
                    minLines: 2,
                    maxLines: maxLines
                )
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(height: measuredHeight + 36)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    BubbleTail()
                        .fill(bubbleColor)
                        .frame(width: 32, height: 24)
                        .offset(x: -42, y: 17)
                }
                .shadow(color: AgentMonitorTheme.cardShadow(for: colorScheme), radius: 14, x: 0, y: 6)
                .animation(.easeOut(duration: 0.18), value: measuredHeight)
            }

            HStack(alignment: .bottom, spacing: 28) {
                BottomIconAction(
                    title: "取消",
                    systemImage: "xmark",
                    action: onCancel
                )

                Spacer(minLength: 0)

                Button {
                    onSend()
                } label: {
                    HStack(spacing: 8) {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSending ? "发送中" : "发送")
                            .font(.system(size: 24, weight: .medium))
                    }
                    .foregroundColor(sendForegroundColor)
                    .frame(width: 176, height: 72)
                    .background(sendBackgroundColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 24)
        }
    }

    private var bubbleColor: Color {
        colorScheme == .dark
            ? Color(red: 0.44, green: 0.82, blue: 0.35)
            : Color(red: 0.56, green: 0.92, blue: 0.39)
    }

    private var sendBackgroundColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(canSend ? 0.16 : 0.08)
        }
        return Color.white.opacity(canSend ? 0.92 : 0.52)
    }

    private var sendForegroundColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(canSend ? 0.92 : 0.38)
        }
        return Color.black.opacity(canSend ? 0.88 : 0.34)
    }
}

private struct BottomInteractionBackdrop<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 22) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 54)
        .padding(.bottom, 10)
        .background(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        AgentMonitorTheme.pageBackground(for: colorScheme).opacity(0),
                        AgentMonitorTheme.pageBackground(for: colorScheme)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 46)

                AgentMonitorTheme.pageBackground(for: colorScheme)
            }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

private struct BottomIconAction: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.18))
                    Image(systemName: systemImage)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.92) : .white)
                }
                .frame(width: 72, height: 72)

                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary.opacity(0.66))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.maxX * 0.64, y: rect.maxY * 0.96)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY * 0.72)
        )
        return path
    }
}

private enum ComposerInputMode {
    case text
    case voice
}

private struct VoiceRecordingOverlaySnapshot {
    var isVisible: Bool
    var isCanceling: Bool
    var isFinalizing: Bool
    var isStarting: Bool
    var isListening: Bool
    var sequence: UInt64
    var pressStartedAt: CFTimeInterval

    func hasSameState(as other: VoiceRecordingOverlaySnapshot) -> Bool {
        isVisible == other.isVisible &&
            isCanceling == other.isCanceling &&
            isFinalizing == other.isFinalizing &&
            isStarting == other.isStarting &&
            isListening == other.isListening &&
            pressStartedAt == other.pressStartedAt
    }
}

@MainActor
private final class VoiceRecordingOverlayRuntime {
    private var observers: [UUID: (VoiceRecordingOverlaySnapshot) -> Void] = [:]
    private var sequence: UInt64 = 0
    private var snapshot = VoiceRecordingOverlaySnapshot(
        isVisible: false,
        isCanceling: false,
        isFinalizing: false,
        isStarting: false,
        isListening: false,
        sequence: 0,
        pressStartedAt: 0
    )

    func show(
        canceling: Bool,
        finalizing: Bool,
        starting: Bool,
        listening: Bool,
        pressStartedAt: CFTimeInterval = 0
    ) {
        update(
            VoiceRecordingOverlaySnapshot(
                isVisible: true,
                isCanceling: canceling,
                isFinalizing: finalizing,
                isStarting: starting,
                isListening: listening,
                sequence: sequence + 1,
                pressStartedAt: pressStartedAt
            )
        )
    }

    func hide() {
        update(
            VoiceRecordingOverlaySnapshot(
                isVisible: false,
                isCanceling: false,
                isFinalizing: false,
                isStarting: false,
                isListening: false,
                sequence: sequence + 1,
                pressStartedAt: 0
            )
        )
    }

    @discardableResult
    func addObserver(_ observer: @escaping (VoiceRecordingOverlaySnapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func update(_ nextSnapshot: VoiceRecordingOverlaySnapshot) {
        guard !snapshot.hasSameState(as: nextSnapshot) else { return }
        snapshot = nextSnapshot
        sequence = nextSnapshot.sequence
        for observer in observers.values {
            observer(nextSnapshot)
        }
    }
}

@MainActor
private final class VoiceInputRuntimeState {
    var transcriptText = ""
    var finalizeTask: Task<Void, Never>?
    var isPressing = false
    var pressStartedAt: CFTimeInterval = 0
    var didLogFirstTranscript = false
    var hasStartedSession = false
    var hasNonEmptyTranscript = false

    var hasTranscript: Bool {
        hasNonEmptyTranscript
    }

	    func reset() {
	        finalizeTask?.cancel()
	        finalizeTask = nil
        isPressing = false
        pressStartedAt = 0
        didLogFirstTranscript = false
        hasStartedSession = false
        hasNonEmptyTranscript = false
        transcriptText = ""
    }
}

@MainActor
@Observable
private final class VoiceDisplayState {
    private struct Snapshot: Equatable {
        var phase: VoiceInputPhase
        var errorMessage: String?
    }

    @ObservationIgnored private var observerID: UUID?
    private var snapshot = Snapshot(phase: .idle, errorMessage: nil)

    var phase: VoiceInputPhase { snapshot.phase }
    var errorMessage: String? { snapshot.errorMessage }
    var isActive: Bool { phase.isActive }
    var isStarting: Bool { phase.isStarting }
    var isListening: Bool { phase.isListening }
    var statusText: String? { phase.statusText }

    func attach(to voiceInput: VoiceInputController) {
        guard observerID == nil else { return }
        observerID = voiceInput.addStateObserver { [weak self] phase, errorMessage in
            self?.apply(phase: phase, errorMessage: errorMessage)
        }
    }

    func detach(from voiceInput: VoiceInputController) {
        if let observerID {
            voiceInput.removeStateObserver(observerID)
        }
        observerID = nil
        apply(phase: .idle, errorMessage: nil)
    }

    private func apply(phase: VoiceInputPhase, errorMessage: String?) {
        let nextSnapshot = Snapshot(phase: phase, errorMessage: errorMessage)
        guard snapshot != nextSnapshot else { return }
        snapshot = nextSnapshot
    }
}

private struct ComposerIconLabel: View {
    let systemImage: String
    let isLoading: Bool

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundColor(.primary.opacity(0.7))
            }
        }
        .frame(width: 38, height: 44)
        .contentShape(Rectangle())
    }

    private var iconSize: CGFloat {
        switch systemImage {
        case "keyboard":
            20
        case "arrow.up.circle.fill":
            24
        default:
            21
        }
    }
}

private struct VoiceRecordingOverlay: UIViewRepresentable {
    let isVisible: Bool
    let isCanceling: Bool
    let isFinalizing: Bool
    let isStarting: Bool
    let isListening: Bool
    let pageBackgroundColor: UIColor
    let runtime: VoiceRecordingOverlayRuntime
    let voiceInput: VoiceInputController

    func makeUIView(context: Context) -> VoiceRecordingOverlayView {
        let view = VoiceRecordingOverlayView()
        context.coordinator.attach(view: view, to: voiceInput)
        context.coordinator.attachRuntime(runtime)
        view.update(
            isVisible: isVisible,
            isCanceling: isCanceling,
            isFinalizing: isFinalizing,
            isStarting: isStarting,
            isListening: isListening,
            pageBackgroundColor: pageBackgroundColor,
            animated: false
        )
        return view
    }

    func updateUIView(_ view: VoiceRecordingOverlayView, context: Context) {
        context.coordinator.attach(view: view, to: voiceInput)
        context.coordinator.attachRuntime(runtime)
        view.update(
            isVisible: isVisible,
            isCanceling: isCanceling,
            isFinalizing: isFinalizing,
            isStarting: isStarting,
            isListening: isListening,
            pageBackgroundColor: pageBackgroundColor,
            animated: true
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ view: VoiceRecordingOverlayView, coordinator: Coordinator) {
        coordinator.detach()
        view.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var view: VoiceRecordingOverlayView?
        private weak var voiceInput: VoiceInputController?
        private var observerID: UUID?
        private var runtimeObserverID: UUID?
        private weak var runtime: VoiceRecordingOverlayRuntime?

        func attach(view: VoiceRecordingOverlayView, to voiceInput: VoiceInputController) {
            if self.view === view, self.voiceInput === voiceInput, observerID != nil {
                return
            }

            detach()
            self.view = view
            self.voiceInput = voiceInput
            observerID = voiceInput.addAudioLevelObserver { [weak view] level in
                view?.updateAudioLevel(level)
            }
        }

        func detach() {
            if let observerID {
                voiceInput?.removeAudioLevelObserver(observerID)
            }
            if let runtimeObserverID {
                runtime?.removeObserver(runtimeObserverID)
            }
            observerID = nil
            runtimeObserverID = nil
            voiceInput = nil
            runtime = nil
            view = nil
        }

        func attachRuntime(_ runtime: VoiceRecordingOverlayRuntime) {
            if self.runtime === runtime, runtimeObserverID != nil {
                return
            }

            if let runtimeObserverID {
                self.runtime?.removeObserver(runtimeObserverID)
            }
            self.runtime = runtime
            runtimeObserverID = runtime.addObserver { [weak self] snapshot in
                self?.view?.apply(snapshot: snapshot)
            }
        }
    }
}

private final class VoiceRecordingOverlayView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let solidLayer = CALayer()
    private let capsuleLayer = CAShapeLayer()
    private let waveformView = VoiceWaveformView()
    private let promptLabel = UILabel()
    private var isVisibleValue = false
    private var isCancelingValue = false
    private var isFinalizingValue = false
    private var isStartingValue = false
    private var isListeningValue = false
    private var pageBackgroundColorValue = UIColor.systemBackground
    private var lastRuntimeSequence: UInt64 = 0
    private var didLogFirstVisibleRuntimeFrame = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 54)
        solidLayer.frame = CGRect(x: 0, y: 46, width: bounds.width, height: max(bounds.height - 46, 0))

        let contentTop: CGFloat = 58
        waveformView.frame = CGRect(x: (bounds.width - 154) / 2, y: contentTop, width: 154, height: 24)
        promptLabel.frame = CGRect(x: 18, y: contentTop + 34, width: max(bounds.width - 36, 0), height: 22)

        let capsuleFrame = CGRect(x: 36, y: bounds.height - 62, width: max(bounds.width - 72, 0), height: 52)
        capsuleLayer.path = UIBezierPath(roundedRect: capsuleFrame, cornerRadius: 26).cgPath
    }

    func update(
        isVisible: Bool,
        isCanceling: Bool,
        isFinalizing: Bool,
        isStarting: Bool,
        isListening: Bool,
        pageBackgroundColor: UIColor,
        animated: Bool
    ) {
        if lastRuntimeSequence > 0 {
            updateBackgroundColor(pageBackgroundColor)
            return
        }

        applyState(
            isVisible: isVisible,
            isCanceling: isCanceling,
            isFinalizing: isFinalizing,
            isStarting: isStarting,
            isListening: isListening,
            pageBackgroundColor: pageBackgroundColor,
            animated: animated
        )
    }

    private func applyState(
        isVisible: Bool,
        isCanceling: Bool,
        isFinalizing: Bool,
        isStarting: Bool,
        isListening: Bool,
        pageBackgroundColor: UIColor,
        animated: Bool
    ) {
        let visibilityChanged = isVisibleValue != isVisible
        isVisibleValue = isVisible
        isCancelingValue = isCanceling
        isFinalizingValue = isFinalizing
        isStartingValue = isStarting
        isListeningValue = isListening
        pageBackgroundColorValue = pageBackgroundColor

        let tint = isCanceling ? UIColor.systemRed : UIColor(red: 0.32, green: 0.64, blue: 0.38, alpha: 1)
        let prompt: String
        if isCanceling {
            prompt = "松开取消"
        } else if isFinalizing {
            prompt = "正在转换文字"
        } else if isStarting {
            prompt = "正在启动语音"
        } else {
            prompt = "松开发送  上滑取消"
        }

        updateBackgroundColor(pageBackgroundColor)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsuleLayer.fillColor = tint.cgColor
        CATransaction.commit()

        promptLabel.text = prompt
        promptLabel.textColor = isCanceling ? .systemRed : .label
        waveformView.update(
            tintColor: tint,
            isAnimating: isAnimating,
            isCanceling: isCanceling,
            isFinalizing: isFinalizing
        )

        let alpha: CGFloat = isVisible ? 1 : 0
        let transform = isVisible ? CGAffineTransform.identity : CGAffineTransform(translationX: 0, y: 14)
        if animated && visibilityChanged {
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
            ) {
                self.alpha = alpha
                self.transform = transform
            }
        } else {
            self.alpha = alpha
            self.transform = transform
        }

        if !isVisible {
            waveformView.updateAudioLevel(0)
        }
        setNeedsLayout()
    }

	    func apply(snapshot: VoiceRecordingOverlaySnapshot) {
        guard snapshot.sequence != lastRuntimeSequence else { return }
        lastRuntimeSequence = snapshot.sequence
        if snapshot.isVisible, !didLogFirstVisibleRuntimeFrame {
            didLogFirstVisibleRuntimeFrame = true
            if snapshot.pressStartedAt > 0 {
                let elapsedMilliseconds = Int((CACurrentMediaTime() - snapshot.pressStartedAt) * 1_000)
                VoiceInputDiagnostics.timing("overlay-runtime-applied", elapsedMilliseconds: elapsedMilliseconds)
            }
        } else if !snapshot.isVisible {
            didLogFirstVisibleRuntimeFrame = false
        }
        let animated = isVisibleValue || !snapshot.isVisible
        applyState(
            isVisible: snapshot.isVisible,
            isCanceling: snapshot.isCanceling,
            isFinalizing: snapshot.isFinalizing,
            isStarting: snapshot.isStarting,
            isListening: snapshot.isListening,
            pageBackgroundColor: pageBackgroundColorValue,
            animated: animated
        )
    }

    private func updateBackgroundColor(_ pageBackgroundColor: UIColor) {
        pageBackgroundColorValue = pageBackgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [
            pageBackgroundColor.withAlphaComponent(0).cgColor,
            pageBackgroundColor.cgColor
        ]
        solidLayer.backgroundColor = pageBackgroundColor.cgColor
        CATransaction.commit()
    }

    func updateAudioLevel(_ level: CGFloat) {
        waveformView.updateAudioLevel(level)
    }

    func stop() {
        waveformView.stopDisplayLink()
    }

    private var isAnimating: Bool {
        isListeningValue || isStartingValue
    }

    private func setup() {
        isOpaque = false
        isUserInteractionEnabled = false
        alpha = 0

        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradientLayer)
        layer.addSublayer(solidLayer)
        layer.addSublayer(capsuleLayer)

        addSubview(waveformView)

        promptLabel.font = .systemFont(ofSize: 15, weight: .medium)
        promptLabel.textAlignment = .center
        addSubview(promptLabel)
    }
}

private final class VoiceWaveformView: UIView {
    private let barCount = 13
    private let minHeight: CGFloat = 4
    private let barProfiles: [(centerBoost: CGFloat, idle: CGFloat, phaseA: Double, phaseB: Double, phaseC: Double)] = {
        let count = 13
        return (0..<count).map { index in
            let position = CGFloat(index) / CGFloat(max(count - 1, 1))
            let centerDistance = abs(position - 0.5) * 2
            return (
                centerBoost: 1 - centerDistance * 0.28,
                idle: 0.08 + (1 - centerDistance) * 0.05,
                phaseA: Double(index) * 0.86,
                phaseB: Double(index) * 0.38,
                phaseC: Double(index) * 1.9
            )
        }
    }()
    private var barLayers: [CALayer] = []
    private var displayLink: CADisplayLink?
    private var startTime = CACurrentMediaTime()
    private var tintColorValue = UIColor.systemGreen
    private var isAnimatingValue = false
    private var isCancelingValue = false
    private var isFinalizingValue = false
    private var audioLevelValue: CGFloat = 0
    private var lastRenderedBounds: CGRect = .null
    private var lastRenderedHeights: [CGFloat] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        setupBars()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderBars(force: bounds != lastRenderedBounds)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            updateDisplayLink()
        }
    }

    func update(
        tintColor: UIColor,
        isAnimating: Bool,
        isCanceling: Bool,
        isFinalizing: Bool
    ) {
        let shouldRedraw = tintColorValue != tintColor ||
            isAnimatingValue != isAnimating ||
            isCancelingValue != isCanceling ||
            isFinalizingValue != isFinalizing

        tintColorValue = tintColor
        isAnimatingValue = isAnimating
        isCancelingValue = isCanceling
        isFinalizingValue = isFinalizing

        if shouldRedraw {
            lastRenderedHeights = Array(repeating: -1, count: barCount)
        }
        updateDisplayLink()
        if shouldRedraw {
            renderBars(force: true)
        }
    }

    func updateAudioLevel(_ audioLevel: CGFloat) {
        let clampedLevel = min(max(audioLevel, 0), 1)
        guard abs(audioLevelValue - clampedLevel) > 0.01 else { return }
        audioLevelValue = clampedLevel
        updateDisplayLink()
        renderBars(force: false)
    }

    private func updateDisplayLink() {
        let shouldAnimate = isCancelingValue || isFinalizingValue || audioLevelValue > 0.02
        if shouldAnimate, displayLink == nil {
            startTime = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(displayTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 12)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !shouldAnimate, displayLink != nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayTick() {
        renderBars(force: false)
    }

    private func setupBars() {
        guard barLayers.isEmpty else { return }
        for _ in 0..<barCount {
            let layer = CALayer()
            layer.backgroundColor = tintColorValue.cgColor
            layer.cornerRadius = 1.5
            layer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "backgroundColor": NSNull(),
                "cornerRadius": NSNull()
            ]
            self.layer.addSublayer(layer)
            barLayers.append(layer)
            lastRenderedHeights.append(-1)
        }
    }

    private func renderBars(force: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let time = CACurrentMediaTime() - startTime
        let spacing: CGFloat = 5
        let barWidth: CGFloat = 3
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = max((bounds.width - totalWidth) / 2, 0)
        let maxHeight = max(bounds.height - 2, minHeight)
        let roundedTint = tintColorValue.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<barCount {
            let rawHeight = barHeight(index: index, time: time, maxHeight: maxHeight)
            let height = round(rawHeight * UIScreen.main.scale) / UIScreen.main.scale
            guard force ||
                index >= lastRenderedHeights.count ||
                abs(lastRenderedHeights[index] - height) > 0.5
            else { continue }

            let x = startX + CGFloat(index) * (barWidth + spacing)
            barLayers[index].cornerRadius = barWidth / 2
            barLayers[index].backgroundColor = roundedTint
            barLayers[index].frame = CGRect(
                x: x,
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            if index < lastRenderedHeights.count {
                lastRenderedHeights[index] = height
            }
        }
        CATransaction.commit()
        lastRenderedBounds = bounds
    }

    private func barHeight(index: Int, time: TimeInterval, maxHeight: CGFloat) -> CGFloat {
        let profile = barProfiles[index]
        if isCancelingValue {
            return cancelHeight(profile: profile, time: time, maxHeight: maxHeight)
        }

        if isFinalizingValue {
            return finalizingHeight(profile: profile, time: time, maxHeight: maxHeight)
        }

        guard isAnimatingValue, audioLevelValue > 0.02 else {
            return idleHeight(profile: profile, maxHeight: maxHeight)
        }

        let beat = CGFloat((sin(time * 8.0 + profile.phaseA) + 1) * 0.5)
        let normalized = min(1, 0.08 + audioLevelValue * 0.46 + beat * audioLevelValue * 0.20)
        return minHeight + (maxHeight - minHeight) * normalized * profile.centerBoost
    }

    private func idleHeight(
        profile: (centerBoost: CGFloat, idle: CGFloat, phaseA: Double, phaseB: Double, phaseC: Double),
        maxHeight: CGFloat
    ) -> CGFloat {
        return minHeight + (maxHeight - minHeight) * profile.idle
    }

    private func finalizingHeight(
        profile: (centerBoost: CGFloat, idle: CGFloat, phaseA: Double, phaseB: Double, phaseC: Double),
        time: TimeInterval,
        maxHeight: CGFloat
    ) -> CGFloat {
        let pulse = CGFloat((sin(time * 3.2 + profile.phaseB) + 1) * 0.5)
        let normalized = 0.32 + pulse * 0.22 + profile.idle
        return minHeight + (maxHeight - minHeight) * normalized
    }

    private func cancelHeight(
        profile: (centerBoost: CGFloat, idle: CGFloat, phaseA: Double, phaseB: Double, phaseC: Double),
        time: TimeInterval,
        maxHeight: CGFloat
    ) -> CGFloat {
        let jitter = CGFloat((sin(time * 15.0 + profile.phaseC) + 1) * 0.5)
        return minHeight + (maxHeight - minHeight) * (0.18 + jitter * 0.14)
    }
}

private struct HoldToSpeakButton: View {
    let isActive: Bool
    let isStarting: Bool
    let isListening: Bool
    let isPressing: Bool
	    let isCanceling: Bool
	    let isFinalizing: Bool
	    let onPressStart: (CFTimeInterval) -> Bool
	    let onPressEnd: () -> Void
    let onCancelStateChange: (Bool) -> Void
    let onEnterCancelZone: () -> Void
    let onPressCancel: () -> Void

    private let cancelThreshold: CGFloat = -38

    var body: some View {
        HoldToSpeakControl(
            isActive: isActive,
            isStarting: isStarting,
            isListening: isListening,
            isPressing: isPressing,
            isCanceling: isCanceling,
            isFinalizing: isFinalizing,
            cancelThreshold: cancelThreshold,
            onPressStart: onPressStart,
            onPressEnd: onPressEnd,
            onCancelStateChange: onCancelStateChange,
            onEnterCancelZone: onEnterCancelZone,
            onPressCancel: onPressCancel
        )
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .accessibilityLabel(isActive ? "Release to convert voice input" : "Hold to speak")
    }
}

private struct HoldToSpeakControl: UIViewRepresentable {
    let isActive: Bool
    let isStarting: Bool
    let isListening: Bool
    let isPressing: Bool
    let isCanceling: Bool
    let isFinalizing: Bool
    let cancelThreshold: CGFloat
	    let onPressStart: (CFTimeInterval) -> Bool
	    let onPressEnd: () -> Void
    let onCancelStateChange: (Bool) -> Void
    let onEnterCancelZone: () -> Void
    let onPressCancel: () -> Void

    func makeUIView(context: Context) -> HoldToSpeakUIView {
	        let view = HoldToSpeakUIView()
	        view.cancelThreshold = cancelThreshold
        view.onPressStart = { touchStartedAt in
            onPressStart(touchStartedAt)
        }
        view.onCancelStateChange = { [weak view] shouldCancel in
            guard view?.isTouchInProgress == true || isPressing || isActive else { return }
            onCancelStateChange(shouldCancel)
        }
        view.onEnterCancelZone = {
            onEnterCancelZone()
        }
        view.onPressFinish = { [weak view] shouldCancel in
            guard view?.isTouchInProgress == true || isPressing || isActive else {
                return
            }
            if shouldCancel {
                onPressCancel()
            } else {
                onPressEnd()
            }
        }
        view.apply(
            isActive: isActive,
            isStarting: isStarting,
            isListening: isListening,
            isPressing: isPressing,
            isCanceling: isCanceling,
            isFinalizing: isFinalizing,
            animated: false
        )
        return view
    }

    func updateUIView(_ view: HoldToSpeakUIView, context: Context) {
	        view.cancelThreshold = cancelThreshold
	        view.acceptsNewTouches = !isStarting && !isFinalizing
        view.onPressStart = { touchStartedAt in
            onPressStart(touchStartedAt)
        }
        view.onCancelStateChange = { [weak view] shouldCancel in
            guard view?.isTouchInProgress == true || isPressing || isActive else { return }
            onCancelStateChange(shouldCancel)
        }
        view.onEnterCancelZone = {
            onEnterCancelZone()
        }
        view.onPressFinish = { [weak view] shouldCancel in
            guard view?.isTouchInProgress == true || isPressing || isActive else {
                return
            }
            if shouldCancel {
                onPressCancel()
            } else {
                onPressEnd()
            }
        }
        view.apply(
            isActive: isActive,
            isStarting: isStarting,
            isListening: isListening,
            isPressing: isPressing,
            isCanceling: isCanceling,
            isFinalizing: isFinalizing,
            animated: true
        )
        if !isActive, !isStarting, !isListening, !isPressing, !isFinalizing {
            view.prepareForNextPress()
        }
    }
}

private final class HoldToSpeakUIView: UIControl {
    private struct VisualState: Equatable {
        var fillColor: UIColor
        var strokeColor: UIColor
        var title: String
        var titleColor: UIColor
        var usesFilledIcon: Bool
        var isPressed: Bool
    }

    var cancelThreshold: CGFloat = -54
    var acceptsNewTouches = true
    var onPressStart: ((CFTimeInterval) -> Bool)?
    var onCancelStateChange: ((Bool) -> Void)?
    var onEnterCancelZone: (() -> Void)?
    var onPressFinish: ((Bool) -> Void)?

    private let backgroundLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let pressImpact = UIImpactFeedbackGenerator(style: .soft)
    private let micImage = UIImage(systemName: "mic")
    private let micFillImage = UIImage(systemName: "mic.fill")
    private var isTouching = false
    private var didEnterCancelZone = false
    private var didTriggerCancelZoneHaptic = false
    private var startPoint: CGPoint = .zero
    private var currentIconImage: UIImage?
    private var lastVisualState: VisualState?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 34)
    }

    func prepareForNextPress() {
        pressImpact.prepare()
    }

    var isTouchInProgress: Bool {
        isTouching
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
        backgroundLayer.path = path
        strokeLayer.path = path

        let labelSize = titleLabel.sizeThatFits(CGSize(width: max(bounds.width - 72, 0), height: bounds.height))
        let iconSize: CGFloat = 16
        let spacing: CGFloat = 6
        let totalWidth = min(bounds.width - 20, iconSize + spacing + labelSize.width)
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.midY

        iconView.frame = CGRect(x: startX, y: centerY - iconSize / 2, width: iconSize, height: iconSize)
        titleLabel.frame = CGRect(
            x: startX + iconSize + spacing,
            y: 0,
            width: min(labelSize.width, max(bounds.width - startX - iconSize - spacing - 10, 0)),
            height: bounds.height
        )
    }

    func apply(
        isActive: Bool,
        isStarting: Bool,
        isListening: Bool,
        isPressing: Bool,
        isCanceling: Bool,
        isFinalizing: Bool,
        animated: Bool
    ) {
        let visualPressing = isTouching || isPressing
        let title: String
        if isStarting {
            title = "启动中"
        } else if isFinalizing {
            title = "正在收尾"
        } else if isCanceling || didEnterCancelZone {
            title = "松开取消"
        } else if isListening || visualPressing {
            title = "按住说话中"
        } else {
            title = "按住 说话"
        }

        let fillColor: UIColor
        let strokeColor: UIColor
        let titleColor: UIColor
        if isCanceling || didEnterCancelZone {
            fillColor = .systemRed
            strokeColor = UIColor.systemRed.withAlphaComponent(0.28)
            titleColor = .white
        } else if isListening || visualPressing || isFinalizing || isActive {
            fillColor = UIColor(red: 0.20, green: 0.64, blue: 0.36, alpha: 1)
            strokeColor = UIColor.systemGreen.withAlphaComponent(0.18)
            titleColor = .white
        } else {
            fillColor = UIColor.secondarySystemFill.withAlphaComponent(0.72)
            strokeColor = UIColor.label.withAlphaComponent(0.04)
            titleColor = UIColor.label.withAlphaComponent(0.78)
        }

        applyVisualState(
            VisualState(
                fillColor: fillColor,
                strokeColor: strokeColor,
                title: title,
                titleColor: titleColor,
                usesFilledIcon: isListening || visualPressing,
                isPressed: visualPressing
            ),
            animated: animated
        )
    }

    private func setup() {
        isMultipleTouchEnabled = false
        backgroundColor = .clear
        isOpaque = false

        backgroundLayer.fillColor = UIColor.secondarySystemFill.withAlphaComponent(0.72).cgColor
        layer.addSublayer(backgroundLayer)

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor.label.withAlphaComponent(0.04).cgColor
        strokeLayer.lineWidth = 1
        layer.addSublayer(strokeLayer)

        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        pressImpact.prepare()

        apply(
            isActive: false,
            isStarting: false,
            isListening: false,
            isPressing: false,
            isCanceling: false,
            isFinalizing: false,
            animated: false
        )
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsNewTouches, !isTouching, let point = touches.first?.location(in: self) else { return }
        let touchStartedAt = CACurrentMediaTime()
        VoiceInputDiagnostics.timing("press-began", elapsedMilliseconds: 0)
        isTouching = true
        isUserInteractionEnabled = true
        didEnterCancelZone = false
        didTriggerCancelZoneHaptic = false
        startPoint = point
        applyInstantTouchFeedback(canceling: false)
        pressImpact.impactOccurred(intensity: 0.75)
        VoiceInputDiagnostics.timing("press-haptic-fired", elapsedMilliseconds: 0)
        let didStart = onPressStart?(touchStartedAt) ?? true
        guard didStart else {
            resetTouchState()
            apply(
                isActive: false,
                isStarting: false,
                isListening: false,
                isPressing: false,
                isCanceling: false,
                isFinalizing: false,
                animated: false
            )
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isTouching else { return }
            self.pressImpact.prepare()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTouching, let point = touches.first?.location(in: self) else { return }
        let offsetY = point.y - startPoint.y
        let shouldCancel = didEnterCancelZone
            ? offsetY < cancelThreshold + 18
            : offsetY < cancelThreshold
        guard shouldCancel != didEnterCancelZone else { return }
        didEnterCancelZone = shouldCancel
        applyInstantTouchFeedback(canceling: shouldCancel)
        onCancelStateChange?(shouldCancel)
        if shouldCancel, !didTriggerCancelZoneHaptic {
            didTriggerCancelZoneHaptic = true
            onEnterCancelZone?()
        } else if !shouldCancel {
            didTriggerCancelZoneHaptic = false
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTouching else { return }
        let point = touches.first?.location(in: self) ?? startPoint
        let shouldCancel = didEnterCancelZone || point.y - startPoint.y < cancelThreshold
        onPressFinish?(shouldCancel)
        resetTouchState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTouching else { return }
        onPressFinish?(true)
        resetTouchState()
    }

    private func applyInstantTouchFeedback(canceling: Bool) {
        applyVisualState(
            VisualState(
                fillColor: canceling ? .systemRed : UIColor(red: 0.20, green: 0.64, blue: 0.36, alpha: 1),
                strokeColor: canceling ? UIColor.systemRed.withAlphaComponent(0.28) : UIColor.systemGreen.withAlphaComponent(0.18),
                title: canceling ? "松开取消" : "按住说话中",
                titleColor: .white,
                usesFilledIcon: true,
                isPressed: true
            ),
            animated: false
        )
    }

    private func applyVisualState(_ state: VisualState, animated: Bool) {
        guard lastVisualState != state else { return }
        lastVisualState = state

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        backgroundLayer.fillColor = state.fillColor.cgColor
        strokeLayer.strokeColor = state.strokeColor.cgColor
        CATransaction.commit()

        titleLabel.text = state.title
        titleLabel.textColor = state.titleColor
	        iconView.tintColor = state.titleColor
	        setIconImage(state.usesFilledIcon ? micFillImage : micImage)
	        updateScale(pressed: state.isPressed, animated: animated && !state.isPressed)
	        setNeedsLayout()
	    }

    private func setIconImage(_ image: UIImage?) {
        guard currentIconImage !== image else { return }
        currentIconImage = image
        iconView.image = image
    }

    private func resetTouchState() {
        isTouching = false
	        didEnterCancelZone = false
	        didTriggerCancelZoneHaptic = false
	        startPoint = .zero
	        updateScale(pressed: false, animated: true)
	    }

	    private func updateScale(pressed: Bool, animated: Bool) {
	        let target = pressed ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
	        guard transform != target else { return }
	        guard animated else {
	            transform = target
	            return
	        }
	        UIView.animate(
	            withDuration: 0.08,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            self.transform = target
        }
    }
}

private struct AutoScrollingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let minLines: Int
    let maxLines: Int
    var isEditable = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = SizingTextView()
        textView.delegate = context.coordinator
        textView.onLayout = { textView in
            context.coordinator.recalculateHeight(for: textView)
        }
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.keyboardDismissMode = .interactive
        textView.returnKeyType = .default
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.isSelectable = isEditable

        if textView.text != text {
            textView.text = text
            context.coordinator.recalculateHeight(for: textView)
            textView.scrollToComposerEnd(animated: false)
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                coordinator.recalculateHeight(for: textView)
                textView.scrollToComposerEnd(animated: false)
            }
        } else {
            context.coordinator.recalculateHeight(for: textView)
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                coordinator.recalculateHeight(for: textView)
            }
        }

        // Let UIKit own first-responder state. SwiftUI refreshes this screen often,
        // and driving focus from updateUIView can immediately cancel a user tap.
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoScrollingTextView

        init(_ parent: AutoScrollingTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            recalculateHeight(for: textView)
            textView.scrollCurrentSelectionIntoView(animated: false)
            DispatchQueue.main.async {
                textView.scrollCurrentSelectionIntoView(animated: false)
            }
        }

        func recalculateHeight(for textView: UITextView) {
            let width = textView.bounds.width
            guard width > 0, let font = textView.font else { return }

            let fittingSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            let contentHeight = ceil(textView.sizeThatFits(fittingSize).height)
            let verticalSlack = max(6, font.descender.magnitude + 4)
            let minHeight = ceil(font.lineHeight * CGFloat(max(parent.minLines, 1)) + verticalSlack)
            let maxHeight = ceil(font.lineHeight * CGFloat(max(parent.maxLines, parent.minLines)) + verticalSlack)
            let nextHeight = min(max(contentHeight, minHeight), maxHeight)

            guard abs(parent.measuredHeight - nextHeight) > 0.5 else { return }

            DispatchQueue.main.async {
                self.parent.measuredHeight = nextHeight
            }
        }
    }

    final class SizingTextView: UITextView {
        var onLayout: ((UITextView) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(self)
        }
    }
}

private extension UITextView {
    func scrollToComposerEnd(animated: Bool) {
        guard !text.isEmpty else {
            setContentOffset(.zero, animated: false)
            return
        }

        let end = NSRange(location: (text as NSString).length, length: 0)
        selectedRange = end
        scrollRangeToVisible(end)
    }

    func scrollCurrentSelectionIntoView(animated: Bool) {
        guard !text.isEmpty else {
            setContentOffset(.zero, animated: false)
            return
        }

        scrollRangeToVisible(selectedRange)
    }
}

// MARK: - Pane Info View

private struct PaneInfoView: View {
    let pane: Pane

    var body: some View {
        List {
            Section("Status") {
                HStack {
                    Text("State")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(statusColor(pane.status)).frame(width: 8, height: 8)
                        Text(pane.status.title)
                    }
                    .foregroundColor(statusColor(pane.status))
                }
                HStack {
                    Text("Reason")
                    Spacer()
                    Text(pane.reason).foregroundColor(.secondary)
                }
                HStack {
                    Text("Updated")
                    Spacer()
                    Text(pane.updatedAt, style: .time).foregroundColor(.secondary)
                }
            }

            Section("Session") {
                InfoRow(label: "Session", value: pane.session)
                InfoRow(label: "Command", value: pane.command.isEmpty ? "shell" : pane.command)
                InfoRow(label: "Pane ID", value: pane.id)
                InfoRow(label: "Target", value: pane.target)
                if let pid = pane.pid {
                    InfoRow(label: "PID", value: String(pid))
                }
            }

            Section("Path") {
                Text(pane.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}
