import Foundation
import Darwin

/// Resolves which coding-agent session is running *inside* a specific pane.
///
/// The naive approach — newest transcript in the pane's cwd project directory —
/// shows the wrong session whenever two agents share a working directory
/// (observed live: an overview displayed a different Claude session's
/// messages). The reliable identity is the agent process itself: walk the
/// pane's process tree to find a `claude`/`codex` process, then ask the kernel
/// which transcript file that process actually has open.
enum AgentSessionLocator {
    struct Located: Equatable {
        let kind: AgentKind
        let url: URL
    }

    /// Find the agent session bound to the shell running in a pane.
    ///
    /// Order of preference:
    /// 1. A transcript file the agent process holds open (exact, but both
    ///    agents open-append-close per write, so this only catches a write in
    ///    flight).
    /// 2. Birth-time correlation: a session's transcript is created shortly
    ///    AFTER its process starts, so among the pane-cwd's candidates, the
    ///    first file born after the agent process started is its session.
    ///    This is what disambiguates two agents sharing one cwd.
    /// 3. Codex only: newest rollout whose `session_meta.cwd` matches.
    /// The final fallback (newest-in-cwd) stays with the caller.
    /// Wrap a transcript path the agent itself reported.
    ///
    /// Used when re-checking a binding that is already in place: the hook
    /// record is authoritative about *which file*, and the kind follows from
    /// where that file lives.
    static func located(atRecorded url: URL) -> Located? {
        if isTranscriptPath(url.path, kind: .codex) {
            return Located(kind: .codex, url: url)
        }
        if isTranscriptPath(url.path, kind: .claude) {
            return Located(kind: .claude, url: url)
        }
        // An unknown JSONL path is not implicitly Claude. That default made a
        // stale or malformed record relabel a known Codex pane and feed the
        // file to the wrong parser.
        return nil
    }

