import SwiftUI
import WebKit

/// An `NSViewRepresentable` wrapper that embeds a `WebViewPane` into SwiftUI.
struct WebViewPaneView: NSViewRepresentable {
    let pane: WebViewPane

    func makeNSView(context: Context) -> NSView {
        return pane
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No dynamic updates needed — the WKWebView manages its own state.
    }
}
