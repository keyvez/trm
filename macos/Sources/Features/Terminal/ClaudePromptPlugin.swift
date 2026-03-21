import Foundation
import SwiftUI
import Combine
import os

/// Shows the last human prompt from Claude Code's conversation JSONL log
/// as a small pill at the top of each terminal pane.
///
/// The pill displays the first sentence of the prompt (truncated after 80 chars
/// if no sentence boundary is found). It stays visible until the prompt changes
/// or the user navigates away from a Claude Code session in that pane.
///
/// Log location: `~/.claude/projects/<encoded-cwd>/*.jsonl`
/// where `<encoded-cwd>` is the cwd path with `/` replaced by `-`.
@MainActor
final class ClaudePromptPlugin: ObservableObject, ServicePlugin, ObservableServicePlugin, ServicePluginOverlayProvider {

    // MARK: - ServicePlugin

    let pluginId = "claude_prompt"
    let displayName = "Claude Prompt"

    static let requiredCapabilities: Set<PluginCapability> = [.fileSystemRead]

    private weak var registry: ServicePluginRegistry?

    private static let log = Logger(subsystem: "com.trm", category: "ClaudePromptPlugin")

    func configure(registry: ServicePluginRegistry) {
        self.registry = registry
    }

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollAllPanes()
            }
        }
        pollAllPanes()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        lastPrompts.removeAll()
        lastFileModTimes.removeAll()
    }

    // MARK: - State

    /// Last human prompt text, keyed by pane ID.
    @Published private var lastPrompts: [Int: String] = [:]

    /// Provider returning [(paneId, cwd)] for all active panes.
    var pwdProvider: (() -> [(paneId: Int, pwd: String?)])?

    private var pollTimer: Timer?

    /// Last mtime of the JSONL file we read per pane (to skip unchanged files).
    private var lastFileModTimes: [Int: Date] = [:]

    // MARK: - Polling

    private func pollAllPanes() {
        guard let pwdProvider else { return }
        for (paneId, pwd) in pwdProvider() {
            guard let pwd, !pwd.isEmpty else { continue }
            refreshPrompt(forPaneId: paneId, pwd: pwd)
        }
    }

    private func refreshPrompt(forPaneId paneId: Int, pwd: String) {
        let projectDir = claudeProjectDir(forCwd: pwd)
        guard let jsonlURL = latestJSONL(in: projectDir) else {
            // No JSONL — clear any stale prompt.
            if lastPrompts[paneId] != nil {
                lastPrompts[paneId] = nil
            }
            return
        }

        // Skip if file hasn't changed since last read.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: jsonlURL.path))?[.modificationDate] as? Date
        if let mtime, mtime == lastFileModTimes[paneId] { return }
        lastFileModTimes[paneId] = mtime

        let prompt = lastHumanPrompt(in: jsonlURL)
        lastPrompts[paneId] = prompt
    }

    // MARK: - JSONL Parsing

    /// Reads the JSONL file and returns the text of the last `type: "user"` message.
    private func lastHumanPrompt(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var lastPrompt: String? = nil
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  let message = obj["message"] as? [String: Any] else { continue }

            let content = message["content"]
            if let str = content as? String, !str.isEmpty {
                lastPrompt = str
            } else if let arr = content as? [[String: Any]] {
                for block in arr {
                    if block["type"] as? String == "text",
                       let t = block["text"] as? String, !t.isEmpty {
                        lastPrompt = t
                        break
                    }
                }
            }
        }
        return lastPrompt.map { truncate($0) }
    }

    /// Returns the first sentence, or the first 80 characters if no sentence boundary found.
    private func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split on sentence-ending punctuation followed by whitespace or end.
        let sentencePattern = #"[.!?](\s|$)"#
        if let range = trimmed.range(of: sentencePattern, options: .regularExpression) {
            // Include the punctuation mark itself.
            let end = trimmed.index(range.lowerBound, offsetBy: 1)
            return String(trimmed[..<end])
        }
        // No sentence boundary — cap at 80 chars.
        if trimmed.count > 80 {
            return String(trimmed.prefix(80)) + "…"
        }
        return trimmed
    }

    // MARK: - File System Helpers

    /// Maps a cwd path to its Claude project directory.
    /// e.g. `/Users/foo/dev/trm` → `~/.claude/projects/-Users-foo-dev-trm`
    private func claudeProjectDir(forCwd cwd: String) -> URL {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encoded)
    }

    /// Returns the most recently modified `.jsonl` file in a directory.
    private func latestJSONL(in dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        return items
            .filter { $0.pathExtension == "jsonl" }
            .max(by: {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            })
    }

    // MARK: - ServicePluginOverlayProvider

    var overlayAlignment: Alignment { .top }

    func overlayView(forPaneId paneId: Int) -> AnyView? {
        guard let prompt = lastPrompts[paneId] else { return nil }
        return AnyView(
            ClaudePromptPillView(prompt: prompt)
                .padding(.top, 8)
        )
    }
}

// MARK: - Pill View

struct ClaudePromptPillView: View {
    let prompt: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(prompt)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(red: 0x58/255, green: 0xa6/255, blue: 0xff/255).opacity(0.82))
        )
        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
    }
}
