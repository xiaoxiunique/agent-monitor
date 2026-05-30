import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MonitorStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var testState: TestState = .idle
    @State private var voiceTestState: TestState = .idle
    @State private var ccSwitchState = CcSwitchSettingsState()

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Server", selection: $settings.activeServerID) {
                        ForEach(settings.serverProfiles) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .onChange(of: settings.activeServerID) { _, id in
                        settings.selectServer(id)
                        testState = .idle
                        reloadCcSwitchStatusForCurrentServer()
                        store.start()
                    }

                    TextField("Server Name", text: activeServerNameBinding)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    TextField("Server URL", text: $settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: settings.serverURL) { _, _ in
                            testState = .idle
                            reloadCcSwitchStatusForCurrentServer()
                        }

                    SecureField("Access Token (optional)", text: $settings.accessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: settings.accessToken) { _, _ in
                            testState = .idle
                            reloadCcSwitchStatusForCurrentServer()
                        }

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "network")
                            Spacer()
                            Text(testState.title)
                                .foregroundStyle(testState.color)
                        }
                    }

                    Button {
                        addServer()
                    } label: {
                        Label("Add Server", systemImage: "plus.circle")
                    }

                    Button(role: .destructive) {
                        deleteActiveServer()
                    } label: {
                        Label("Delete Current Server", systemImage: "trash")
                    }
                    .disabled(settings.serverProfiles.count <= 1)
                }

                Section("Monitor") {
                    Picker("Refresh Interval", selection: $settings.refreshInterval) {
                        Text("1s").tag(1.0)
                        Text("2.5s").tag(2.5)
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                    }

                    Toggle("Keep Screen Awake", isOn: $settings.keepScreenAwake)
                }

                Section {
                    if ccSwitchState.isLoading && ccSwitchState.apps.isEmpty {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading providers")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = ccSwitchState.errorMessage, ccSwitchState.apps.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(ccSwitchState.apps) { app in
                            CcSwitchAppSettingsView(
                                app: app,
                                isBusy: ccSwitchState.isBusy,
                                switchingProviderID: ccSwitchState.switchingProviderID,
                                onSwitch: { provider in
                                    Task { await switchCcProvider(app: app, provider: provider) }
                                }
                            )
                        }
                    }

                    Button {
                        Task { await loadCcSwitchStatus() }
                    } label: {
                        HStack {
                            Label("Refresh Providers", systemImage: "arrow.clockwise")
                            Spacer()
                            if ccSwitchState.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(ccSwitchState.isBusy)

                    if let error = ccSwitchState.errorMessage, !ccSwitchState.apps.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("CC Switch")
                } footer: {
                    Text("Switches the active Claude Code and Codex providers in CC Switch on the selected Mac.")
                }

                Section {
                    ForEach(settings.quickActionButtons.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            TextField("Button text", text: quickActionBinding(at: index))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Button(role: .destructive) {
                                removeQuickActionButton(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove quick button")
                        }
                    }

                    Button {
                        addQuickActionButton()
                    } label: {
                        Label("Add Button", systemImage: "plus.circle")
                    }
                    .disabled(settings.quickActionButtons.count >= AppSettings.maxQuickActionButtons)

                    Button {
                        settings.resetQuickActionButtons()
                    } label: {
                        Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Quick Buttons")
                } footer: {
                    Text("These buttons appear above the composer. Empty or duplicate labels are hidden in the detail view.")
                }

                Section("Voice Input") {
                    Picker("Recognition", selection: $settings.voiceRecognitionProviderRaw) {
                        ForEach(VoiceRecognitionProvider.allCases) { provider in
                            Text(provider.title).tag(provider.rawValue)
                        }
                    }
                    .onChange(of: settings.voiceRecognitionProviderRaw) { _, _ in
                        voiceTestState = .idle
                    }

                    Text(voiceProviderDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if settings.voiceRecognitionProvider == .tencent {
                        TextField("Tencent AppID", text: $settings.tencentASRAppID)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: settings.tencentASRAppID) { _, _ in
                                voiceTestState = .idle
                            }

                        TextField("Tencent SecretId", text: $settings.tencentASRSecretID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: settings.tencentASRSecretID) { _, _ in
                                voiceTestState = .idle
                            }

                        SecureField("Tencent SecretKey", text: $settings.tencentASRSecretKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: settings.tencentASRSecretKey) { _, _ in
                                voiceTestState = .idle
                            }

                        SecureField("Tencent Token (optional)", text: $settings.tencentASRToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: settings.tencentASRToken) { _, _ in
                                voiceTestState = .idle
                            }

                        Button {
                            Task { await testTencentASR() }
                        } label: {
                            HStack {
                                Label("Test Tencent Credentials", systemImage: "key")
                                Spacer()
                                if voiceTestState == .testing {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(voiceTestState.title)
                                    .foregroundStyle(voiceTestState.color)
                            }
                        }
                        .disabled(voiceTestState == .testing)

                        if case let .failed(message) = voiceTestState {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        } else if case let .success(message) = voiceTestState {
                            Text("\(message) This does not test microphone recording.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Reset") {
                    Button(role: .destructive) {
                        settings.reset()
                        store.start()
                    } label: {
                        Label("Reset Settings", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AgentMonitorTheme.backgroundGradient(for: colorScheme))
            .navigationTitle("Settings")
            .onChange(of: settings.serverURL) { _, _ in
                store.start()
            }
            .onChange(of: settings.accessToken) { _, _ in
                store.start()
            }
            .onChange(of: settings.refreshInterval) { _, _ in
                store.start()
            }
            .task {
                reloadCcSwitchStatusForCurrentServer()
            }
        }
    }

    private var voiceProviderDescription: String {
        switch settings.voiceRecognitionProvider {
        case .tencent:
            return "Tencent is initialized only when you tap the mic. Switching this picker only selects the provider; use the test button to verify credentials, then test recording from the composer."
        case .apple:
            return "Apple Speech uses iOS speech recognition and may refine punctuation before sending."
        }
    }

    private var activeServerNameBinding: Binding<String> {
        Binding {
            settings.activeServerProfile?.name ?? ""
        } set: { value in
            settings.renameActiveServer(value)
        }
    }

    private func addServer() {
        let profile = settings.addServerProfile()
        testState = .idle
        settings.selectServer(profile.id)
        store.start()
    }

    private func deleteActiveServer() {
        let activeID = settings.activeServerID
        settings.removeServerProfile(activeID)
        testState = .idle
        reloadCcSwitchStatusForCurrentServer()
        store.start()
    }

    private func quickActionBinding(at index: Int) -> Binding<String> {
        Binding {
            guard settings.quickActionButtons.indices.contains(index) else { return "" }
            return settings.quickActionButtons[index]
        } set: { value in
            guard settings.quickActionButtons.indices.contains(index) else { return }
            settings.quickActionButtons[index] = value
        }
    }

    private func addQuickActionButton() {
        guard settings.quickActionButtons.count < AppSettings.maxQuickActionButtons else { return }
        settings.quickActionButtons.append("")
    }

    private func removeQuickActionButton(at index: Int) {
        guard settings.quickActionButtons.indices.contains(index) else { return }
        settings.quickActionButtons.remove(at: index)
    }
    private func testConnection() async {
        guard let client = store.makeClient() else {
            testState = .failed("Invalid URL")
            return
        }

        testState = .testing
        do {
            let snapshot = try await client.snapshot()
            testState = .success("\(snapshot.panes.count) panes")
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private func testTencentASR() async {
        voiceTestState = .testing
        let result = await TencentVoiceRecognitionConfigTester.test(settings: settings)
        switch result {
        case let .success(message):
            voiceTestState = .success(message)
            Haptics.sent(success: true)
        case let .failure(message):
            voiceTestState = .failed(message)
            Haptics.sent(success: false)
        }
    }

    private func loadCcSwitchStatus() async {
        guard !ccSwitchState.isBusy else { return }
        let serverIdentity = settings.activeServerIdentity
        guard let client = store.makeClient() else {
            guard serverIdentity == settings.activeServerIdentity else { return }
            ccSwitchState.apps = []
            ccSwitchState.errorMessage = "Invalid server URL"
            return
        }

        ccSwitchState.isLoading = true
        defer {
            if serverIdentity == settings.activeServerIdentity {
                ccSwitchState.isLoading = false
            }
        }

        do {
            let response = try await client.ccSwitchStatus()
            guard serverIdentity == settings.activeServerIdentity else { return }
            ccSwitchState.apps = response.apps
            ccSwitchState.errorMessage = response.ok ? nil : (response.error ?? "Failed to load providers")
        } catch {
            guard serverIdentity == settings.activeServerIdentity else { return }
            ccSwitchState.errorMessage = error.localizedDescription
        }
    }

    private func switchCcProvider(app: CcSwitchAppStatus, provider: CcSwitchProvider) async {
        guard !provider.isCurrent, !ccSwitchState.isBusy else { return }
        let serverIdentity = settings.activeServerIdentity
        guard let client = store.makeClient() else {
            guard serverIdentity == settings.activeServerIdentity else { return }
            ccSwitchState.errorMessage = "Invalid server URL"
            return
        }

        ccSwitchState.switchingProviderID = provider.id
        defer {
            if serverIdentity == settings.activeServerIdentity {
                ccSwitchState.switchingProviderID = nil
            }
        }

        do {
            let response = try await client.switchCcProvider(appType: app.appType, providerId: provider.id)
            guard serverIdentity == settings.activeServerIdentity else { return }
            ccSwitchState.apps = response.apps
            ccSwitchState.errorMessage = response.ok ? nil : (response.error ?? "Failed to switch provider")
            if response.ok {
                Haptics.sent(success: true)
            } else {
                Haptics.sent(success: false)
            }
        } catch {
            guard serverIdentity == settings.activeServerIdentity else { return }
            ccSwitchState.errorMessage = error.localizedDescription
            Haptics.sent(success: false)
        }
    }

    private func reloadCcSwitchStatusForCurrentServer() {
        ccSwitchState = CcSwitchSettingsState()
        Task { await loadCcSwitchStatus() }
    }
}

private struct CcSwitchSettingsState {
    var isLoading = false
    var apps: [CcSwitchAppStatus] = []
    var errorMessage: String?
    var switchingProviderID: String?

    var isBusy: Bool {
        isLoading || switchingProviderID != nil
    }
}

private struct CcSwitchAppSettingsView: View {
    let app: CcSwitchAppStatus
    let isBusy: Bool
    let switchingProviderID: String?
    let onSwitch: (CcSwitchProvider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(activeProviderTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if app.providers.isEmpty {
                    Text("No providers")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(app.providers) { provider in
                let isSwitching = switchingProviderID == provider.id
                Button {
                    guard !provider.isCurrent, !isBusy else { return }
                    onSwitch(provider)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: provider.isCurrent ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(provider.isCurrent ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                                .foregroundStyle(.primary)
                            if let baseUrl = provider.baseUrl, !baseUrl.isEmpty {
                                Text(baseUrl)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("No base URL")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if provider.hasApiKey {
                            Image(systemName: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Has API key")
                        }
                        if isSwitching {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(provider.isCurrent ? "Active" : "Switch")
                                .font(.caption.weight(provider.isCurrent ? .semibold : .regular))
                                .foregroundStyle(provider.isCurrent ? .green : .blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(provider.isCurrent || isBusy)
                .accessibilityLabel(accessibilityLabel(for: provider))
            }
        }
        .padding(.vertical, 4)
    }

    private var activeProviderTitle: String {
        guard let active = app.activeProvider else { return "No active provider" }
        return "Active: \(active.name)"
    }

    private func accessibilityLabel(for provider: CcSwitchProvider) -> String {
        let state = provider.isCurrent ? "active" : "available"
        if let baseUrl = provider.baseUrl, !baseUrl.isEmpty {
            return "\(provider.name), \(state), \(baseUrl)"
        }
        return "\(provider.name), \(state)"
    }
}

enum TestState: Equatable {
    case idle
    case testing
    case success(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Not tested"
        case .testing: "Testing"
        case let .success(message): message
        case let .failed(message): message
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .testing: .orange
        case .success: .green
        case .failed: .red
        }
    }
}
