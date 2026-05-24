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

    var onData: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var lastParameters: ConnectionParameters?
    private var connectionKey: String?

    func connect(with params: ConnectionParameters, force: Bool = false) {
        let nextConnectionKey = connectionKey(for: params)
        if !force, connectionKey == nextConnectionKey, wsTask != nil {
            return
        }

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
    }

    func reconnectIfPossible() {
        guard let params = lastParameters else { return }
        connect(with: params, force: true)
    }

    func suspendForBackground() {
        closeCurrentTask(notifyDisconnected: false, clearParameters: false)
        if state == .connected || state == .connecting {
            state = .disconnected
        }
    }

    func sendInput(_ text: String) {
        guard let wsTask, state == .connected || state == .connecting else { return }
        let msg = "{\"type\":\"input\",\"data\":\(jsonEscape(text))}"
        wsTask.send(.string(msg)) { _ in }
    }

    func sendResize(cols: Int, rows: Int) {
        updateStoredTerminalSize(cols: cols, rows: rows)
        guard let wsTask, state == .connected || state == .connecting else { return }
        let msg = "{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"
        wsTask.send(.string(msg)) { _ in }
    }

    func sendScroll(lines: Int) {
        guard let wsTask, state == .connected || state == .connecting else { return }
        let safeLines = max(-200, min(200, lines))
        guard safeLines != 0 else { return }
        let msg = "{\"type\":\"scroll\",\"lines\":\(safeLines)}"
        wsTask.send(.string(msg)) { _ in }
    }

    func disconnect() {
        closeCurrentTask(notifyDisconnected: true, clearParameters: true)
    }

    // MARK: - Private

    private func closeCurrentTask(notifyDisconnected: Bool, clearParameters: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        let task = wsTask
        wsTask = nil
        connectionKey = nil
        if clearParameters {
            lastParameters = nil
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
            String(params.cols),
            String(params.rows),
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
                case "data":
                    if let payload = server.data {
                        guard wsTask === task else { return }
                        if state != .connected {
                            state = .connected
                            onStateChange?(.connected)
                        }
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

    private func markTaskClosed(_ task: URLSessionWebSocketTask, state nextState: State) {
        guard wsTask === task else { return }
        receiveTask = nil
        wsTask = nil
        connectionKey = nil
        state = nextState
        onStateChange?(nextState)
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
