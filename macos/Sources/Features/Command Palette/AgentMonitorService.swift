import Foundation

/// Monitors AI agents running in terminal panes and produces one-liner status summaries.
/// Uses pane output scanning (TerminalOutputSubscriber) and Text Tap events.
@MainActor
final class AgentMonitorService: ObservableObject, TerminalOutputSubscriber {
    weak var aiState: CommandPaletteAIState?
    var monitoredPaneId: Int?
    private var lastOutputSnapshot: String = ""

    // MARK: - TerminalOutputSubscriber

    func terminalOutputDidChange(paneId: Int, text: String, hash: String) {
        guard paneId == monitoredPaneId else { return }

        let summary = diffAndSummarize(old: lastOutputSnapshot, new: text)
        lastOutputSnapshot = text

        if let summary {
            aiState?.isAgentActive = true
            aiState?.appendStatus(summary)
        }
    }

    func terminalPaneDidClose(paneId: Int) {
        guard paneId == monitoredPaneId else { return }
        monitoredPaneId = nil
        aiState?.isAgentActive = false
    }

    // MARK: - Text Tap Events

    func handleTextTapEvent(_ payload: [String: Any]) {
        guard let toolName = payload["tool_name"] as? String else { return }

        var summary = toolName
        if let file = payload["file"] as? String {
            let filename = (file as NSString).lastPathComponent
            summary = "\(toolDisplayName(toolName)) \(filename)"
        }

        aiState?.isAgentActive = true
        aiState?.appendStatus(summary)
    }

    // MARK: - Output Diffing

    private func diffAndSummarize(old: String, new: String) -> String? {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        // Look at the last 5 lines of new output that aren't in old
        let tailNew = newLines.suffix(5)
        let tailOld = Set(oldLines.suffix(10))
        let newContent = tailNew.filter { !tailOld.contains($0) && !$0.isEmpty }

        guard !newContent.isEmpty else { return nil }

        // Try to extract a meaningful summary from the new lines
        for line in newContent {
            if let match = detectPattern(in: line) {
                return match
            }
        }

        return nil
    }

    /// Regex-based pattern detection for common agent activities.
    private func detectPattern(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // File operations: "Reading src/main.swift", "Editing config.zig"
        let filePatterns: [(pattern: String, verb: String)] = [
            (#"(?:Reading|Read)\s+(.+)"#, "Reading"),
            (#"(?:Writing|Wrote|Write)\s+(.+)"#, "Writing"),
            (#"(?:Editing|Edit)\s+(.+)"#, "Editing"),
            (#"(?:Creating|Create)\s+(.+)"#, "Creating"),
        ]

        for (pattern, verb) in filePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                let path = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                let filename = (path as NSString).lastPathComponent
                return "\(verb) \(filename)"
            }
        }

        // Command execution: "$ npm test", "Running tests"
        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("> ") {
            let cmd = String(trimmed.dropFirst(2)).prefix(40)
            return "Running: \(cmd)"
        }

        // Thinking/processing indicators
        if trimmed.lowercased().contains("thinking") || trimmed.lowercased().contains("processing") {
            return "Thinking..."
        }

        // File path on its own line (common in build output)
        if trimmed.contains("/") && !trimmed.contains(" "),
           trimmed.count < 120 {
            let filename = (trimmed as NSString).lastPathComponent
            return "Processing \(filename)"
        }

        return nil
    }

    private func toolDisplayName(_ tool: String) -> String {
        switch tool.lowercased() {
        case "read", "read_file": return "Reading"
        case "write", "write_file": return "Writing"
        case "edit", "edit_file": return "Editing"
        case "bash", "execute": return "Running"
        case "glob", "search": return "Searching"
        case "grep": return "Searching"
        default: return tool.capitalized
        }
    }
}
