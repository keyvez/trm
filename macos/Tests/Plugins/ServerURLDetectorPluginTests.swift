import Testing
import Foundation
import SwiftUI
@testable import trm

@MainActor
struct ServerURLDetectorPluginTests {

    /// Helper: create a fresh plugin configured with a registry.
    private func makePlugin() -> ServerURLDetectorPlugin {
        let plugin = ServerURLDetectorPlugin()
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        plugin.configure(registry: registry)
        return plugin
    }

    // MARK: - URL Detection via terminalOutputDidChange

    @Test func detectsHttpLocalhost() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "Server running at http://localhost:3000", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "http://localhost:3000")
    }

    @Test func detectsHttp127001() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "Listening on http://127.0.0.1:8080/api", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "http://127.0.0.1:8080/api")
    }

    @Test func detects0000NormalizedToLocalhost() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://0.0.0.0:5000", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "http://localhost:5000")
    }

    @Test func detectsBareLocalhostWithPort() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "Available at localhost:3000", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "http://localhost:3000")
    }

    @Test func detectsMultipleURLsInSameText() {
        let plugin = makePlugin()
        let text = """
        Frontend: http://localhost:3000
        Backend: http://localhost:8080/api
        """
        plugin.terminalOutputDidChange(paneIndex: 0, text: text, hash: "a")

        #expect(plugin.urls[0]?.count == 2)
    }

    @Test func deduplicatesIdenticalURLs() {
        let plugin = makePlugin()
        let text = """
        http://localhost:3000
        http://localhost:3000
        http://localhost:3000
        """
        plugin.terminalOutputDidChange(paneIndex: 0, text: text, hash: "a")

        #expect(plugin.urls[0]?.count == 1)
    }

    @Test func preservesPositionOrdering() {
        let plugin = makePlugin()
        let text = """
        First: http://localhost:8080
        Second: http://localhost:3000
        """
        plugin.terminalOutputDidChange(paneIndex: 0, text: text, hash: "a")

        let urls = plugin.urls[0]!
        #expect(urls.count == 2)
        #expect(urls[0].absoluteString == "http://localhost:8080")
        #expect(urls[1].absoluteString == "http://localhost:3000")
    }

    @Test func stripsTrailingPunctuation() {
        let plugin = makePlugin()

        // Trailing period
        plugin.terminalOutputDidChange(paneIndex: 0, text: "Visit http://localhost:3000.", hash: "a")
        #expect(plugin.urls[0]?.first?.absoluteString == "http://localhost:3000")

        // Trailing comma
        plugin.terminalOutputDidChange(paneIndex: 1, text: "http://localhost:4000, and more", hash: "b")
        #expect(plugin.urls[1]?.first?.absoluteString == "http://localhost:4000")

        // Trailing semicolon
        plugin.terminalOutputDidChange(paneIndex: 2, text: "http://localhost:5000;", hash: "c")
        #expect(plugin.urls[2]?.first?.absoluteString == "http://localhost:5000")
    }

    @Test func handlesWebSocketURLs() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "WebSocket at ws://localhost:3001/ws", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "ws://localhost:3001/ws")
    }

    @Test func handlesWssWebSocketURLs() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "Secure WS: wss://localhost:3001", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "wss://localhost:3001")
    }

    @Test func handlesIPv6URLs() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://[::1]:3000/path", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "http://[::1]:3000/path")
    }

    // MARK: - Custom Patterns

    @Test func customPatternsDetectURLs() {
        let plugin = makePlugin()
        // Match ngrok URLs: https://xxxx.ngrok.io
        plugin.setCustomPatterns([#"https?://[\w-]+\.ngrok\.io[/\w]*"#])

        plugin.terminalOutputDidChange(paneIndex: 0, text: "Tunnel: https://abc123.ngrok.io/api", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "https://abc123.ngrok.io/api")
    }

    @Test func invalidCustomPatternsAreSilentlySkipped() {
        let plugin = makePlugin()
        // The "[invalid" is a bad regex
        plugin.setCustomPatterns(["[invalid", #"https?://[\w-]+\.ngrok\.io"#])

        // Only the valid pattern should remain
        #expect(plugin.customPatterns.count == 1)
    }

    @Test func customPatternsCheckedBeforeBuiltIn() {
        let plugin = makePlugin()
        // Custom pattern that matches a different format
        plugin.setCustomPatterns([#"https?://myapp\.local:\d+"#])

        let text = "http://myapp.local:9000 and http://localhost:3000"
        plugin.terminalOutputDidChange(paneIndex: 0, text: text, hash: "a")

        let urls = plugin.urls[0]!
        #expect(urls.count == 2)
        // Custom pattern match comes first since it appears first in text
        #expect(urls[0].absoluteString == "http://myapp.local:9000")
        #expect(urls[1].absoluteString == "http://localhost:3000")
    }

    // MARK: - Pane Lifecycle

    @Test func terminalPaneDidCloseRemovesURLs() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://localhost:3000", hash: "a")
        #expect(plugin.urls[0] != nil)

        plugin.terminalPaneDidClose(paneIndex: 0)

        #expect(plugin.urls[0] == nil)
    }

    @Test func stopClearsAllURLs() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://localhost:3000", hash: "a")
        plugin.terminalOutputDidChange(paneIndex: 1, text: "http://localhost:4000", hash: "b")

        plugin.stop()

        #expect(plugin.urls.isEmpty)
    }

    @Test func emptyTextClearsStaleURLsForPane() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://localhost:3000", hash: "a")
        #expect(plugin.urls[0] != nil)

        // Now terminal shows text with no URLs (user ran a different command)
        plugin.terminalOutputDidChange(paneIndex: 0, text: "ls -la\ntotal 42\ndrwxr-xr-x", hash: "b")

        #expect(plugin.urls[0] == nil)
    }

    // MARK: - Overlay Provider

    @Test func overlayViewReturnsNilWhenNoURLs() {
        let plugin = makePlugin()

        #expect(plugin.overlayView(forPane: 0) == nil)
    }

    @Test func overlayViewReturnsNonNilWhenURLsExist() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://localhost:3000", hash: "a")

        #expect(plugin.overlayView(forPane: 0) != nil)
    }

    @Test func overlayViewReturnsNilForPaneWithoutURLs() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://localhost:3000", hash: "a")

        // Pane 1 has no URLs
        #expect(plugin.overlayView(forPane: 1) == nil)
    }

    @Test func overlayAlignmentIsTop() {
        let plugin = makePlugin()
        #expect(plugin.overlayAlignment == .top)
    }

    // MARK: - Multiple Panes

    @Test func tracksURLsPerPane() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://localhost:3000", hash: "a")
        plugin.terminalOutputDidChange(paneIndex: 1, text: "http://localhost:8080", hash: "b")

        #expect(plugin.urls[0]?.first?.absoluteString == "http://localhost:3000")
        #expect(plugin.urls[1]?.first?.absoluteString == "http://localhost:8080")
    }

    @Test func closingOnePaneDoesNotAffectOthers() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://localhost:3000", hash: "a")
        plugin.terminalOutputDidChange(paneIndex: 1, text: "http://localhost:8080", hash: "b")

        plugin.terminalPaneDidClose(paneIndex: 0)

        #expect(plugin.urls[0] == nil)
        #expect(plugin.urls[1]?.first?.absoluteString == "http://localhost:8080")
    }

    // MARK: - Edge Cases

    @Test func httpsURLsDetected() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "https://localhost:3000/secure", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "https://localhost:3000/secure")
    }

    @Test func urlWithPathAndQuery() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "http://localhost:3000/api/v1?key=value", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "http://localhost:3000/api/v1?key=value")
    }

    @Test func bare0000NormalizedToLocalhost() {
        let plugin = makePlugin()
        plugin.terminalOutputDidChange(paneIndex: 0, text: "Listening on 0.0.0.0:9000", hash: "a")

        #expect(plugin.urls[0]?.count == 1)
        #expect(plugin.urls[0]?.first?.absoluteString == "http://localhost:9000")
    }
}
