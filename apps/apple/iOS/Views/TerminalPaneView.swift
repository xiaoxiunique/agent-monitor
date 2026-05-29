import SwiftUI
import SwiftTerm

struct TerminalPaneView: View {
    let pane: Pane
    @Environment(MonitorStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var service = TerminalWebSocketService()

    var body: some View {
        Group {
            if let client = store.makeClient() {
                SwiftTermView(
                    pane: pane,
                    baseURL: client.baseURL,
                    token: client.token,
                    service: service
                )
            } else {
                ContentUnavailableView(
                    "Terminal unavailable",
                    systemImage: "terminal",
                    description: Text("Configure service URL and token in Settings.")
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                service.reconnectIfPossible()
            case .background:
                service.suspendForBackground()
            default:
                break
            }
        }
    }
}

struct SwiftTermView: UIViewRepresentable {
    let pane: Pane
    let baseURL: URL
    let token: String
    let service: TerminalWebSocketService

    func makeCoordinator() -> Coordinator {
        Coordinator(service: service)
    }

    @MainActor
    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.nativeBackgroundColor = UIColor(red: 0.02, green: 0.024, blue: 0.02, alpha: 1)
        tv.nativeForegroundColor = UIColor(red: 0.86, green: 0.90, blue: 0.82, alpha: 1)
        tv.caretColor = UIColor(red: 0.616, green: 0.878, blue: 0.482, alpha: 1)
        tv.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.allowMouseReporting = true

        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.installScrollGesture(on: tv)

        service.onData = { [weak tv] text in
            tv?.feed(text: text)
        }
        service.onStateChange = { [weak tv] newState in
            switch newState {
            case .closed(let code):
                tv?.feed(text: "\r\n[session closed, exit code: \(code ?? 0)]")
            case .error(let msg):
                tv?.feed(text: "\r\n[error: \(msg)]")
            case .disconnected:
                tv?.feed(text: "\r\n[disconnected]")
            default:
                break
            }
        }

        // Defer connection so the view has laid out and SwiftTerm knows its size
        DispatchQueue.main.async {
            let terminal = tv.getTerminal()
            service.connect(with: .init(
                baseURL: baseURL,
                token: token,
                paneId: pane.id,
                cols: terminal.cols,
                rows: terminal.rows
            ))
        }

        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        let svc = coordinator.service
        MainActor.assumeIsolated { svc.disconnect() }
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        // Safe: TerminalViewDelegate is called on main thread, service is @MainActor
        let service: TerminalWebSocketService
        weak var terminalView: TerminalView?
        private var scrollGesture: UIPanGestureRecognizer?
        private var pendingScrollDelta: CGFloat = 0
        private var isTerminalScrollGestureActive = false

        init(service: TerminalWebSocketService) {
            self.service = service
        }

        @MainActor
        func installScrollGesture(on terminalView: TerminalView) {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
            gesture.cancelsTouchesInView = true
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            terminalView.addGestureRecognizer(gesture)
            terminalView.panGestureRecognizer.require(toFail: gesture)
            scrollGesture = gesture
        }

        @MainActor
        @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
            guard let terminalView = terminalView else { return }
            let translation = gesture.translation(in: terminalView)
            gesture.setTranslation(.zero, in: terminalView)

            switch gesture.state {
            case .began:
                isTerminalScrollGestureActive = true
                pendingScrollDelta = 0
            case .changed:
                isTerminalScrollGestureActive = true
                let cellHeight = max(terminalView.caretFrame.height, 12)
                pendingScrollDelta += translation.y / cellHeight
                let wholeLines = Int(pendingScrollDelta)
                guard wholeLines != 0 else { return }
                pendingScrollDelta -= CGFloat(wholeLines)
                sendScroll(lines: wholeLines)
            case .ended, .cancelled, .failed:
                pendingScrollDelta = 0
                isTerminalScrollGestureActive = false
            default:
                break
            }
        }

        private func sendScroll(lines: Int) {
            let svc = service
            MainActor.assumeIsolated { svc.sendScroll(lines: lines) }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let str = String(bytes: data, encoding: .utf8) ?? ""
            guard !str.isEmpty else { return }
            if isTerminalScrollGestureActive && Self.isCursorKeyInput(str) {
                return
            }
            let svc = service
            MainActor.assumeIsolated { svc.sendInput(str) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let svc = service
            MainActor.assumeIsolated { svc.sendResize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
        }

        func bell(source: TerminalView) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        private static func isCursorKeyInput(_ value: String) -> Bool {
            value == "\u{001B}[A" ||
                value == "\u{001B}[B" ||
                value == "\u{001B}OA" ||
                value == "\u{001B}OB"
        }
    }
}

extension SwiftTermView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === scrollGesture,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let terminalView else {
            return true
        }
        let velocity = pan.velocity(in: terminalView)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
