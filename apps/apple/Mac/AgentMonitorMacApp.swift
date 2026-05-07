import SwiftUI

@main
struct AgentMonitorMacApp: App {
    @State private var service = ServiceController()
    @State private var environment = EnvironmentController()

    var body: some Scene {
        MenuBarExtra {
            AgentMonitorMenu(service: service, environment: environment)
        } label: {
            Image(systemName: service.menuIcon)
        }
        .menuBarExtraStyle(.menu)

        Window("Agent Monitor", id: "control-center") {
            ControlCenterView(service: service, environment: environment)
        }
        .windowResizability(.contentSize)
    }
}

private struct AgentMonitorMenu: View {
    let service: ServiceController
    let environment: EnvironmentController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(service.statusTitle)
        Text(service.dashboardURL.absoluteString)
            .font(.caption)
        Text("\(service.phoneURLKind): \(service.phoneDashboardURL.absoluteString)")
            .font(.caption)

        if let lanDashboardURL = service.lanDashboardURL, service.tailscaleHost != nil {
            Text("LAN: \(lanDashboardURL.absoluteString)")
                .font(.caption)
        }

        if !service.lastMessage.isEmpty {
            Divider()
            Text(service.lastMessage)
                .lineLimit(3)
        }

        Divider()

        Button("Open Control Center") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "control-center")
        }

        Button("Open Dashboard") {
            service.openDashboard()
        }
        .disabled(!service.isReachable)

        Button("Copy Phone URL") {
            service.copyPhoneDashboardURL()
        }

        Button("Start Service") {
            Task { await service.startOwnedService() }
        }
        .disabled(service.isReachable)

        Button("Restart Owned Service") {
            Task { await service.restartOwnedService() }
        }
        .disabled(!service.ownsProcess)

        Button("Stop Owned Service") {
            service.stopOwnedService()
        }
        .disabled(!service.ownsProcess)

        Divider()

        Button("Reveal Service Folder") {
            service.revealServiceFolder()
        }

        Button("Copy Diagnostics") {
            environment.copyDiagnostics(service: service)
        }

        Button("Refresh Status") {
            Task {
                await service.refreshStatus()
                await environment.refresh()
            }
        }

        Divider()

        Button("Quit") {
            service.stopOwnedService()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
