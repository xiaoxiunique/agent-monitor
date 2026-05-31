import SwiftUI

struct AgentToolsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MonitorStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var ccSwitchState = CcSwitchControlState()

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Picker("Mac", selection: $settings.activeServerID) {
                        ForEach(settings.serverProfiles) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .onChange(of: settings.activeServerID) { _, id in
                        settings.selectServer(id)
                        reloadCcSwitchStatusForCurrentServer()
                        store.start()
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(settings.activeServerDisplayName)
                                .font(.system(size: 15, weight: .semibold))
                            Text(settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Target")
                } footer: {
                    Text("Provider changes apply to the selected Mac service.")
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
                            CcSwitchAppControlView(
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
                    Text("Switches the active Claude Code and Codex providers through ccs-*-switch compatible state on the selected Mac.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AgentMonitorTheme.backgroundGradient(for: colorScheme))
            .navigationTitle("Agent Tools")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: settings.serverURL) { _, _ in
                reloadCcSwitchStatusForCurrentServer()
            }
            .onChange(of: settings.accessToken) { _, _ in
                reloadCcSwitchStatusForCurrentServer()
            }
            .task {
                reloadCcSwitchStatusForCurrentServer()
            }
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
            Haptics.sent(success: response.ok)
        } catch {
            guard serverIdentity == settings.activeServerIdentity else { return }
            ccSwitchState.errorMessage = error.localizedDescription
            Haptics.sent(success: false)
        }
    }

    private func reloadCcSwitchStatusForCurrentServer() {
        ccSwitchState = CcSwitchControlState()
        Task { await loadCcSwitchStatus() }
    }
}

private struct CcSwitchControlState {
    var isLoading = false
    var apps: [CcSwitchAppStatus] = []
    var errorMessage: String?
    var switchingProviderID: String?

    var isBusy: Bool {
        isLoading || switchingProviderID != nil
    }
}

private struct CcSwitchAppControlView: View {
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
