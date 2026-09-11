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

/// Reading typeface for Agent Overview prose. Code and tool details remain
/// monospaced in either mode; this controls the surrounding reading surface.
enum AgentOverviewFontFamily: String, CaseIterable, Hashable {
    case regular
    case monospace

    var menuTitle: String {
        switch self {
        case .regular: return "Regular"
        case .monospace: return "Monospace"
        }
    }

    var symbolName: String {
        switch self {
        case .regular: return "textformat"
        case .monospace: return "character.cursor.ibeam"
        }
    }

    var design: Font.Design {
        switch self {
        case .regular: return .default
        case .monospace: return .monospaced
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
    /// pane never keeps a closed terminal alive. Change this through
    /// `rebind(to:)`: assigning the pointer without clearing the transcript
    /// caches lets an old pane's parse land in the newly-bound overview.
    private(set) weak var surface: Ghostty.SurfaceView?

    /// Stable pane ID of the bound surface, kept so the pane can still be
    /// labelled and matched after the surface goes away.
    @Published private(set) var boundPaneId: Int?

    @Published var transcript = AgentTranscript() {
        didSet { reanchorTurnSelection() }
    }

    /// How many turns back from the latest the view shows; 0 = live.
    /// Transient browsing state — deliberately not persisted.
    @Published var turnOffset: Int = 0

    /// Stable id of the turn being read when browsing history, so a new turn
    /// arriving mid-read doesn't shift the page underneath the reader.
    private var viewedTurnID: String? = nil

    var turnCount: Int { transcript.turns.count }
    var canGoOlderTurn: Bool { turnOffset < turnCount - 1 }
    var canGoNewerTurn: Bool { turnOffset > 0 }

    func goToOlderTurn() { selectTurn(offset: turnOffset + 1) }
    func goToNewerTurn() { selectTurn(offset: turnOffset - 1) }
    func goToLatestTurn() { selectTurn(offset: 0) }

    private func selectTurn(offset: Int) {
        let clamped = min(max(0, offset), max(0, turnCount - 1))
        turnOffset = clamped
        let turns = transcript.turns
        viewedTurnID = clamped > 0 ? turns[turns.count - 1 - clamped].id : nil
    }

    /// The archived turn the view renders, or nil when live (offset 0) — the
    /// live view renders the transcript's top-level fields, which include the
    /// wider prompt-search fallback that archived turns don't get.
    var displayedTurn: AgentTranscript.Turn? {
        guard turnOffset > 0 else { return nil }
        let turns = transcript.turns
        let index = turns.count - 1 - turnOffset
        guard turns.indices.contains(index) else { return nil }
        return turns[index]
    }

    /// After a poll replaces the transcript, keep pointing at the same turn:
    /// new turns appending (or old ones sliding out of the tail window) change
    /// the viewed turn's distance from the end.
    private func reanchorTurnSelection() {
        guard turnOffset > 0, let id = viewedTurnID else { return }
        let turns = transcript.turns
        if let index = turns.lastIndex(where: { $0.id == id }) {
            let offset = turns.count - 1 - index
            if offset != turnOffset { turnOffset = offset }
        } else {
            // The viewed turn left the window — clamp to the oldest we have.
            let clamped = min(turnOffset, max(0, turns.count - 1))
            if clamped != turnOffset { turnOffset = clamped }
            viewedTurnID = displayedTurn?.id
        }
    }

    /// The transcript the view renders: the live one, or — while browsing
    /// history — the selected archived turn dressed up as a transcript. The
    /// view is written against this single value so it needn't know which
    /// mode the reader is in.
    var displayedTranscript: AgentTranscript {
        guard let turn = displayedTurn else { return transcript }
        var value = transcript
        value.blocks = turn.blocks
        value.activity = turn.activity
        value.questions = turn.questions
        value.lastUserPrompt = turn.prompt
        value.promptBlocks = turn.promptBlocks
        // An archived turn is finished by definition; only the live view
        // should show the working spinner.
        value.isWorking = false
        return value
    }

    var canShowPreviousTurn: Bool { canGoOlderTurn }
    var canShowNextTurn: Bool { canGoNewerTurn }
    func showPreviousTurn() { goToOlderTurn() }
    func showNextTurn() { goToNewerTurn() }

    var turnPositionLabel: String? {
        guard turnCount > 1 else { return nil }
        return "\(turnCount - turnOffset)/\(turnCount)"
    }

    /// Which sections this overview shows. Per-pane (not global) so two
    /// overviews can watch two agents in different ways side by side;
    /// persisted in the session TOML as `overview_mode`.
    ///
    /// A set rather than a single mode: the sections are additive, and
    /// watching an agent's commands while reading its reply is the normal
    /// case, not an either/or.
    @Published var sections: AgentOverviewSections = .default

    /// Which agent this pane is currently showing. Nil until the bound
    /// process or an exact transcript record identifies it; an unresolved
    /// pane must not claim to be Claude merely because Claude was supported
    /// first.
    @Published var agentKind: AgentKind? = nil

    /// True once the pane has been established to be an ordinary shell —
    /// nothing with a transcript running in it — and the overview has switched
    /// to reading its scrollback instead.
    ///
    /// An overview of a shell pane is not a consolation prize. The same
    /// question is being asked of both kinds of pane ("what has this been
    /// doing, and did any of it fail"), and the same answer is available: a
    /// shell's turns are its commands, its tool calls are the programs it ran,
    /// and its errors are the lines those printed.
    @Published private(set) var isShellPane: Bool = false

    /// The commands parsed out of a shell pane's scrollback, oldest first and
    /// index-aligned with `transcript.turns`.
    @Published private(set) var shellCommands: [ShellCommand] = []

    /// The scrollback those commands came from, kept whole so "copy the full
    /// log" means the log rather than the part that fit on screen.
    @Published private(set) var shellScrollback: String = ""

    /// The command the view is showing, honouring turn paging.
    var displayedShellCommand: ShellCommand? {
        guard !shellCommands.isEmpty else { return nil }
        let index = shellCommands.count - 1 - turnOffset
        guard shellCommands.indices.contains(index) else { return shellCommands.last }
        return shellCommands[index]
    }

    var agentDisplayName: String {
        if let agentKind { return agentKind.displayName }
        return isShellPane ? "Shell" : "Agent"
    }

    /// Whether the reply is shown as cards rather than as running prose.
    @Published var cardsEnabled: Bool {
        didSet { UserDefaults.standard.set(cardsEnabled, forKey: Self.cardsDefaultsKey) }
    }

    static let cardsDefaultsKey = "AgentOverviewCardsView"

    /// Whether bionic reading emphasis is applied to prose.
    @Published var bionicEnabled: Bool {
        didSet { UserDefaults.standard.set(bionicEnabled, forKey: Self.bionicDefaultsKey) }
    }

    /// Set when the bound pane has no readable agent transcript.
    @Published var statusMessage: String? = nil

    private static let bionicDefaultsKey = "AgentOverviewBionicReading"

    /// Multiplier applied to the overview's compact in-grid type scale.
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

    /// Independent type scale used by the expanded peek reading view. A peek
    /// has far more horizontal room than a grid cell, so sharing one value
    /// forced the user to choose between cramped compact text and undersized
    /// expanded text.
    @Published var peekFontScale: CGFloat = AgentOverviewPane.defaultPeekFontScale {
        didSet {
            let clamped = min(max(peekFontScale, Self.minFontScale), Self.maxFontScale)
            if clamped != peekFontScale {
                peekFontScale = clamped
                return
            }
            UserDefaults.standard.set(Double(peekFontScale), forKey: Self.peekFontScaleDefaultsKey)
        }
    }

    /// Typeface used for prose throughout this overview. Persisted globally as
    /// the default for new panes and per pane in session TOML.
    /// Reads the displayed reply aloud with the best installed system voice.
    /// Owned by the pane (not the view) so speech survives the view being
    /// rebuilt — peeking the pane mid-sentence must not cut the voice off.
    ///
    /// Assigned in `init` rather than here: a reading that is still playing for
    /// this pane is adopted instead of replaced. Closing an overview no longer
    /// stops the voice, so opening one again has to find the reading already in
    /// progress — otherwise the pane would show a play button over audio that
    /// is audibly playing, and pressing it would start a second reading on top
    /// of the first.
    let speaker: OverviewSpeaker

    @Published var fontFamily: AgentOverviewFontFamily = .regular {
        didSet {
            UserDefaults.standard.set(fontFamily.rawValue, forKey: Self.fontFamilyDefaultsKey)
        }
    }

    static let defaultFontScale: CGFloat = 0.9
    static let defaultPeekFontScale: CGFloat = 1.2
    static let minFontScale: CGFloat = 0.7
    static let maxFontScale: CGFloat = 2.0
    private static let fontScaleStep: CGFloat = 0.1
    private static let fontScaleDefaultsKey = "AgentOverviewFontScale"
    private static let peekFontScaleDefaultsKey = "AgentOverviewPeekFontScale"
    private static let fontFamilyDefaultsKey = "AgentOverviewFontFamily"

    /// What to call this pane where its reading is offered without it — the
    /// watermark it wears on screen, which is how the pane is recognised
    /// everywhere else, and the terminal's own title when it has no watermark.
    private var speechSourceLabel: String {
        if let paneId = boundPaneId,
           let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId)),
           !watermark.isEmpty {
            return watermark
        }
        let title = surface?.title ?? ""
        return title.isEmpty ? "Agent Overview" : title
    }

