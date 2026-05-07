import SwiftUI
import WebKit

struct TerminalPaneView: View {
    let pane: Pane
    @Environment(MonitorStore.self) private var store

    var body: some View {
        Group {
            if let url = store.terminalURL(for: pane) {
                TerminalWebView(url: url)
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                ContentUnavailableView(
                    "Terminal unavailable",
                    systemImage: "terminal",
                    description: Text("Configure service URL and token in Settings.")
                )
            }
        }
    }
}

struct TerminalWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.delaysContentTouches = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
