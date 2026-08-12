import SwiftUI
import AppKit
import Darwin

/// Runtime model for the agent overview pane.
///
/// The pane is bound to exactly one terminal surface — the pane running the
/// coding agent — and is constrained by the grid to sit adjacent to it. It
/// polls that pane's transcript on a timer and publishes a parsed
/// `AgentTranscript` for the view.
///
/// Supports Claude Code and Codex. `AgentSessionLocator` finds the agent
/// process running in the bound pane and the transcript it holds open, and the
/// per-agent readers (`AgentTranscriptReader`, `CodexTranscriptReader`) parse
/// it — this class and the view stay agent-agnostic.
/// Where an agent overview sits relative to its bound terminal pane. The
/// overview is always adjacent — beside it in the same row, or in its own
/// row directly above/below.
enum AgentOverviewPlacement: String, CaseIterable {
    case trailing
    case leading
    case above
    case below

    var menuTitle: String {
        switch self {
        case .trailing: return "Right of Pane"
        case .leading: return "Left of Pane"
        case .above: return "Above Pane"
        case .below: return "Below Pane"
        }
    }
}

@MainActor
final class AgentOverviewPane: ObservableObject, Identifiable {
    let id = UUID()

    /// Where this overview sits relative to its terminal pane. Mutated only
    /// through `BaseTerminalController.setOverviewPlacement`, which also
    /// applies the matching grid change.
    var placement: AgentOverviewPlacement = .trailing

    /// The terminal surface whose agent this view describes. Weak so the view
    /// pane never keeps a closed terminal alive.
    weak var surface: Ghostty.SurfaceView?

    /// Stable pane ID of the bound surface, kept so the pane can still be
    /// labelled and matched after the surface goes away.
    let boundPaneId: Int?

    @Published var transcript = AgentTranscript()

    /// Which sections this overview shows. Per-pane (not global) so two
    /// overviews can watch two agents in different ways side by side;
    /// persisted in the session TOML as `overview_mode`.
    ///
    /// A set rather than a single mode: the sections are additive, and
    /// watching an agent's commands while reading its reply is the normal
    /// case, not an either/or.
    @Published var sections: AgentOverviewSections = .default

    /// Which agent this pane is currently showing. Drives the header title.
    @Published var agentKind: AgentKind = .claude

    /// Whether bionic reading emphasis is applied to prose.
    @Published var bionicEnabled: Bool {
        didSet { UserDefaults.standard.set(bionicEnabled, forKey: Self.bionicDefaultsKey) }
    }

    /// Set when the bound pane has no readable Claude transcript.
    @Published var statusMessage: String? = nil

    private static let bionicDefaultsKey = "AgentOverviewBionicReading"

    /// Multiplier applied to the overview's type scale.
    ///
    /// The overview is a reading surface that often sits in a narrow column,
    /// so the comfortable size depends on the pane's width and the reader —
    /// hence a per-pane control rather than one global setting. Persisted so
    /// a resized overview stays resized across restarts.
    @Published var fontScale: CGFloat = AgentOverviewPane.defaultFontScale {
        didSet {
            // Clamp on write so no caller can push it somewhere unreadable.
            let clamped = min(max(fontScale, Self.minFontScale), Self.maxFontScale)
            if clamped != fontScale {
                fontScale = clamped
                return
            }
            UserDefaults.standard.set(Double(fontScale), forKey: Self.fontScaleDefaultsKey)
        }
    }

    static let defaultFontScale: CGFloat = 1.0
    static let minFontScale: CGFloat = 0.7
    static let maxFontScale: CGFloat = 2.0
    private static let fontScaleStep: CGFloat = 0.1
    private static let fontScaleDefaultsKey = "AgentOverviewFontScale"

    func increaseFontSize() { fontScale += Self.fontScaleStep }
    func decreaseFontSize() { fontScale -= Self.fontScaleStep }
    func resetFontSize() { fontScale = Self.defaultFontScale }

    var canIncreaseFontSize: Bool { fontScale < Self.maxFontScale }
    var canDecreaseFontSize: Bool { fontScale > Self.minFontScale }

    private var timer: Timer?

    /// mtime of the transcript at the last successful parse, so an unchanged
    /// file costs one stat instead of a re-parse.
    private var lastMtime: Date?