    /// The conversation a running Claude process is on, in its own words.
    ///
    /// Claude keeps `~/.claude/sessions/<pid>.json` — its session id and
    /// working directory — and rewrites it when the conversation changes:
    /// resumed at launch, `/clear`, `/resume`. That is exact where everything
    /// else here is inference, and it follows the one case inference cannot:
    /// a process that resumed a conversation older than itself, whose file was
    /// born before the process started and so never matched a birth-time rule.
    static func claudeSessionTranscript(pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              !sessionId.contains("/"),
              let cwd = object["cwd"] as? String, !cwd.isEmpty
        else { return nil }
        let url = AgentTranscriptReader.projectDir(forCwd: cwd)
            .appendingPathComponent("\(sessionId).jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func locate(
        shellPid: pid_t,
        paneCwd: String?,
        recordKey: String? = nil
    ) -> Located? {
        guard shellPid > 0 else { return nil }
        guard let agent = agentProcess(underShell: shellPid) else { return nil }

        if agent.kind == .claude, let url = claudeSessionTranscript(pid: agent.pid) {
            return Located(kind: .claude, url: url)
        }

        // An exact answer, when the agent's SessionStart hook has recorded one:
        // the transcript path the agent itself reported. Everything below is a
        // correlation of timestamps that cannot separate several agents
        // sharing a project directory.
        if let recordKey {
            let started = processStartDate(pid: agent.pid)
            if let url = AgentSessionHook.recordedTranscript(
                recordKey: recordKey,
                recordedAfter: started?.addingTimeInterval(-30)
            ), let located = located(atRecorded: url), located.kind == agent.kind {
                // The record can outlive the process that wrote it. Requiring
                // its path kind to agree with the process prevents an old
                // Claude record from taking over a Codex pane (and vice versa).
                return located
            }
        }

        if let url = openTranscript(pid: agent.pid, kind: agent.kind) {
            return Located(kind: agent.kind, url: url)
        }

        if let cwd = paneCwd, let started = processStartDate(pid: agent.pid) {
            let candidates: [URL]
            switch agent.kind {
            case .claude:
                candidates = jsonlFiles(in: AgentTranscriptReader.projectDir(forCwd: cwd))
            case .codex:
                candidates = codexRollouts(matchingCwd: cwd)
            }
            if let url = transcriptBorn(after: started, among: candidates) {
                // Claude keeps one process alive across `/clear`, but starts a
                // new JSONL each time. Its bridgeSessionId is stable across
                // those files and distinct between neighbouring panes, so it
                // upgrades the birth-time match to the current chat without
                // falling into newest-file-in-cwd ambiguity.
                let current = agent.kind == .claude
                    ? latestClaudeTranscript(inBridgeOf: url, among: candidates)
                    : nil
                return Located(kind: agent.kind, url: current ?? url)
            }
        }

        if agent.kind == .codex, let cwd = paneCwd,
           let url = CodexTranscriptReader.latestRollout(matchingCwd: cwd) {
            return Located(kind: .codex, url: url)
        }

        return nil
    }

    /// When the given process started, via libproc.
    static func processStartDate(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    /// Among candidate transcripts, the one this process created: the FIRST
    /// file born after the process started (small slack for clock fuzz),
    /// ignoring files this process cannot be talking into.
    static func transcriptBorn(
        after started: Date,
        among candidates: [URL],
        now: Date = Date()
    ) -> URL? {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let described: [Candidate] = candidates.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let born = values.creationDate,
                  let modified = values.contentModificationDate else { return nil }
            return Candidate(url: url, born: born, modified: modified)
        }
        return selectTranscript(
            startedAt: started, slack: 30, now: now, candidates: described)?.url
    }

    /// One transcript file, described by the two times that say whether it
    /// could be a given process's conversation.
    struct Candidate: Equatable {
        let url: URL
        /// When the file was created.
        let born: Date
        /// When it was last appended to.
        let modified: Date
    }

    /// Claude's stable identity for one running CLI process. `/clear` changes
    /// `sessionId` and the JSONL path, while `bridgeSessionId` survives and its
    /// sequence advances. This is the exact local fallback when a process was
    /// already running before the SessionStart hook was installed.
    struct ClaudeBridgeIdentity: Equatable {
        let id: String
        let sequence: Int
    }

    /// Bridge metadata is repeated near the live tail, so a bounded scan keeps
    /// this cheap even for transcripts containing tens of megabytes of media.
    private static let claudeBridgeScanBytes: UInt64 = 256 * 1024

    static func claudeBridgeIdentity(of url: URL) -> ClaudeBridgeIdentity? {
        guard let lines = AgentTranscriptReader.readTailLines(
            url: url, bytes: claudeBridgeScanBytes) else { return nil }

        var best: ClaudeBridgeIdentity?
        for line in lines where line.contains("\"bridgeSessionId\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "bridge-session",
                  let id = object["bridgeSessionId"] as? String,
                  !id.isEmpty else { continue }
            let sequence = (object["lastSequenceNum"] as? NSNumber)?.intValue ?? 0
            let identity = ClaudeBridgeIdentity(id: id, sequence: sequence)
            if best == nil || sequence > best!.sequence { best = identity }
        }
        return best
    }

    /// Follow a Claude process through one or more `/clear` files. Candidates
    /// from another pane cannot win because their bridge id differs, even when
    /// both panes share a project directory and are active simultaneously.
    static func latestClaudeTranscript(
        inBridgeOf current: URL,
        among candidates: [URL]
    ) -> URL? {
        guard let currentIdentity = claudeBridgeIdentity(of: current),
              let currentValues = try? current.resourceValues(forKeys: [.creationDateKey]),
              let currentBorn = currentValues.creationDate else { return nil }

        var bestURL = current
        var bestIdentity = currentIdentity
        var bestBorn = currentBorn
        for url in candidates where url != current {
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey]),
                  let born = values.creationDate,
                  born >= currentBorn,
                  let identity = claudeBridgeIdentity(of: url),
                  identity.id == currentIdentity.id else { continue }
            if identity.sequence > bestIdentity.sequence
                || (identity.sequence == bestIdentity.sequence && born > bestBorn) {
                bestURL = url
                bestIdentity = identity
                bestBorn = born
            }
        }
        return bestURL
    }

    static func latestClaudeTranscript(inBridgeOf current: URL) -> URL? {
        latestClaudeTranscript(
            inBridgeOf: current,
            among: jsonlFiles(in: current.deletingLastPathComponent()))
    }

    /// A file written for only a moment and silent ever since is an abandoned
    /// stub — an agent that was started and quit, or a session that never got
    /// a first message. Observed in the wild: a 32 KB transcript with ten
    /// seconds of writes, dead for four hours, sitting in a project directory
    /// where three agents were working.
    private static func isAbandonedStub(_ c: Candidate, now: Date) -> Bool {
        c.modified.timeIntervalSince(c.born) < 60 && now.timeIntervalSince(c.modified) > 300
    }

    /// Pure selection logic. Exposed for testing.
    ///
    /// Agents don't hold their transcripts open (verified: `lsof` on a running
    /// `claude` lists no `.jsonl`), so the binding is a correlation of times,
    /// and it has to survive a project directory holding several agents'
    /// sessions plus the debris of old ones:
    ///
    /// 1. Born after the process started (minus slack) — the session this
    ///    process created rather than one that predates it.
    /// 2. Written to since the process started — a conversation this process
    ///    takes part in must have grown during its lifetime. This is what
    ///    rules out a stub created seconds before the agent launched, which
    ///    the birth test alone accepts and then binds forever.
    /// 3. Not an abandoned stub, unless nothing else qualifies — a short
    ///    session the user really did leave idle is still the right answer
    ///    when it is the only candidate.
    /// 4. Prefer files born at/after this process. The slack window exists for
    ///    timestamp granularity, not to let a pane opened seconds earlier win.
    /// 5. Of post-start files, the earliest born is this process's best match;
    ///    if clock slack is required, use the closest pre-start file instead.
    static func selectTranscript(
        startedAt: Date,
        slack: TimeInterval,
        now: Date = Date(),
        candidates: [Candidate]
    ) -> Candidate? {
        let live = candidates.filter {
            $0.born >= startedAt.addingTimeInterval(-slack) && $0.modified >= startedAt
        }

        // Two panes are often opened within the 30-second clock-fuzz window.
        // For the later process, the earlier pane's transcript is then inside
        // the slack and used to win simply because it was born first. Prefer
        // files born at/after this process; only reach into the slack window
        // when there is no such candidate at all.
        let afterStart = live.filter { $0.born >= startedAt }
        let timePool = afterStart.isEmpty ? live : afterStart
        let active = timePool.filter { !isAbandonedStub($0, now: now) }
        let pool = active.isEmpty ? timePool : active
        if afterStart.isEmpty {
            // All candidates precede the process due to timestamp granularity
            // or genuine clock fuzz. The closest one is the plausible match.
            return pool.max { $0.born < $1.born }
        }
        return pool.min { $0.born < $1.born }
    }

    private static func jsonlFiles(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ))?.filter { $0.pathExtension == "jsonl" } ?? []
    }

    private static func codexRollouts(matchingCwd cwd: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: CodexTranscriptReader.sessionsRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if CodexTranscriptReader.sessionCwd(of: url) == cwd { out.append(url) }
        }
        return out
    }

    // MARK: - Process tree

    struct AgentProcess: Equatable {
        let pid: pid_t
        let kind: AgentKind
    }

    /// Find the nearest descendant of `shellPid` that is a known agent CLI.
    ///
    /// Enumerates all processes once, builds the child map, and BFS-walks from
    /// the shell so the *closest* agent wins when nesting occurs (an agent
    /// spawning sub-agents).
    static func agentProcess(underShell shellPid: pid_t) -> AgentProcess? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }

        var children: [pid_t: [pid_t]] = [:]
        var names: [pid_t: String] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let ret = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size))
            guard ret > 0 else { continue }
            children[pid_t(info.pbsi_ppid), default: []].append(pid)
            names[pid] = withUnsafeBytes(of: info.pbsi_comm) { bytes -> String in
                let buf = bytes.bindMemory(to: CChar.self)
                guard let base = buf.baseAddress else { return "" }
                return String(cString: base)
            }
        }

        var queue: [pid_t] = children[shellPid] ?? []
        var visited = Set<pid_t>()
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard visited.insert(pid).inserted else { continue }
            if let name = names[pid], let kind = kind(forProcessName: name) {
                return AgentProcess(pid: pid, kind: kind)
            }
            // p_comm is the executable's name, and Claude's versioned
            // installer runs a binary literally named after its version
            // ("2.1.226") — matching on it finds nothing, the locator gives
            // up, and the overview falls back to newest-transcript-in-cwd,
            // which binds the WRONG session when several agents share a
            // folder. The stable identity is argv[0], which the launcher
            // sets to "claude". Only descendants of the pane's shell reach
            // this, so the extra sysctl stays cheap.
            if let arg0 = argv0(pid: pid),
               let kind = kind(forProcessName: (arg0 as NSString).lastPathComponent) {
                return AgentProcess(pid: pid, kind: kind)
            }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return nil
    }

    /// argv[0] of a process via KERN_PROCARGS2 (same-user processes only).
    ///
    /// Layout: `int argc`, the exec path, NUL padding, then argv[0].
    static func argv0(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }  // exec path
        while i < size, buf[i] == 0 { i += 1 }  // padding
        guard i < size else { return nil }
        let start = i
        while i < size, buf[i] != 0 { i += 1 }
        return String(decoding: buf[start..<i], as: UTF8.self)
    }

    /// Match a process basename to an agent kind. Exposed for testing.
    static func kind(forProcessName name: String) -> AgentKind? {
        switch name {
        case AgentKind.claude.processName: return .claude
        case AgentKind.codex.processName: return .codex
        default: return nil
        }
    }

    // MARK: - Open files

    /// The transcript file `pid` holds open, if any.
    ///
    /// lsof-style: list the process's file descriptors, resolve vnode fds to
    /// paths, and keep the one under the agent's session directory.
    static func openTranscript(pid: pid_t, kind: AgentKind) -> URL? {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return nil }
        let fdCount = Int(bufSize) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard filled > 0 else { return nil }
        let usable = Int(filled) / MemoryLayout<proc_fdinfo>.size

        var newest: (URL, Date)? = nil
        for fd in fds.prefix(usable) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            let ret = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard ret > 0 else { continue }
            let path = withUnsafeBytes(of: vi.pvip.vip_path) { bytes -> String in
                let buf = bytes.bindMemory(to: CChar.self)
                guard let base = buf.baseAddress, base.pointee != 0 else { return "" }
                return String(cString: base)
            }
            guard isTranscriptPath(path, kind: kind) else { continue }
            let url = URL(fileURLWithPath: path)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            if newest == nil || mtime > newest!.1 {
                newest = (url, mtime)
            }
        }
        return newest?.0
    }

    /// Whether a path is a transcript for the given agent. Exposed for testing.
    static func isTranscriptPath(_ path: String, kind: AgentKind) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        switch kind {
        case .claude: return path.contains("/.claude/projects/")
        case .codex: return path.contains("/.codex/sessions/")
        }
    }
}
