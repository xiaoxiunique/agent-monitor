#if DEBUG
import SwiftUI

struct TerminalScrollUITestHarnessView: View {
    @State private var service = TerminalWebSocketService()

    var body: some View {
        SwiftTermView(
            pane: Self.pane,
            baseURL: URL(string: "http://127.0.0.1:8797")!,
            token: "",
            service: service
        )
        .background(Color.black)
        .ignoresSafeArea()
        .accessibilityIdentifier("terminal-scroll-harness")
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
