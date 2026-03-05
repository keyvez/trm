import Foundation
import SwiftUI

/// A single shortcut extracted from terminal output.
struct ExtractedShortcut: Identifiable, Equatable {
    let id: String          // stable ID from key + label
    let key: String         // "b", "d", "c", "q", "h"
    let label: String       // "open a browser", "open devtools"
    let rawMatch: String    // the full matched text for dedup
}

/// Detects inline keyboard shortcuts printed by dev tools (Vite, Next.js, Expo,
/// Flutter, Wrangler, etc.) and surfaces them as clickable pill buttons on the pane.
///
/// Uses a two-pass approach:
///
/// **Pass 1 — Inline patterns** (high confidence, matched individually):
///   - Bracket:  `[b] open a browser`
///   - Press:    `press h to show help`
///   - Parens:   `(r) restart`
///
/// **Pass 2 — Block patterns** (lower confidence per-line, require 2+ consecutive
/// lines sharing the same structure to count):
///   - Dash:     `h - show help`  or  `h – show help`
///   - Bare:     `r Hot reload.`  (single letter + space + description)
///
/// Block detection avoids false positives: a lone `r Hot reload` line could be
/// anything, but five consecutive lines like that are clearly a shortcut listing.
@MainActor
final class ShortcutExtractorPlugin: ObservableObject, ServicePlugin, ObservableServicePlugin, TerminalOutputSubscriber, ServicePluginOverlayProvider {

    // MARK: - ServicePlugin

    let pluginId = "shortcut_extractor"
    let displayName = "Shortcut Extractor"

    static let requiredCapabilities: Set<PluginCapability> = [.terminalOutputRead]

    private weak var registry: ServicePluginRegistry?

    func configure(registry: ServicePluginRegistry) {
        self.registry = registry
    }

    func start() {
        // No-op — driven by scanner callbacks.
    }

    func stop() {
        shortcuts.removeAll()
    }

    // MARK: - Published State

    /// All unique detected shortcuts for each terminal pane index.
    @Published var shortcuts: [Int: [ExtractedShortcut]] = [:]

    // MARK: - Regex Patterns

    // --- Pass 1: high-confidence inline patterns (matched individually) ---

