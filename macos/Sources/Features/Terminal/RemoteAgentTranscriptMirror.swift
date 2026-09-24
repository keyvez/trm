import Foundation
import os

/// Streams a remote pane's agent transcript to a local mirror file so the
/// Agent Overview can read it with the same parsers it uses for local panes.
///
/// A remote pane's agent process and its transcript both live on the other
/// machine — the local process-tree walk in `AgentSessionLocator` can't see
/// them. This class does the same resolution over SSH instead:
///
/// 1. **Locate** (short-lived `ssh`): a shell probe — the SSH-side mirror of
///    `AgentSessionLocator` — resolves the zmx session's shell pid via its
///    socket, BFS-walks descendants for a `claude`/`codex` process, and
///    prints the transcript path that process holds open (falling back to
///    the newest transcript for its working directory).
/// 2. **Stream** (long-lived `ssh … tail -n +1 -F`): replays the transcript
///    from the top and follows appends into a local mirror file under
///    Caches. The overview stats and parses the mirror exactly as it would
///    a local transcript.
///
/// Re-locates periodically so a new session started in the same pane (path
/// change) swaps the stream. All state is lock-guarded: `poll()` runs on the
/// overview's 1.5 s main-actor timer while ssh work completes on background
/// queues.
final class RemoteAgentTranscriptMirror: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "RemoteAgentTranscriptMirror"
    )

    let host: String
    let remoteSession: String
    let mirrorURL: URL

    private let lock = NSLock()
    private var locatedKindLocked: AgentKind?
    private var locatedPathLocked: String?
    private var statusLocked: String?
    private var locateInFlight = false
    private var lastLocateAt: Date?
    /// Whether a locate has ever come back, whatever it said.
    private var didAttemptLocateLocked = false
    private var lastStreamStartAt: Date?
    private var streamProcess: Process?
    private var mirrorHandle: FileHandle?
    private var stopped = false

    /// How often the remote session is re-resolved while already streaming,
    /// to catch the agent starting a new session (new transcript path).
    private static let relocateInterval: TimeInterval = 30
    /// Minimum delay between stream (re)starts, so a dead host doesn't get
    /// hammered from a 1.5 s poll.
    private static let streamRestartCooldown: TimeInterval = 5

    /// Every live mirror, so the app can tear their ssh children down on the
    /// way out. Weak: a mirror's lifetime belongs to its overview pane.
    private static let liveMirrors = NSHashTable<RemoteAgentTranscriptMirror>.weakObjects()
    private static let liveMirrorsLock = NSLock()

    /// Stop every running stream. Called on app termination — the streams are
    /// child `ssh` processes that outlive us otherwise (see `reapOrphanedStreams`).
    static func stopAll() {
        liveMirrorsLock.lock()
        let mirrors = liveMirrors.allObjects
        liveMirrorsLock.unlock()
        for mirror in mirrors { mirror.stop() }
    }

    /// Kill transcript streams left behind by a previous trm that didn't exit
    /// cleanly.
    ///
    /// A stream is `ssh … tail -F <transcript>`; when trm is killed rather
    /// than quit, `stop()` never runs and the ssh keeps going with its parent
    /// reparented to launchd — writing into a closed pipe and holding an SSH
    /// session open on the remote machine forever. Found one on a laptop that
    /// had outlived its trm by hours. Matching is deliberately narrow: our own
    /// processes, orphaned (ppid 1), and carrying the exact command shape this
    /// class builds.
    /// Delete mirror files nothing is streaming into any more.
    ///
    /// A mirror replays a remote transcript from the top and follows it, so it
    /// grows for as long as the session runs and is never shortened. That is
    /// correct while the session is live. What is not correct is what happens
    /// afterwards: the file stays, and the directory accumulates one per
    /// session per host — including hosts addressed by a name that has since
    /// changed, which can never be reused. It was 183 MB on the machine this
    /// was found on, a third of it dead.
    ///
    /// Run at launch, beside the stream reaping, since that is the moment
    /// nothing of ours is streaming and every file is safely judged by its
    /// age. That used to be the whole argument, and it is one process too
    /// narrow: a relaunch (⌘⇧R, or a crash-and-restart) has the new trm
    /// running this while the old one still holds its mirrors open, and a
    /// deleted mirror does not stop being written — the handle keeps taking
    /// data into an inode with no name while every reader stats a path with
    /// nothing behind it. Live mirrors are therefore skipped explicitly
    /// rather than assumed absent.
    static func pruneStaleMirrors(olderThan age: TimeInterval = 24 * 60 * 60) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("trm/remote-overview", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        liveMirrorsLock.lock()
        let streaming = Set(liveMirrors.allObjects.map(\.mirrorURL.path))
        liveMirrorsLock.unlock()

        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        var bytes: Int64 = 0
        for file in files where file.pathExtension == "jsonl" {
            // An idle session's mirror stops changing, so age alone would
            // happily delete the file a live stream is filling.
            guard !streaming.contains(file.path) else { continue }
            guard let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            bytes += Int64(values.fileSize ?? 0)
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        if removed > 0 {
            let megabytes = bytes / (1024 * 1024)
            logger.info(
                "Pruned \(removed, privacy: .public) stale mirror(s), \(megabytes, privacy: .public) MB")
        }
    }

    static func reapOrphanedStreams() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // `-x` without `-a`: this user's processes only.
        process.arguments = ["-xo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var reaped = 0
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]), ppid == 1,
                  line.contains("/usr/bin/ssh"),
                  line.contains("tail -n +1 -F "),
                  line.contains(".jsonl")
            else { continue }
            kill(pid, SIGTERM)
            reaped += 1
        }
        if reaped > 0 {
            logger.info("Reaped \(reaped, privacy: .public) orphaned transcript stream(s)")
        }
    }

    /// Where a given host+session would mirror to, without building one.
    static func mirrorURL(host: String, remoteSession: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches
            .appendingPathComponent("trm/remote-overview", isDirectory: true)
            .appendingPathComponent("\(host)-\(remoteSession).jsonl")
    }

    /// Whether a transcript was ever mirrored for this remote session.
    ///
    /// The cheap, local answer to "is there an agent over there". A mirror
    /// only exists once a probe found an agent and started streaming its
    /// transcript, so a non-empty file is positive evidence; a missing one is
    /// merely no evidence, which is the honest state for a pane nothing has
    /// looked at yet. Asking the far side properly costs an SSH round trip,
    /// which is too much to spend answering a click.
    static func hasMirroredTranscript(host: String, remoteSession: String) -> Bool {
        let url = mirrorURL(host: host, remoteSession: remoteSession)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber else { return false }
        return size.intValue > 0
    }

    /// Live mirrors by host and session, so one remote transcript is streamed
    /// once no matter how many things are reading it.
    ///
    /// A mirror is an SSH connection holding `tail -F` open on the far side.
    /// One was built per `AgentOverviewPane`, and a single remote session
    /// routinely has several: the Command Center keeps a headless overview for
    /// every pane, a visible overview is another, and peeking opens a third.
    /// Measured on one machine that meant six streams following one file, 52
    /// SSH connections from a single laptop, and 26 logins a minute — enough
    /// for sshd to start resetting handshakes, which surfaced as remote panes
    /// failing to launch with `kex_exchange_identification: Connection reset`.
    private static var shared: [String: RemoteAgentTranscriptMirror] = [:]
    private static var refCounts: [String: Int] = [:]
    private static let sharedLock = NSLock()

    private var shareKey: String { "\(host)|\(remoteSession)" }

    /// Take a reference to the mirror for this session, building one only if
    /// nothing else is already streaming it.
    static func acquire(host: String, remoteSession: String) -> RemoteAgentTranscriptMirror {
        let key = "\(host)|\(remoteSession)"
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = shared[key] {
            refCounts[key, default: 0] += 1
            return existing
        }
        let mirror = RemoteAgentTranscriptMirror(host: host, remoteSession: remoteSession)
        shared[key] = mirror
        refCounts[key] = 1
        return mirror
    }

    /// Give up a reference. The stream is torn down when the last one goes,
    /// not before — stopping on the first release would kill the feed under
    /// everything else still reading it.
    static func release(_ mirror: RemoteAgentTranscriptMirror) {
        let key = mirror.shareKey
        sharedLock.lock()
        let remaining = (refCounts[key] ?? 1) - 1
        if remaining <= 0 {
            refCounts.removeValue(forKey: key)
            shared.removeValue(forKey: key)
        } else {
            refCounts[key] = remaining
        }
        sharedLock.unlock()
        if remaining <= 0 { mirror.stop() }
    }

    private init(host: String, remoteSession: String) {
        self.host = host
        self.remoteSession = remoteSession

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("trm/remote-overview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Host and session are validated upstream (strict character sets), so
        // they are safe as a file name.
        self.mirrorURL = dir.appendingPathComponent("\(host)-\(remoteSession).jsonl")

        Self.liveMirrorsLock.lock()
        Self.liveMirrors.add(self)
        Self.liveMirrorsLock.unlock()
    }

    /// Agent kind of the located remote session, if resolution succeeded.
    var locatedKind: AgentKind? {
        lock.lock(); defer { lock.unlock() }
        return locatedKindLocked
    }

    /// Identity of the remote transcript currently feeding the stable local
    /// mirror URL. The URL itself never changes, so consumers need this value
    /// to distinguish an idle file from `/clear` replacing it with a new,
    /// initially empty conversation.
    var locatedTranscriptPath: String? {
        lock.lock(); defer { lock.unlock() }
        return locatedPathLocked
    }

    /// True until the first probe returns. Distinguishes "the SSH round trip
    /// hasn't come back" from "it came back and there is no agent here" —
    /// which look identical from `locatedKind` alone, and made a pane whose
    /// probe failed sit on the board saying "Connecting…" forever.
    var isAwaitingFirstLocate: Bool {
        lock.lock(); defer { lock.unlock() }
        return !didAttemptLocateLocked
    }

    /// Human-readable state for the overview while not streaming.
    var statusMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return statusLocked
    }

    /// Which file the open handle is actually writing into, by inode.
    ///
    /// The mirror is written through a handle and read back by path, and the
    /// two stop meaning the same bytes the moment anything unlinks it. Keeping
    /// the inode is what makes that detectable at all: a deleted mirror looks
    /// exactly like an idle one from the path alone — no file, no new data,
    /// nothing wrong.
    private var mirrorFileNumber: Int?

    /// Which stream a callback belongs to. A terminated stream's handlers can
    /// fire after a restart has installed a new process and handle, and
    /// closing those, or writing the old stream's replay into them, is a
    /// second way to end up with a mirror nothing updates.
    private var streamGeneration: UInt = 0

    private static func fileNumber(atPath path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
    }

    /// Restart the stream when the file it writes into is no longer the file
    /// the overview reads.
    ///
    /// Something outside this object can take the mirror away: the launch-time
    /// pruner deleting one an older trm was still streaming, a `stop()` from a
    /// mirror that has since been replaced, anyone emptying `~/Library/Caches`.
    /// Nothing noticed — the writes kept succeeding into an unnamed inode, the
    /// reader kept statting a path with no file, and the pane's overview sat on
    /// its last parse for as long as the app ran. Found on a laptop with one
    /// overview a day stale and 2.5 MB written into nowhere.
    ///
    /// The restart goes through the ordinary cooldown, so a path something is
    /// repeatedly clearing costs one ssh every five seconds rather than a loop.
    private func restartIfMirrorVanished() {
        lock.lock()
        guard !stopped, streamProcess != nil, let expected = mirrorFileNumber else {
            lock.unlock()
            return
        }
        guard Self.fileNumber(atPath: mirrorURL.path) != expected else {
            lock.unlock()
            return
        }
        streamGeneration &+= 1
        let process = streamProcess
        streamProcess = nil
        let handle = mirrorHandle
        mirrorHandle = nil
        mirrorFileNumber = nil
        lock.unlock()
        process?.terminate()
        try? handle?.close()
        Self.logger.info(
            "Mirror for \(self.remoteSession, privacy: .public) was deleted underneath its stream; restarting")
    }

    /// Drive the mirror: called from the overview's poll timer.
    func poll() {
        lock.lock()
        let needsLocate = !locateInFlight && !stopped
            && (lastLocateAt.map { Date().timeIntervalSince($0) > Self.relocateInterval } ?? true)
        if needsLocate { locateInFlight = true }
        lock.unlock()

        if needsLocate { locateRemoteSession() }
        restartIfMirrorVanished()
        ensureStreaming()
    }

    /// Stop all ssh work. Safe to call from deinit paths.
    func stop() {
        lock.lock()
        stopped = true
        streamGeneration &+= 1
        let process = streamProcess
        streamProcess = nil
        let handle = mirrorHandle
        mirrorHandle = nil
        let owned = mirrorFileNumber
        mirrorFileNumber = nil
        lock.unlock()
        process?.terminate()
        try? handle?.close()
        // Only the file this mirror made. Mirrors for one session share a
        // path, so a mirror that has already been replaced would otherwise
        // delete its successor's file on the way out and leave that overview
        // reading a path with nothing behind it.
        if let owned, Self.fileNumber(atPath: mirrorURL.path) == owned {
            try? FileManager.default.removeItem(at: mirrorURL)
        }
    }

    // MARK: - Locate

    /// The SSH-side counterpart of `AgentSessionLocator`: resolve the zmx
    /// session's shell, find the agent process under it, and print
    /// `OK <kind> <transcript-path>`. Runs on the remote machine via
    /// `bash -s`, so the remote needs no particular trm version installed.
    private static let locateScript = """
    S="$1"
    # Same socket-dir fallback order as zmx itself: trm's pinned dir first,
    # then zmx's defaults — remote panes created before ZMX_DIR was pinned
    # live in the per-user tmp dir. TMPDIR's trailing slash MUST be trimmed:
    # `[ -S ]` tolerates the double slash it would create, but lsof's name
    # matching does not, which made live daemons look dead.
    T="${TMPDIR:-/tmp}"; T="${T%/}/zmx-$(id -u)"
    SOCK="$HOME/.trm/zmx/$S"
    if [ ! -S "$SOCK" ] && [ -n "$XDG_RUNTIME_DIR" ]; then SOCK="$XDG_RUNTIME_DIR/zmx/$S"; fi
    if [ ! -S "$SOCK" ]; then SOCK="$T/$S"; fi
    [ -S "$SOCK" ] || { echo "ERR no-session"; exit 0; }

    SHELL_PID=""
    for pid in $(lsof -t "$SOCK" 2>/dev/null); do
      c="$(pgrep -P "$pid" 2>/dev/null | head -1)"
      [ -n "$c" ] && { SHELL_PID="$c"; break; }
    done
    [ -n "$SHELL_PID" ] || { echo "ERR no-shell"; exit 0; }

    AGENT_PID=""; AGENT_KIND=""
    queue="$SHELL_PID"; depth=0
    while [ -n "${queue# }" ] && [ "$depth" -lt 6 ] && [ -z "$AGENT_PID" ]; do
      next=""
      for pid in $queue; do
        base="$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)" 2>/dev/null)"
        case "$base" in
          claude) AGENT_PID="$pid"; AGENT_KIND=claude; break ;;
          codex)  AGENT_PID="$pid"; AGENT_KIND=codex; break ;;
        esac
        next="$next $(pgrep -P "$pid" 2>/dev/null | tr '\\n' ' ')"
      done
      queue="$next"; depth=$((depth+1))
    done

    cwd_of() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
    newest_jsonl() { ls -t "$1"/*.jsonl 2>/dev/null | head -1; }

    # Unix time process $1 started, from its elapsed time. Empty if unknown.
    started_at() {
      et="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')"
      [ -n "$et" ] || return 0
      secs="$(printf %s "$et" | awk -F'[-:]' '{ if (NF==4) print $1*86400+$2*3600+$3*60+$4; else if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print $1 }')"
      echo $(( $(date +%s) - secs ))
    }

    \(AgentProbeShell.claudeBridgeFunctions)

    # Exact answer: the SessionStart hook names the transcript, but its record
    # can outlive the process that wrote it. Accept it only when it is fresh
    # for, and the same kind as, the agent currently under this shell. Without
    # both checks an old Claude record can relabel a later Codex pane.
    REC="$HOME/.trm/agent-sessions/$S"
    if [ -n "$AGENT_PID" ] && [ -f "$REC" ]; then
      P="$(cat "$REC" 2>/dev/null)"
      STARTED="$(started_at "$AGENT_PID")"
      RECORDED="$(stat -f %m "$REC" 2>/dev/null)"
      if [ -n "$P" ] && [ -f "$P" ] && [ -n "$STARTED" ] \
         && [ -n "$RECORDED" ] && [ "$RECORDED" -ge $(( STARTED - 30 )) ]; then
        case "$AGENT_KIND:$P" in
          codex:*/.codex/sessions/*.jsonl) echo "OK codex $P"; exit 0 ;;
          claude:*/.claude/projects/*.jsonl) P="$(claude_bridge_latest "$P")"; echo "OK claude $P"; exit 0 ;;
        esac
      fi
    fi

    # Codex writes one rollout per session under a date-sharded tree, and
    # records the directory it was started in as `cwd` in the first line's
    # session_meta. That field is the only thing tying a rollout to a pane:
    # newest-overall (what this used to do) hands every codex pane on the
    # machine the same transcript, so two panes in two different folders
    # showed one conversation. Newest 40 is plenty — rollouts are date-sharded
    # and we only care about live ones.
    codex_rollout() {
      cwd="$1"; started="$2"
      [ -n "$cwd" ] || return 0
      find "$HOME/.codex/sessions" -type f -name '*.jsonl' 2>/dev/null -exec ls -t {} + 2>/dev/null \
        | head -40 \
        | while IFS= read -r f; do
            h="$(head -1 "$f" 2>/dev/null)"
            case "$h" in
              *"\"cwd\":\"$cwd\""*|*"\"cwd\": \"$cwd\""*) ;;
              *) continue ;;
            esac
            # Prefer one this agent can actually have written to.
            if [ -n "$started" ]; then
              m="$(stat -f %m "$f" 2>/dev/null)"
              [ -n "$m" ] && [ "$m" -lt "$started" ] && continue
            fi
            echo "$f"
            break
          done \
        | head -1
    }

    # The .jsonl in $1 that process $2 is talking into. Mirrors
    # AgentSessionLocator.selectTranscript on the local side; keep the two in
    # step. Agents don't hold transcripts open, so this is a correlation of
    # times, and a project directory routinely holds several agents' sessions
    # plus the debris of old ones:
    #   - born after the agent started (30 s slack for clock fuzz)
    #   - written to since the agent started: a conversation it takes part in
    #     must have grown during its lifetime. Without this a stub created
    #     seconds before the agent launched wins on earliest birth and gets
    #     bound forever (seen live: 32 KB, ten seconds of writes, dead for
    #     four hours, in a directory where three agents were working).
    #   - not an abandoned stub (a moment of writes, silent since), unless
    #     nothing else qualifies — a genuinely brief session the user left
    #     idle is still the right answer when it is the only candidate.
    # Prefer a file born at/after this process. The slack is only for timestamp
    # granularity; without that split, a pane opened seconds earlier wins for
    # the later pane. Falls back to newest by mtime.
    born_after() {
      dir="$1"; apid="$2"
      started="$(started_at "$apid")"
      [ -n "$started" ] || { newest_jsonl "$dir"; return; }
      now="$(date +%s)"
      earliest=$(( started - 30 ))
      after=""; afterb=0; afterstub=""; afterstubb=0
      before=""; beforeb=0; beforestub=""; beforestubb=0
      for f in "$dir"/*.jsonl; do
        [ -e "$f" ] || continue
        b="$(stat -f %B "$f" 2>/dev/null)" || continue
        m="$(stat -f %m "$f" 2>/dev/null)" || continue
        [ "$b" -ge "$earliest" ] || continue
        [ "$m" -ge "$started" ] || continue
        isstub=0
        [ $(( m - b )) -lt 60 ] && [ $(( now - m )) -gt 300 ] && isstub=1
        if [ "$b" -ge "$started" ]; then
          if [ "$isstub" -eq 1 ]; then
            if [ -z "$afterstub" ] || [ "$b" -lt "$afterstubb" ]; then afterstub="$f"; afterstubb="$b"; fi
          elif [ -z "$after" ] || [ "$b" -lt "$afterb" ]; then after="$f"; afterb="$b"; fi
        else
          if [ "$isstub" -eq 1 ]; then
            if [ -z "$beforestub" ] || [ "$b" -gt "$beforestubb" ]; then beforestub="$f"; beforestubb="$b"; fi
          elif [ -z "$before" ] || [ "$b" -gt "$beforeb" ]; then before="$f"; beforeb="$b"; fi
        fi
      done
      if [ -n "$after" ]; then printf '%s\n' "$after"
      elif [ -n "$afterstub" ]; then printf '%s\n' "$afterstub"
      elif [ -n "$before" ]; then printf '%s\n' "$before"
      elif [ -n "$beforestub" ]; then printf '%s\n' "$beforestub"
      else newest_jsonl "$dir"; fi
    }

    if [ -n "$AGENT_PID" ]; then
      case "$AGENT_KIND" in
        claude) pat='/\\.claude/projects/.*\\.jsonl$' ;;
        codex)  pat='/\\.codex/sessions/.*\\.jsonl$' ;;
      esac
      OPEN="$(lsof -p "$AGENT_PID" -Fn 2>/dev/null | sed -n 's/^n//p' | grep -E "$pat" | head -1)"
      if [ -n "$OPEN" ]; then
        [ "$AGENT_KIND" = claude ] && OPEN="$(claude_bridge_latest "$OPEN")"
        echo "OK $AGENT_KIND $OPEN"; exit 0
      fi
      CWD="$(cwd_of "$AGENT_PID")"
      if [ "$AGENT_KIND" = claude ] && [ -n "$CWD" ]; then
        ENC="$(printf %s "$CWD" | tr './_' '---')"
        P="$(born_after "$HOME/.claude/projects/$ENC" "$AGENT_PID")"
        [ -n "$P" ] && P="$(claude_bridge_latest "$P")"
        [ -n "$P" ] && { echo "OK claude $P"; exit 0; }
      fi
      if [ "$AGENT_KIND" = codex ]; then
        STARTED="$(started_at "$AGENT_PID")"
        P="$(codex_rollout "$CWD" "$STARTED")"
        # Same folder but older than this process: a session it resumed.
        [ -n "$P" ] || P="$(codex_rollout "$CWD" "")"
        # No cwd match at all — usually because the agent's cwd couldn't be
        # read. Matching on the folder is what stops two codex panes sharing
        # one conversation, so it is tried first and only first; falling back
        # to the newest live rollout is still better than reporting no agent
        # for a pane that plainly has one.
        if [ -z "$P" ]; then
          P="$(find "$HOME/.codex/sessions" -type f -name '*.jsonl' 2>/dev/null -exec ls -t {} + 2>/dev/null | head -1)"
        fi
        [ -n "$P" ] && { echo "OK codex $P"; exit 0; }
      fi
      echo "ERR no-transcript"; exit 0
    fi

    CWD="$(cwd_of "$SHELL_PID")"
    if [ -n "$CWD" ]; then
      ENC="$(printf %s "$CWD" | tr './_' '---')"
      P="$(newest_jsonl "$HOME/.claude/projects/$ENC")"
      [ -n "$P" ] && { echo "OK claude $P"; exit 0; }
    fi
    echo "ERR no-agent"
    """

    /// Keep the sizeable generated probe under a real shell parser in tests.
    static var locateScriptForTesting: String { locateScript }

    private func locateRemoteSession() {
        lock.lock()
        if statusLocked == nil { statusLocked = "Looking for an agent on \(host)…" }
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Self.runLocateProbe(
                host: self.host, session: self.remoteSession, script: Self.locateScript
            )

            self.lock.lock()
            self.locateInFlight = false
            self.lastLocateAt = Date()
            self.didAttemptLocateLocked = true
            var pathChanged = false
            switch result {
            case .located(let kind, let path):
                pathChanged = (path != self.locatedPathLocked)
                self.locatedKindLocked = kind
                self.locatedPathLocked = path
                self.statusLocked = nil
            case .failed(let message):
                // Keep an existing stream running on a transient probe
                // failure; only surface the message while nothing streams.
                if self.locatedPathLocked == nil { self.statusLocked = message }
            }
            let process = pathChanged ? self.streamProcess : nil
            if pathChanged { self.streamProcess = nil }
            self.lock.unlock()

            // A new transcript path invalidates the running stream.
            process?.terminate()
        }
    }

    private enum LocateResult {
        case located(AgentKind, String)
        case failed(String)
    }

    private static func runLocateProbe(host: String, session: String, script: String) -> LocateResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshOptions + [host, "/bin/bash -s '\(session)'"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed("Could not run ssh: \(error.localizedDescription)")
        }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return .failed("SSH to \(host) failed — key-based access is required.")
        }
        let line = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines).first ?? ""
        let parts = line.split(separator: " ", maxSplits: 2)
        if parts.count == 3, parts[0] == "OK",
           let kind = AgentKind(rawValue: String(parts[1])) {
            let path = String(parts[2])
            // The path is interpolated into the stream command; hold it to a
            // shape that cannot escape its quoting.
            guard path.hasPrefix("/"), !path.contains("'"), !path.contains("\n") else {
                return .failed("Remote transcript path looks invalid.")
            }
            return .located(kind, path)
        }
        switch line {
        // no-shell means the socket exists but no daemon holds it — the
        // session died and left a stale socket, which is "not running" from
        // the user's point of view, not "no agent".
        case "ERR no-session", "ERR no-shell":
            return .failed("Session \(session) is not running on \(host). Reconnect the pane to restart it.")
        case "ERR no-agent":
            return .failed("No coding agent found in this pane on \(host).")
        case "ERR no-transcript": return .failed("The agent on \(host) has no transcript yet.")
        default: return .failed("Could not resolve the agent session on \(host).")
        }
    }

    // MARK: - Stream

    private func ensureStreaming() {
        lock.lock()
        guard !stopped,
              streamProcess == nil,
              let path = locatedPathLocked,
              (lastStreamStartAt.map { Date().timeIntervalSince($0) > Self.streamRestartCooldown } ?? true)
        else {
            lock.unlock()
            return
        }
        lastStreamStartAt = Date()

        // Fresh mirror per stream: `tail -n +1` replays the whole file, so
        // an append-only mirror would duplicate history after a restart.
        FileManager.default.createFile(atPath: mirrorURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: mirrorURL) else {
            lock.unlock()
            return
        }
        mirrorHandle = handle
        mirrorFileNumber = Self.fileNumber(atPath: mirrorURL.path)
        streamGeneration &+= 1
        let generation = streamGeneration

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // The path was validated to contain no single quotes.
        process.arguments = Self.sshOptions + [host, "tail -n +1 -F '\(path)'"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            // A superseded stream replays the transcript from the top, so
            // letting its last reads through would write that history into
            // the live mirror a second time.
            let sink = self.streamGeneration == generation ? self.mirrorHandle : nil
            self.lock.unlock()
            sink?.write(data)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            stdout.fileHandleForReading.readabilityHandler = nil
            self.lock.lock()
            // Only when this is still the live stream. A handler that fires
            // after a restart would otherwise close the *new* handle, which
            // stops the mirror being written at all while everything upstream
            // still believes it is streaming.
            if self.streamGeneration == generation {
                self.streamProcess = nil
                try? self.mirrorHandle?.close()
                self.mirrorHandle = nil
                self.mirrorFileNumber = nil
            }
            self.lock.unlock()
        }

        streamProcess = process
        lock.unlock()

        do {
            try process.run()
            Self.logger.info("Streaming \(self.host, privacy: .public) transcript for \(self.remoteSession, privacy: .public)")
        } catch {
            Self.logger.error("Stream start failed: \(error.localizedDescription)")
            lock.lock()
            streamProcess = nil
            try? mirrorHandle?.close()
            mirrorHandle = nil
            mirrorFileNumber = nil
            lock.unlock()
        }
    }

    /// Never prompt (a hung ssh inside a poll loop is worse than a failed
    /// one), bounded connect, and keepalives so a dead host tears the stream
    /// down instead of wedging it.
    private static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=2",
    ]
}
