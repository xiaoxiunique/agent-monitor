import Foundation

@MainActor
final class PaneLogWebSocketService {
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    struct ConnectionParameters: Sendable {
        let baseURL: URL
        let token: String
        let paneId: String
        let lines: Int
    }

    struct Event: Sendable {
        let paneId: String
        let tail: String
        let capturedAt: Date
    }

    private(set) var state: State = .disconnected

    var onEvent: ((Event) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectionKey: String?

    func connect(with params: ConnectionParameters) {
        let nextConnectionKey = [
            params.baseURL.absoluteString,
            params.token,
            params.paneId,
            String(params.lines),
        ].joined(separator: "\n")
        if connectionKey == nextConnectionKey, wsTask != nil {
            return
        }

        disconnect()
        connectionKey = nextConnectionKey

        state = .connecting
        onStateChange?(.connecting)

        guard var components = URLComponents(url: params.baseURL, resolvingAgainstBaseURL: false) else {
            state = .error("Invalid URL")
            onStateChange?(.error("Invalid URL"))
            return
        }
        components.path = "/pane-log/ws"
        components.scheme = params.baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "paneId", value: params.paneId),
            URLQueryItem(name: "lines", value: String(params.lines)),
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
        wsTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        let task = wsTask
        wsTask = nil
        connectionKey = nil
        let wasActive = state == .connected || state == .connecting
        if wasActive {
            state = .disconnected
            onStateChange?(.disconnected)
        }
        task?.cancel(with: .goingAway, reason: nil)
    }

    func requestRefresh() {
        guard let wsTask else { return }
        wsTask.send(.string(#"{"type":"refresh"}"#)) { _ in }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let string):
                    text = string
                case .data(let data):
                    text = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    continue
                }

                guard let data = text.data(using: .utf8),
                      let server = try? AgentMonitorClient.decode(ServerMessage.self, from: data) else {
                    continue
                }

                switch server.type {
                case "paneLog":
                    guard let paneId = server.paneId, let tail = server.tail else { continue }
                    if state != .connected {
                        state = .connected
                        onStateChange?(.connected)
                    }
                    onEvent?(Event(
                        paneId: paneId,
                        tail: tail,
                        capturedAt: server.capturedAt ?? Date()
                    ))
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
}

private struct ServerMessage: Decodable, Sendable {
    let type: String?
    let paneId: String?
    let tail: String?
    let capturedAt: Date?
    let error: String?
}
