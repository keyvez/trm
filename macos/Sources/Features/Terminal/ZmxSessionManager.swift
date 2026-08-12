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
/// state via ghostty-vt. Remote attach: `ssh -t host zmx attach <name>`.
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
            let info = SessionInfo(
                name: name,
                cwd: pid.flatMap { cwd(ofPid: $0) },
                command: pid.flatMap { command(ofShellPid: $0) },
                attached: attached.contains(name),
                referenced: referenced.contains(name)
            )
            lock.lock()
            results[index] = info
            lock.unlock()
        }

        return results.compactMap { $0 }
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
}