    /// `[b] open a browser`
    private static let bracketPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\[(\w)\]\s+(.+?)(?=\s*\[\w\]|\s{2,}|$)"#,
            options: [.anchorsMatchLines]
        )
    }()

    /// `press h to show help`
    private static let pressPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"press\s+(\w)\s+to\s+(.+?)$"#,
            options: [.caseInsensitive, .anchorsMatchLines]
        )
    }()

    /// `(r) restart`
    private static let parenPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\((\w)\)\s+(.+?)(?=\s*\(\w\)|\s{2,}|$)"#,
            options: [.anchorsMatchLines]
        )
    }()

    /// High-confidence patterns that are matched individually.
    private static let inlinePatterns: [NSRegularExpression] = [
        bracketPattern, pressPattern, parenPattern,
    ]

    // --- Pass 2: block patterns (require 2+ consecutive matching lines) ---

    /// `h - show help` or `h – show help`
    private static let dashLinePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^\s*(\w)\s*[-–—]\s+(.+?)\s*$"#,
            options: [.anchorsMatchLines]
        )
    }()

    /// `r Hot reload.` — bare single letter at line start + description.
    /// Requires the label to start with a capital letter or be a known verb
    /// to reduce noise.
    private static let bareLinePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^\s*(\w)\s{1,3}([A-Z].+?)\s*$"#,
            options: [.anchorsMatchLines]
        )
    }()

    /// Block patterns: each is applied line-by-line and only lines that appear
    /// in a run of 2+ consecutive matches are kept.
    private static let blockPatterns: [NSRegularExpression] = [
        dashLinePattern, bareLinePattern,
    ]

    // MARK: - TerminalOutputSubscriber

    func terminalOutputDidChange(paneId: Int, text: String, hash: String) {
        let found = extractShortcuts(from: text)

        if found.isEmpty {
            // No shortcuts detected in the current viewport — clear any stale
            // shortcuts so pills disappear once the shortcut listing scrolls
            // off screen or the process changes.
            if shortcuts[paneId] != nil {
                shortcuts.removeValue(forKey: paneId)
            }
            return
        }

        // Replace shortcuts for this pane with the current detection results.
        // This ensures only shortcuts visible in the current viewport are shown,
        // preventing stale shortcuts from other pane states from persisting.
        if shortcuts[paneId] != found {
            shortcuts[paneId] = found
        }
    }

    func terminalPaneDidClose(paneId: Int) {
        shortcuts.removeValue(forKey: paneId)
    }

    // MARK: - ServicePluginOverlayProvider

    var overlayAlignment: Alignment { .bottom }

    func overlayView(forPaneId paneId: Int) -> AnyView? {
        guard let paneShortcuts = shortcuts[paneId], !paneShortcuts.isEmpty else { return nil }
        return AnyView(
            ShortcutExtractorOverlayView(
                shortcuts: paneShortcuts,
                onExecute: { shortcut in
                    NotificationCenter.default.post(
                        name: .trmShortcutExecute,
                        object: nil,
                        userInfo: [
                            "key": shortcut.key,
                            "paneId": paneId,
                        ]
                    )
                }
            )
            .padding(.bottom, 8)
            .padding(.leading, 8)
        )
    }

    // MARK: - Shortcut Extraction

    private struct PositionedMatch {
        let location: Int
        let key: String
        let label: String
        let rawMatch: String
    }

    /// Returns all unique shortcuts found in `text`, ordered by position.
    private func extractShortcuts(from text: String) -> [ExtractedShortcut] {
        var seen = Set<String>()
        var matches: [PositionedMatch] = []

        // Pass 1: high-confidence inline patterns
        let inlineMatches = matchInlinePatterns(in: text)
        for m in inlineMatches {
            if insertIfNew(m, into: &matches, seen: &seen) {}
        }

        // Pass 2: block patterns — only keep runs of 2+ consecutive matching lines
        let blockMatches = matchBlockPatterns(in: text)
        for m in blockMatches {
            if insertIfNew(m, into: &matches, seen: &seen) {}
        }

        matches.sort { $0.location < $1.location }

        return matches.map { m in
            ExtractedShortcut(
                id: "\(m.key):\(m.label)",
                key: m.key,
                label: m.label,
                rawMatch: m.rawMatch
            )
        }
    }

    /// Match high-confidence inline patterns (each match stands on its own).
    private func matchInlinePatterns(in text: String) -> [PositionedMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [PositionedMatch] = []

        for pattern in Self.inlinePatterns {
            for result in pattern.matches(in: text, range: fullRange) {
                guard let m = extractMatch(from: result, in: nsText) else { continue }
                results.append(m)
            }
        }
        return results
    }

    /// Match block patterns — only return matches that appear in runs of 2+
    /// consecutive non-blank lines sharing the same pattern.
    private func matchBlockPatterns(in text: String) -> [PositionedMatch] {
        let lines = text.components(separatedBy: .newlines)
        var allResults: [PositionedMatch] = []

        // Track cumulative character offset for each line so we can produce
        // locations comparable to the NSString-based inline pass.
        var lineOffsets: [Int] = []
        var offset = 0
        for line in lines {
            lineOffsets.append(offset)
            offset += line.utf16.count + 1  // +1 for the newline
        }

        for pattern in Self.blockPatterns {
            // For each line, try to match the pattern. Record line indices
            // where it matched along with the extracted data.
            struct LineMatch {
                let lineIndex: Int
                let match: PositionedMatch
            }
            var lineMatches: [LineMatch] = []

            for (i, line) in lines.enumerated() {
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                guard let result = pattern.firstMatch(in: line, range: range),
                      var m = extractMatch(from: result, in: nsLine) else { continue }
                // Adjust location to be relative to full text.
                m = PositionedMatch(
                    location: lineOffsets[i] + m.location,
                    key: m.key,
                    label: m.label,
                    rawMatch: m.rawMatch
                )
                lineMatches.append(LineMatch(lineIndex: i, match: m))
            }

            // Find runs of consecutive (or near-consecutive allowing 1 blank
            // line gap) matches and keep only runs of length >= 2.
            var runStart = 0
            while runStart < lineMatches.count {
                var runEnd = runStart
                while runEnd + 1 < lineMatches.count {
                    let gap = lineMatches[runEnd + 1].lineIndex - lineMatches[runEnd].lineIndex
                    // Allow a gap of 1 blank line between shortcut lines.
                    if gap <= 2 {
                        runEnd += 1
                    } else {
                        break
                    }
                }
                let runLength = runEnd - runStart + 1
                if runLength >= 2 {
                    for idx in runStart...runEnd {
                        allResults.append(lineMatches[idx].match)
                    }
                }
                runStart = runEnd + 1
            }
        }

        return allResults
    }

    /// Extract key and label from a regex match result.
    private func extractMatch(from result: NSTextCheckingResult, in nsText: NSString) -> PositionedMatch? {
        guard result.numberOfRanges >= 3 else { return nil }
        let keyRange = result.range(at: 1)
        let labelRange = result.range(at: 2)
        guard keyRange.location != NSNotFound,
              labelRange.location != NSNotFound else { return nil }

        let key = nsText.substring(with: keyRange)
        let label = nsText.substring(with: labelRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip trailing punctuation like periods and emoji clutter
            .replacingOccurrences(of: #"[\s.!]+$"#, with: "", options: .regularExpression)
        let rawMatch = nsText.substring(with: result.range)

        // Reject labels that are too short (likely noise) or too long (not a shortcut hint).
        guard label.count >= 2, label.count <= 80 else { return nil }

        return PositionedMatch(
            location: result.range.location,
            key: key,
            label: label,
            rawMatch: rawMatch
        )
    }

    /// Insert a match if its key hasn't been seen yet. Returns true if inserted.
    @discardableResult
    private func insertIfNew(_ m: PositionedMatch, into matches: inout [PositionedMatch], seen: inout Set<String>) -> Bool {
        let keyDedup = "key:\(m.key)"
        guard !seen.contains(m.rawMatch), !seen.contains(keyDedup) else { return false }
        seen.insert(m.rawMatch)
        seen.insert(keyDedup)
        matches.append(m)
        return true
    }
}
