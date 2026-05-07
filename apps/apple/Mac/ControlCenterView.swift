import SwiftUI

struct ControlCenterView: View {
    let service: ServiceController
    let environment: EnvironmentController

    var body: some View {
        ZStack {
            GlassBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    HStack(spacing: 8) {
                        StatusPill(title: service.state.title, systemImage: service.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill", tint: service.isReachable ? .green : .red)
                        StatusPill(title: environment.tmuxVersion ?? "tmux missing", systemImage: environment.tmuxPath == nil ? "terminal.fill" : "terminal", tint: environment.tmuxPath == nil ? .orange : .green)
                        StatusPill(title: service.phoneURLKind, systemImage: service.tailscaleHost == nil ? "wifi" : "network", tint: service.tailscaleHost == nil ? .secondary : .blue)
                    }

                    OfficialGlassContainer {
                        VStack(spacing: 12) {
                            ServiceStatusSection(service: service, environment: environment)
                            EnvironmentStatusSection(service: service, environment: environment)
                            CommandStatusSection(environment: environment)
                        }
                    }

                    if !environment.lastMessage.isEmpty || !service.lastMessage.isEmpty {
                        Text(environment.lastMessage.isEmpty ? service.lastMessage : environment.lastMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.horizontal, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 560, height: 610)
        .task {
            await environment.refresh()
            await service.refreshStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.35), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Monitor")
                    .font(.title2.weight(.semibold))
                Text("Local setup and service control")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await service.refreshStatus()
                    await environment.refresh()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

private struct ServiceStatusSection: View {
    let service: ServiceController
    let environment: EnvironmentController

    var body: some View {
        GlassCard(title: "Service", systemImage: "server.rack") {
            StatusRow(
                icon: service.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill",
                title: "HTTP service",
                value: service.state.title,
                isGood: service.isReachable
            )

            CopyRow(title: "Local", value: service.dashboardURL.absoluteString)
            CopyRow(title: service.phoneURLKind, value: service.phoneDashboardURL.absoluteString)

            if let lanDashboardURL = service.lanDashboardURL, service.tailscaleHost != nil {
                CopyRow(title: "LAN", value: lanDashboardURL.absoluteString)
            }

            HStack {
                Button {
                    service.openDashboard()
                } label: {
                    Label("Open Dashboard", systemImage: "safari")
                }
                .disabled(!service.isReachable)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    service.copyPhoneDashboardURL()
                } label: {
                    Label("Copy Phone URL", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    Task { await service.restartOwnedService() }
                } label: {
                    Label("Restart", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!service.ownsProcess)
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }
}

private struct EnvironmentStatusSection: View {
    let service: ServiceController
    let environment: EnvironmentController

    var body: some View {
        GlassCard(title: "Environment", systemImage: "macbook.and.iphone") {
            StatusRow(
                icon: environment.tmuxPath == nil ? "xmark.circle.fill" : "checkmark.circle.fill",
                title: "tmux",
                value: environment.tmuxVersion ?? "Missing",
                isGood: environment.tmuxPath != nil
            )

            if let tmuxPath = environment.tmuxPath {
                Text(tmuxPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                HStack {
                    Text(environment.brewPath == nil ? "Homebrew is required to install tmux." : "tmux is required for managed agent sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        environment.openTmuxInstallTerminal()
                    } label: {
                        Label(environment.brewPath == nil ? "Open Homebrew" : "Install tmux", systemImage: "shippingbox")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack {
                StatusPill(title: service.tailscaleHost == nil ? "Tailscale not detected" : "Tailscale \(service.tailscaleHost!)", systemImage: service.tailscaleHost == nil ? "circle" : "checkmark.circle.fill", tint: service.tailscaleHost == nil ? .secondary : .green)
                if let lanHost = service.lanHost {
                    StatusPill(title: "LAN \(lanHost)", systemImage: "wifi", tint: .blue)
                }
                Spacer()
                Button {
                    environment.copyDiagnostics(service: service)
                } label: {
                    Label("Copy Diagnostics", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

private struct CommandStatusSection: View {
    let environment: EnvironmentController

    var body: some View {
        GlassCard(title: "Shell Commands", systemImage: "terminal") {
            CommandRow(name: "cc", detail: "Open Claude in a per-directory tmux session.", state: environment.ccState)
            Hairline()
            CommandRow(name: "cx", detail: "Open Codex in a per-directory tmux session.", state: environment.cxState)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Wrappers are installed to ~/.agent-monitor/bin and added to PATH from ~/.zshrc. Existing aliases or functions are reported as conflicts instead of being overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    Task { await environment.installWrappers() }
                } label: {
                    Label(environment.ccState.isInstalled && environment.cxState.isInstalled ? "Reinstall cc/cx" : "Install cc/cx", systemImage: "terminal")
                }
                .disabled(environment.isWorking)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    Task { await environment.refresh() }
                } label: {
                    Label("Check Commands", systemImage: "magnifyingglass")
                }
                .disabled(environment.isWorking)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
    }
}

private struct GlassCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 9) {
                content
            }
        }
        .padding(14)
        .officialGlassCard(cornerRadius: 20)
    }
}

private struct OfficialGlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func officialGlassCard(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 22, x: 0, y: 14)
        } else {
            self
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay {
                            shape
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.46),
                                            .white.opacity(0.16),
                                            Color.accentColor.opacity(0.06)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .blendMode(.plusLighter)
                        }
                }
                .overlay {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.88),
                                    .white.opacity(0.24),
                                    .black.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .overlay(alignment: .topLeading) {
                    shape
                        .stroke(.white.opacity(0.36), lineWidth: 0.5)
                        .blur(radius: 0.5)
                        .padding(1)
                }
                .shadow(color: .white.opacity(0.34), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(0.16), radius: 28, x: 0, y: 18)
        }
    }
}

private struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.14),
                    Color(nsColor: .windowBackgroundColor).opacity(0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            Color.accentColor.opacity(0.10),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 260)
                .rotationEffect(.degrees(-9))
                .offset(x: -120, y: -130)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.blue.opacity(0.08),
                            .white.opacity(0.22)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 220)
                .rotationEffect(.degrees(11))
                .offset(x: 90, y: 210)
        }
        .ignoresSafeArea()
    }
}

private struct StatusRow: View {
    let icon: String
    let title: String
    let value: String
    let isGood: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(isGood ? .green : .red)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

private struct CopyRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

private struct CommandRow: View {
    let name: String
    let detail: String
    let state: EnvironmentController.CommandState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stateIcon)
                .foregroundStyle(stateColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    Text(state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let stateDetail {
                    Text(stateDetail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
    }

    private var stateIcon: String {
        switch state {
        case .installed, .managed: "checkmark.circle.fill"
        case .missing: "xmark.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch state {
        case .installed: .green
        case .managed: .blue
        case .missing: .red
        case .conflict: .orange
        }
    }

    private var stateDetail: String? {
        switch state {
        case .installed(let path): path
        case .managed(let detail): detail
        case .missing: nil
        case .conflict(let detail): detail
        }
    }
}

private struct StatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.6)
            }
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.separator.opacity(0.55))
            .frame(height: 0.5)
            .padding(.leading, 28)
    }
}
