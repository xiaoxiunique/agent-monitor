import SwiftUI

@main
struct AgentMonitorApp: App {
    @State private var settings: AppSettings
    @State private var store: MonitorStore

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _store = State(initialValue: MonitorStore(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(settings)
                .environment(store)
        }
    }
}
