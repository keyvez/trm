import Darwin
import Foundation
import os

/// Manages zmx-backed detachable pane sessions.
///
/// When `session_persistence = true` in the trm config, every terminal pane's
/// command is wrapped as `zmx attach <session> [command]`. The pane's normal
/// in-process PTY hosts the zmx *client*; a per-session *daemon* (spawned by
/// zmx itself) owns the real PTY and survives GUI quit. Closing a window
/// detaches; relaunching reattaches by session name and zmx replays terminal
/// state via ghostty-vt. Remote attach (ZMX_DIR must point at trm's socket
/// dir): `ssh -t host 'ZMX_DIR="$HOME/.trm/zmx" zmx attach <name>'`.
///
/// The zmx binary is bundled into trm.app as an auxiliary executable and is
/// built from `vendor/zmx` by `zig build` (see src/build/GhosttyZmx.zig).
@MainActor
enum ZmxSessionManager {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "ZmxSessionManager"
    )

    /// Prefix for all trm-owned session names. Keeps `zmx list` shared with
    /// user-created sessions without trm touching those.
    static let sessionPrefix = "trm-"

    /// Path to the bundled zmx binary. In debug builds falls back to the
    /// repo's zig-out so `zig build` output works without a full app bundle.
    nonisolated static var zmxPath: String? {
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: "zmx") {
            return bundled
        }
        #if DEBUG
        let devPath = FileManager.default.currentDirectoryPath + "/zig-out/bin/zmx"
        if FileManager.default.isExecutableFile(atPath: devPath) { return devPath }
        #endif
        return nil
    }

    /// Directory holding zmx session sockets. Deliberately short and stable:
    /// Unix socket paths are capped at ~104 bytes on macOS, and the default
    /// /tmp location is wiped on reboot which would strand session bookkeeping.
    nonisolated static var zmxDir: String {
        let dir = NSHomeDirectory() + "/.trm/zmx"
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return dir
    }

    /// Whether session persistence can actually work (config flag is checked
    /// by callers; this checks the binary exists).
    static var isAvailable: Bool { zmxPath != nil }

    /// Generate a fresh, collision-free session name (`trm-xxxxxxxx`).
    static func newSessionName() -> String {
        for _ in 0..<8 {
            let hex = String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
            let name = sessionPrefix + hex
            if !sessionExists(name) { return name }
        }
        // Practically unreachable; timestamp fallback keeps it unique anyway.
        return sessionPrefix + String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 16)
    }

    /// A session exists iff its socket file exists in the zmx dir.
    /// (zmx socket path convention: `<dir>/<session-name>`, no extension.)
    static func sessionExists(_ name: String) -> Bool {
        var isDir: ObjCBool = false
        let path = zmxDir + "/" + name
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// The pid of the shell running inside a session, or nil if not found.
    ///
    /// A server-backed pane's child process is the `zmx attach` *client*: it
    /// has no children and its cwd is wherever trm was launched from, so
    /// anything that needs the real shell — the working directory, the agent
    /// process-tree walk behind the Agent Overview — cannot get there from the
    /// pane's pid. The shell is a child of the process holding the session
    /// socket, which this finds by asking who has that socket open and taking
    /// its first child.
    /// Cache of resolved shell pids. `lsof` is a process spawn — far too
    /// expensive to repeat on a 1.5 s UI poll — and a session's shell pid is
    /// stable for the session's life, so it is resolved once and only redone
    /// when the cached process is gone.
    private static var shellPidCache: [String: pid_t] = [:]

    /// Cached variant of `serverShellPid`, safe to call from a hot path.
    ///
    /// Returns the cached pid while that process is still alive (a `kill(0)`
    /// check, no spawn). Only a dead or missing entry pays for an `lsof`.
    static func cachedServerShellPid(session: String) -> pid_t? {
        if let cached = shellPidCache[session], kill(cached, 0) == 0 {
            return cached
        }
        shellPidCache.removeValue(forKey: session)
        guard let resolved = serverShellPid(session: session) else { return nil }
        shellPidCache[session] = resolved
        return resolved
    }

    /// Whether a session's shell currently has a foreground command running.
    /// This is the "is this pane doing work" signal for flows that replace a
    /// pane's surface (e.g. switching it to a remote host): a zmx-backed
    /// pane's real children live under the session daemon, so the surface's
    /// own process check can't see them.
    static func sessionHasRunningCommand(_ session: String) -> Bool {
        guard let shellPid = cachedServerShellPid(session: session) else { return false }
        return command(ofShellPid: shellPid) != nil
    }

    static func serverShellPid(session: String) -> pid_t? {
        let socketPath = zmxDir + "/" + session
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        // `lsof -t` prints just the pids holding the socket. The server may
        // appear more than once (multiple fds), and attached clients hold it
        // too — the one with a child is the server.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", socketPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.warning("lsof failed for session \(session): \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pids = Set(text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) })
        guard !pids.isEmpty else { return nil }

        for pid in pids.sorted() {
            if let child = firstChildPid(of: pid) { return child }
        }
        return nil
    }

    /// First child process of `parent`, if any.
    nonisolated private static func firstChildPid(of parent: pid_t) -> pid_t? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }

        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let ret = proc_pidinfo(
                pid, PROC_PIDT_SHORTBSDINFO, 0,
                &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)
            )
            guard ret > 0 else { continue }
            if pid_t(info.pbsi_ppid) == parent { return pid }
        }
        return nil
    }

    /// All trm-owned session names, from socket files in the zmx dir.
    static func listSessions() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: zmxDir) else { return [] }
        return entries.filter { $0.hasPrefix(sessionPrefix) }.sorted()
    }

    /// Session names referenced by any saved session TOML (autosaves and
    /// named sessions). Everything else in `listSessions()` is an orphan.
    static func referencedSessions() -> Set<String> {
        let fm = FileManager.default
        let dir = SessionManager.sessionsDirectory
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var referenced: Set<String> = []
        for file in files where file.hasSuffix(".toml") {
            guard let content = try? String(
                contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("zmx_session"),
                      let eq = trimmed.firstIndex(of: "=") else { continue }
                var value = String(trimmed[trimmed.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { referenced.insert(value) }
            }
        }
        return referenced
    }

    /// Live trm-owned sessions that no saved TOML references — typically
    /// left behind when autosave was cleared but daemons kept running.
    static func orphanSessions() -> [String] {
        let referenced = referencedSessions()
        return listSessions().filter { !referenced.contains($0) }
    }

    /// One saved window: the TOML that describes it and the sessions it owns,
    /// in pane order. This is the grouping the session browser displays —
    /// sessions belong to windows, and showing them flat loses which panes
    /// were arranged together.
    struct SessionGroup: Identifiable, Sendable {
        /// Display name: the session file's base name (`recovered`,
        /// `_autosave_0`), or a synthetic label for ungrouped sessions.
        let name: String
        /// Path to the session TOML, or nil for the orphan group.
        let path: String?
        /// Session names this window references, in pane order.
        let sessionNames: [String]
        /// Watermark per session name, where the window's TOML set one. This
        /// is the pane's own label ("trm", "gooshi"), so it identifies a pane
        /// far better than its scrollback does.
        let watermarks: [String: String]
        /// True for the synthetic group holding sessions no TOML references.
        let isOrphanGroup: Bool

        var id: String { path ?? "__orphans__" }
    }

    /// Map every saved session TOML to the sessions it references, in pane
    /// order, keeping only sessions whose daemon is still alive. Any live
    /// session left over lands in a trailing orphan group.
    static func sessionGroups() -> [SessionGroup] {
        let fm = FileManager.default
        let dir = SessionManager.sessionsDirectory
        let live = Set(listSessions())

        var groups: [SessionGroup] = []
        var claimed: Set<String> = []

        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".toml") }
            .sorted()

        for file in files {
            let url = dir.appendingPathComponent(file)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            // Pane order matters, so collect in document order rather than
            // using the Set-based referencedSessions(). `watermark` and
            // `zmx_session` are separate keys in the same [[panes]] block and
            // can appear in either order, so both are buffered per block and
            // paired when the block ends.
            var names: [String] = []
            var marks: [String: String] = [:]
            var blockSession: String?
            var blockMark: String?

            func flushBlock() {
                guard let session = blockSession, live.contains(session) else {
                    blockSession = nil
                    blockMark = nil
                    return
                }
                names.append(session)
                claimed.insert(session)
                if let mark = blockMark, !mark.isEmpty { marks[session] = mark }
                blockSession = nil
                blockMark = nil
            }

            func unquoted(_ line: String) -> String? {
                guard let eq = line.firstIndex(of: "=") else { return nil }
                var value = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? nil : value
            }

            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "[[panes]]" {
                    // A window can reference a session whose daemon has since
                    // died (that is what blocks Reload Latest UI); flushBlock
                    // drops those so the browser only lists what can open.
                    flushBlock()
                } else if trimmed.hasPrefix("zmx_session") {
                    blockSession = unquoted(trimmed)
                } else if trimmed.hasPrefix("watermark") {
                    blockMark = unquoted(trimmed)
                }
            }
            flushBlock()

            guard !names.isEmpty else { continue }
            groups.append(SessionGroup(
                name: String(file.dropLast(5)),
                path: url.path,
                sessionNames: names,
                watermarks: marks,
                isOrphanGroup: false
            ))
        }

        let orphans = listSessions().filter { !claimed.contains($0) }
        if !orphans.isEmpty {
            groups.append(SessionGroup(
                name: "Ungrouped",
                path: nil,
                sessionNames: orphans,
                watermarks: [:],
                isOrphanGroup: true
            ))
        }
        return groups
    }

    /// Kill one session (its daemon and child process) via `zmx kill`.
    static func killSession(_ name: String) {
        runZmx(["kill", name])
    }

    // MARK: - Introspection (Session Browser)

    /// Everything the session browser needs to describe one live session.
    struct SessionInfo: Identifiable, Sendable {
        let name: String
        /// Trailing scrollback lines, as the session last rendered them.
        /// Working directory of the session's shell, if resolvable.
        let cwd: String?
        /// Foreground command running in the session (e.g. `claude`, `ssh mini`).
        let command: String?
        /// Whether any UI client is currently attached.
        let attached: Bool
        /// Whether a saved session TOML references this session.
        let referenced: Bool
        /// The pane's watermark from its window's TOML, when it has one.
        var watermark: String?
        /// Which agent is running here, when one is.
        var agentKind: AgentKind?
        /// Where the agent's transcript lives, so a later request can read the
        /// whole conversation without locating it again.
        var transcriptPath: String?
        /// The last thing the person asked this agent.
        var lastPrompt: String?
        /// Everything asked of this agent, oldest first. The phone offers it
        /// back so a message can be sent again without retyping it.
        var promptHistory: [String] = []
        /// A sentence of what the agent said back.
        ///
        /// A browser full of tiles reading `claude --dangerously-skip-permissions`
        /// tells you nothing about which session is which — the conversation
        /// does. The command is the fallback for a pane that is just a shell.
        var summary: String?
        /// SSH destination the session lives on, or nil for a local session.
        /// A remote session's daemon runs on that machine; everything trm does
        /// with it — open, terminate — has to go over SSH.
        var remoteHost: String?
        /// True while the agent's newest transcript entry is a tool call with
        /// no result yet. Read from the same transcript the summary comes
        /// from, so a session tile and a board row can't disagree about
        /// whether the agent is mid-task or waiting.
        var isWorking = false
        /// True when the agent asked something and is blocked on the answer.
        var needsAttention = false

        var id: String { name }

        /// Short label for the cwd: last two path components.
        var shortCwd: String? {
            guard let cwd, cwd != "/" else { return nil }
            let parts = cwd.split(separator: "/").suffix(2)
            return parts.isEmpty ? nil : parts.joined(separator: "/")
        }
    }

    /// Working directory of a process.
    nonisolated private static func cwd(ofPid pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// The most interesting command in a session: the shell's first child
    /// (`claude`, `ssh`, …), or nil for a bare shell.
    nonisolated private static func command(ofShellPid shellPid: pid_t) -> String? {
        guard let childPid = firstChildPid(of: shellPid) else { return nil }
        var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(childPid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let base = (String(cString: buf) as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }

    /// Whether a session currently has an attached client. `zmx list` reports
    /// a `clients=N` field per session; N > 0 means some UI owns it.
    static func attachedSessions() -> Set<String> {
        guard let text = runZmxCapturing(["list"]) else { return [] }
        var result: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            guard let name = field(in: line, key: "name="),
                  let clients = field(in: line, key: "clients="),
                  let count = Int(clients), count > 0 else { continue }
            result.insert(name)
        }
        return result
    }

    /// Extract a whitespace-delimited `key=value` field from a `zmx list` line.
    nonisolated private static func field(in line: String, key: String) -> String? {
        for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if token.hasPrefix(key) { return String(token.dropFirst(key.count)) }
        }
        return nil
    }

    /// Build the full session list for the browser.
    ///
    /// Every entry costs several process spawns (`zmx history`, and `lsof` for
    /// an uncached shell pid). Done serially across a few dozen sessions that
    /// runs into seconds, so the per-session work is fanned out across a
    /// concurrent queue and only the assembled result is returned.
    ///
    /// Callers must invoke this off the main actor.
    nonisolated static func allSessionInfoConcurrently(
        names: [String],
        referenced: Set<String>,
        attached: Set<String>,
        shellPids: [String: pid_t]
    ) -> [SessionInfo] {
        var results = [SessionInfo?](repeating: nil, count: names.count)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: names.count) { index in
            let name = names[index]
            let pid = shellPids[name]
            let paneCwd = pid.flatMap { cwd(ofPid: $0) }
            var info = SessionInfo(
                name: name,
                cwd: paneCwd,
                command: pid.flatMap { command(ofShellPid: $0) },
                attached: attached.contains(name),
                referenced: referenced.contains(name)
            )
            // What the session is *doing*, when an agent is running it. The
            // same locator the Agent Overview uses, so a tile and an overview
            // never disagree about which conversation a pane is having.
            if let pid, let located = AgentSessionLocator.locate(
                shellPid: pid, paneCwd: paneCwd, recordKey: name) {
                let transcript = located.kind == .codex
                    ? CodexTranscriptReader.parse(url: located.url)
                    : AgentTranscriptReader.parse(url: located.url)
                if let transcript {
                    info.agentKind = located.kind
                    info.transcriptPath = located.url.path
                    info.lastPrompt = transcript.lastUserPrompt
                    info.promptHistory = CommandCenterMonitor.promptHistory(transcript)
                    info.summary = summarize(transcript)
                    info.isWorking = transcript.isWorking
                    info.needsAttention = !transcript.questions.isEmpty
                }
            }
            lock.lock()
            results[index] = info
            lock.unlock()
        }

        return results.compactMap { $0 }
    }

    /// One line of what the agent last said, for a browser tile.
    nonisolated static func summarize(_ transcript: AgentTranscript) -> String? {
        // Newest message first, for the same reason the Command Center uses
        // it: a one-line summary should say what is being said now.
        let source = transcript.latestBlocks.isEmpty
            ? transcript.blocks : transcript.latestBlocks
        for block in source {
            guard case .paragraph(let text) = block else { continue }
            let sentence = CommandCenterMonitor.firstSentence(of: text, limit: 200)
            if !sentence.isEmpty { return sentence }
        }
        if let question = transcript.questions.first?.text, !question.isEmpty {
            return question
        }
        if let tool = transcript.activity.last {
            return tool.detail.map { "\(tool.name) \($0)" } ?? tool.name
        }
        return nil
    }

    /// Run zmx and return stdout as a string. Used by the browser's
    /// introspection helpers; never used for attach.
    nonisolated private static func runZmxCapturing(_ args: [String]) -> String? {
        guard let zmx = zmxPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["ZMX_DIR"] = zmxDir
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("zmx \(args.joined(separator: " ")) failed: \(error.localizedDescription)")
            return nil
        }
        // Read before waiting: a large history would otherwise fill the pipe
        // buffer and deadlock against waitUntilExit().
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Kill every trm-owned session. Used by "Terminate All & Quit".
    static func killAllTrmSessions() {
        for name in listSessions() {
            killSession(name)
        }
    }

    /// The wrapped spawn command for a pane: `zmx attach <session> [logical]`.
    /// Returns nil when the zmx binary can't be found (callers fall back to
    /// the unwrapped command).
    static func wrappedCommand(session: String, logical: String?) -> String? {
        guard let zmx = zmxPath else { return nil }
        // The command string is executed via the user's shell (ghostty
        // `shell:` semantics), so quote the binary path; the logical command
        // is passed through as-is so its own quoting keeps working.
        var cmd = "\"\(zmx)\" attach \(session)"
        if let logical, !logical.isEmpty {
            cmd += " \(logical)"
        }
        return cmd
    }

    /// The tail of a session's scrollback, as the session last rendered it.
    ///
    /// This is what the pane would be showing if you were sitting in front of
    /// it — the whole point of reading it from a phone. Capped rather than
    /// returned whole: a session that has been running an agent all day holds
    /// megabytes, and none of the part you want is at the top.
    nonisolated static func history(session name: String, lines: Int = 400) -> String? {
        guard !name.isEmpty else { return nil }
        guard let text = runZmxCapturing(["history", name]) else { return nil }
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
            // Terminal scrollback is padded to the pane's width, so most lines
            // carry a tail of spaces. Harmless in a terminal, and the reason a
            // wrapped line on a phone can run on for half a screen of nothing.
            .map { $0.reversed().drop { $0 == " " || $0 == "\t" }.reversed() }
            .map { String($0) }
        // A pane that has been idle ends in a screenful of blank lines; opening
        // its scrollback should not land you below the last thing it said.
        while let last = all.last, last.isEmpty { all.removeLast() }
        guard all.count > lines else { return all.joined(separator: "\n") }
        return all.suffix(lines).joined(separator: "\n")
    }

    // MARK: - Watermarks that outlive their window

    /// Watermarks remembered per session name.
    ///
    /// A watermark used to live only in the window TOML that described the
    /// pane showing it. That is fine until the window goes away and the
    /// session does not — a crash, or opening a group the browser had no
    /// saved arrangement for — and then every pane comes back called
    /// something else. The session is the thing with an identity worth
    /// keeping a name for; the window is just where it was being shown.
    private static let watermarkStoreURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".trm/watermarks.json")

    /// Guarded rather than actor-isolated: the store is read from the session
    /// scan, which runs off the main actor, and written from the main one.
    private static let watermarkLock = NSLock()
    nonisolated(unsafe) private static var watermarkCache: [String: String]?

    nonisolated static func rememberedWatermarks() -> [String: String] {
        watermarkLock.lock()
        defer { watermarkLock.unlock() }
        return loadLocked()
    }

    nonisolated private static func loadLocked() -> [String: String] {
        if let cached = watermarkCache { return cached }
        guard let data = try? Data(contentsOf: watermarkStoreURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            watermarkCache = [:]
            return [:]
        }
        watermarkCache = map
        return map
    }

    /// Record what a session is called, so restoring it anywhere restores
    /// its name too. Keyed by session name because that is what survives.
    nonisolated static func rememberWatermark(_ watermark: String, forSession name: String) {
        let trimmed = watermark.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        watermarkLock.lock()
        defer { watermarkLock.unlock() }
        var map = loadLocked()
        if trimmed.isEmpty {
            guard map.removeValue(forKey: name) != nil else { return }
        } else {
            guard map[name] != trimmed else { return }
            map[name] = trimmed
        }
        watermarkCache = map
        let directory = watermarkStoreURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: watermarkStoreURL, options: .atomic)
    }

    nonisolated static func rememberedWatermark(forSession name: String) -> String? {
        rememberedWatermarks()[name]
    }

    /// Type text into a session's pty, whether or not anything is attached.
    ///
    /// `zmx send` writes to the daemon, which is multi-client — the same
    /// property `trm mirror` is built on. That is what lets a phone answer an
    /// agent running on a machine with no window open for it: there is no
    /// surface in the middle, and none is needed.
    ///
    /// The text is passed as one argument rather than interpolated into a
    /// shell command; a reply is arbitrary prose and will contain quotes.
    @discardableResult
    static func sendText(_ text: String, toSession name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return runZmx(["send", name, text]) == 0
    }

    /// Run the bundled zmx synchronously with ZMX_DIR set. Short-lived
    /// management commands only (kill/list); never used for attach.
    @discardableResult
    private static func runZmx(_ args: [String]) -> Int32 {
        guard let zmx = zmxPath else {
            logger.warning("zmx binary not found; cannot run \(args.joined(separator: " "))")
            return -1
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["ZMX_DIR"] = zmxDir
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            logger.error("zmx \(args.joined(separator: " ")) failed: \(error.localizedDescription)")
            return -1
        }
    }

    // MARK: - Remote Sessions

    /// Sessions living on another machine, with the host they came from.
    struct RemoteSessions: Sendable {
        let host: String
        let sessions: [SessionInfo]
        /// Why the host produced nothing, when it produced nothing for a
        /// reason worth saying out loud. A host that answered and simply has
        /// no sessions leaves this nil.
        let error: String?
    }

    /// Default path to zmx inside a remote trm install.
    static let remoteZmxPath = "/Applications/trm.app/Contents/MacOS/zmx"

    /// Wrap a POSIX shell script so it runs under `/bin/sh` on the far side.
    ///
    /// `ssh host '<script>'` hands the script to the *login* shell, which is
    /// whatever the user chose — zsh on a stock Mac. That is not a portability
    /// nicety: zsh does not word-split unquoted parameters, so a plain
    /// `for tok in $line` loop silently matches nothing and the probe returns
    /// an empty list from a machine full of sessions (and a fish login shell
    /// wouldn't parse the script at all). Naming the interpreter removes the
    /// whole class of problem.
    nonisolated private static func shWrapped(_ script: String) -> String {
        let quoted = script.replacingOccurrences(of: "'", with: "'\\''")
        return "exec /bin/sh -c '\(quoted)'"
    }

    /// One shell script, run once per host, that describes every zmx session
    /// on that machine as `name<TAB>clients<TAB>cwd<TAB>command`.
    ///
    /// It is one round trip on purpose: SSH latency dominates everything here,
    /// and a probe per session would make the browser take seconds per host.
    /// Both socket directories are listed — trm pins `~/.trm/zmx`, but
    /// sessions created before that pin still live in the per-user tmp dir.
    nonisolated private static func remoteProbeScript() -> String {
        // Written as one command per element and joined with spaces: the whole
        // thing travels as a single ssh argument, and a here-doc or embedded
        // newlines would have to survive the login shell on the other side.
        [
            // Transcript resolution, shared with the Agent Overview's probe so
            // a tile and an overview can't disagree about which conversation a
            // session is having.
            AgentProbeShell.functions,
            "Z=\"\(remoteZmxPath)\";",
            "[ -x \"$Z\" ] || exit 0;",
            "D=\"$HOME/.trm/zmx\";",
            "T=\"${TMPDIR:-/tmp}\"; T=\"${T%/}/zmx-$(id -u)\";",
            "for DIR in \"$D\" \"$T\"; do",
            "  [ -d \"$DIR\" ] || continue;",
            "  ZMX_DIR=\"$DIR\" \"$Z\" list 2>/dev/null | while IFS= read -r L; do",
            "    case \"$L\" in *name=*) ;; *) continue ;; esac;",
            "    N=\"\"; P=\"\"; C=\"\";",
            "    for TOK in $L; do",
            "      case \"$TOK\" in",
            "        name=*) N=${TOK#name=} ;;",
            "        pid=*) P=${TOK#pid=} ;;",
            "        clients=*) C=${TOK#clients=} ;;",
            "      esac;",
            "    done;",
            "    [ -n \"$N\" ] || continue;",
            "    W=\"\"; M=\"\"; T=\"\"; AKIND=\"\";",
            "    if [ -n \"$P\" ]; then",
            "      W=$(lsof -a -p \"$P\" -d cwd -Fn 2>/dev/null | sed -n \"s/^n//p\" | head -1);",
            "      K=$(pgrep -P \"$P\" 2>/dev/null | head -1);",
            "      [ -n \"$K\" ] && M=$(ps -o command= -p \"$K\" 2>/dev/null | head -1);",
            // What this session is *saying*, resolved the same way the Agent
            // Overview resolves it — the hook's record where there is one, the
            // process tree and file times otherwise. Reading only the record
            // meant a machine without the hook showed a wall of identical
            // command lines.
            "      RT=\"$(resolve_transcript \"$P\" \"$N\")\";",
            "      if [ -n \"$RT\" ]; then AKIND=\"${RT%% *}\"; T=\"${RT#* }\"; fi;",
            "    fi;",
            "    printf \"%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n\" \"$N\" \"$C\" \"$W\" \"$M\" \"$T\" \"$AKIND\";",
            "  done;",
            "done",
        ].joined(separator: " ")
    }

    /// Ask one host what it is running. Returns an empty list when the host is
    /// unreachable, has no trm, or times out — an unreachable machine is not
    /// an error worth putting in front of the user, it just has nothing to
    /// show.
    nonisolated static func remoteSessions(host: String) -> RemoteSessions {
        let args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            host,
            shWrapped(remoteProbeScript()),
        ]
        let run = runCapturing("/usr/bin/ssh", args, timeout: 20)
        guard let out = run.output, run.status == 0 else {
            return RemoteSessions(
                host: host,
                sessions: [],
                error: sshFailureMessage(run.error, status: run.status))
        }

        var result: [SessionInfo] = []
        /// session name → transcript path on the far side.
        var transcripts: [String: String] = [:]
        /// session name → which agent wrote it, as the probe reported.
        var kinds: [String: String] = [:]
        for line in out.components(separatedBy: .newlines) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 4, !cols[0].isEmpty else { continue }
            let clients = Int(cols[1]) ?? 0
            let cwd = cols[2].isEmpty ? nil : cols[2]
            let command = cols[3].isEmpty ? nil : cols[3]
            if cols.count >= 5, !cols[4].isEmpty { transcripts[cols[0]] = cols[4] }
            if cols.count >= 6, !cols[5].isEmpty { kinds[cols[0]] = cols[5] }
            result.append(SessionInfo(
                name: cols[0],
                cwd: cwd,
                command: command,
                attached: clients > 0,
                // "Referenced" is a statement about *this* machine's saved
                // windows, which say nothing about another machine's sessions.
                referenced: false,
                remoteHost: host
            ))
        }
        // One more round trip for the conversations, rather than one per
        // session: a tile saying `claude --dangerously-skip-permissions` is
        // the same tile for every pane on the machine.
        if !transcripts.isEmpty {
            let tails = remoteTranscriptTails(host: host, paths: transcripts)
            for index in result.indices {
                guard let text = tails[result[index].name], !text.isEmpty else { continue }
                let isCodex = kinds[result[index].name] == "codex"
                    || (transcripts[result[index].name] ?? "").contains("/.codex/")
                let lines = text.components(separatedBy: .newlines)
                let transcript = isCodex
                    ? CodexTranscriptReader.parse(lines: lines)
                    : AgentTranscriptReader.parse(lines: lines)
                result[index].agentKind = isCodex ? .codex : .claude
                result[index].lastPrompt = transcript.lastUserPrompt
                result[index].summary = summarize(transcript)
            }
        }

        return RemoteSessions(host: host, sessions: result, error: nil)
    }

    /// Fetch the tail of each named transcript in one connection.
    ///
    /// Tails, not whole files: an agent's transcript runs to tens of megabytes
    /// and a browser needs the last exchange. Each is fenced with a marker
    /// naming its session so one reply carries them all.
    nonisolated private static func remoteTranscriptTails(
        host: String, paths: [String: String], bytesEach: Int = 160_000
    ) -> [String: String] {
        let script = paths.map { session, path in
            // Session names are `trm-<hex>`; the path came from the machine
            // itself. Both are quoted anyway — this string becomes a command.
            "printf '\\n@@@%s@@@\\n' \"\(session)\"; tail -c \(bytesEach) \"\(path)\" 2>/dev/null;"
        }.joined(separator: " ")

        let run = runCapturing(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, shWrapped(script)],
            timeout: 25)
        guard let out = run.output, run.status == 0 else { return [:] }

        var result: [String: String] = [:]
        var current: String?
        var buffer: [String] = []
        for line in out.components(separatedBy: .newlines) {
            if line.hasPrefix("@@@"), line.hasSuffix("@@@"), line.count > 6 {
                if let current { result[current] = buffer.joined(separator: "\n") }
                current = String(line.dropFirst(3).dropLast(3))
                buffer = []
                continue
            }
            buffer.append(line)
        }
        if let current { result[current] = buffer.joined(separator: "\n") }
        return result
    }

    /// Turn ssh's stderr into something worth showing a person.
    ///
    /// The distinction that matters is *can't reach it* versus *wouldn't let
    /// me in*: the second is the one with a fix, and it is easy to hit here
    /// because the probe runs `BatchMode=yes` — a key held in the login
    /// keychain and only unlocked interactively authenticates a pane the user
    /// is watching but not a background scan.
    nonisolated private static func sshFailureMessage(
        _ stderr: String?, status: Int32
    ) -> String {
        let text = (stderr ?? "").lowercased()
        if text.contains("permission denied") || text.contains("publickey") {
            return "SSH refused the key. The browser connects non-interactively, "
                + "so this host needs key-based login that doesn't prompt "
                + "(`ssh-add --apple-use-keychain`)."
        }
        if text.contains("could not resolve") || text.contains("name or service") {
            return "Host not found — it may be off the network under this name."
        }
        if text.contains("connection refused") {
            return "Connection refused. Is Remote Login enabled on that Mac?"
        }
        if text.contains("timed out") || text.contains("timeout") || status == 15 {
            return "Timed out. The machine is probably asleep or off the network."
        }
        if text.contains("host key verification") {
            return "Host key verification failed — connect once from a terminal to accept it."
        }
        return "Couldn't reach it over SSH."
    }

    /// Probe several hosts at once. Hosts are independent and each is mostly
    /// waiting on the network, so they go in parallel; a dead host costs the
    /// connect timeout, not the sum of them.
    /// `expected` marks a host this Mac has actually put panes on. Those are
    /// worth reporting when they fail — their sessions are the ones you came
    /// looking for. A machine that merely happens to be advertising on the
    /// network stays quiet, so a sleeping laptop on the LAN doesn't spread
    /// error cards through the list.
    nonisolated static func remoteSessionsConcurrently(
        hosts: [(host: String, expected: Bool)]
    ) -> [RemoteSessions] {
        guard !hosts.isEmpty else { return [] }
        var results = [RemoteSessions?](repeating: nil, count: hosts.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
            let entry = hosts[index]
            let probed = remoteSessions(host: entry.host)
            guard !probed.sessions.isEmpty || (probed.error != nil && entry.expected) else { return }
            lock.lock()
            results[index] = probed
            lock.unlock()
        }

        // One machine can be reachable under several names — `mini`,
        // `mini.local` from Bonjour, `100.x.y.z` over Tailscale — and each
        // would otherwise become its own group listing the same sessions
        // twice. Identity is what a host is *running*, so a host whose
        // sessions are already covered by an earlier one is dropped.
        var deduped: [RemoteSessions] = []
        var claimed: Set<String> = []
        for entry in results.compactMap({ $0 }) {
            let names = Set(entry.sessions.map(\.name))
            // Unreachable hosts have no sessions to compare, so they are never
            // folded into each other.
            if !names.isEmpty {
                if names.isSubset(of: claimed) { continue }
                claimed.formUnion(names)
            }
            deduped.append(entry)
        }
        return deduped
    }

    /// Whether a session still exists on another machine.
    ///
    /// Returns nil when the host could not be asked — unreachable is not the
    /// same as gone, and the two lead to opposite decisions about the pane.
    ///
    /// This is the only honest way to tell "the user typed `exit`" from "the
    /// link dropped". Both end the pane's `ssh` process identically, and the
    /// exit status can't separate them either: on macOS every pane runs under
    /// `login(1)`, which reports 0 no matter what the child did (verified —
    /// a child exiting 3 or 255 both surface as 0). What *does* differ is the
    /// far side: a zmx daemon unlinks its socket the moment its shell exits,
    /// and keeps it when only the client went away.
    /// The tail of a remote session's scrollback, fetched over SSH.
    ///
    /// A pane here that shells into another Mac is a viewer; the scrollback
    /// lives in the daemon over there. Refusing to fetch it and telling the
    /// person to go and pair with that machine was the wrong answer — trm
    /// already asks that host whether the session is alive, and this is the
    /// same round trip for something far more useful.
    ///
    /// Trimmed on the far side so the padding a terminal writes to fill its
    /// width never crosses the network.
    nonisolated static func remoteHistory(
        _ name: String, host: String, lines: Int = 400
    ) -> String? {
        let script = [
            "S=\"\(name)\";",
            "Z=\"\(remoteZmxPath)\";",
            "[ -x \"$Z\" ] || exit 1;",
            "D=\"$HOME/.trm/zmx\";",
            "T=\"${TMPDIR:-/tmp}\"; T=\"${T%/}/zmx-$(id -u)\";",
            "for DIR in \"$D\" \"$T\"; do",
            "  [ -S \"$DIR/$S\" ] || continue;",
            "  ZMX_DIR=\"$DIR\" \"$Z\" history \"$S\" 2>/dev/null",
            "    | sed -e 's/[[:space:]]*$//'",
            "    | tail -n \(lines);",
            "  exit 0;",
            "done;",
            "exit 1",
        ].joined(separator: " ")

        let run = runCapturing(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, shWrapped(script)],
            timeout: 20)
        guard run.status == 0, let out = run.output, !out.isEmpty else { return nil }
        // An idle pane ends in a screenful of blanks; opening its scrollback
        // should not land you below the last thing it said.
        var all = out.components(separatedBy: "\n")
        while let last = all.last, last.isEmpty { all.removeLast() }
        return all.joined(separator: "\n")
    }

    nonisolated static func remoteSessionAlive(_ name: String, host: String) -> Bool? {
        let script = [
            "S=\"\(name)\";",
            "D=\"$HOME/.trm/zmx\";",
            "T=\"${TMPDIR:-/tmp}\"; T=\"${T%/}/zmx-$(id -u)\";",
            "for DIR in \"$D\" \"$T\"; do",
            "  [ -S \"$DIR/$S\" ] && { echo alive; exit 0; };",
            "done;",
            "echo gone",
        ].joined(separator: " ")

        let run = runCapturing(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, shWrapped(script)],
            timeout: 12)
        guard run.status == 0, let out = run.output else { return nil }
        if out.contains("alive") { return true }
        if out.contains("gone") { return false }
        return nil
    }

    /// Kill a session on another machine.
    nonisolated static func killRemoteSession(_ name: String, host: String) {
        // Quoted so a session name can never turn into extra shell words; the
        // names trm generates are `trm-<hex>`, but this also runs on names
        // typed by a user of plain zmx on the other machine.
        let script = "D=\"$HOME/.trm/zmx\"; T=\"${TMPDIR:-/tmp}\"; T=\"${T%/}/zmx-$(id -u)\"; "
            + "for DIR in \"$D\" \"$T\"; do "
            + "ZMX_DIR=\"$DIR\" \"\(remoteZmxPath)\" kill \"\(name)\" 2>/dev/null && exit 0; "
            + "done"
        let run = runCapturing(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, shWrapped(script)],
            timeout: 20)
        if run.status != 0 {
            let why = sshFailureMessage(run.error, status: run.status)
            logger.error("remote kill of \(name) on \(host) failed: \(why)")
        }
    }

    /// SSH destinations named by `remote_host` in any saved session TOML.
    /// These are the machines this Mac has actually put panes on, which is a
    /// better list than Bonjour alone: a host reached over Tailscale or a VPN
    /// never shows up in a LAN service browse.
    static func savedRemoteHosts() -> [String] {
        let fm = FileManager.default
        let dir = SessionManager.sessionsDirectory
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var hosts: [String] = []
        var seen: Set<String> = []
        for file in files where file.hasSuffix(".toml") {
            guard let content = try? String(
                contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { continue }
            for rawLine in content.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("remote_host"), let eq = line.firstIndex(of: "=") else { continue }
                let value = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
                hosts.append(value)
            }
        }
        return hosts
    }

    /// Hand a background read back to the waiting caller.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Run an executable and capture stdout, giving up after `timeout`
    /// seconds. A hung SSH must never wedge the browser's scan.
    nonisolated private static func runCapturing(
        _ executable: String,
        _ args: [String],
        timeout: TimeInterval
    ) -> (output: String?, error: String?, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("\(executable) failed to launch: \(error.localizedDescription)")
            return (nil, error.localizedDescription, -1)
        }

        // Drain the pipe on another thread: reading here and waiting for exit
        // afterwards would deadlock on a full pipe buffer, and waiting first
        // gives the timeout nothing to interrupt. Terminating the child closes
        // the write end, which is what unblocks the reader.
        let box = Box()
        let errBox = Box()
        let sem = DispatchSemaphore(value: 0)
        let errSem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
            sem.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.set((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())
            errSem.signal()
        }
        var timedOut = false
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            logger.warning("\(executable) timed out after \(Int(timeout))s; terminating")
            timedOut = true
            process.terminate()
            _ = sem.wait(timeout: .now() + 2)
        }
        _ = errSem.wait(timeout: .now() + 2)
        process.waitUntilExit()
        let status = timedOut ? 15 : process.terminationStatus
        return (
            String(data: box.get(), encoding: .utf8),
            String(data: errBox.get(), encoding: .utf8),
            status
        )
    }
}
