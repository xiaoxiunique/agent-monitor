#if DEBUG
import SwiftUI

struct TerminalScrollUITestHarnessView: View {
    @State private var service = TerminalWebSocketService()
    @State private var isLogMode = false

    var body: some View {
        if isLogMode {
            Text("Log Mode")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea()
                .accessibilityIdentifier("terminal-log-mode-harness")
        } else {
            SwiftTermView(
                pane: Self.pane,
                baseURL: URL(string: "http://127.0.0.1:8797")!,
                token: "",
                service: service,
                onBrowseLogRequest: ProcessInfo.processInfo.arguments.contains("AGENT_MONITOR_TERMINAL_LOG_SWITCH_UITEST") ? {
                    isLogMode = true
                } : nil
            )
            .background(Color.black)
            .ignoresSafeArea()
            .accessibilityIdentifier("terminal-scroll-harness")
        }
    }

    private static let pane = Pane(
        id: "%terminal-scroll-ui-test",
        target: "ui-test",
        session: "ui_test",
        windowIndex: "0",
        windowName: "Terminal Scroll UI Test",
        paneIndex: "0",
        command: "tmux",
        path: "/tmp",
        active: true,
        pid: nil,
        title: "Terminal Scroll UI Test",
        tail: "",
        status: .running,
        reason: "UI test harness",
        updatedAt: Date(),
        messages: nil
    )
}
#endif
