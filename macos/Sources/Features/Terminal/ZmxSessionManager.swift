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
    static var zmxPath: String? {
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
    static var zmxDir: String {
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

    /// Kill one session (its daemon and child process) via `zmx kill`.
    static func killSession(_ name: String) {
        runZmx(["kill", name])
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
