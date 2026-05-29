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
        let tv = AgentMonitorTerminalView(frame: .zero)
        tv.nativeBackgroundColor = UIColor(red: 0.02, green: 0.024, blue: 0.02, alpha: 1)
        tv.nativeForegroundColor = UIColor(red: 0.86, green: 0.90, blue: 0.82, alpha: 1)
        tv.caretColor = UIColor(red: 0.616, green: 0.878, blue: 0.482, alpha: 1)
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isScrollEnabled = false
        tv.alwaysBounceVertical = false
        tv.keyboardDismissMode = .interactive
        tv.allowMouseReporting = true
        tv.inputAccessoryView = nil

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
        coordinator.invalidate()
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
        private var queuedScrollLines = 0
        private var scrollFlushWorkItem: DispatchWorkItem?
        private var inertiaDisplayLink: CADisplayLink?
        private var inertiaVelocityLinesPerSecond: CGFloat = 0
        private var inertiaRemainder: CGFloat = 0
        private var lastInertiaTimestamp: CFTimeInterval = 0

        init(service: TerminalWebSocketService) {
            self.service = service
        }

        deinit {
            invalidate()
        }

        func invalidate() {
            scrollFlushWorkItem?.cancel()
            scrollFlushWorkItem = nil
            inertiaDisplayLink?.invalidate()
            inertiaDisplayLink = nil
        }

        @MainActor
        func installScrollGesture(on terminalView: TerminalView) {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
            gesture.cancelsTouchesInView = true
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.maximumNumberOfTouches = 1
            gesture.delegate = self
            if let terminalView = terminalView as? AgentMonitorTerminalView {
                terminalView.remoteScrollGesture = gesture
            }
            terminalView.addGestureRecognizer(gesture)
            terminalView.panGestureRecognizer.isEnabled = false
            terminalView.panGestureRecognizer.require(toFail: gesture)
            (terminalView as? AgentMonitorTerminalView)?.disableNativePanGestures()
            scrollGesture = gesture
        }

        @MainActor
        @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
            guard let terminalView = terminalView else { return }
            let translation = gesture.translation(in: terminalView)
            gesture.setTranslation(.zero, in: terminalView)

            switch gesture.state {
            case .began:
                stopInertia()
                isTerminalScrollGestureActive = true
                pendingScrollDelta = 0
            case .changed:
                isTerminalScrollGestureActive = true
                let cellHeight = max(terminalView.caretFrame.height, 12)
                pendingScrollDelta += translation.y / cellHeight
                let wholeLines = Int(pendingScrollDelta)
                guard wholeLines != 0 else { return }
                pendingScrollDelta -= CGFloat(wholeLines)
                queueScroll(lines: wholeLines)
            case .ended, .cancelled, .failed:
                let cellHeight = max(terminalView.caretFrame.height, 12)
                let velocity = gesture.velocity(in: terminalView).y / cellHeight
                startInertia(velocityLinesPerSecond: velocity)
                pendingScrollDelta = 0
                isTerminalScrollGestureActive = false
            default:
                break
            }
        }

        private func queueScroll(lines: Int) {
            guard lines != 0 else { return }
            queuedScrollLines += lines
            guard scrollFlushWorkItem == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                self?.flushQueuedScroll()
            }
            scrollFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: workItem)
        }

        private func flushQueuedScroll() {
            scrollFlushWorkItem = nil
            guard queuedScrollLines != 0 else { return }

            let chunk = max(-80, min(80, queuedScrollLines))
            queuedScrollLines -= chunk
            sendScroll(lines: chunk)

            if queuedScrollLines != 0 {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.flushQueuedScroll()
                }
                scrollFlushWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: workItem)
            }
        }

        private func startInertia(velocityLinesPerSecond: CGFloat) {
            stopInertia()
            let clampedVelocity = max(-900, min(900, velocityLinesPerSecond))
            guard abs(clampedVelocity) >= 18 else {
                flushQueuedScroll()
                return
            }

            inertiaVelocityLinesPerSecond = clampedVelocity
            inertiaRemainder = pendingScrollDelta
            lastInertiaTimestamp = 0

            let displayLink = CADisplayLink(target: self, selector: #selector(handleInertiaFrame(_:)))
            displayLink.add(to: .main, forMode: .common)
            inertiaDisplayLink = displayLink
        }

        @objc private func handleInertiaFrame(_ displayLink: CADisplayLink) {
            if lastInertiaTimestamp == 0 {
                lastInertiaTimestamp = displayLink.timestamp
                return
            }

            let elapsed = max(0.001, min(0.05, displayLink.timestamp - lastInertiaTimestamp))
            lastInertiaTimestamp = displayLink.timestamp

            let rawDelta = inertiaVelocityLinesPerSecond * CGFloat(elapsed) + inertiaRemainder
            let wholeLines = Int(rawDelta)
            inertiaRemainder = rawDelta - CGFloat(wholeLines)
            if wholeLines != 0 {
                queueScroll(lines: wholeLines)
            }

            inertiaVelocityLinesPerSecond *= pow(0.88, CGFloat(elapsed) * 60)
            if abs(inertiaVelocityLinesPerSecond) < 8 {
                stopInertia()
                flushQueuedScroll()
            }
        }

        private func stopInertia() {
            inertiaDisplayLink?.invalidate()
            inertiaDisplayLink = nil
            inertiaVelocityLinesPerSecond = 0
            inertiaRemainder = 0
            lastInertiaTimestamp = 0
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
                value == "\u{001B}[C" ||
                value == "\u{001B}[D" ||
                value == "\u{001B}OA" ||
                value == "\u{001B}OB" ||
                value == "\u{001B}OC" ||
                value == "\u{001B}OD"
        }
    }
}

private final class AgentMonitorTerminalView: TerminalView {
    weak var remoteScrollGesture: UIPanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        installKeyboardDismissalObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installKeyboardDismissalObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        disableNativePanGestureIfNeeded(gestureRecognizer)
    }

    override func mouseModeChanged(source: Terminal) {
        disableNativePanGestures()
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        DispatchQueue.main.async { [weak self] in
            self?.disableNativePanGestures()
        }
    }

    func disableNativePanGestures() {
        panGestureRecognizer.isEnabled = false
        for gesture in gestureRecognizers ?? [] {
            disableNativePanGestureIfNeeded(gesture)
        }
    }

    private func installKeyboardDismissalObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardDismissalRequest),
            name: KeyboardDismissal.requestNotification,
            object: nil,
        )
    }

    @objc private func handleKeyboardDismissalRequest() {
        inputView = nil
        reloadInputViews()
        _ = resignFirstResponder()
    }

    private func disableNativePanGestureIfNeeded(_ gesture: UIGestureRecognizer) {
        guard let pan = gesture as? UIPanGestureRecognizer else { return }
        guard pan !== remoteScrollGesture else { return }
        pan.isEnabled = false
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
        if abs(velocity.x) < 1 && abs(velocity.y) < 1 {
            return true
        }
        return abs(velocity.y) >= abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
