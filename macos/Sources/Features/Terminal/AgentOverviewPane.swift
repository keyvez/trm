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

    /// Which agent this pane is currently showing. Drives the header title.
    @Published var agentKind: AgentKind = .claude

    /// Whether bionic reading emphasis is applied to prose.
    @Published var bionicEnabled: Bool {
        didSet { UserDefaults.standard.set(bionicEnabled, forKey: Self.bionicDefaultsKey) }
    }

    /// Set when the bound pane has no readable Claude transcript.
    @Published var statusMessage: String? = nil

    private static let bionicDefaultsKey = "AgentOverviewBionicReading"

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

    var title: String {
        if let boundPaneId { return "\(agentKind.displayName) · pane \(boundPaneId + 1)" }
        return "Agent Overview"
    }

    init(surface: Ghostty.SurfaceView?) {
        self.surface = surface
        self.boundPaneId = surface?.paneId
        self.bionicEnabled = UserDefaults.standard.bool(forKey: Self.bionicDefaultsKey)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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
        let shellPid: pid_t
        if let paneId = surface.paneId {
            shellPid = Trm.shared.paneChildPid(paneId: UInt32(paneId))
        } else {
            shellPid = 0
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
