import Foundation

/// Bringing an AI coding agent back after the machine has restarted.
///
/// Session persistence normally means the processes never died: panes run
/// under zmx, so quitting trm — or killing it — leaves the shells running and
/// relaunching reattaches to them. A reboot is the one event that defeats
/// that. Every daemon is gone, so every pane comes back as a fresh shell, and
/// an agent that was thirty turns into a problem is simply not there any more.
///
/// The agents themselves can come back, though, because both keep their
/// conversation on disk and both take a flag to resume one. So a reboot
/// restores in a lighter way than a relaunch does: the layout, the
/// directories and the watermarks as always, and in place of a live process,
/// the agent restarted on the conversation it was having.
///
/// The id needs no new capture. The SessionStart hook already records which
/// transcript belongs to which pane, and for both agents the transcript's
/// filename *is* the session id — so the thing to persist was sitting in a
/// path trm already had.
enum AgentResume {

    /// What to put back, and how.
    struct Record: Equatable {
        let kind: AgentKind
        let id: String
    }

    /// The agent conversation running in the pane backed by `zmxSession`.
    ///
    /// Read at save time rather than restore time: the hook's record is keyed
    /// by zmx session name and nothing prunes it, but a conversation that has
    /// been resumed elsewhere or cleared moves on, and the snapshot in the
    /// session file should say what was true when the layout was saved.
    static func record(forZmxSession session: String) -> Record? {
        guard let transcript = AgentSessionHook.recordedTranscript(recordKey: session) else {
            return nil
        }
        return record(forTranscript: transcript)
    }

    static func record(forTranscript url: URL) -> Record? {
        let path = url.path
        let kind: AgentKind
        if path.contains("/.claude/projects/") {
            kind = .claude
        } else if path.contains("/.codex/sessions/") {
            kind = .codex
        } else {
            return nil
        }
        guard let id = sessionID(fromTranscript: url, kind: kind) else { return nil }
        return Record(kind: kind, id: id)
    }

    /// Pull the session id out of a transcript filename.
    ///
    /// Claude names the file after the session: `<uuid>.jsonl`. Codex prefixes
    /// a timestamp: `rollout-2026-09-11T13-01-10-<uuid>.jsonl`, where the uuid
    /// is the last five dash-separated groups — the timestamp contains dashes
    /// too, so counting from the end is the only reading that survives it.
    static func sessionID(fromTranscript url: URL, kind: AgentKind) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        switch kind {
        case .claude:
            return isUUID(name) ? name : nil
        case .codex:
            let parts = name.split(separator: "-")
            guard parts.count >= 5 else { return nil }
            let candidate = parts.suffix(5).joined(separator: "-")
            return isUUID(candidate) ? candidate : nil
        }
    }

    /// What to type into a fresh shell to pick the conversation back up.
    ///
    /// Quoted even though these ids are hex and dashes: the id is read from a
    /// filename on disk, and a command built from a filename should not be
    /// the one place that assumes the filename is tame.
    static func command(for record: Record) -> String {
        let id = "'" + record.id.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch record.kind {
        case .claude: return "claude --resume \(id)"
        case .codex: return "codex resume \(id)"
        }
    }

    /// 8-4-4-4-12 hex. Both agents use them; anything else in that filename
    /// position is something we do not understand and must not pass to a
    /// shell.
    static func isUUID(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
              groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }
}
