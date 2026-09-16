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

    // MARK: - Panes on another machine

    /// What a host says about one of its own sessions.
    ///
    /// A remote pane cannot be snapshotted the way a local one is. The daemon,
    /// the hook's record and the transcript all live on the far machine, so
    /// `record(forZmxSession:)` has nothing to read here, and reading it there
    /// would mean an SSH round trip per pane on the 30-second checkpoint.
    ///
    /// So a remote pane is asked at *restore* instead, once per host, where a
    /// single round trip answers both halves of the question at once: did this
    /// session survive, and if it did not, what was it talking about. That is
    /// also the more truthful answer — it describes the machine as it is now
    /// rather than as it was when the layout was last written.
    struct RemoteSession: Equatable {
        /// The session's daemon is still running, so whatever agent was in it
        /// is still in it. The pane must not be typed at: `zmx attach` will
        /// reattach to the live shell and the resume would land in the agent
        /// as a prompt.
        let alive: Bool
        /// The conversation the hook recorded for this session. Only resolved
        /// when the session is gone, since that is the only case that acts.
        let record: Record?
    }

    /// Ask one host about a set of its sessions, in one round trip.
    ///
    /// Returns nothing when the host is unreachable or the probe fails, which
    /// is the right answer: an unreachable machine's panes are about to show
    /// an SSH error, and typing a resume into that is worse than silence.
    nonisolated static func remoteSessions(
        host: String, sessions: [String]
    ) -> [String: RemoteSession] {
        let names = sessions.filter(isSafeSessionName)
        guard !names.isEmpty else { return [:] }
        let run = ZmxSessionManager.runCapturing(
            "/usr/bin/ssh",
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=2",
                host,
                ZmxSessionManager.shWrapped(remoteProbeScript(sessions: names)),
            ],
            timeout: 20)
        guard run.status == 0, let out = run.output else { return [:] }
        return parseRemoteProbe(out)
    }

    /// One script, run once per host, printing `name<TAB>alive|gone<TAB>path`.
    ///
    /// Liveness is `lsof` on the socket rather than the socket merely being
    /// there. The sockets live under `$HOME` and so outlive a restart: a
    /// machine that has just rebooted is precisely the case where the file is
    /// present and nothing is listening, and that is the one case this whole
    /// feature exists for. Both socket directories are checked, as the attach
    /// command itself does — trm pins `~/.trm/zmx`, but sessions made before
    /// that pin still live in the per-user tmp dir.
    static func remoteProbeScript(sessions: [String]) -> String {
        let names = sessions.map { "\"\($0)\"" }.joined(separator: " ")
        return [
            "D=\"$HOME/.trm/zmx\";",
            "T=\"${TMPDIR:-/tmp}\"; T=\"${T%/}/zmx-$(id -u)\";",
            "for N in \(names); do",
            "  A=gone;",
            "  for DIR in \"$D\" \"$T\"; do",
            "    [ -S \"$DIR/$N\" ] || continue;",
            "    [ -n \"$(lsof -t \"$DIR/$N\" 2>/dev/null)\" ] && A=alive;",
            "  done;",
            "  P=\"\";",
            "  if [ \"$A\" = gone ] && [ -f \"$HOME/.trm/agent-sessions/$N\" ]; then",
            "    P=\"$(cat \"$HOME/.trm/agent-sessions/$N\" 2>/dev/null)\";",
            "    [ -n \"$P\" ] && [ -f \"$P\" ] || P=\"\";",
            "  fi;",
            "  printf '%s\\t%s\\t%s\\n' \"$N\" \"$A\" \"$P\";",
            "done",
        ].joined(separator: " ")
    }

    static func parseRemoteProbe(_ output: String) -> [String: RemoteSession] {
        var result: [String: RemoteSession] = [:]
        for line in output.components(separatedBy: .newlines) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2, !cols[0].isEmpty else { continue }
            let alive = cols[1] == "alive"
            guard alive || cols[1] == "gone" else { continue }
            var found: Record?
            if !alive, cols.count >= 3, !cols[2].isEmpty {
                found = record(forTranscript: URL(fileURLWithPath: cols[2]))
            }
            result[cols[0]] = RemoteSession(alive: alive, record: found)
        }
        return result
    }

    /// A session name is about to become a shell word on a machine we do not
    /// control. trm's own are `trm-<hex>`, but a pane can be pointed at a
    /// session someone made with plain zmx, so the shape is checked rather
    /// than assumed.
    static func isSafeSessionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
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