    func increaseFontSize() { fontScale += Self.fontScaleStep }
    func decreaseFontSize() { fontScale -= Self.fontScaleStep }
    func resetFontSize() { fontScale = Self.defaultFontScale }

    func increasePeekFontSize() { peekFontScale += Self.fontScaleStep }
    func decreasePeekFontSize() { peekFontScale -= Self.fontScaleStep }
    func resetPeekFontSize() { peekFontScale = Self.defaultPeekFontScale }

    var canIncreaseFontSize: Bool { fontScale < Self.maxFontScale }
    var canDecreaseFontSize: Bool { fontScale > Self.minFontScale }
    var canIncreasePeekFontSize: Bool { peekFontScale < Self.maxFontScale }
    var canDecreasePeekFontSize: Bool { peekFontScale > Self.minFontScale }

    private var timer: Timer?

    /// mtime of the transcript at the last successful parse, so an unchanged
    /// file costs one stat instead of a re-parse.
    private var lastMtime: Date?

    /// True while a parse task is running, so the 1.5 s poll starts at most
    /// one at a time.
    ///
    /// Transcripts and their remote mirrors run to tens of megabytes, and a
    /// parse routinely outlasts the poll interval. Without this every tick
    /// launched another parse of the same bytes and whichever finished last
    /// won — so a parse of a mirror as it was moments after `tail -n +1`
    /// created it could land *after* a good one and blank the overview. That
    /// state then survived forever: the mirror stops changing when the
    /// session goes idle, and an unchanged mtime is exactly the case the
    /// early return below skips. Nine remote overviews re-parsing 15–27 MB
    /// files every 1.5 s was also, on its own, a great deal of work to do to
    /// arrive at the answer already on screen.
    private var parseInFlight = false

