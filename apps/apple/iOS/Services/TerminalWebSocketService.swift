import Foundation

@MainActor
final class TerminalWebSocketService {
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case closed(exitCode: Int?)
        case error(String)
    }

    struct ConnectionParameters: Sendable {
        let baseURL: URL
        let token: String
        let paneId: String
        let cols: Int
        let rows: Int
    }

    private(set) var state: State = .disconnected
    var isReadyForInteraction: Bool { state == .connected }

    var onData: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var readinessTimeoutTask: Task<Void, Never>?
    private var lastParameters: ConnectionParameters?
    private var connectionKey: String?
    private var reconnectAttempt = 0
    private var pendingResize: (cols: Int, rows: Int)?

    func connect(with params: ConnectionParameters, force: Bool = false) {
        let nextConnectionKey = connectionKey(for: params)
        if !force, connectionKey == nextConnectionKey, wsTask != nil {
            let sizeChanged = lastParameters?.cols != params.cols || lastParameters?.rows != params.rows
            lastParameters = params
            if sizeChanged {
                sendResize(cols: params.cols, rows: params.rows)
            }
            return
        }

        cancelReconnect()
        closeCurrentTask(notifyDisconnected: false, clearParameters: false)
        lastParameters = params
        connectionKey = nextConnectionKey

        state = .connecting
        onStateChange?(.connecting)

        guard var components = URLComponents(url: params.baseURL, resolvingAgainstBaseURL: false) else {
            state = .error("Invalid URL")
            onStateChange?(.error("Invalid URL"))
            return
        }
        components.path = "/terminal/ws"
        components.scheme = params.baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "paneId", value: params.paneId),
            URLQueryItem(name: "cols", value: String(params.cols)),
            URLQueryItem(name: "rows", value: String(params.rows)),
        ]

        guard let url = components.url else {
            state = .error("Invalid WebSocket URL")
            onStateChange?(.error("Invalid WebSocket URL"))
            return
        }

        var request = URLRequest(url: url)
        if !params.token.isEmpty {
            request.setValue("Bearer \(params.token)", forHTTPHeaderField: "Authorization")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        self.wsTask = task
        task.resume()
        state = .connecting
        onStateChange?(.connecting)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
        scheduleReadinessTimeout(for: task)
    }

    func reconnectIfPossible() {
        guard let params = lastParameters else { return }
        if wsTask != nil, state == .connected || state == .connecting {
            return
        }
        connect(with: params, force: true)
    }

    func suspendForBackground() {
        cancelReconnect()
        cancelReadinessTimeout()
        closeCurrentTask(notifyDisconnected: false, clearParameters: false)
        if state == .connected || state == .connecting {
            state = .disconnected
            onStateChange?(.disconnected)
        }
    }

    func sendInput(_ text: String) {
        guard !text.isEmpty else { return }
        guard isInteractionRecoverable else { return }
        let msg = "{\"type\":\"input\",\"data\":\(jsonEscape(text))}"
        guard isReadyForInteraction else {
            scheduleReconnectIfPossible()
            return
        }
        sendMessage(msg)
    }

    func sendResize(cols: Int, rows: Int) {
        updateStoredTerminalSize(cols: cols, rows: rows)
        guard isInteractionRecoverable else { return }
        let msg = "{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"
        guard isReadyForInteraction else {
            pendingResize = (cols, rows)
            scheduleReconnectIfPossible()
            return
        }
        sendMessage(msg) { [weak self] in
            self?.pendingResize = (cols, rows)
        }
    }

    func sendScroll(lines: Int) {
        guard isInteractionRecoverable else { return }
        let safeLines = max(-200, min(200, lines))
        guard safeLines != 0 else { return }
        let msg = "{\"type\":\"scroll\",\"lines\":\(safeLines)}"
        guard isReadyForInteraction else {
            scheduleReconnectIfPossible()
            return
        }
        sendMessage(msg)
    }

    func disconnect() {
        cancelReconnect()
        cancelReadinessTimeout()
        closeCurrentTask(notifyDisconnected: true, clearParameters: true)
    }

    // MARK: - Private

    private var isInteractionRecoverable: Bool {
        switch state {
        case .closed, .error:
            false
        case .disconnected, .connecting, .connected:
            true
        }
    }

    private func closeCurrentTask(notifyDisconnected: Bool, clearParameters: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        let task = wsTask
        wsTask = nil
        connectionKey = nil
        if clearParameters {
            lastParameters = nil
            clearQueuedInteraction()
        }
        let wasActive = state == .connected || state == .connecting
        if notifyDisconnected, wasActive {
            state = .disconnected
            onStateChange?(.disconnected)
        }
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func connectionKey(for params: ConnectionParameters) -> String {
        [
            params.baseURL.absoluteString,
            params.token,
            params.paneId,
        ].joined(separator: "\n")
    }

    private func updateStoredTerminalSize(cols: Int, rows: Int) {
        guard let params = lastParameters else { return }
        let updatedParams = ConnectionParameters(
            baseURL: params.baseURL,
            token: params.token,
            paneId: params.paneId,
            cols: cols,
            rows: rows
        )
        lastParameters = updatedParams
        connectionKey = connectionKey(for: updatedParams)
    }

    private func clearQueuedInteraction() {
        pendingResize = nil
    }

    private func flushQueuedInteraction() {
        if let pendingResize {
            self.pendingResize = nil
            sendResize(cols: pendingResize.cols, rows: pendingResize.rows)
        }
    }

    private func sendMessage(_ message: String, recover: (@MainActor () -> Void)? = nil) {
        guard let task = wsTask, isReadyForInteraction else {
            recover?()
            if state == .disconnected {
                scheduleReconnectIfPossible()
            }
            return
        }
        task.send(.string(message)) { [weak self, task] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self else { return }
                recover?()
                if self.wsTask === task {
                    self.handleTransportFailure(for: task)
                } else if self.isReadyForInteraction {
                    self.flushQueuedInteraction()
                } else if self.state == .disconnected {
                    self.scheduleReconnectIfPossible()
                }
            }
        }
    }

    private func handleTransportFailure(for task: URLSessionWebSocketTask) {
        guard wsTask === task else { return }
        closeCurrentTask(notifyDisconnected: false, clearParameters: false)
        state = .disconnected
        onStateChange?(.disconnected)
        scheduleReconnectIfPossible()
    }

    private func scheduleReconnectIfPossible() {
        guard lastParameters != nil else { return }
        guard reconnectTask == nil else { return }
        switch state {
        case .disconnected:
            break
        case .connecting, .connected, .closed, .error:
            return
        }

        reconnectAttempt += 1
        let delayMilliseconds = min(3_000, 250 * (1 << min(reconnectAttempt - 1, 4)))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            self?.runScheduledReconnect()
        }
    }

    private func runScheduledReconnect() {
        reconnectTask = nil
        guard state != .connected else { return }
        guard let params = lastParameters else { return }
        connect(with: params, force: true)
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func scheduleReadinessTimeout(for task: URLSessionWebSocketTask) {
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = Task { [weak self, weak task] in
            try? await Task.sleep(for: .seconds(6))
            await MainActor.run {
                guard let self, let task, self.wsTask === task, self.state == .connecting else { return }
                self.closeCurrentTask(notifyDisconnected: false, clearParameters: false)
                self.state = .disconnected
                self.onStateChange?(.disconnected)
                self.scheduleReconnectIfPossible()
            }
        }
    }

    private func cancelReadinessTimeout() {
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }

                guard let data = text.data(using: .utf8),
                      let server = try? JSONDecoder().decode(ServerMessage.self, from: data) else {
                    continue
                }

                switch server.type {
                case "ready":
                    markTaskConnected(task)
                case "data":
                    if let payload = server.data {
                        guard wsTask === task else { return }
                        markTaskConnected(task)
                        onData?(payload)
                    }
                case "exit":
                    markTaskClosed(task, state: .closed(exitCode: server.exitCode))
                    return
                case "error":
                    markTaskClosed(task, state: .error(server.error ?? "Unknown error"))
                    return
                default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    markTaskClosed(task, state: .disconnected)
                }
                return
            }
        }
    }

    private func markTaskConnected(_ task: URLSessionWebSocketTask) {
        guard wsTask === task else { return }
        reconnectAttempt = 0
        cancelReconnect()
        cancelReadinessTimeout()
        if state != .connected {
            state = .connected
            onStateChange?(.connected)
        }
        flushQueuedInteraction()
    }

    private func markTaskClosed(_ task: URLSessionWebSocketTask, state nextState: State) {
        guard wsTask === task else { return }
        receiveTask = nil
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        wsTask = nil
        connectionKey = nil
        state = nextState
        onStateChange?(nextState)
        if nextState == .disconnected {
            scheduleReconnectIfPossible()
        } else {
            clearQueuedInteraction()
        }
    }

    private func jsonEscape(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s) else { return "\"\"" }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

private struct ServerMessage: Decodable, Sendable {
    let type: String
    let data: String?
    let error: String?
    let exitCode: Int?
    let signal: Int?
}