    /// The transcript path resolved on the previous poll. Cached so a pane
    /// whose cwd hasn't changed skips directory enumeration.
    private var lastURL: URL?
    private var lastCwd: String?

    /// The exact agent session located via the pane's process tree, plus the
    /// agent pid it was resolved from. Re-resolved when the pid dies or on a
    /// cwd change — process-tree walks are hundreds of syscalls, too heavy to
    /// repeat every 1.5 s poll.
    private var locatedSession: AgentSessionLocator.Located?
    private var locatedAgentPid: pid_t = 0

    /// The watermark of the terminal this overview describes.
    ///
    /// Now that an overview can be moved and stacked anywhere in the grid, it
    /// is no longer identifiable by sitting next to its agent — so it carries
    /// that pane's label with it.
    var boundWatermark: String? {
        guard let boundPaneId else { return nil }
        let mark = Trm.shared.watermark(forPaneId: UInt32(boundPaneId))
        guard let mark, !mark.isEmpty else { return nil }
        return mark
    }

    var title: String {
        // Prefer the bound pane's watermark — it is what the user labelled
        // that pane with, and matches what they see on the terminal itself.
        if let mark = boundWatermark {
            return "\(agentKind.displayName) · \(mark)"
        }
        if let boundPaneId { return "\(agentKind.displayName) · pane \(boundPaneId + 1)" }
        return "Agent Overview"
    }

    init(surface: Ghostty.SurfaceView?) {
        self.surface = surface
        self.boundPaneId = surface?.paneId
        self.bionicEnabled = UserDefaults.standard.bool(forKey: Self.bionicDefaultsKey)
        // `object(forKey:)` rather than `double(forKey:)`: an absent key
        // reads as 0.0, which would start every new overview at the minimum.
        if let saved = UserDefaults.standard.object(forKey: Self.fontScaleDefaultsKey) as? Double {
            self.fontScale = min(max(CGFloat(saved), Self.minFontScale), Self.maxFontScale)
        }
        refresh()
        // Stagger the polls across panes rather than firing them together.
        //
        // Restoring a saved window creates every overview in the same runloop
        // turn, so their timers all landed on the same 1.5 s boundary: six
        // panes would each read and parse a multi-megabyte transcript tail at
        // the same instant, then again 1.5 s later. Spreading the phase evenly
        // over the interval keeps the same per-pane refresh rate while turning
        // one large synchronised burst into small separated ones.
        let phase = Self.nextPollPhase()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.fireDate = Date().addingTimeInterval(phase)
    }

    /// Rotating phase offset handed to each new overview pane, so panes created
    /// together do not share a tick.
    private static var pollPhaseCounter: Int = 0
    private static func nextPollPhase() -> TimeInterval {
        // Six slots across the 1.5 s interval: 0, 0.25, 0.5, … 1.25.
        let slot = pollPhaseCounter % 6
        pollPhaseCounter += 1
        return 1.5 * (Double(slot) / 6.0)
    }

    deinit {
        timer?.invalidate()
    }

    func toggleBionic() {
        bionicEnabled.toggle()
    }

