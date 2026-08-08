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
    static func locate(shellPid: pid_t, paneCwd: String?) -> Located? {
        guard shellPid > 0 else { return nil }
        guard let agent = agentProcess(underShell: shellPid) else { return nil }

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
                return Located(kind: agent.kind, url: url)
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
    /// file born after the process started (small slack for clock fuzz).
    static func transcriptBorn(after started: Date, among candidates: [URL]) -> URL? {
        let born: [(URL, Date)] = candidates.compactMap { url in
            guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) else { return nil }
            return (url, created)
        }
        return selectTranscript(startedAt: started, slack: 30, candidates: born)?.0
    }

    /// Pure selection logic: the earliest candidate created after
    /// `startedAt - slack`. Exposed for testing.
    static func selectTranscript(startedAt: Date, slack: TimeInterval, candidates: [(URL, Date)]) -> (URL, Date)? {
        candidates
            .filter { $0.1 >= startedAt.addingTimeInterval(-slack) }
            .min { $0.1 < $1.1 }
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
            queue.append(contentsOf: children[pid] ?? [])
        }
        return nil
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
