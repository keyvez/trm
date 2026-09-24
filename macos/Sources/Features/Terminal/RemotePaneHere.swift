import Foundation

/// ⌃⌘⇧N: a new remote pane where the focused one is, running what it runs.
///
/// ⌘⇧N opens a shell on the other machine in its home directory, and the first
/// thing anyone does next is `cd` back to the project the pane beside it is in
/// and start the same agent again. This answers both from the focused pane: one
/// SSH round trip reads the folder its session's shell is in and the agent
/// running under it, the new pane's zmx session is started in that folder, and
/// the agent's command is typed into it.
enum RemotePaneHere {
    /// What the focused pane's session is doing on its machine.
    struct Context: Equatable {
        /// The folder to open in: the agent's when there is one (that is the
        /// project it was started in), the shell's otherwise.
        var directory: String?
        var agent: AgentKind?
        /// The agent's command line as `ps` reports it, flags and all.
        var agentCommandLine: String?
    }

    /// One script for one session: `<cwd>\t<kind>\t<command line>`.
    ///
    /// Finds the session's shell the way the Session Browser's probe does —
    /// `zmx list` in both socket directories — then the agent under it.
    static func probeScript(session: String) -> String {
        [
            AgentProbeShell.functions,
            "Z=\"\(ZmxSessionManager.remoteZmxPath)\";",
            "[ -x \"$Z\" ] || exit 0;",
            "D=\"$HOME/.trm/zmx\";",
            "T=\"${TMPDIR:-/tmp}\"; T=\"${T%/}/zmx-$(id -u)\";",
            "P=\"\";",
            "for DIR in \"$D\" \"$T\"; do",
            "  [ -d \"$DIR\" ] || continue;",
            "  L=$(ZMX_DIR=\"$DIR\" \"$Z\" list 2>/dev/null | grep \"name=\(session)[[:space:]]\" | head -1);",
            "  [ -n \"$L\" ] || continue;",
            "  for TOK in $L; do case \"$TOK\" in pid=*) P=${TOK#pid=} ;; esac; done;",
            "  [ -n \"$P\" ] && break;",
            "done;",
            "[ -n \"$P\" ] || exit 0;",
            "W=$(cwd_of \"$P\"); K=\"\"; C=\"\";",
            "A=$(agent_under \"$P\");",
            "if [ -n \"$A\" ]; then",
            "  AP=${A%% *}; K=${A#* };",
            "  C=$(ps -o command= -p \"$AP\" 2>/dev/null | head -1);",
            "  AW=$(cwd_of \"$AP\"); [ -n \"$AW\" ] && W=\"$AW\";",
            "fi;",
            "printf \"%s\\t%s\\t%s\\n\" \"$W\" \"$K\" \"$C\"",
        ].joined(separator: " ")
    }

    static func parse(_ output: String) -> Context? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).first
        else { return nil }
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard !cols.isEmpty else { return nil }
        func col(_ i: Int) -> String? {
            guard i < cols.count else { return nil }
            let value = cols[i].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return Context(
            directory: col(0),
            agent: col(1).flatMap(AgentKind.init(rawValue:)),
            agentCommandLine: col(2))
    }

    /// Ask the focused pane's machine. Nil when it can't be reached; the pane
    /// is then opened the ordinary ⌘⇧N way rather than not at all.
    nonisolated static func probe(host: String, session: String) -> Context? {
        guard AgentResume.isSafeSessionName(session) else { return nil }
        let args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            host,
            ZmxSessionManager.shWrapped(probeScript(session: session)),
        ]
        let run = ZmxSessionManager.runCapturing("/usr/bin/ssh", args, timeout: 10)
        guard run.status == 0, let out = run.output else { return nil }
        return parse(out)
    }

    /// The command that starts the same agent afresh.
    ///
    /// The flags come along — `--dangerously-skip-permissions`, `--model …` are
    /// how this person runs this agent — but not the ones that name a
    /// conversation: a second agent resuming the first one's session would be
    /// two processes writing one transcript. The program is the agent's own
    /// name rather than whatever `ps` shows as argv0, which for Claude Code can
    /// be a path ending in a version number.
    static func launchCommand(agent: AgentKind, commandLine: String?) -> String {
        var tokens = (commandLine ?? "").split(separator: " ").map(String.init)
        if !tokens.isEmpty { tokens.removeFirst() }

        // Flag → whether it takes a value.
        let dropped: [String: Bool]
        switch agent {
        case .claude:
            dropped = [
                "--resume": true, "-r": true, "--session-id": true,
                "--continue": false, "-c": false, "--fork-session": false,
            ]
        case .codex:
            dropped = ["--last": false]
            // `codex resume [id]` is a subcommand, not a flag.
            if tokens.first == "resume" {
                tokens.removeFirst()
                if let next = tokens.first, !next.hasPrefix("-") { tokens.removeFirst() }
            }
        }

        var kept: [String] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if let takesValue = dropped[name] {
                i += 1
                // `--resume=<id>` carries its value; `--resume <id>` is two
                // tokens, and `-r` alone (pick a conversation) is none.
                if takesValue, !token.contains("="),
                   i < tokens.count, !tokens[i].hasPrefix("-") {
                    i += 1
                }
                continue
            }
            kept.append(token)
            i += 1
        }
        return ([agent.processName] + kept.map(shellQuoted)).joined(separator: " ")
    }

    /// A local path under this user's home as `~/…`, so it can name the same
    /// place on a machine where the user is called something else.
    static func homeRelative(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// A folder as a `cd` argument for the remote shell: quoted, with a
    /// leading `~` left outside the quotes as `$HOME` so it expands there.
    static func remoteCdTarget(_ directory: String) -> String {
        if directory == "~" { return "\"$HOME\"" }
        if directory.hasPrefix("~/") {
            return "\"$HOME\"/" + shellQuoted(String(directory.dropFirst(2)))
        }
        return shellQuoted(directory)
    }

    /// Single-quote for a POSIX shell unless the word needs nothing.
    static func shellQuoted(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_=./:,@%+"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ plain.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