    /// Re-read the bound pane's transcript.
    ///
    /// All file work happens off the main actor: transcripts reach tens of
    /// megabytes and this runs every 1.5s, so parsing inline would stutter
    /// typing in every pane (the same trap `ClaudePromptPlugin` hit).
    func refresh() {
        guard let surface else {
            statusMessage = "The terminal pane this view was tracking has closed."
            return
        }

        // pwd is read on the main actor because it touches surface state.
        let cwd = Self.workingDirectory(for: surface)
        guard let cwd, !cwd.isEmpty else {
            statusMessage = "Waiting for the pane's working directory…"
            return
        }

        let knownMtime = lastMtime
        let cachedSession = locatedSession
        let cachedAgentPid = locatedAgentPid
        let cwdChanged = (cwd != lastCwd)
        // The pane's shell pid anchors the process-tree walk; read on the main
        // actor since it goes through the shared Zig handle.
        //
        // Under session persistence the pane's child is the `zmx attach`
        // client, which has no children — walking from it finds no agent, so
        // the overview never bound to a session. Prefer the shell running
        // inside the zmx server, which is the real parent of the agent.
        var shellPid: pid_t = 0
        if let session = surface.zmxSessionName,
           let serverShell = ZmxSessionManager.cachedServerShellPid(session: session) {
            shellPid = serverShell
        } else if let paneId = surface.paneId {
            shellPid = Trm.shared.paneChildPid(paneId: UInt32(paneId))
        }

        Task.detached(priority: .utility) {
            // Prefer the session bound to the agent process actually running
            // in this pane — the newest-file-in-cwd fallback shows the wrong
            // session when several agents share a working directory.
            var session = cachedSession
            let cachedPidAlive = cachedAgentPid > 0 && kill(cachedAgentPid, 0) == 0
            if session == nil || !cachedPidAlive || cwdChanged {
                if let agent = AgentSessionLocator.agentProcess(underShell: shellPid) {
                    if let located = AgentSessionLocator.locate(shellPid: shellPid, paneCwd: cwd) {
                        session = located
                    }
                    await MainActor.run { [weak self] in
                        self?.locatedAgentPid = agent.pid
                    }
                } else {
                    session = nil
                    await MainActor.run { [weak self] in
                        self?.locatedAgentPid = 0
                    }
                }
            }

            let kind = session?.kind ?? .claude
            let url = session?.url ?? AgentTranscriptReader.latestJSONL(
                in: AgentTranscriptReader.projectDir(forCwd: cwd)
            )
            guard let url else {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastCwd = cwd
                    self.lastURL = nil
                    self.locatedSession = nil
                    self.statusMessage =
                        "No coding agent session found for \((cwd as NSString).lastPathComponent)."
                }
                return
            }

            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

            // Unchanged transcript — nothing to re-parse.
            if let mtime, let knownMtime, mtime == knownMtime, url == cachedSession?.url {
                await MainActor.run { [weak self] in
                    self?.lastCwd = cwd
                    self?.lastURL = url
                    self?.locatedSession = session
                }
                return
            }

            let parsed = kind == .codex
                ? CodexTranscriptReader.parse(url: url)
                : AgentTranscriptReader.parse(url: url)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastCwd = cwd
                self.lastURL = url
                self.lastMtime = mtime
                self.locatedSession = session
                self.agentKind = kind
                if let parsed, !parsed.isEmpty {
                    self.transcript = parsed
                    self.statusMessage = nil
                } else if parsed?.isEmpty ?? true {
                    self.statusMessage = "No messages in this session yet."
                }
            }
        }
    }

    // MARK: - Working directory

    /// Resolve the working directory of a terminal surface.
    ///
    /// Prefers the shell-reported pwd; falls back to the child process's cwd
    /// via libproc, which is what makes this work when the agent has cd'd
    /// somewhere the shell integration hasn't reported.
    static func workingDirectory(for surface: Ghostty.SurfaceView) -> String? {
        if let pwd = surface.pwd, !pwd.isEmpty { return pwd }

        // With session persistence on, the pane's child is the `zmx attach`
        // client, whose cwd is wherever trm was launched from ($HOME) — not
        // the project directory. The real shell lives under the zmx *server*
        // process, reachable through the session socket rather than by walking
        // down from the pane's pid.
        //
        // Tried before the pane-pid path and without depending on it: a
        // reattached pane can report a child pid of 0, and gating this lookup
        // behind `pid > 0` made the overview give up entirely on exactly the
        // restored panes it needed to work for.
        if let session = surface.zmxSessionName,
           let shellPid = ZmxSessionManager.cachedServerShellPid(session: session),
           let cwd = processCurrentDirectory(pid: shellPid), !cwd.isEmpty {
            return cwd
        }

        guard let paneId = surface.paneId else { return nil }
        let pid = Trm.shared.paneChildPid(paneId: UInt32(paneId))
        guard pid > 0 else { return nil }
        return processCurrentDirectory(pid: pid)
    }

    /// Current working directory of a process, via libproc.
    static func processCurrentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard ret > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes -> String? in
            let buf = bytes.bindMemory(to: CChar.self)
            guard let base = buf.baseAddress, base.pointee != 0 else { return nil }
            return String(cString: base)
        }
    }
}
