import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MonitorStore.self) private var store
    @State private var testState: TestState = .idle

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Service") {
                    TextField("Server URL", text: $settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField("Access Token (optional)", text: $settings.accessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

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

                Section("Reset") {
                    Button(role: .destructive) {
                        settings.reset()
                        store.start()
                    } label: {
                        Label("Reset Settings", systemImage: "arrow.counterclockwise")
                    }
                }
            }
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
        }
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
}

private enum TestState: Equatable {
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