    /// Invalidates detached parses when an overview starts following another
    /// terminal. A task already reading a large transcript cannot be cancelled
    /// reliably, but it can be prevented from publishing into the new binding.
    private var bindingGeneration: UInt = 0

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

    /// For a remote pane (`remote_host` set), the SSH transcript mirror that
    /// stands in for the local process-tree walk and file reads.
    private var remoteMirror: RemoteAgentTranscriptMirror?

    /// The remote source path behind the mirror's stable local URL. `/clear`
    /// changes the former but not the latter, so this is the only reliable
    /// signal that an empty mirror means a new chat rather than a partial read.
    private var lastRemoteTranscriptPath: String?

    /// When the shell scrollback was last read, so the poll that costs a
    /// subprocess (or an SSH round trip) runs far less often than the poll
    /// that costs a `stat`.
    private var lastShellReadAt: Date?

    /// Hash of the pane's visible screen at the last scrollback read, so an
    /// idle pane is not dumped again to learn that nothing happened.
    private var lastShellViewportHash: Int?

    /// How often a shell pane's scrollback is re-read, at the fastest.
    /// `zmx history` is a process spawn per pane.
    private static let shellReadInterval: TimeInterval = 2.5

    /// How long a pane whose screen has not changed still gets re-read.
    /// Output that lands entirely above the fold — a scrolled-back pane, a
    /// command whose result never reached the visible rows — would otherwise
    /// never be noticed.
    private static let shellIdleReadInterval: TimeInterval = 30

    /// The same, over SSH. A round trip per pane per poll is the thing the
    /// remote mirror exists to avoid, so this is deliberately slow.
    private static let remoteShellReadInterval: TimeInterval = 10

    /// Lines of scrollback read for a shell pane. Enough to hold a build log
    /// and the commands around it; bounded because this is parsed on every
    /// read and rendered into a column.
    private static let shellScrollbackLines = 800

