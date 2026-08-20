import Foundation
import os

/// Installs and manages the Claude Code `SessionStart` hook that tells trm
/// which transcript belongs to which pane.
///
/// Without it, binding a pane to its agent transcript is a correlation of
/// timestamps: agents don't hold their `.jsonl` open, so the overview looks
/// for the file in the project directory born just after the agent process
/// started. That guess fails in two shapes seen in the wild — a session
/// *resumed* from a file created days earlier, and several agents working in
/// one project directory, where the debris of old sessions is indistinguishable
/// from the live one.
///
/// The hook removes the guess. Claude Code runs it whenever a session starts,
/// resumes, or is cleared, handing it JSON containing `transcript_path` on
/// stdin. The script writes that path to `~/.trm/agent-sessions/<key>`, keyed
/// by the pane's **zmx session name** (`$ZMX_SESSION`, injected by zmx into
/// every session's shell). That key works identically on both sides of an SSH
/// link: a remote pane's overview knows the remote session name, and the file
/// it needs sits on the machine the agent runs on.
///
/// Nothing depends on the hook — every reader falls back to the correlation
/// when no record exists, which is also what happens for agents that were
/// already running when the hook was installed.
///
/// Deliberately actor-free: every member is file or subprocess work, and the
/// readers run on background queues (the overview's poll) while the installer
/// runs from the command palette on the main actor.
enum AgentSessionHook {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "AgentSessionHook"
    )

    /// Marker used to recognise our own hook entry in a settings file we did
    /// not write, so installing twice doesn't duplicate it.
    static let scriptName = "trm-agent-session-hook"

    /// Where the script lives, on this machine and on remote ones.
    static let scriptPath = "$HOME/.trm/bin/\(scriptName)"

    /// Directory the script writes records into.
    static var recordsDirectory: String { NSHomeDirectory() + "/.trm/agent-sessions" }

    /// The record for one zmx session, or nil when the hook hasn't run for it.
    ///
    /// `recordedAfter` guards against a stale record: a pane whose agent was
    /// replaced by one started without the hook would otherwise keep pointing
    /// at the old conversation. The hook rewrites the record at every session
    /// start, so a record older than the agent process cannot describe it.
    static func recordedTranscript(
        zmxSession: String,
        recordedAfter: Date? = nil
    ) -> URL? {
        let path = NSHomeDirectory() + "/.trm/agent-sessions/" + zmxSession
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let transcript = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, FileManager.default.fileExists(atPath: transcript) else {
            return nil
        }
        if let recordedAfter,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let written = attrs[.modificationDate] as? Date,
           written < recordedAfter {
            return nil
        }
        return URL(fileURLWithPath: transcript)
    }

    // MARK: - The script

    /// POSIX sh, no dependencies beyond `sed`: it runs on whatever the other
    /// machine has, and a hook that fails is a hook that breaks someone's
    /// agent. Every failure path exits 0 and prints nothing — a SessionStart
    /// hook's stdout is injected into the agent's context, so this one must
    /// stay silent.
    static let script = """
    #!/bin/sh
    # Written by trm. Records which agent transcript belongs to which pane, so
    # the Agent Overview can bind the two exactly instead of guessing from file
    # timestamps. Safe to delete: trm falls back to the guess without it.
    #
    # Keyed by the zmx session name, which is the one identifier that means the
    # same thing on both ends of an SSH link. TRM_PANE_ID is the fallback for
    # panes running without session persistence.
    key="${ZMX_SESSION:-}"
    [ -n "$key" ] || key="pane-${TRM_PANE_ID:-}"
    [ "$key" = "pane-" ] && exit 0

    dir="$HOME/.trm/agent-sessions"
    mkdir -p "$dir" 2>/dev/null || exit 0

    payload="$(cat | tr -d '\\n')"
    path="$(printf '%s' "$payload" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')"
    [ -n "$path" ] || exit 0

    printf '%s\\n' "$path" > "$dir/$key" 2>/dev/null || exit 0

    # Records outlive their sessions; drop ones nothing points at any more.
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      p="$(cat "$f" 2>/dev/null)"
      [ -n "$p" ] && [ ! -f "$p" ] && rm -f "$f" 2>/dev/null
    done
    exit 0
    """

    // MARK: - Local install

    /// Whether the hook is installed for this machine's Claude Code.
    static func isInstalled() -> Bool {
        guard let settings = readSettings(atPath: localSettingsPath) else { return false }
        return settingsContainHook(settings)
    }

    /// Write the script and register it in `~/.claude/settings.json`.
    /// Returns nil on success, or a message describing what stopped it.
    @discardableResult
    static func install() -> String? {
        let home = NSHomeDirectory()
        if let error = writeScript(toDirectory: home + "/.trm/bin") { return error }

        var settings = readSettings(atPath: localSettingsPath) ?? [:]
        guard !settingsContainHook(settings) else { return nil }
        settings = settingsAddingHook(settings)

        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            let url = URL(fileURLWithPath: localSettingsPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep a copy of whatever was there: this is the user's own config.
            if FileManager.default.fileExists(atPath: localSettingsPath) {
                let backup = localSettingsPath + ".trm-backup"
                try? FileManager.default.removeItem(atPath: backup)
                try? FileManager.default.copyItem(atPath: localSettingsPath, toPath: backup)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            return "Could not write ~/.claude/settings.json: \(error.localizedDescription)"
        }
        logger.info("Installed the agent session hook locally")
        return nil
    }

    private static var localSettingsPath: String { NSHomeDirectory() + "/.claude/settings.json" }

    private static func writeScript(toDirectory dir: String) -> String? {
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/" + scriptName
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path)
            return nil
        } catch {
            return "Could not write the hook script: \(error.localizedDescription)"
        }
    }

    // MARK: - Remote install

    /// Install on another machine over SSH.
    ///
    /// The JSON merge happens here rather than on the far side: the remote is
    /// only asked to `cat` a file in and out, so this needs no python, jq, or
    /// particular trm version over there.
    static func installRemote(host: String) -> String? {
        let scriptDir = "$HOME/.trm/bin"
        let write = "mkdir -p \(scriptDir) && cat > \(scriptDir)/\(scriptName) "
            + "&& chmod 755 \(scriptDir)/\(scriptName)"
        if let error = runSSH(host: host, command: write, stdin: script).error {
            return "Could not write the hook script on \(host): \(error)"
        }

        let read = runSSH(host: host, command: "cat $HOME/.claude/settings.json 2>/dev/null")
        var settings = parseSettings(read.output ?? "") ?? [:]
        if settingsContainHook(settings) { return nil }
        settings = settingsAddingHook(settings)

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "Could not build settings JSON for \(host)."
        }

        let install = "mkdir -p $HOME/.claude && "
            + "cp $HOME/.claude/settings.json $HOME/.claude/settings.json.trm-backup 2>/dev/null; "
            + "cat > $HOME/.claude/settings.json"
        if let error = runSSH(host: host, command: install, stdin: json).error {
            return "Could not write settings.json on \(host): \(error)"
        }
        return nil
    }

    /// Whether the hook is installed on another machine.
    static func isInstalledRemotely(host: String) -> Bool {
        let result = runSSH(
            host: host,
            command: "test -x $HOME/.trm/bin/\(scriptName) "
                + "&& grep -q \(scriptName) $HOME/.claude/settings.json 2>/dev/null "
                + "&& echo yes")
        return (result.output ?? "").contains("yes")
    }

    // MARK: - Settings surgery

    /// Whether a settings dictionary already registers our hook. Matched on
    /// the script name so a hand-edited entry (different path, wrapper script)
    /// still counts and doesn't get a duplicate.
    static func settingsContainHook(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let sessionStart = hooks["SessionStart"] as? [[String: Any]] else { return false }
        for group in sessionStart {
            guard let entries = group["hooks"] as? [[String: Any]] else { continue }
            for entry in entries {
                if let command = entry["command"] as? String, command.contains(scriptName) {
                    return true
                }
            }
        }
        return false
    }

    /// The settings dictionary with our SessionStart hook appended, preserving
    /// every other key and any hooks the user already has. Pure, for testing.
    static func settingsAddingHook(_ settings: [String: Any]) -> [String: Any] {
        var result = settings
        var hooks = (result["hooks"] as? [String: Any]) ?? [:]
        var sessionStart = (hooks["SessionStart"] as? [[String: Any]]) ?? []
        sessionStart.append([
            "hooks": [[
                "type": "command",
                "command": scriptPath,
            ]] as [[String: String]],
        ])
        hooks["SessionStart"] = sessionStart
        result["hooks"] = hooks
        return result
    }

    private static func readSettings(atPath path: String) -> [String: Any]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parseSettings(text)
    }

    private static func parseSettings(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    // MARK: - SSH

    private static func runSSH(
        host: String, command: String, stdin: String? = nil
    ) -> (output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, command,
        ]
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = Pipe()
        process.standardInput = stdin != nil ? stdinPipe : FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (nil, error.localizedDescription)
        }
        if let stdin {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }
        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, message.isEmpty ? "ssh exited \(process.terminationStatus)" : message)
        }
        return (String(decoding: out, as: UTF8.self), nil)
    }
}
