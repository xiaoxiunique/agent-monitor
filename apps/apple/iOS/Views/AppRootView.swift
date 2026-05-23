import SwiftUI
import UIKit

struct AppRootView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var backgroundAudio = BackgroundAudioKeepAlive()

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                MonitorView()
                    .task {
                        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
                        applyBackgroundAudioSetting(settings.backgroundAudioKeepAlive)
                        store.start()
                    }
                    .onDisappear {
                        UIApplication.shared.isIdleTimerDisabled = false
                        backgroundAudio.setEnabled(false)
                        store.stop()
                    }
            } else {
                OnboardingView()
            }
        }
        .environment(backgroundAudio)
        .onChange(of: settings.hasCompletedOnboarding) { _, completed in
            if completed {
                UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
                applyBackgroundAudioSetting(settings.backgroundAudioKeepAlive)
                store.start()
            } else {
                store.stop()
            }
        }
        .onChange(of: settings.keepScreenAwake) { _, value in
            UIApplication.shared.isIdleTimerDisabled = value
        }
        .onChange(of: settings.backgroundAudioKeepAlive) { _, value in
            applyBackgroundAudioSetting(value)
        }
    }

    private func applyBackgroundAudioSetting(_ enabled: Bool) {
        guard backgroundAudio.setEnabled(enabled) else {
            settings.backgroundAudioKeepAlive = false
            return
        }
    }
}

#Preview {
    let settings = AppSettings(defaults: .init(suiteName: "preview-root")!)
    AppRootView()
        .environment(settings)
        .environment(MonitorStore(settings: settings))
}