    /// True while a remote pane's agent hasn't been resolved yet: the SSH
    /// probe is a round trip, so there is a window after the pane appears in
    /// which "no transcript" means "still asking", not "nothing there". The
    /// Command Center uses this to hold a place for the pane instead of
    /// leaving it off the board.
    var isResolvingRemoteAgent: Bool {
        guard let surface, surface.remoteHost != nil else { return false }
        // A remote pane with no session name has nothing to ask the other
        // machine *about*: `refresh()` never takes the remote path, so no
        // mirror is ever built and no probe is ever sent. Reporting that as
        // "resolving" left such panes sitting on the board saying
        // "Connecting…" for as long as they existed.
        guard surface.remoteZmxSession != nil else { return false }
        guard let mirror = remoteMirror else { return true }
        // Resolved, whatever it found: no longer "connecting".
        return mirror.isAwaitingFirstLocate
    }

    /// Whether the remote probe has actually run and reached an answer.
    ///
    /// Distinct from `isResolvingRemoteAgent`, which reports "still asking"
    /// for a pane that has never asked — a pane with no mirror looks
    /// indistinguishable from one mid-probe. A caller waiting for a verdict
    /// needs to tell "no agent" from "no question asked yet", and this is that
    /// difference.
    var remoteProbeConcluded: Bool {
        guard surface?.remoteHost != nil else { return true }
        guard let mirror = remoteMirror else { return false }
        return !mirror.isAwaitingFirstLocate
    }

    /// What the remote probe last said, when it has said anything. The board
    /// shows this instead of a hopeful placeholder, so a pane whose agent
    /// can't be found says why.
    var remoteStatusMessage: String? {
        guard surface?.remoteHost != nil else { return nil }
        return remoteMirror?.statusMessage
    }

