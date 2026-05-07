import SwiftUI
import UIKit

struct AppRootView: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        MonitorView()
        .task {
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
            store.start()
        }
        .onChange(of: settings.keepScreenAwake) { _, value in
            UIApplication.shared.isIdleTimerDisabled = value
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
