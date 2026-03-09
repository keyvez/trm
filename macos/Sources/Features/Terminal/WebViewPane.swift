import Cocoa
import WebKit
import Combine

/// A pane that wraps a WKWebView for displaying web content inline in the grid.
///
/// Includes a scriptable API for agent integration: agents can evaluate JavaScript,
/// snapshot the accessibility tree, click elements, fill forms, and more — all via
/// the Text Tap socket API (open_browser, browser_eval, browser_snapshot, etc.).
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
        // Allow insecure localhost for dev servers
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let webView = WKWebView(frame: bounds, configuration: config)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        addSubview(webView)
        self.webView = webView

        if url.absoluteString != "about:blank" {
            webView.load(URLRequest(url: url))
        }
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

    // MARK: - Scriptable API (Agent Browser Integration)

    /// Evaluate arbitrary JavaScript and return the result as a JSON string.
    func evaluateJS(_ script: String) async throws -> String {
        let result = try await webView.evaluateJavaScript(script)
        if let result = result {
            if let jsonData = try? JSONSerialization.data(withJSONObject: result),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
            return String(describing: result)
        }
        return "null"
    }

    /// Snapshot the page's accessibility tree as a simplified JSON structure.
    /// Returns an array of elements with tag, role, text, href, and a ref index.
    func snapshotAccessibilityTree() async throws -> String {
        let js = """
        (() => {
            const elements = [];
            const walk = (node, depth) => {
                if (depth > 10) return;
                if (node.nodeType === Node.ELEMENT_NODE) {
                    const tag = node.tagName.toLowerCase();
                    const role = node.getAttribute('role') || '';
                    const text = (node.innerText || '').substring(0, 100).trim();
                    const href = node.getAttribute('href') || '';
                    const type = node.getAttribute('type') || '';
                    const name = node.getAttribute('name') || '';
                    const id = node.getAttribute('id') || '';
                    const isInteractive = ['a','button','input','select','textarea'].includes(tag)
                        || role === 'button' || role === 'link' || role === 'textbox';
                    if (isInteractive || text.length > 0) {
                        elements.push({
                            ref: elements.length,
                            tag, role, text, href, type, name, id,
                            interactive: isInteractive
                        });
                    }
                }
                for (const child of node.children) {
                    walk(child, depth + 1);
                }
            };
            walk(document.body, 0);
            return JSON.stringify(elements.slice(0, 200));
        })()
        """
        return try await evaluateJS(js)
    }

    /// Click an element by CSS selector.
    func clickElement(selector: String) async throws -> Bool {
        let escapedSelector = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (() => {
            const el = document.querySelector('\(escapedSelector)');
            if (!el) return false;
            el.click();
            return true;
        })()
        """
        let result = try await webView.evaluateJavaScript(js)
        return (result as? Bool) ?? false
    }

    /// Fill a form field by CSS selector with the given text.
    func fillField(selector: String, text: String) async throws -> Bool {
        let escapedSelector = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (() => {
            const el = document.querySelector('\(escapedSelector)');
            if (!el) return false;
            el.focus();
            el.value = '\(escapedText)';
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
        })()
        """
        let result = try await webView.evaluateJavaScript(js)
        return (result as? Bool) ?? false
    }

    /// Get the current page info as JSON: { url, title, readyState }.
    func pageInfo() async throws -> String {
        let js = """
        JSON.stringify({
            url: location.href,
            title: document.title,
            readyState: document.readyState
        })
        """
        return try await evaluateJS(js)
    }

    /// Scroll to a specific position or element.
    func scrollTo(selector: String? = nil, x: Int = 0, y: Int = 0) async throws {
        if let selector = selector {
            let escaped = selector
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = "document.querySelector('\(escaped)')?.scrollIntoView({ behavior: 'smooth', block: 'center' })"
            _ = try await webView.evaluateJavaScript(js)
        } else {
            let js = "window.scrollTo({ left: \(x), top: \(y), behavior: 'smooth' })"
            _ = try await webView.evaluateJavaScript(js)
        }
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

    /// Allow insecure localhost connections for dev servers.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "localhost" || challenge.protectionSpace.host == "127.0.0.1" {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
