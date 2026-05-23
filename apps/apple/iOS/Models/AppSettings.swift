import Foundation
import Observation

enum VoiceRecognitionProvider: String, CaseIterable, Identifiable {
    case tencent
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tencent: "Tencent Cloud"
        case .apple: "Apple Speech"
        }
    }
}

struct ServerProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var token: String

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        return Self.defaultName(for: url)
    }

    var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasToken: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var monitorIdentity: String {
        [
            id,
            trimmedURL,
            token.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1f}")
    }

    static func defaultName(for url: String) -> String {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return "New Server" }
        if let host = URL(string: trimmedURL)?.host, !host.isEmpty {
            return host
        }
        return trimmedURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/")
            .first
            .map(String.init) ?? "Server"
    }
}

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

@MainActor
@Observable
final class AppSettings {
    static let defaultQuickActionButtons = ["继续", "yes", "no", "LGTM", "skip"]
    static let maxQuickActionButtons = 12

    #if targetEnvironment(simulator)
    private static let defaultServerURL = "http://127.0.0.1:8797"
    #else
    private static let defaultServerURL = ""
    #endif

    var serverURL: String {
        didSet {
            defaults.set(serverURL, forKey: Keys.serverURL)
            syncActiveServerFromLegacyFields()
        }
    }

    var accessToken: String {
        didSet {
            defaults.set(accessToken, forKey: Keys.accessToken)
            syncActiveServerFromLegacyFields()
        }
    }

    var serverProfiles: [ServerProfile] {
        didSet { persistServerProfiles() }
    }

