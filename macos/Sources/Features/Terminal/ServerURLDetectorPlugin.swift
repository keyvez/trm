import Foundation
import SwiftUI

/// Detects server URLs (e.g. localhost:3000, 127.0.0.1:8080) from terminal
/// pane output and provides a banner overlay.
///
/// This is the first service plugin, replacing the standalone `ServerURLDetector`.
/// It no longer owns a polling timer — it receives content-change callbacks
/// from the shared `TerminalOutputScanner` via `TerminalOutputSubscriber`.
@MainActor
final class ServerURLDetectorPlugin: ObservableObject, ServicePlugin, ObservableServicePlugin, TerminalOutputSubscriber, ServicePluginOverlayProvider {

    // MARK: - ServicePlugin

    let pluginId = "server_url_detector"
    let displayName = "Server URL Detector"

    static let requiredCapabilities: Set<PluginCapability> = [.terminalOutputRead]

    private weak var registry: ServicePluginRegistry?

    func configure(registry: ServicePluginRegistry) {
        self.registry = registry
    }

    func start() {
        // No-op — driven by scanner callbacks.
    }

    func stop() {
        urls.removeAll()
        lockedPanes.removeAll()
    }

    // MARK: - Published State

    /// All unique detected server URLs for each terminal pane index, ordered by
    /// position in the output (earliest first).
    @Published var urls: [Int: [URL]] = [:]

    // MARK: - Configuration

    /// Extra regex patterns supplied by the user (from config).
    /// These are checked *before* the built-in patterns.
    var customPatterns: [NSRegularExpression] = []

    /// Panes whose URLs have been locked in. Once URLs are detected for a pane,
    /// further scans are ignored — the URLs from the initial startup output persist
    /// until the pane closes.
    private var lockedPanes: Set<Int> = []

    /// Compile user-supplied pattern strings into regex objects.
    /// Invalid patterns are silently skipped.
    func setCustomPatterns(_ rawPatterns: [String]) {
        customPatterns = rawPatterns.compactMap { raw in
            try? NSRegularExpression(pattern: raw, options: [.caseInsensitive])
        }
    }

    // MARK: - TerminalOutputSubscriber

    func terminalOutputDidChange(paneId: Int, text: String, hash: String) {
        // Once URLs are locked for a pane, ignore further updates.
        // The startup URLs persist until the pane closes.
        guard !lockedPanes.contains(paneId) else { return }

        // Scan the first 500 lines — server URLs are printed at startup.
        let scanText: String
        let lines = text.components(separatedBy: "\n")
        if lines.count > 500 {
            scanText = lines.prefix(500).joined(separator: "\n")
        } else {
            scanText = text
        }

        let found = extractServerURLs(from: scanText)
        if !found.isEmpty {
            urls[paneId] = found
            lockedPanes.insert(paneId)
        }
    }

    func terminalCommandDidFinish(paneId: Int) {
        // A command finished (shell prompt returned). Unlock the pane so
        // the next command's startup URLs can be detected.
        urls.removeValue(forKey: paneId)
        lockedPanes.remove(paneId)
    }

    func terminalPaneDidClose(paneId: Int) {
        urls.removeValue(forKey: paneId)
        lockedPanes.remove(paneId)
    }

    // MARK: - ServicePluginOverlayProvider

    var overlayAlignment: Alignment { .top }

    func overlayView(forPaneId paneId: Int) -> AnyView? {
        guard let paneURLs = urls[paneId], !paneURLs.isEmpty else { return nil }
        return AnyView(
            ServerURLBannerView(urls: paneURLs)
                .padding(.top, 8)
        )
    }

    // MARK: - URL Extraction (unchanged from ServerURLDetector)

    /// Built-in regex patterns that match common dev-server output.
    private static let builtinPatterns: [NSRegularExpression] = {
        let raw = [
            // Full URLs with http(s) scheme
            #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):\d{2,5}[/\w\-._~:?#\[\]@!$&'()*+,;=%]*"#,
            // WebSocket URLs with ws(s) scheme
            #"wss?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):\d{2,5}[/\w\-._~:?#\[\]@!$&'()*+,;=%]*"#,
            // Bare host:port (no scheme)
            #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0):\d{2,5}"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// All patterns: custom first, then built-in.
    private var allPatterns: [NSRegularExpression] {
        customPatterns + Self.builtinPatterns
    }

    /// Returns all unique server URLs found in `text`, ordered by position.
    private func extractServerURLs(from text: String) -> [URL] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        struct PositionedMatch: Hashable {
            let location: Int
            let raw: String
        }
        var seen = Set<String>()
        var matches: [PositionedMatch] = []

        for pattern in allPatterns {
            for result in pattern.matches(in: text, range: fullRange) {
                let raw = nsText.substring(with: result.range)
                let normalized = normalizeURL(raw)
                guard !seen.contains(normalized) else { continue }
                seen.insert(normalized)
                matches.append(PositionedMatch(location: result.range.location, raw: raw))
            }
        }

        matches.sort { $0.location < $1.location }

        return matches.compactMap { m in
            URL(string: normalizeURL(m.raw))
        }
    }

    /// Normalize a raw matched string into a well-formed URL string.
    private func normalizeURL(_ raw: String) -> String {
        var s = raw

        // Strip trailing punctuation
        while s.hasSuffix(".") || s.hasSuffix(",") || s.hasSuffix(";") {
            s = String(s.dropLast())
        }

        // Ensure scheme
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://")
            && !lower.hasPrefix("ws://") && !lower.hasPrefix("wss://") {
            s = "http://\(s)"
        }

        // Normalise 0.0.0.0 -> localhost
        s = s.replacingOccurrences(of: "://0.0.0.0:", with: "://localhost:")

        return s
    }
}
