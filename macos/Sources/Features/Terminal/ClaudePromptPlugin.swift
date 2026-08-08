import Foundation
import SwiftUI
import Combine
import os
import Darwin

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
        let panes = pwdProvider()
        guard !panes.isEmpty else { return }

        // Snapshot state needed for off-main work.
        let previousMtimes = lastFileModTimes

        // Move all the heavy work (proc enumeration, directory reads, file I/O,
        // JSON parsing) off the main thread. With many panes this was the main
        // source of typing lag: every 3s it would run hundreds of syscalls and
        // parse JSONL files synchronously on the main actor.
        Task.detached(priority: .utility) { [weak self, panes, previousMtimes] in
            let activeClaudeDirs = Self.claudeActiveDirs()

            if activeClaudeDirs.isEmpty {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for (paneId, _) in panes where self.lastPrompts[paneId] != nil {
                        self.lastPrompts[paneId] = nil
                    }
                }
                return
            }

            var jsonlCache: [String: String?] = [:]
            var updates: [(paneId: Int, prompt: String?, mtime: Date?, clear: Bool, skip: Bool)] = []

            for (paneId, pwd) in panes {
                guard let pwd, !pwd.isEmpty else { continue }

                let normalised = pwd.hasSuffix("/") ? pwd : pwd + "/"
                let isActive = activeClaudeDirs.contains(where: { dir in
                    let d = dir.hasSuffix("/") ? dir : dir + "/"
                    return d.hasPrefix(normalised) || dir == pwd
                })
                guard isActive else {
                    updates.append((paneId, nil, nil, true, false))
                    continue
                }

                let projectDir = Self.claudeProjectDir(forCwd: pwd)
                guard let jsonlURL = Self.latestJSONL(in: projectDir) else {
                    updates.append((paneId, nil, nil, true, false))
                    continue
                }

                let mtime = (try? FileManager.default.attributesOfItem(atPath: jsonlURL.path))?[.modificationDate] as? Date
                if let mtime, mtime == previousMtimes[paneId] {
                    updates.append((paneId, nil, mtime, false, true))
                    continue
                }

                let path = jsonlURL.path
                let prompt: String?
                if let cached = jsonlCache[path] {
                    prompt = cached
                } else {
                    prompt = Self.lastHumanPrompt(in: jsonlURL)
                    jsonlCache[path] = prompt
                }
                updates.append((paneId, prompt, mtime, false, false))
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                for u in updates {
                    if let mtime = u.mtime { self.lastFileModTimes[u.paneId] = mtime }
                    if u.skip { continue }
                    if u.clear {
                        if self.lastPrompts[u.paneId] != nil { self.lastPrompts[u.paneId] = nil }
                    } else {
                        if self.lastPrompts[u.paneId] != u.prompt { self.lastPrompts[u.paneId] = u.prompt }
                    }
                }
            }
        }
    }

    // MARK: - JSONL Parsing

    /// Reads the JSONL file and returns the text of the last `type: "user"` message.
    /// Reads the file from the end to avoid parsing megabytes of history — scans
    /// backwards through the last 256 KB looking for the most recent user message.
    nonisolated private static func lastHumanPrompt(in url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let maxRead: UInt64 = 256 * 1024 // 256 KB from end
        let fileSize = (try? fh.seekToEnd()) ?? 0
        let readOffset = fileSize > maxRead ? fileSize - maxRead : 0
        try? fh.seek(toOffset: readOffset)
        guard let data = try? fh.readToEnd(),
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
        return lastPrompt.map { Self.truncate($0) }
    }

    /// Returns the first sentence, or the first 80 characters if no sentence boundary found.
    nonisolated private static func truncate(_ text: String) -> String {
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

    // MARK: - Process Detection

    /// Process-scan cache shared across all plugin instances. Each window
    /// registers its own ClaudePromptPlugin, and enumerating every PID on the
    /// system (hundreds of syscalls) once per window per tick adds up; the
    /// result is identical app-wide, so scan at most once per TTL.
    private final class ActiveDirsCache: @unchecked Sendable {
        private let lock = NSLock()
        private var dirs: Set<String> = []
        private var scannedAt: Date = .distantPast
        private let ttl: TimeInterval = 2.5

        func get(scan: () -> Set<String>) -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            if now.timeIntervalSince(scannedAt) >= ttl {
                dirs = scan()
                scannedAt = now
            }
            return dirs
        }
    }

    private static let activeDirsCache = ActiveDirsCache()

    /// Returns the set of working directories for all active `claude` processes.
    /// Called once per poll cycle; panes are then matched against this set
    /// with a simple string check instead of per-pane system calls.
    nonisolated private static func claudeActiveDirs() -> Set<String> {
        activeDirsCache.get {
            let claudePIDs = pidsByName("claude")
            guard !claudePIDs.isEmpty else { return [] }
            var dirs = Set<String>()
            for pid in claudePIDs {
                if let cwd = processCurrentDirectory(pid: pid) {
                    dirs.insert(cwd)
                }
            }
            return dirs
        }
    }

    /// Returns all PIDs whose executable basename matches `name` exactly,
    /// excluding processes that are children of another process with the same name
    /// (to avoid counting sub-agent or nested invocations).
    nonisolated private static func pidsByName(_ name: String) -> [pid_t] {
        // Use proc_listallpids to enumerate all PIDs, then filter by name.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        // First pass: collect (pid, ppid, name) for all processes.
        struct ProcEntry { var pid: pid_t; var ppid: pid_t; var name: String }
        var allEntries: [ProcEntry] = []
        for pid in pids.prefix(Int(filled)) {
            guard pid > 0 else { continue }
            var info = proc_bsdshortinfo()
            let ret = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size))
            guard ret > 0 else { continue }
            let exeName = withUnsafeBytes(of: info.pbsi_comm) { bytes -> String in
                let buf = bytes.bindMemory(to: CChar.self)
                return String(cString: buf.baseAddress!)
            }
            allEntries.append(ProcEntry(pid: pid, ppid: pid_t(info.pbsi_ppid), name: exeName))
        }

        // Build a set of PIDs named `name` for quick parent lookup.
        let namedPIDs = Set(allEntries.filter { $0.name == name }.map { $0.pid })

        // Second pass: return only top-level `name` processes (parent is NOT also named `name`).
        return allEntries.compactMap { entry -> pid_t? in
            guard entry.name == name else { return nil }
            // Skip if the parent is also a `claude` process (sub-agent / nested invocation).
            guard !namedPIDs.contains(entry.ppid) else { return nil }
            return entry.pid
        }
    }

    /// Returns the current working directory of the given PID using `libproc`.
    nonisolated private static func processCurrentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard ret > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes -> String? in
            let buf = bytes.bindMemory(to: CChar.self)
            guard let base = buf.baseAddress, base.pointee != 0 else { return nil }
            return String(cString: base)
        }
    }

    // MARK: - File System Helpers

    /// Maps a cwd path to its Claude project directory.
    /// e.g. `/Users/foo/dev/trm` → `~/.claude/projects/-Users-foo-dev-trm`
    nonisolated private static func claudeProjectDir(forCwd cwd: String) -> URL {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encoded)
    }

    /// Returns the most recently modified `.jsonl` file in a directory.
    nonisolated private static func latestJSONL(in dir: URL) -> URL? {
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
