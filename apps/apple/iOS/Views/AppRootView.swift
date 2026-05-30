import SwiftUI
import UIKit

struct AppRootView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("AGENT_MONITOR_TERMINAL_SCROLL_UITEST") {
                TerminalScrollUITestHarnessView()
            } else if settings.hasCompletedOnboarding {
                monitorView
            } else {
                OnboardingView()
            }
            #else
            if settings.hasCompletedOnboarding {
                monitorView
            } else {
                OnboardingView()
            }
            #endif
        }
        .onChange(of: settings.hasCompletedOnboarding) { _, completed in
            if completed {
                UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
                store.start()
            } else {
                store.stop()
            }
        }
        .onChange(of: settings.keepScreenAwake) { _, value in
            UIApplication.shared.isIdleTimerDisabled = value
        }
    }

    private var monitorView: some View {
        MonitorView()
            .task {
                UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
                store.start()
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                store.stop()
            }
    }
}

#Preview {
    let settings = AppSettings(defaults: .init(suiteName: "preview-root")!)
    AppRootView()
        .environment(settings)
        .environment(MonitorStore(settings: settings))
}
