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

    init(host: String, remoteSession: String) {
        self.host = host
        self.remoteSession = remoteSession

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("trm/remote-overview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Host and session are validated upstream (strict character sets), so
        // they are safe as a file name.
        self.mirrorURL = dir.appendingPathComponent("\(host)-\(remoteSession).jsonl")
    }

    /// Agent kind of the located remote session, if resolution succeeded.
    var locatedKind: AgentKind? {
        lock.lock(); defer { lock.unlock() }
        return locatedKindLocked
    }

    /// Human-readable state for the overview while not streaming.
    var statusMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return statusLocked
    }

    /// Drive the mirror: called from the overview's poll timer.
    func poll() {
        lock.lock()
        let needsLocate = !locateInFlight && !stopped
            && (lastLocateAt.map { Date().timeIntervalSince($0) > Self.relocateInterval } ?? true)
        if needsLocate { locateInFlight = true }
        lock.unlock()

        if needsLocate { locateRemoteSession() }
        ensureStreaming()
    }

    /// Stop all ssh work. Safe to call from deinit paths.
    func stop() {
        lock.lock()
        stopped = true
        let process = streamProcess
        streamProcess = nil
        let handle = mirrorHandle
        mirrorHandle = nil
        lock.unlock()
        process?.terminate()
        try? handle?.close()
        try? FileManager.default.removeItem(at: mirrorURL)
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

    # First .jsonl in $1 born after process $2 started (30 s slack) — the
    # session THAT agent created, which newest-by-mtime gets wrong whenever
    # several agents share a working directory. Falls back to newest.
    born_after() {
      dir="$1"; apid="$2"
      et="$(ps -o etime= -p "$apid" 2>/dev/null | tr -d ' ')"
      [ -n "$et" ] || { newest_jsonl "$dir"; return; }
      secs="$(printf %s "$et" | awk -F'[-:]' '{ if (NF==4) print $1*86400+$2*3600+$3*60+$4; else if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print $1 }')"
      started=$(( $(date +%s) - secs - 30 ))
      best=""; bestb=0
      for f in "$dir"/*.jsonl; do
        [ -e "$f" ] || continue
        b="$(stat -f %B "$f" 2>/dev/null)" || continue
        if [ "$b" -ge "$started" ] && { [ -z "$best" ] || [ "$b" -lt "$bestb" ]; }; then
          best="$f"; bestb="$b"
        fi
      done
      if [ -n "$best" ]; then printf '%s\n' "$best"; else newest_jsonl "$dir"; fi
    }

    if [ -n "$AGENT_PID" ]; then
      case "$AGENT_KIND" in
        claude) pat='/\\.claude/projects/.*\\.jsonl$' ;;
        codex)  pat='/\\.codex/sessions/.*\\.jsonl$' ;;
      esac
      OPEN="$(lsof -p "$AGENT_PID" -Fn 2>/dev/null | sed -n 's/^n//p' | grep -E "$pat" | head -1)"
      [ -n "$OPEN" ] && { echo "OK $AGENT_KIND $OPEN"; exit 0; }
      CWD="$(cwd_of "$AGENT_PID")"
      if [ "$AGENT_KIND" = claude ] && [ -n "$CWD" ]; then
        ENC="$(printf %s "$CWD" | tr / -)"
        P="$(born_after "$HOME/.claude/projects/$ENC" "$AGENT_PID")"
        [ -n "$P" ] && { echo "OK claude $P"; exit 0; }
      fi
      if [ "$AGENT_KIND" = codex ]; then
        P="$(find "$HOME/.codex/sessions" -type f -name '*.jsonl' 2>/dev/null -print0 | xargs -0 ls -t 2>/dev/null | head -1)"
        [ -n "$P" ] && { echo "OK codex $P"; exit 0; }
      fi
      echo "ERR no-transcript"; exit 0
    fi

    CWD="$(cwd_of "$SHELL_PID")"
    if [ -n "$CWD" ]; then
      ENC="$(printf %s "$CWD" | tr / -)"
      P="$(newest_jsonl "$HOME/.claude/projects/$ENC")"
      [ -n "$P" ] && { echo "OK claude $P"; exit 0; }
    fi
    echo "ERR no-agent"
    """

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
            let sink = self.mirrorHandle
            self.lock.unlock()
            sink?.write(data)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            stdout.fileHandleForReading.readabilityHandler = nil
            self.lock.lock()
            self.streamProcess = nil
            try? self.mirrorHandle?.close()
            self.mirrorHandle = nil
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
