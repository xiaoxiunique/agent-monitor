import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MonitorStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    @State private var connectionState: TestState = .idle
    @State private var voiceTestState: TestState = .idle
    @State private var selectedStep: Step = .service
    @State private var didInitializeStep = false

    private enum Step: Int, CaseIterable {
        case service
        case voice
    }

    private enum Field {
        case serverURL
        case accessToken
        case tencentAppID
        case tencentSecretID
        case tencentSecretKey
        case tencentToken
    }

    private var canContinueFromService: Bool {
        !settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTencentCredentials: Bool {
        !settings.tencentASRAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !settings.tencentASRSecretID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !settings.tencentASRSecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var bindableSettings = settings

        NavigationStack {
            ZStack {
                AgentMonitorTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        stepIndicator

                        switch selectedStep {
                        case .service:
                            serviceStep(settings: $bindableSettings)
                        case .voice:
                            voiceStep(settings: $bindableSettings)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 34)
                    .padding(.bottom, 28)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !didInitializeStep else { return }
                selectedStep = .service
                didInitializeStep = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("Set up Agent Monitor")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.primary)

            Text("Connect the iPhone app to your Mac service, then optionally configure Tencent voice input.")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= selectedStep.rawValue ? Color.accentColor : AgentMonitorTheme.softFill(for: colorScheme))
                    .frame(height: 5)
            }
        }
    }

    private func serviceStep(settings: Bindable<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingSection(title: "Mac service", systemImage: "network") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Server URL")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    TextField("http://192.168.1.10:8797", text: settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .focused($focusedField, equals: .serverURL)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .accessToken }
                        .onChange(of: self.settings.serverURL) { _, _ in
                            connectionState = .idle
                        }
                        .onAppear {
                            if self.settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                focusedField = .serverURL
                            }
                        }
                        .onboardingFieldStyle()

                    SecureField("Access Token (optional)", text: settings.accessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .accessToken)
                        .onChange(of: self.settings.accessToken) { _, _ in
                            connectionState = .idle
                        }
                        .onboardingFieldStyle()

                    Button {
                        Task { await testConnection() }
                    } label: {
                        OnboardingActionLabel(
                            title: "Test Connection",
                            systemImage: "wifi",
                            state: connectionState
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(connectionState == .testing || !canContinueFromService)

                    if case let .failed(message) = connectionState {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if case let .success(message) = connectionState {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                selectedStep = .voice
            } label: {
                Text("Continue")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(canContinueFromService ? Color.accentColor : Color.gray.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canContinueFromService)
        }
    }

    private func voiceStep(settings: Bindable<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingSection(title: "Voice input", systemImage: "waveform") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Recognition", selection: settings.voiceRecognitionProviderRaw) {
                        ForEach(VoiceRecognitionProvider.allCases) { provider in
                            Text(provider.title).tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: self.settings.voiceRecognitionProviderRaw) { _, _ in
                        voiceTestState = .idle
                    }

                    Text("Tencent is recommended for better Chinese transcription. You can skip this and configure it later in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if self.settings.voiceRecognitionProvider == .tencent {
                        TextField("Tencent AppID", text: settings.tencentASRAppID)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .tencentAppID)
                            .onChange(of: self.settings.tencentASRAppID) { _, _ in voiceTestState = .idle }
                            .onboardingFieldStyle()

                        TextField("Tencent SecretId", text: settings.tencentASRSecretID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .tencentSecretID)
                            .onChange(of: self.settings.tencentASRSecretID) { _, _ in voiceTestState = .idle }
                            .onboardingFieldStyle()

                        SecureField("Tencent SecretKey", text: settings.tencentASRSecretKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .tencentSecretKey)
                            .onChange(of: self.settings.tencentASRSecretKey) { _, _ in voiceTestState = .idle }
                            .onboardingFieldStyle()

                        SecureField("Tencent Token (optional)", text: settings.tencentASRToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .tencentToken)
                            .onChange(of: self.settings.tencentASRToken) { _, _ in voiceTestState = .idle }
                            .onboardingFieldStyle()

                        Button {
                            Task { await testTencentASR() }
                        } label: {
                            OnboardingActionLabel(
                                title: "Test Tencent Credentials",
                                systemImage: "key",
                                state: voiceTestState
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(voiceTestState == .testing || !hasTencentCredentials)

                        if case let .failed(message) = voiceTestState {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if case let .success(message) = voiceTestState {
                            Text("\(message) Microphone recording is tested from the composer.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    selectedStep = .service
                } label: {
                    Text("Back")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(AgentMonitorTheme.softFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    completeOnboarding()
                } label: {
                    Text("Start Monitoring")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func testConnection() async {
        guard let client = store.makeClient() else {
            connectionState = .failed("Invalid URL")
            Haptics.sent(success: false)
            return
        }

        connectionState = .testing
        do {
            let snapshot = try await client.snapshot()
            connectionState = .success("Connected. Found \(snapshot.panes.count) panes.")
            Haptics.sent(success: true)
        } catch {
            connectionState = .failed(error.localizedDescription)
            Haptics.sent(success: false)
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

    private func completeOnboarding() {
        focusedField = nil
        settings.hasCompletedOnboarding = true
        Haptics.sent(success: true)
    }
}

private struct OnboardingSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            content
        }
        .padding(16)
        .background(AgentMonitorTheme.elevatedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AgentMonitorTheme.separator(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: AgentMonitorTheme.cardShadow(for: colorScheme), radius: 12, x: 0, y: 5)
    }
}

private struct OnboardingActionLabel: View {
    let title: String
    let systemImage: String
    let state: TestState

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            if state == .testing {
                ProgressView()
                    .controlSize(.small)
            }

            Text(state.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension View {
    func onboardingFieldStyle() -> some View {
        self
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    let settings = AppSettings(defaults: .init(suiteName: "preview-onboarding")!)
    OnboardingView()
        .environment(settings)
        .environment(MonitorStore(settings: settings))
}
