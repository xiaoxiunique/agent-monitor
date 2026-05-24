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

struct RefinedTextResponse: Codable {
    let ok: Bool
    let text: String
    let changed: Bool
    let fallback: Bool?
    let error: String?
}

struct UploadedImageResponse: Codable {
    let ok: Bool
    let path: String
    let size: Int
    let contentType: String
}

struct PaneContextResponse: Codable {
    let ok: Bool
    let paneId: String
    let lines: Int
    let tail: String
    let capturedAt: Date
}

struct PaneCommandResponse: Codable {
    let ok: Bool
    let paneId: String?
    let tail: String?
    let capturedAt: Date?
}

struct AgentMonitorClient {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    func snapshot() async throws -> Snapshot {
        let data = try await data(path: "/api/snapshot", method: "GET")
        let snapshot = try Self.decode(Snapshot.self, from: data)
        if let error = snapshot.error, !snapshot.ok {
            throw AgentMonitorError.server(error)
        }
        return snapshot
    }

    func sendText(_ text: String, to pane: Pane, vimMode: Bool) async throws -> PaneCommandResponse {
        let body: [String: Any] = [
            "paneId": pane.id,
            "text": text,
            "enter": true,
            "submitKey": pane.sendSubmitKey,
            "vimMode": vimMode
        ]
        let data = try await data(path: "/api/send", method: "POST", body: body)
        return try Self.decode(PaneCommandResponse.self, from: data)
    }

    func refineText(_ text: String) async throws -> RefinedTextResponse {
        let data = try await data(path: "/api/refine-text", method: "POST", body: ["text": text])
        return try Self.decode(RefinedTextResponse.self, from: data)
    }

    func uploadImage(_ imageData: Data, to pane: Pane, contentType: String) async throws -> UploadedImageResponse {
        var components = try components(path: "/api/upload-image")
        components.queryItems = [
            URLQueryItem(name: "paneId", value: pane.id)
        ]
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        setAuthorizationHeader(on: &request)

        let (data, response) = try await session.upload(for: request, from: imageData)
        try validate(response)
        return try Self.decode(UploadedImageResponse.self, from: data)
    }

    func sendKey(_ key: String, to pane: Pane) async throws -> PaneCommandResponse {
        var components = try components(path: "/api/key")
        components.queryItems = [
            URLQueryItem(name: "paneId", value: pane.id),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        setAuthorizationHeader(on: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try Self.decode(PaneCommandResponse.self, from: data)
    }

    func closePane(_ pane: Pane) async throws {
        _ = try await data(path: "/api/session/kill", method: "POST", body: ["paneId": pane.id])
    }

    func paneContext(for pane: Pane, lines: Int) async throws -> PaneContextResponse {
        var components = try components(path: "/api/pane/context")
        components.queryItems = [
            URLQueryItem(name: "paneId", value: pane.id),
            URLQueryItem(name: "lines", value: String(lines))
        ]
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        setAuthorizationHeader(on: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try Self.decode(PaneContextResponse.self, from: data)
    }

    func paneEvents(for pane: Pane, limit: Int = 140) async throws -> AgentEventsResponse {
        var components = try components(path: "/api/pane/events")
        components.queryItems = [
            URLQueryItem(name: "paneId", value: pane.id),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        setAuthorizationHeader(on: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try Self.decode(AgentEventsResponse.self, from: data)
    }

    func snapshotWebSocketRequest() throws -> URLRequest {
        var components = try components(path: "/ws")
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw AgentMonitorError.invalidServerURL }
        var request = URLRequest(url: url)
        setAuthorizationHeader(on: &request)
        return request
    }

    private func data(path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        let components = try components(path: path)
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

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = DateParsers.parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        return decoder
    }
}

private enum DateParsers {
    private static let lock = NSLock()

    nonisolated(unsafe) private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }

        return iso8601WithFractionalSeconds.date(from: string)
            ?? iso8601.date(from: string)
    }
}