    /// Whether the remote probe found an agent to stream. A pane whose probe
    /// came back with a transcript keeps its place on the board while that
    /// transcript is still being read.
    var agentTranscriptLocated: Bool {
        remoteMirror?.locatedKind != nil
    }

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
            return "\(agentDisplayName) · \(mark)"
        }
        if let boundPaneId { return "\(agentDisplayName) · pane \(boundPaneId + 1)" }
        return "Agent Overview"
    }

    /// Whether this overview reads plain shell panes.
    ///
    /// False for the headless panes the Command Center keeps for every
    /// surface on the machine: reading a shell costs a `zmx history` spawn
    /// per pane, and the board does not show shells, so that work would buy
    /// nothing. Such a pane still learns that it *is* a shell, which is what
    /// the board filters on.
    private let readsShellPanes: Bool

    init(surface: Ghostty.SurfaceView?, readsShellPanes: Bool = true) {
        self.surface = surface
        self.readsShellPanes = readsShellPanes
        self.boundPaneId = surface?.paneId
        self.speaker = SpeechNowPlaying.shared.adopt(paneId: surface?.paneId)
            ?? OverviewSpeaker()
        self.speaker.sourcePaneId = surface?.paneId
        self.bionicEnabled = UserDefaults.standard.bool(forKey: Self.bionicDefaultsKey)
        self.cardsEnabled = UserDefaults.standard.bool(forKey: Self.cardsDefaultsKey)
        // `object(forKey:)` rather than `double(forKey:)`: an absent key
        // reads as 0.0, which would start every new overview at the minimum.
        if let saved = UserDefaults.standard.object(forKey: Self.fontScaleDefaultsKey) as? Double {
            self.fontScale = min(max(CGFloat(saved), Self.minFontScale), Self.maxFontScale)
        }
        if let saved = UserDefaults.standard.object(forKey: Self.peekFontScaleDefaultsKey) as? Double {
            self.peekFontScale = min(max(CGFloat(saved), Self.minFontScale), Self.maxFontScale)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.fontFamilyDefaultsKey),
           let family = AgentOverviewFontFamily(rawValue: raw) {
            self.fontFamily = family
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
        if let mirror = remoteMirror { RemoteAgentTranscriptMirror.release(mirror) }
    }

    /// Make this overview follow a different terminal pane.
    ///
    /// The surface pointer is only one part of the binding: local session
    /// correlation, remote SSH mirrors, mtimes, history selection, and an
    /// in-flight parse all belong to the previous terminal too. Reset them as
    /// one atomic main-actor operation so no old summary can survive a move.
    func rebind(to newSurface: Ghostty.SurfaceView) {
        guard surface !== newSurface else { return }

        bindingGeneration &+= 1
        parseInFlight = false
        speaker.stop()
        speaker.sourcePaneId = newSurface.paneId

        if let mirror = remoteMirror {
            RemoteAgentTranscriptMirror.release(mirror)
            remoteMirror = nil
        }

        surface = newSurface
        boundPaneId = newSurface.paneId
        lastRemoteTranscriptPath = nil
        lastMtime = nil
        lastURL = nil
        lastCwd = nil
        locatedSession = nil
        locatedAgentPid = 0
        agentKind = nil
        clearShellState()
        goToLatestTurn()
        transcript = AgentTranscript()
        statusMessage = "Looking for the agent in this pane…"
        refresh()
    }

    func toggleCards() {
        cardsEnabled.toggle()
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
        // Cheap, and the only place that sees a rename: the label the Command
        // Center puts over the playback controls is this pane's watermark.
        speaker.sourceLabel = speechSourceLabel
        let generation = bindingGeneration

        // A remote pane's agent process and transcript live on the other
        // machine — resolve and stream them over SSH instead of walking the
        // local process tree.
        if let host = surface.remoteHost, let remoteSession = surface.remoteZmxSession {
            refreshRemote(host: host, remoteSession: remoteSession)
            return
        }

        // pwd is read on the main actor because it touches surface state.
        let cwd = Self.workingDirectory(for: surface)
        guard let cwd, !cwd.isEmpty else {
            statusMessage = "Waiting for the pane's working directory…"
            return
        }

        let knownMtime = lastMtime
        let knownURL = lastURL
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
        let zmxSession = surface.zmxSessionName
        // The hook uses the zmx session when persistence is active and the
        // injected pane id otherwise. Mirror that choice when reading it.
        let sessionRecordKey = zmxSession ?? surface.paneId.map { "pane-\($0)" }
        if let session = zmxSession,
           let serverShell = ZmxSessionManager.cachedServerShellPid(session: session) {
            shellPid = serverShell
        } else if let paneId = surface.paneId {
            shellPid = Trm.shared.paneChildPid(paneId: UInt32(paneId))
        }

        // Read for the shell path, which needs the pane's own scrollback
        // rather than a transcript file.
        //
        // The viewport is read first, for two jobs. It is the fallback source
        // for a pane with no session to ask. And its hash says whether
        // anything has happened in the pane at all: dumping a whole session's
        // scrollback costs a process spawn, and a pane sitting at a prompt
        // has nothing new in it however often you ask. Fetched only while
        // this could still be a shell — once an agent is identified the pane
        // never takes this path again.
        let couldBeShell = readsShellPanes && (isShellPane || agentKind == nil)
        let viewportText: String? = couldBeShell ? surface.cachedVisibleContents.get() : nil
        let viewportHash = viewportText?.hashValue
        let sinceLastRead = lastShellReadAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let shellReadDue = couldBeShell
            && sinceLastRead >= Self.shellReadInterval
            && (viewportHash != lastShellViewportHash
                || sinceLastRead >= Self.shellIdleReadInterval
                || shellCommands.isEmpty)
        let shellLines = Self.shellScrollbackLines

        guard !parseInFlight else { return }
        parseInFlight = true
        Task.detached(priority: .utility) {
            // Prefer the session bound to the agent process actually running
            // in this pane — the newest-file-in-cwd fallback shows the wrong
            // session when several agents share a working directory.
            var session = cachedSession
            let cachedPidAlive = cachedAgentPid > 0 && kill(cachedAgentPid, 0) == 0

            // `/clear` starts a fresh transcript under the *same* process, so
            // a live pid is no longer evidence that the binding is current.
            // Nothing below would notice — same pid, same cwd, a session
            // already cached — and the overview would keep reading a file the
            // agent abandoned, showing the conversation from before the clear
            // for as long as the pane lived.
            //
            // The agent reports its own transcript through the SessionStart
            // hook, and `/clear` fires that hook again. Reading the record is
            // one small file read per refresh, and it is authoritative.
            if cachedPidAlive, let expectedKind = session?.kind,
               let sessionRecordKey,
               let started = AgentSessionLocator.processStartDate(pid: cachedAgentPid),
               let recorded = AgentSessionHook.recordedTranscript(
                   recordKey: sessionRecordKey,
                   recordedAfter: started.addingTimeInterval(-30)),
               let located = AgentSessionLocator.located(atRecorded: recorded),
               located.kind == expectedKind,
               located.url != session?.url {
                session = located
            }

            // A Claude process that predates hook installation cannot report
            // its new path on `/clear`. Follow Claude's stable bridge identity
            // across the replacement JSONLs; unlike a newest-file fallback,
            // this remains exact with several panes in the same directory.
            if cachedPidAlive, session?.kind == .claude,
               let current = session?.url,
               let latest = AgentSessionLocator.latestClaudeTranscript(
                   inBridgeOf: current),
               latest != current {
                session = AgentSessionLocator.Located(kind: .claude, url: latest)
            }

            // There is deliberately no "guess from the directory" fallback
            // here. It was tried: if the bound file goes quiet while another
            // in the same project is being written, treat that as a clear.
            // In a directory with two agents — which is ordinary — an idle
            // pane rebinds to a busy neighbour's transcript, and the two can
            // trade files back and forth, resetting the reader on every swap
            // so the overview never settles at all. Being occasionally stale
            // is a far smaller fault than being confidently wrong about whose
            // conversation you are reading.
            //
            // The hook above is the answer, because the agent names its own
            // transcript instead of anyone inferring it.

            var detectedKind = session?.kind
            if session == nil || !cachedPidAlive || cwdChanged {
                // The cached binding belongs to the old process/cwd. Do not
                // retain it if locating the replacement has no answer.
                session = nil
                if let agent = AgentSessionLocator.agentProcess(underShell: shellPid) {
                    detectedKind = agent.kind
                    if let located = AgentSessionLocator.locate(
                        shellPid: shellPid, paneCwd: cwd, recordKey: sessionRecordKey) {
                        session = located
                        detectedKind = located.kind
                    }
                    await MainActor.run { [weak self] in
                        guard let self, self.bindingGeneration == generation else { return }
                        self.locatedAgentPid = agent.pid
                        self.agentKind = agent.kind
                        self.clearShellState()
                    }
                } else {
                    // No agent in this pane — so read it as what it is. The
                    // scrollback is the shell's transcript, and everything the
                    // overview does with an agent's (turns, activity, errors,
                    // cards, copying) it can do with this.
                    let scrollback: String? = shellReadDue
                        ? (zmxSession.flatMap {
                            ZmxSessionManager.history(session: $0, lines: shellLines)
                        } ?? viewportText)
                        : nil
                    let commands = scrollback.map {
                        ShellTranscriptReader.commands(
                            inScrollback: $0,
                            cwdName: (cwd as NSString).lastPathComponent)
                    }
                    await MainActor.run { [weak self] in
                        guard let self, self.bindingGeneration == generation else { return }
                        self.parseInFlight = false
                        self.locatedAgentPid = 0
                        self.locatedSession = nil
                        self.agentKind = nil
                        self.lastCwd = cwd
                        self.lastURL = nil
                        self.lastMtime = nil
                        self.applyShell(
                            scrollback: scrollback,
                            commands: commands,
                            viewportHash: viewportHash,
                            emptyStatus:
                                "Nothing has run in \((cwd as NSString).lastPathComponent) yet.")
                    }
                    return
                }
            }

            guard let kind = session?.kind ?? detectedKind else {
                await MainActor.run { [weak self] in
                    guard let self, self.bindingGeneration == generation else { return }
                    self.parseInFlight = false
                    self.agentKind = nil
                    self.statusMessage = "Looking for a coding agent…"
                }
                return
            }

            // If exact correlation did not find a file, stay within the kind
            // of process we actually saw. The old unconditional Claude lookup
            // is how a Codex pane acquired a neighbour's Claude summary.
            let fallbackURL: URL?
            switch kind {
            case .claude:
                fallbackURL = AgentTranscriptReader.latestJSONL(
                    in: AgentTranscriptReader.projectDir(forCwd: cwd))
            case .codex:
                fallbackURL = CodexTranscriptReader.latestRollout(matchingCwd: cwd)
            }
            let url = session?.url ?? fallbackURL
            guard let url else {
                await MainActor.run { [weak self] in
                    guard let self, self.bindingGeneration == generation else { return }
                    self.parseInFlight = false
                    self.agentKind = kind
                    self.clearShellState()
                    self.lastCwd = cwd
                    self.lastURL = nil
                    self.lastMtime = nil
                    self.locatedSession = nil
                    self.goToLatestTurn()
                    self.transcript = AgentTranscript()
                    self.statusMessage =
                        "No \(kind.displayName) session found for \((cwd as NSString).lastPathComponent)."
                }
                return
            }

            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

            // Unchanged transcript — nothing to re-parse.
            if let mtime, let knownMtime, mtime == knownMtime, url == knownURL {
                await MainActor.run { [weak self] in
                    guard let self, self.bindingGeneration == generation else { return }
                    self.parseInFlight = false
                    self.lastCwd = cwd
                    self.lastURL = url
                    self.locatedSession = session
                    self.agentKind = kind
                    self.clearShellState()
                    // See the remote path: a status set before the file had
                    // content outlives its reason once the mtime settles.
                    if !self.transcript.isEmpty { self.statusMessage = nil }
                }
                return
            }

            let parsed = kind == .codex
                ? CodexTranscriptReader.parse(url: url)
                : AgentTranscriptReader.parse(url: url)

            await MainActor.run { [weak self] in
                guard let self, self.bindingGeneration == generation else { return }
                self.parseInFlight = false
                self.lastCwd = cwd
                self.lastURL = url
                self.lastMtime = mtime
                self.locatedSession = session
                self.agentKind = kind
                self.clearShellState()
                let sessionChanged = knownURL != url
                if sessionChanged {
                    // `/clear` and `/new` intentionally start with an empty
                    // transcript. That emptiness is authoritative: retaining
                    // the previous non-empty model is precisely how the old
                    // turn remained on screen after the chat changed.
                    self.goToLatestTurn()
                    self.transcript = parsed ?? AgentTranscript()
                } else if let parsed, !parsed.isEmpty {
                    // Setting the transcript re-anchors any in-progress
                    // history browsing by turn id (see didSet).
                    self.transcript = parsed
                }
                if !self.transcript.isEmpty {
                    self.statusMessage = nil
                } else {
                    self.statusMessage = "No messages in this session yet."
                }
            }
        }
    }

    /// Remote-pane refresh: drive the SSH mirror, then stat and parse the
    /// local mirror file exactly like a local transcript.
    private func refreshRemote(host: String, remoteSession: String) {
        let generation = bindingGeneration
        if let mirror = remoteMirror,
           mirror.host != host || mirror.remoteSession != remoteSession {
            RemoteAgentTranscriptMirror.release(mirror)
            remoteMirror = nil
            lastRemoteTranscriptPath = nil
            lastMtime = nil
        }
        if remoteMirror == nil {
            // Shared: several overviews routinely describe one remote session,
            // and each building its own stream is an SSH connection per copy.
            remoteMirror = RemoteAgentTranscriptMirror.acquire(
                host: host, remoteSession: remoteSession)
        }
        guard let mirror = remoteMirror else { return }
        mirror.poll()

        guard let kind = mirror.locatedKind else {
            // The probe has answered and there is no agent over there. That
            // makes it a shell like any other, and its scrollback is fetched
            // the same way the session browser fetches one — except far less
            // often, since this is an SSH round trip per read.
            if !mirror.isAwaitingFirstLocate {
                refreshRemoteShell(host: host, remoteSession: remoteSession)
            } else {
                statusMessage = mirror.statusMessage ?? "Looking for an agent on \(host)…"
            }
            return
        }

        if let remotePath = mirror.locatedTranscriptPath,
           remotePath != lastRemoteTranscriptPath {
            // The stream will replay the new file into the same mirror URL.
            // Clear the prior turn immediately, including the empty interval
            // between `/clear` and the first prompt in the fresh chat.
            lastRemoteTranscriptPath = remotePath
            lastMtime = nil
            goToLatestTurn()
            transcript = AgentTranscript()
        }

        let url = mirror.mirrorURL
        let knownMtime = lastMtime
        guard !parseInFlight else { return }
        parseInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = attributes?[.modificationDate] as? Date
            // Whether the transfer has actually delivered anything. This is
            // what separates "still arriving" from "arrived, and the session
            // has nothing in it" — two states that looked identical before.
            let mirrorHasData = ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 0
            // Unchanged mirror — nothing to re-parse.
            if let mtime, let knownMtime, mtime == knownMtime {
                await MainActor.run { [weak self] in
                    guard let self, self.bindingGeneration == generation else { return }
                    self.parseInFlight = false
                    // A "still streaming" message set before the mirror had
                    // content would otherwise never be revisited, because an
                    // idle session stops changing the mirror's mtime and this
                    // return is then the only path taken. Retire it as soon as
                    // there is something on screen for it to be wrong about,
                    // and correct it when the mirror turns out to be complete
                    // and simply empty.
                    if !self.transcript.isEmpty {
                        self.statusMessage = nil
                    } else {
                        self.statusMessage = Self.remoteEmptyStatus(
                            host: host, mirrorHasData: mirrorHasData)
                    }
                }
                return
            }

            let parsed = kind == .codex
                ? CodexTranscriptReader.parse(url: url)
                : AgentTranscriptReader.parse(url: url)

            await MainActor.run { [weak self] in
                guard let self, self.bindingGeneration == generation else { return }
                self.parseInFlight = false
                self.lastMtime = mtime
                self.agentKind = kind
                self.clearShellState()
                if let parsed, !parsed.isEmpty {
                    self.transcript = parsed
                    self.statusMessage = nil
                } else if self.transcript.isEmpty {
                    // Only while there is genuinely nothing to show. An empty
                    // parse must not put a status over a transcript that has
                    // already arrived — the mirror is replayed from the top,
                    // so "empty" is routinely just "not filled in yet".
                    self.statusMessage = Self.remoteEmptyStatus(
                        host: host, mirrorHasData: mirrorHasData)
                }
            }
        }
    }

    // MARK: - Shell panes

    /// Read a remote shell pane's scrollback over SSH.
    ///
    /// Deliberately infrequent: unlike the local path, where reading costs a
    /// process spawn, every read here is a connection to another machine.
    /// A shell being watched from across the network is not being watched
    /// frame by frame.
    private func refreshRemoteShell(host: String, remoteSession: String) {
        let generation = bindingGeneration
        let due = readsShellPanes && (lastShellReadAt.map {
            Date().timeIntervalSince($0) >= Self.remoteShellReadInterval
        } ?? true)
        guard due else {
            isShellPane = true
            return
        }
        guard !parseInFlight else { return }
        parseInFlight = true
        let lines = Self.shellScrollbackLines
        Task.detached(priority: .utility) { [weak self] in
            let scrollback = ZmxSessionManager.remoteHistory(
                remoteSession, host: host, lines: lines)
            let commands = scrollback.map {
                ShellTranscriptReader.commands(inScrollback: $0)
            }
            await MainActor.run { [weak self] in
                guard let self, self.bindingGeneration == generation else { return }
                self.parseInFlight = false
                self.agentKind = nil
                self.applyShell(
                    scrollback: scrollback,
                    commands: commands,
                    emptyStatus: "Nothing has run in this session on \(host) yet.")
            }
        }
    }

    /// Publish a shell read.
    ///
    /// A read that was skipped by the throttle passes nil, which must leave
    /// what is on screen alone: the alternative is a pane that blanks itself
    /// between reads, which is what "no new data" would otherwise be taken to
    /// mean. A read that came back with nothing is different, and says so.
    private func applyShell(
        scrollback: String?, commands: [ShellCommand]?,
        viewportHash: Int? = nil, emptyStatus: String
    ) {
        isShellPane = true
        guard let scrollback, let commands else {
            // Throttled, not empty — keep the last good read.
            if transcript.isEmpty && shellCommands.isEmpty {
                statusMessage = statusMessage ?? "Reading this pane…"
            }
            return
        }
        lastShellReadAt = Date()
        lastShellViewportHash = viewportHash
        shellScrollback = scrollback

        guard !commands.isEmpty else {
            shellCommands = []
            goToLatestTurn()
            transcript = AgentTranscript()
            statusMessage = emptyStatus
            return
        }

        // Paging is by turn, and the turns are these commands — so the two
        // are replaced together and stay index-aligned.
        //
        // Only when something actually changed. A shell pane is re-read every
        // couple of seconds whether or not anything has happened in it, and
        // republishing an identical transcript rebuilds the view — including
        // any selection in it — for nothing.
        let next = ShellTranscriptReader.transcript(commands: commands, updatedAt: Date())
        if shellCommands != commands {
            shellCommands = commands
        }
        if next.turns != transcript.turns || next.isWorking != transcript.isWorking {
            transcript = next
        }
        statusMessage = nil
    }

    /// Forget everything read as a shell. Called the moment an agent is found
    /// in the pane, so a pane that was a shell a second ago cannot show a
    /// stale command list beside a live agent's reply.
    private func clearShellState() {
        guard isShellPane || !shellCommands.isEmpty || !shellScrollback.isEmpty else { return }
        isShellPane = false
        shellCommands = []
        shellScrollback = ""
        lastShellReadAt = nil
        lastShellViewportHash = nil
    }

    /// What to say about a remote session that has produced no transcript.
    ///
    /// "Streaming…" is a claim that a transfer is in progress, and it was
    /// being made about sessions whose transfer had finished perfectly well
    /// and simply had nothing in them — a mirror of fifteen lines and no
    /// assistant messages sat under that message indefinitely, reading as a
    /// hang. Once bytes have arrived the stream has plainly worked, so the
    /// honest remaining answer is the one the local path already gives.
    static func remoteEmptyStatus(host: String, mirrorHasData: Bool) -> String {
        mirrorHasData
            ? "No messages in this session yet."
            : "Streaming the session from \(host)…"
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
