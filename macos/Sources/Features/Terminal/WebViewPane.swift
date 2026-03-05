import Cocoa
import WebKit
import Combine

/// A pane that wraps a WKWebView for displaying web content inline in the grid.
class WebViewPane: NSView, ObservableObject, Identifiable, WKNavigationDelegate {
    let id = UUID()
    let initialURL: URL

    @Published var title: String = ""
    @Published var currentURL: URL?
    @Published var isLoading: Bool = true

    private(set) var webView: WKWebView!

    init(url: URL) {
        self.initialURL = url
        self.currentURL = url
        super.init(frame: .zero)

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: bounds, configuration: config)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        self.webView = webView

        webView.load(URLRequest(url: url))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Navigation Helpers

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func openInDefaultBrowser() {
        guard let url = webView.url ?? currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    func navigate(to urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let urlStr = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: urlStr) else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        title = webView.title ?? initialURL.host ?? "Web"
        currentURL = webView.url ?? initialURL
        isLoading = false
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}