    var activeServerID: String {
        didSet { defaults.set(activeServerID, forKey: Keys.activeServerID) }
    }

    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Keys.keepScreenAwake) }
    }

    var backgroundAudioKeepAlive: Bool {
        didSet { defaults.set(backgroundAudioKeepAlive, forKey: Keys.backgroundAudioKeepAlive) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    var voiceRecognitionProviderRaw: String {
        didSet { defaults.set(voiceRecognitionProviderRaw, forKey: Keys.voiceRecognitionProviderRaw) }
    }

    var tencentASRAppID: String {
        didSet { defaults.set(tencentASRAppID, forKey: Keys.tencentASRAppID) }
    }

    var tencentASRSecretID: String {
        didSet { defaults.set(tencentASRSecretID, forKey: Keys.tencentASRSecretID) }
    }

    var tencentASRSecretKey: String {
        didSet { defaults.set(tencentASRSecretKey, forKey: Keys.tencentASRSecretKey) }
    }

    var tencentASRToken: String {
        didSet { defaults.set(tencentASRToken, forKey: Keys.tencentASRToken) }
    }

    var pinnedProjects: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(pinnedProjects) {
                defaults.set(data, forKey: Keys.pinnedProjects)
            }
        }
    }

    var quickActionButtons: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(quickActionButtons) {
                defaults.set(data, forKey: Keys.quickActionButtons)
            }
        }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var isApplyingServerProfile = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedServerURL = defaults.string(forKey: Keys.serverURL)
        let savedAccessToken = defaults.string(forKey: Keys.accessToken) ?? ""
        let initialServerURL = savedServerURL ?? Self.defaultServerURL
        let initialProfiles = Self.loadServerProfiles(
            from: defaults,
            legacyURL: initialServerURL,
            legacyToken: savedAccessToken
        )
        let savedActiveServerID = defaults.string(forKey: Keys.activeServerID)
        let activeProfile = Self.resolveActiveProfile(
            profiles: initialProfiles,
            savedActiveID: savedActiveServerID,
            legacyURL: initialServerURL
        )
        serverProfiles = initialProfiles
        activeServerID = activeProfile.id
        serverURL = activeProfile.url
        accessToken = activeProfile.token
        let savedInterval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = savedInterval == 0 ? 2.5 : savedInterval
        keepScreenAwake = defaults.object(forKey: Keys.keepScreenAwake) as? Bool ?? false
        backgroundAudioKeepAlive = defaults.object(forKey: Keys.backgroundAudioKeepAlive) as? Bool ?? false
        hasCompletedOnboarding = defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool
            ?? !activeProfile.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        voiceRecognitionProviderRaw = defaults.string(forKey: Keys.voiceRecognitionProviderRaw) ?? VoiceRecognitionProvider.tencent.rawValue
        tencentASRAppID = defaults.string(forKey: Keys.tencentASRAppID) ?? "1316852800"
        tencentASRSecretID = defaults.string(forKey: Keys.tencentASRSecretID) ?? ""
        tencentASRSecretKey = defaults.string(forKey: Keys.tencentASRSecretKey) ?? ""
        tencentASRToken = defaults.string(forKey: Keys.tencentASRToken) ?? ""
        if let data = defaults.data(forKey: Keys.pinnedProjects),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            pinnedProjects = decoded
        } else {
            pinnedProjects = []
        }
        if let data = defaults.data(forKey: Keys.quickActionButtons),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            quickActionButtons = decoded
        } else {
            quickActionButtons = Self.defaultQuickActionButtons
        }
        persistServerProfiles()
        defaults.set(activeServerID, forKey: Keys.activeServerID)
        defaults.set(serverURL, forKey: Keys.serverURL)
        defaults.set(accessToken, forKey: Keys.accessToken)
    }

    var baseURL: URL? {
        URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var activeServerProfile: ServerProfile? {
        serverProfiles.first(where: { $0.id == activeServerID })
    }

    var activeServerDisplayName: String {
        activeServerProfile?.displayName ?? "Server"
    }

    var activeServerIdentity: String {
        [
            activeServerID,
            serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1f}")
    }

    var voiceRecognitionProvider: VoiceRecognitionProvider {
        VoiceRecognitionProvider(rawValue: voiceRecognitionProviderRaw) ?? .tencent
    }

    func reset() {
        let defaultProfile = Self.makeServerProfile(
            id: "default",
            name: Self.defaultServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : ServerProfile.defaultName(for: Self.defaultServerURL),
            url: Self.defaultServerURL,
            token: ""
        )
        isApplyingServerProfile = true
        serverProfiles = [defaultProfile]
        activeServerID = defaultProfile.id
        serverURL = defaultProfile.url
        accessToken = defaultProfile.token
        isApplyingServerProfile = false
        refreshInterval = 2.5
        keepScreenAwake = false
        backgroundAudioKeepAlive = false
        hasCompletedOnboarding = false
        voiceRecognitionProviderRaw = VoiceRecognitionProvider.tencent.rawValue
        tencentASRAppID = "1316852800"
        tencentASRSecretID = ""
        tencentASRSecretKey = ""
        tencentASRToken = ""
        pinnedProjects = []
        quickActionButtons = Self.defaultQuickActionButtons
    }

    @discardableResult
    func addServerProfile() -> ServerProfile {
        let profile = Self.makeServerProfile(
            name: "",
            url: "",
            token: ""
        )
        serverProfiles.append(profile)
        selectServer(profile.id)
        return profile
    }

    func selectServer(_ id: String) {
        guard let profile = serverProfiles.first(where: { $0.id == id }) else { return }
        activeServerID = profile.id
        applyActiveServerProfile(profile)
    }

    func renameActiveServer(_ name: String) {
        guard let index = serverProfiles.firstIndex(where: { $0.id == activeServerID }) else { return }
        serverProfiles[index].name = name
    }

    func removeServerProfile(_ id: String) {
        guard serverProfiles.count > 1 else { return }
        let wasActive = id == activeServerID
        serverProfiles.removeAll { $0.id == id }
        guard wasActive, let nextProfile = serverProfiles.first else { return }
        selectServer(nextProfile.id)
    }

    func isProjectPinned(_ project: String) -> Bool {
        pinnedProjects.contains(project)
    }

    func toggleProjectPin(_ project: String) {
        if let idx = pinnedProjects.firstIndex(of: project) {
            pinnedProjects.remove(at: idx)
        } else {
            pinnedProjects.append(project)
        }
    }

    var visibleQuickActionButtons: [String] {
        Self.visibleQuickActionButtons(from: quickActionButtons)
    }

    func resetQuickActionButtons() {
        quickActionButtons = Self.defaultQuickActionButtons
    }

    static func visibleQuickActionButtons(from buttons: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []

        for button in buttons {
            let text = button
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let key = text.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            cleaned.append(text)

            if cleaned.count >= maxQuickActionButtons {
                break
            }
        }

        return cleaned
    }

    nonisolated static func projectName(from session: String) -> String {
        let parts = session.split(separator: "_")
        if parts.count >= 3 {
            return parts.dropFirst().dropLast().joined(separator: "_")
        }
        if parts.count == 2 {
            return String(parts[1])
        }
        return session
    }

    private enum Keys {
        static let serverURL = "serverURL"
        static let accessToken = "accessToken"
        static let serverProfiles = "serverProfiles"
        static let activeServerID = "activeServerID"
        static let refreshInterval = "refreshInterval"
        static let keepScreenAwake = "keepScreenAwake"
        static let backgroundAudioKeepAlive = "backgroundAudioKeepAlive"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let voiceRecognitionProviderRaw = "voiceRecognitionProviderRaw"
        static let tencentASRAppID = "tencentASRAppID"
        static let tencentASRSecretID = "tencentASRSecretID"
        static let tencentASRSecretKey = "tencentASRSecretKey"
        static let tencentASRToken = "tencentASRToken"
        static let pinnedProjects = "pinnedProjects"
        static let quickActionButtons = "quickActionButtons"
    }

    private func applyActiveServerProfile(_ profile: ServerProfile) {
        isApplyingServerProfile = true
        serverURL = profile.url
        accessToken = profile.token
        isApplyingServerProfile = false
    }

    private func syncActiveServerFromLegacyFields() {
        guard !isApplyingServerProfile else { return }
        if let index = serverProfiles.firstIndex(where: { $0.id == activeServerID }) {
            serverProfiles[index].url = serverURL
            serverProfiles[index].token = accessToken
            if serverProfiles[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                serverProfiles[index].name = ServerProfile.defaultName(for: serverURL)
            }
            return
        }

        let profile = Self.makeServerProfile(
            id: activeServerID.isEmpty ? UUID().uuidString : activeServerID,
            name: ServerProfile.defaultName(for: serverURL),
            url: serverURL,
            token: accessToken
        )
        serverProfiles.append(profile)
        activeServerID = profile.id
    }

    private func persistServerProfiles() {
        if let data = try? JSONEncoder().encode(serverProfiles) {
            defaults.set(data, forKey: Keys.serverProfiles)
        }
    }

    private static func loadServerProfiles(
        from defaults: UserDefaults,
        legacyURL: String,
        legacyToken: String
    ) -> [ServerProfile] {
        let decodedProfiles: [ServerProfile]
        if let data = defaults.data(forKey: Keys.serverProfiles),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            decodedProfiles = decoded
        } else {
            decodedProfiles = []
        }

        let cleaned = decodedProfiles.map { profile in
            makeServerProfile(
                id: profile.id.isEmpty ? UUID().uuidString : profile.id,
                name: profile.name,
                url: profile.url,
                token: profile.token
            )
        }

        if !cleaned.isEmpty { return cleaned }
        return [
            makeServerProfile(
                id: "default",
                name: legacyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ""
                    : ServerProfile.defaultName(for: legacyURL),
                url: legacyURL,
                token: legacyToken
            )
        ]
    }

    private static func resolveActiveProfile(
        profiles: [ServerProfile],
        savedActiveID: String?,
        legacyURL: String
    ) -> ServerProfile {
        if let savedActiveID,
           let profile = profiles.first(where: { $0.id == savedActiveID }) {
            return profile
        }

        let trimmedLegacyURL = legacyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLegacyURL.isEmpty,
           let profile = profiles.first(where: { $0.trimmedURL == trimmedLegacyURL }) {
            return profile
        }

        return profiles.first ?? makeServerProfile(
            id: "default",
            name: ServerProfile.defaultName(for: legacyURL),
            url: legacyURL,
            token: ""
        )
    }

    private static func makeServerProfile(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        token: String
    ) -> ServerProfile {
        ServerProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
