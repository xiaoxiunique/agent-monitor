import Foundation

enum AgentMonitorError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Invalid service URL"
        case .invalidResponse: "Invalid response from service"
        case let .server(message): message
        }
    }
}

struct AgentMonitorClient {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    func snapshot() async throws -> Snapshot {
        let data = try await data(path: "/api/snapshot", method: "GET")
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        if let error = snapshot.error, !snapshot.ok {
            throw AgentMonitorError.server(error)
        }
        return snapshot
    }

    func sendText(_ text: String, to pane: Pane, vimMode: Bool) async throws {
        let body: [String: Any] = [
            "paneId": pane.id,
            "text": text,
            "enter": true,
            "vimMode": vimMode
        ]
        _ = try await data(path: "/api/send", method: "POST", body: body)
    }

    func sendKey(_ key: String, to pane: Pane) async throws {
        var components = try components(path: "/api/key")
        components.queryItems = authQueryItems() + [
            URLQueryItem(name: "paneId", value: pane.id),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        setAuthorizationHeader(on: &request)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func killSession(_ sessionName: String) async throws {
        _ = try await data(path: "/api/session/kill", method: "POST", body: ["session": sessionName])
    }

    func terminalURL(for pane: Pane) throws -> URL {
        var components = try components(path: "/terminal.html")
        components.queryItems = authQueryItems() + [
            URLQueryItem(name: "paneId", value: pane.id),
            URLQueryItem(name: "v", value: "keyboard-focus-2")
        ]
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }
        return url
    }

    func snapshotWebSocketURL() throws -> URL {
        var components = try components(path: "/ws")
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = authQueryItems()
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }
        return url
    }

    private func data(path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var components = try components(path: path)
        components.queryItems = authQueryItems()
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        setAuthorizationHeader(on: &request)

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private func components(path: String) throws -> URLComponents {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        guard let components else { throw AgentMonitorError.invalidServerURL }
        return components
    }

    private func authQueryItems() -> [URLQueryItem] {
        token.isEmpty ? [] : [URLQueryItem(name: "token", value: token)]
    }

    private func setAuthorizationHeader(on request: inout URLRequest) {
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AgentMonitorError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentMonitorError.server("HTTP \(http.statusCode)")
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
