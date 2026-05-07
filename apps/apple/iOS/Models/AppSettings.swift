import Foundation
import Observation

enum DetailTab: String, CaseIterable, Identifiable {
    case actions
    case terminal
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actions: "Actions"
        case .terminal: "Terminal"
        case .status: "Status"
        }
    }
}

@Observable
final class AppSettings {
    private static let defaultServerURL = ""

    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }

    var accessToken: String {
        didSet { defaults.set(accessToken, forKey: Keys.accessToken) }
    }

    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Keys.keepScreenAwake) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        accessToken = defaults.string(forKey: Keys.accessToken) ?? ""
        let savedInterval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = savedInterval == 0 ? 2.5 : savedInterval
        keepScreenAwake = defaults.object(forKey: Keys.keepScreenAwake) as? Bool ?? false
    }

    var baseURL: URL? {
        URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func reset() {
        serverURL = Self.defaultServerURL
        accessToken = ""
        refreshInterval = 2.5
        keepScreenAwake = false
    }

    private enum Keys {
        static let serverURL = "serverURL"
        static let accessToken = "accessToken"
        static let refreshInterval = "refreshInterval"
        static let keepScreenAwake = "keepScreenAwake"
    }
}
