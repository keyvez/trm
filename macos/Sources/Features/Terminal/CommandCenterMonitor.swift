import AppKit
import Combine
import Foundation

/// What every agent in every window is saying right now, in one list.
///
/// An Agent Overview answers "what is *this* agent doing" and costs a pane to
/// read. With five or six agents running that trade stops working: either the
/// grid is all overviews, or you page between them and miss the one that
/// finished. This gathers the same message each overview would show — the
/// agent's current reply — for every pane that has an agent, and identifies
/// them the way the panes identify themselves, by watermark.
///
/// Panes that already have an overview open are read through *that* overview
/// rather than a second poller: the transcripts run to tens of megabytes and
/// parsing one twice a second twice over is exactly the stutter this codebase
/// has fought before. Panes without one get a headless overview object, which
/// is the same machinery with no view attached.
@MainActor
final class CommandCenterMonitor: ObservableObject {

    static let shared = CommandCenterMonitor()

    /// One agent's current state, as the activity list shows it.
    struct Entry: Identifiable {
        /// The row's identity: the surface itself.
        ///
        /// Was the pane id, which is *usually* unique and occasionally isn't —
        /// a pane with no id yet reports 0, and every such pane collapsed into
        /// one row, so a board of seven agents showed four. The surface is the
        /// thing being described and can't collide with itself.
        let id: ObjectIdentifier
        /// Pane id, for the watermark lookup and cmux addressing.
        let paneId: Int
        /// The pane's own label, the way it draws it on itself.
        let watermark: String
        /// Which agent is running: two agents behave differently enough that
        /// "who am I talking to" belongs on the card, not just in the pane.
        let kind: AgentKind?
        /// Where the work is: the project directory, and the machine when the
        /// pane is remote.
        let location: String?
        let host: String?
        /// The agent's current message — the paragraph an overview would show.
        ///
        /// Flattened and capped: a board row is one line, so the markers come
        /// out and code blocks are dropped. Use `messageBlocks` anywhere with
        /// room to render the message as what it is.
        let message: String
        /// The same message in the form the Overview renders — paragraphs with
        /// their markdown intact, fenced code as code, images as images. The
        /// expanded panel has half a screen for the reply and no reason to
        /// show it as flattened, truncated prose.
        ///
        /// Defaulted, so a row built for a test or a placeholder says what it
        /// is about — the board's text — without having to hand over blocks
        /// it has no opinion on.
        var messageBlocks: [AgentTranscript.Block] = []
        /// The question a finished reply ends on — "Want me to deploy?" —
        /// read from the whole reply, never the capped `message`.
        ///
        /// It is usually the last sentence of a long reply, which is exactly
        /// the part a capped message and a one-line summary both lose, and it
        /// is the one sentence on the row you have to act on.
        var closingQuestion: String? = nil
        /// Claude Code's own recap of where the session stands, while it is
        /// still current. See `AgentTranscript.recap`.
        var recap: String? = nil

        /// Whether the row is waiting on you: a question on screen, or a
        /// finished reply that ends by asking one. The second is the common
        /// case — "Want me to deploy?" — and reads as idle otherwise, which is
        /// the one state a board has to tell apart from "done, nothing to do".
        var isAskingYou: Bool { needsAttention || closingQuestion != nil }
        /// The last thing the human asked, for context when the reply is terse.
        let prompt: String?
        /// Everything this person has said to this agent, oldest first, as the
        /// transcript records it. The reply box walks back through this.
        let promptHistory: [String]
        /// What the agent actually did this turn, newest last: the tool calls,
        /// as short phrases. Context for the summarizer, which is told to
        /// write about what came of them rather than to list them — a briefing
        /// never shows these as they are, since a command is what the terminal
        /// one pane away is already displaying.
        let activity: [String]
        /// Links found anywhere in the agent's message, whole.
        ///
        /// Kept apart from the prose because a card truncates and a truncated
        /// URL is worthless — the one thing on a status board you actually
        /// want to grab is the server address the agent just printed.
        let links: [String]
        /// True while the newest transcript entry is a tool call with no
        /// result yet: the agent is mid-task rather than waiting on you.
        let isWorking: Bool
        /// True when the agent asked a question and is blocked on the answer.
        let needsAttention: Bool
        /// A question the agent is asking *on screen*, read from the pane's
        /// own viewport rather than its transcript.
        ///
        /// The permission prompts — may I run this, may I make this edit,
        /// shall I leave plan mode — never reach the JSONL at all, and
        /// `AskUserQuestion` reaches it only once the turn moves on. Both mean
        /// the board learns about a question at the moment it stops being one.
        /// This is the other source, and it is the honest one while the agent
        /// is actually waiting.
        var pendingPrompt: PanePrompt? = nil
        /// Tool calls in this turn that came back as errors. A handful of
        /// these is the difference between "still going" and "this one needs
        /// you to sit down with it".
        let errorCount: Int
        /// First line of the most recent error, when there is one.
        let errorText: String?
        let updatedAt: Date?
        /// The pane to reveal when the row is clicked.
        weak var surface: Ghostty.SurfaceView?
    }

    @Published private(set) var entries: [Entry] = []

    /// The entry stream, for observers that need to react once per scan rather
    /// than once per view body. `$entries` itself is `private(set)`, so this is
    /// the read-only door onto it.
    var entriesPublisher: AnyPublisher<[Entry], Never> {
        $entries.eraseToAnyPublisher()
    }

    /// Whether the first scan has finished looking.
    ///
    /// "No agents running" and "haven't looked yet" are different answers and
    /// must not share a screen. A pane's transcript is parsed off the main
    /// actor, so the scan that runs the instant the panel opens finds nothing
    /// *yet* — reporting that as an empty board is wrong the moment the panel
    /// is opened on a machine full of agents.
    @Published private(set) var hasSettled = false

    /// Scans completed since the panel opened. The board settles on the third
    /// one — about five seconds — or the moment anything shows up, whichever
    /// comes first. Three because a pane holding a 20 MB transcript can miss
    /// the first two, and flashing "no agents running" before the list fills
    /// in is worse than a spinner that lingers.
    private var scansCompleted = 0

    /// What a briefing says: the headline, and — only when there is more
    /// worth knowing — a few plain-English lines of what was done.
    struct Briefing: Equatable {
        /// One sentence, the thing you read first.
        let sentence: String
        /// Whole sentences of English, or empty — the substance the headline
        /// had no room for. Deliberately never the tool calls themselves:
        /// "Bash npm test" names the command, not what came of it, and a
        /// column of those is the thing the terminal is already showing one
        /// pane away. What earns the space is what the agent found, changed,
        /// or is stuck on, in its own words.
        let bullets: [String]
    }

    /// Summaries, keyed by pane. Populated only in briefing mode, and only
    /// when a pane's message actually changes.
    @Published private(set) var briefings: [ObjectIdentifier: Briefing] = [:]

    /// Whether to keep `briefings` up to date. Off by default: each refresh
    /// can be an LLM call, and the detail view doesn't use them.
    var briefingsEnabled = false {
        didSet { if briefingsEnabled { refresh() } else { briefingHashes.removeAll() } }
    }

    /// Hash of the message each briefing was made from, so an unchanged pane
    /// is never summarized twice.
    private var briefingHashes: [ObjectIdentifier: Int] = [:]
    private var briefingsInFlight: Set<ObjectIdentifier> = []

    /// Panes already named in the log as unresolvable, so a 2.5 s poll
    /// doesn't repeat itself forever.
    private static var reportedUnresolvableRemotePanes: Set<Int> = []

    /// Headless overviews for panes that don't have one on screen, keyed by
    /// surface identity so they're reused across polls and dropped with the
    /// pane.
    private var headless: [ObjectIdentifier: AgentOverviewPane] = [:]

    /// The overview object describing a pane, on screen or headless.
    ///
    /// The phone's summary view reads the same turns the Mac's overview draws,
    /// rather than re-deriving them from a text dump — two parsers over one
    /// transcript is two things to keep agreeing.
    func overviewPane(forPaneId paneId: Int) -> AgentOverviewPane? {
        for controller in TerminalController.all {
            for pane in controller.agentOverviewPanes
            where pane.surface?.paneId == paneId { return pane }
        }
        return headless.values.first { $0.surface?.paneId == paneId }
    }
    private var timer: Timer?
    /// How many activity panes are on screen. Polling costs real work, so it
    /// only runs while something is displaying the result.
    private var subscribers = 0

    private init() {}

    // MARK: - Lifecycle

    func subscribe() {
        subscribers += 1
        guard timer == nil else { return }
        hasSettled = false
        scansCompleted = 0
        // Slower than an overview's 1.5 s: this is an at-a-glance list, and it
        // may be polling every agent on the machine at once.
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        timer?.invalidate()
        timer = nil
        headless.removeAll()
        hasSettled = false
        scansCompleted = 0
    }

    // MARK: - Poll

    func refresh() {
        var live: Set<ObjectIdentifier> = []
        var next: [Entry] = []

        for controller in TerminalController.all {
            // Overviews already on screen are the cheap source: they poll
            // themselves, so reading them costs nothing.
            var openOverviews: [ObjectIdentifier: AgentOverviewPane] = [:]
            for overview in controller.agentOverviewPanes {
                guard let surface = overview.surface else { continue }
                openOverviews[ObjectIdentifier(surface)] = overview
            }

            for surface in Self.surfacesInPaneOrder(controller) {
                let key = ObjectIdentifier(surface)
                live.insert(key)

                let source: AgentOverviewPane
                if let existing = openOverviews[key] {
                    source = existing
                } else {
                    let pane = headless[key]
                        ?? AgentOverviewPane(surface: surface, readsShellPanes: false)
                    headless[key] = pane
                    // Only headless panes need driving; an on-screen overview
                    // is already on its own timer.
                    pane.refresh()
                    source = pane
                }

                guard var entry = Self.entry(for: surface, from: source) else { continue }
                entry.pendingPrompt = Self.onScreenPrompt(for: surface, entry: entry)
                next.append(entry)
            }
        }

        headless = headless.filter { live.contains($0.key) }
        // Deliberately NOT sorted by state or recency. The list is read while
        // work is moving, and a row that jumps to the top the moment its agent
        // says something is a row you lose track of mid-sentence — worse, the
        // reply box you were typing into moves out from under you. Pane order
        // is the order the user arranged, and it holds still.
        entries = next
        scansCompleted += 1
        if !next.isEmpty || scansCompleted >= 3 { hasSettled = true }
        updateBriefings(for: next)
    }

    /// The question a pane is showing right now, if it is showing one.
    ///
    /// Read from the viewport text, which is already cached for half a second
    /// and shared with the output scanner, so this costs a string compare per
    /// pane per scan. The cells — which is what the view draws, colours and
    /// all — are only fetched when a prompt has actually been found.
    ///
    /// Skipped for a pane that is mid-tool: an agent running a command is not
    /// waiting on you, and a box still on screen from a moment ago would be
    /// read as live. The transcript is the better witness for *that* question,
    /// so it wins where it has an opinion.
    private static func onScreenPrompt(
        for surface: Ghostty.SurfaceView, entry: Entry
    ) -> PanePrompt? {
        guard !entry.isWorking else { return nil }
        let viewport = surface.cachedVisibleContents.get()
        guard !viewport.isEmpty else { return nil }
        if let prompt = PanePromptDetector.detect(inViewport: viewport) { return prompt }
        // A menu at the bottom with its question scrolled out of a small
        // pane: read further up. Only then — the whole screen is the
        // scrollback too, and most scans have no menu on screen at all.
        guard PanePromptDetector.showsMenuCursor(viewport) else { return nil }
        return PanePromptDetector.detect(inScreenTail: surface.cachedScreenContents.get())
    }

    /// The pane's screen, for drawing the region a prompt occupies.
    ///
    /// Not part of `Entry`: a viewport is a few thousand cells, and putting
    /// one on every row of the board would copy the whole grid into the model
    /// on every scan for the sake of the one or two rows that are asking
    /// something. The view asks for it when it has a prompt to draw.
    func screen(for entry: Entry) -> Trm.PaneScreen? {
        guard entry.pendingPrompt != nil else { return nil }
        return Trm.shared.paneScreen(paneId: UInt32(entry.paneId))
    }

    /// Answer a pane's on-screen question by picking one of its choices.
    ///
    /// The number is sent as a keystroke and nothing else — no Return. These
    /// menus select on the digit, and a Return behind it would arrive at
    /// whatever the agent draws next, which is usually a prompt waiting for a
    /// message and would submit an empty one.
    func answer(_ option: PanePrompt.Option, for entry: Entry) {
        guard let surface = entry.surface,
              let controller = Self.controller(owning: surface) else { return }
        controller.sendKeystrokeToSurface(surface, text: String(option.number))
    }

    /// A controller's terminal surfaces in the order the grid draws them.
    ///
    /// `surfaceTree` is in tree order, which is not what the window looks
    /// like once panes have been moved, stacked, or parked;
    /// `paneDisplayOrder` is the visual order.
    private static func surfacesInPaneOrder(
        _ controller: BaseTerminalController
    ) -> [Ghostty.SurfaceView] {
        var rank: [ObjectIdentifier: Int] = [:]
        for (index, id) in controller.paneDisplayOrder.enumerated() { rank[id] = index }
        // Parked panes come after the grid, in shelf order.
        for (index, id) in controller.sidebarPanes.enumerated() {
            rank[id] = controller.paneDisplayOrder.count + index
        }
        return Array(controller.surfaceTree)
            .enumerated()
            .sorted { a, b in
                let ra = rank[ObjectIdentifier(a.element)] ?? Int.max
                let rb = rank[ObjectIdentifier(b.element)] ?? Int.max
                // Tree order breaks ties, so the sort is deterministic even
                // for surfaces the display order hasn't caught up with yet.
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    /// Build a row, or nil when the pane has no agent to report.
    private static func entry(
        for surface: Ghostty.SurfaceView,
        from pane: AgentOverviewPane
    ) -> Entry? {
        // The overview reads plain shell panes too now. The board does not
        // show them: it is a board of agents working unattended, and a shell
        // sitting at a prompt is neither working nor unattended — you are
        // looking right at it.
        guard !pane.isShellPane else { return nil }
        let transcript = pane.transcript
        // Anything at all means this pane has an agent. Requiring a *reply*
        // here made a row vanish the moment you sent it a message: the new
        // turn has a prompt and no assistant text yet, so the pane briefly
        // looks like it has nothing to say — exactly when you are watching it.
        //
        // An empty transcript is not the same as no agent. A local pane's
        // transcript can be tens of megabytes and parses off the main actor; a
        // remote pane's has to come over SSH first. Both leave a real agent
        // looking like an absent one for the first few seconds, so a pane that
        // *has* an agent holds its place on the board and says so.
        guard !transcript.isEmpty else {
            guard Self.hasAgent(surface: surface, pane: pane) else { return nil }
            return pending(
                for: surface,
                resolving: pane.isResolvingRemoteAgent,
                status: pane.remoteStatusMessage)
        }

        let questions = transcript.questions
        let message = currentMessage(transcript)
        // What the agent is saying *now*, matching `currentMessage`: a turn's
        // blocks accumulate, and the newest message is the live one.
        let messageBlocks = transcript.latestBlocks.isEmpty
            ? transcript.blocks
            : transcript.latestBlocks
        let errors = transcript.activity.filter(\.isError)

        let paneId = surface.paneId ?? 0
        let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = AgentOverviewPane.workingDirectory(for: surface)

        return Entry(
            id: ObjectIdentifier(surface),
            paneId: paneId,
            watermark: Self.rowLabel(watermark: watermark, cwd: cwd, paneId: paneId),
            kind: pane.agentKind,
            // A worktree's name is the branch, which is the informative half.
            // `genui-a2ui` beats `fasmac` when three panes share the repo.
            location: WorktreeMark.name(forPath: cwd)
                ?? cwd.map { ($0 as NSString).lastPathComponent },
            host: surface.remoteHost,
            message: message,
            messageBlocks: messageBlocks,
            closingQuestion: transcript.isWorking || !questions.isEmpty
                ? nil : Self.closingQuestion(in: messageBlocks),
            recap: transcript.recap,
            prompt: transcript.lastUserPrompt,
            promptHistory: Self.promptHistory(transcript),
            activity: Self.activityLines(transcript),
            links: Self.links(in: transcript),
            isWorking: transcript.isWorking,
            needsAttention: !questions.isEmpty,
            errorCount: errors.count,
            errorText: errors.last?.errorText ?? errors.last.map { "\($0.name) failed" },
            updatedAt: transcript.updatedAt,
            surface: surface
        )
    }

    /// What to show for an agent right now, in order of how much it tells you:
    /// what it said, what it asked, what it is doing, that it is doing
    /// something. A turn in progress has no reply text yet, and a row that
    /// goes blank in that window is a row that looks broken.
    private static func currentMessage(_ transcript: AgentTranscript) -> String {
        // The newest message, not the whole turn. A turn's blocks accumulate
        // now so the overview can grow with it; a board row is one line, and
        // the useful line is what the agent is saying at this moment rather
        // than how it opened.
        let reply = summarize(
            transcript.latestBlocks.isEmpty ? transcript.blocks : transcript.latestBlocks)
        if !reply.isEmpty { return reply }
        if let question = transcript.questions.first?.text, !question.isEmpty {
            return question
        }
        if let tool = transcript.activity.last {
            // The tool's name, not the command line it ran. A briefing that
            // reads "Bash: zig build -Doptimize=ReleaseFast test" is the
            // terminal's job, one pane away; here it only has to say the agent
            // is mid-task and roughly at what.
            return tool.finished ? "Ran \(tool.name)" : "Running \(tool.name)…"
        }
        return transcript.isWorking ? "Working…" : "Waiting"
    }

    /// Whether a pane is running an agent, without parsing anything.
    ///
    /// The process walk is cheap (it reads the pane's own process tree) and is
    /// the only way to know a pane deserves a row before its transcript has
    /// been read. Remote panes can't be walked from here, so the mirror's own
    /// "still resolving" flag stands in.
    private static func hasAgent(surface: Ghostty.SurfaceView, pane: AgentOverviewPane) -> Bool {
        // A remote pane earns a place while its probe is still out, and keeps
        // it once the probe found an agent. A probe that came back empty means
        // this is an ordinary shell, and an ordinary shell is not an agent.
        if surface.remoteHost != nil {
            if pane.isResolvingRemoteAgent || pane.agentTranscriptLocated { return true }
            // Every drop is logged once, because a pane that isn't on the
            // board is indistinguishable from a pane that has no agent — and
            // "ten agents, five rows" is unanswerable without knowing which
            // five were dropped and why. Only the no-session case used to say
            // anything, which is the rarer of the two.
            if let paneId = surface.paneId,
               !reportedUnresolvableRemotePanes.contains(paneId) {
                reportedUnresolvableRemotePanes.insert(paneId)
                let host = surface.remoteHost ?? "?"
                if let session = surface.remoteZmxSession {
                    TrmDiagnostics.log(
                        "[command-center] pane \(paneId) on \(host) dropped: probe for session " +
                        "\(session) finished without locating an agent transcript. The pane is " +
                        "treated as an ordinary shell until it resolves.")
                } else {
                    TrmDiagnostics.log(
                        "[command-center] pane \(paneId) on \(host) has no " +
                        "recorded zmx session; its agent can't be resolved. Reconnect the pane.")
                }
            }
            return false
        }
        var shellPid: pid_t = 0
        if let session = surface.zmxSessionName,
           let serverShell = ZmxSessionManager.cachedServerShellPid(session: session) {
            shellPid = serverShell
        } else if let paneId = surface.paneId {
            shellPid = Trm.shared.paneChildPid(paneId: UInt32(paneId))
        }
        guard shellPid > 0 else { return false }
        return AgentSessionLocator.agentProcess(underShell: shellPid) != nil
    }

    /// A row for a pane whose agent is known but whose transcript hasn't
    /// arrived: it holds the pane's place rather than letting the board look
    /// short.
    private static func pending(
        for surface: Ghostty.SurfaceView, resolving: Bool, status: String? = nil
    ) -> Entry {
        let paneId = surface.paneId ?? 0
        let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = AgentOverviewPane.workingDirectory(for: surface)
        return Entry(
            id: ObjectIdentifier(surface),
            paneId: paneId,
            watermark: (watermark?.isEmpty == false ? watermark! : "pane \(paneId)"),
            // The remote probe or local overview may still be identifying the
            // process. "Agent" is honest during that window; defaulting this
            // field to Claude made Codex panes look misbound before parsing
            // had even begun.
            kind: nil,
            location: cwd.map { ($0 as NSString).lastPathComponent },
            host: surface.remoteHost,
            message: resolving
                ? "Connecting…"
                : (status ?? "Reading the transcript…"),
            prompt: nil,
            promptHistory: [],
            activity: [],
            links: [],
            isWorking: false,
            needsAttention: false,
            errorCount: 0,
            errorText: nil,
            updatedAt: nil,
            surface: surface
        )
    }

    /// The turn's tool calls as short phrases — "Edited grid.zig", "Ran zig
    /// build test" — oldest first, capped.
    ///
    /// This is the plainest available answer to "what did it just do", and it
    /// needs no model: the transcript already names every call and its
    /// subject.
    nonisolated static func activityLines(_ transcript: AgentTranscript, limit: Int = 4) -> [String] {
        let lines = transcript.activity.map { tool -> String in
            guard let detail = tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !detail.isEmpty else { return tool.name }
            let trimmed = detail.count > 60 ? String(detail.prefix(60)) + "…" : detail
            return "\(tool.name) \(trimmed)"
        }
        return Array(lines.suffix(limit))
    }

    /// Every link in the agent's current message, in the order they appear,
    /// deduplicated and capped.
    ///
    /// Read from the full message rather than the truncated summary: the whole
    /// point is that a URL survives the card's line limits intact.
    nonisolated static func links(in transcript: AgentTranscript, limit: Int = 4) -> [String] {
        var text = ""
        for block in transcript.blocks {
            if case .paragraph(let paragraph) = block { text += paragraph + "\n" }
        }
        return links(inText: text, limit: limit)
    }

    /// Pure link extraction, so the trimming rules are testable.
    nonisolated static func links(inText text: String, limit: Int = 4) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        // Written-out links only: the detector also turns a file name like
        // `jobs.rs` into http://jobs.rs, and the check for "://" below could
        // never catch that — the scheme it tests is the one the detector added.
        for match in WrittenLinks.matches(in: text) {
            let url = match.url
            // Prose and markdown leave debris clinging to a URL. A trailing
            // `)` or `.` is almost never part of an address, and neither are
            // the emphasis markers an agent wraps one in — `**https://…**`
            // arrived as a link ending in two stars, which pastes nowhere.
            var string = url.absoluteString
            string = Self.trimmingURLDebris(string)
            guard string.contains("://"), seen.insert(string).inserted else { continue }
            found.append(string)
            if found.count >= limit { break }
        }
        return found
    }

    /// Prompts from the parse window, oldest first, deduplicated against
    /// consecutive repeats and capped — this is a reply box's history, not an
    /// archive.
    /// What to call a pane on the board, marked when it is a worktree.
    ///
    /// The mark is added to a watermark rather than replacing it: someone who
    /// named a pane meant that name, and the insignia is extra information
    /// about where it sits, not a correction.
    nonisolated static func rowLabel(watermark: String?, cwd: String?, paneId: Int) -> String {
        let isWorktree = WorktreeMark.name(forPath: cwd) != nil
        if let watermark, !watermark.isEmpty {
            return isWorktree ? WorktreeMark.marked(watermark) : watermark
        }
        if let worktree = WorktreeMark.name(forPath: cwd) {
            return WorktreeMark.marked(worktree)
        }
        return "pane \(paneId)"
    }

    nonisolated static func promptHistory(_ transcript: AgentTranscript, limit: Int = 50) -> [String] {
        var result: [String] = []
        for turn in transcript.turns {
            guard let prompt = turn.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty, prompt != result.last else { continue }
            result.append(prompt)
        }
        return Array(result.suffix(limit))
    }

    // MARK: - Sent messages

    /// Messages sent from trm, per pane, with when they went.
    ///
    /// The transcript is the real record of what this person has said to an
    /// agent — including messages sent from here, once the agent writes them
    /// down. Until it does there is a gap of a second or two, and for a pane
    /// whose program keeps no transcript there is a gap forever, so what trm
    /// sent is kept alongside and merged in.
    private var sentMessages: [Int: [(text: String, at: Date)]] = [:]

    func recordSentMessage(paneId: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var log = sentMessages[paneId] ?? []
        log.append((text: trimmed, at: Date()))
        sentMessages[paneId] = Array(log.suffix(50))
    }

    /// What this person has said to a pane, newest first: everything trm sent
    /// that the transcript hasn't caught up with yet, then the transcript's
    /// own prompts in reverse.
    ///
    /// Interleaving by wall-clock isn't needed and would be worse: the
    /// transcript already holds both sources in true send order once it
    /// settles, so the only thing to splice is the recent tail trm knows
    /// about and the agent hasn't recorded.
    func messageHistory(for entry: Entry) -> [String] {
        let recorded = Set(entry.promptHistory)
        let pending = (sentMessages[entry.paneId] ?? [])
            .filter { !recorded.contains($0.text) }
            .sorted { $0.at > $1.at }
            .map(\.text)
        var seen: Set<String> = []
        return (pending + entry.promptHistory.reversed()).filter { seen.insert($0).inserted }
    }

    /// Strip the punctuation prose leaves stuck to a URL.
    ///
    /// Two passes are needed because the detector hands some of it back
    /// percent-encoded: a URL inside backticks arrives ending in `%60`, which
    /// no amount of trimming raw characters will find.
    static let urlDebris = ").,;:]}*_~`'\"<>"

    nonisolated static func trimmingURLDebris(_ url: String) -> String {
        var string = url
        var changed = true
        while changed {
            changed = false
            if let last = string.last, urlDebris.contains(last) {
                string.removeLast()
                changed = true
                continue
            }
            // A trailing %XX that decodes to the same debris.
            if string.count > 3 {
                let tail = String(string.suffix(3))
                if tail.hasPrefix("%"),
                   let decoded = tail.removingPercentEncoding,
                   decoded.count == 1, let char = decoded.first,
                   urlDebris.contains(char) {
                    string.removeLast(3)
                    changed = true
                }
            }
        }
        while let first = string.first, "*_~`'\"<(".contains(first) {
            string.removeFirst()
        }
        return string
    }

    /// Inline markdown taken out, for the places that show plain text.
    ///
    /// The overview renders emphasis properly; a briefing row and a phone card
    /// show a string, so `**shipped**` should read as shipped rather than as
    /// its own punctuation.
    nonisolated static func withoutInlineMarkdown(_ text: String) -> String {
        var result = text
        for marker in ["**", "__", "~~", "`"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result
    }

    /// The agent's message as plain text, paragraphs and all.
    ///
    /// Code blocks and images are dropped rather than flattened: this is a
    /// glanceable summary, and a wall of code in a one-line row tells you
    /// nothing about what the agent is doing.
    ///
    /// The cap is deliberately roomy. It is what a briefing writes its detail
    /// lines from and what the summarizer is given to read, and an agent's
    /// account of its own turn — what it changed, what it found, what is left
    /// — is usually two or three paragraphs in. Cut it at a paragraph and the
    /// board ends up reporting the throat-clearing.
    nonisolated static func summarize(_ blocks: [AgentTranscript.Block], limit: Int = 2000) -> String {
        var parts: [String] = []
        for block in blocks {
            guard case .paragraph(let text) = block else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        let joined = withoutInlineMarkdown(parts.joined(separator: "\n\n"))
        return keepingEnds(joined, limit: limit)
    }

    /// Cut a long reply to `limit` by dropping its middle, not its end.
    ///
    /// Keeping only the start lost the part of a reply that matters most on a
    /// board: agents close on what they need from you — "Want me to deploy?"
    /// — and a reply of a few thousand characters had that cut off before the
    /// summarizer or the row ever saw it. The opening says what happened; the
    /// ending says what happens next. Both survive, each cut at a sentence.
    nonisolated static func keepingEnds(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let headBudget = limit * 3 / 5
        let tailBudget = limit - headBudget

        var head = String(text.prefix(headBudget))
        if let stop = head.lastIndex(where: { ".!?".contains($0) }) {
            head = String(head[...stop])
        }
        var tail = Substring(text.suffix(tailBudget))
        // Start the tail at a sentence rather than halfway through a word.
        if let start = tail.firstIndex(where: { ".!?\n".contains($0) }) {
            let rest = tail[tail.index(after: start)...]
                .drop { $0 == " " || $0 == "\n" }
            if !rest.isEmpty { tail = rest }
        }
        return head + "\n\n…\n\n" + tail
    }

    /// The question a reply ends on, if it ends on one.
    ///
    /// The last sentence of the agent's prose, when it asks something. Only
    /// the last: a question in the middle of a reply is usually rhetorical or
    /// already answered by the paragraph under it, while the one it closes on
    /// is what it is waiting for.
    nonisolated static func closingQuestion(in blocks: [AgentTranscript.Block]) -> String? {
        let prose = blocks.compactMap { block -> String? in
            guard case .paragraph(let text) = block else { return nil }
            return text
        }.joined(separator: "\n\n")
        guard let last = sentences(in: prose).last,
              last.hasSuffix("?") else { return nil }
        return truncate(last, limit: headlineLimit)
    }

    // MARK: - Briefings

    /// Refresh the one-sentence summary for every entry whose message changed.
    ///
    /// The summary is produced locally first — the opening sentence of what
    /// the agent said — so a row is never blank and the mode works with no LLM
    /// configured at all. When one *is* configured it replaces that with a
    /// real summary, which earns the call: the opening sentence of an agent's
    /// reply is often "I'll start by reading the file" rather than what it
    /// ended up doing.
    private func updateBriefings(for entries: [Entry]) {
        guard briefingsEnabled else { return }
        let live = Set(entries.map(\.id))
        briefings = briefings.filter { live.contains($0.key) }
        briefingHashes = briefingHashes.filter { live.contains($0.key) }

        for entry in entries {
            let hash = entry.message.hashValue
            guard briefingHashes[entry.id] != hash else { continue }
            briefingHashes[entry.id] = hash
            // A stored briefing belongs to the message it was written from, so
            // a new message drops it rather than leaving the last turn's
            // sentence sitting over this turn's work — the failure that makes
            // a row read as describing something else entirely. Until the
            // model answers the row falls back to `localBriefing`, which is
            // rebuilt from the live entry on every scan and so can only ever
            // describe the turn in front of you.
            briefings[entry.id] = nil

            guard !briefingsInFlight.contains(entry.id) else { continue }
            briefingsInFlight.insert(entry.id)
            let message = entry.message
            let prompt = entry.prompt
            let activity = entry.activity
            let errorCount = entry.errorCount
            let errorText = entry.errorText
            let isWorking = entry.isWorking
            let needsAttention = entry.needsAttention
            Task { [weak self] in
                let summary = await Self.summarize(
                    message: message, prompt: prompt, activity: activity,
                    errorCount: errorCount, errorText: errorText,
                    isWorking: isWorking, needsAttention: needsAttention)
                guard let self else { return }
                self.briefingsInFlight.remove(entry.id)
                // Only accept it if the pane hasn't moved on while we waited.
                guard let summary, self.briefingHashes[entry.id] == hash else { return }
                self.briefings[entry.id] = summary
            }
        }
    }

    /// Ask the configured LLM for one sentence. Returns nil when there is no
    /// provider, the call fails, or it comes back empty — each of which leaves
    /// the local first-sentence summary in place.
    private static func summarize(
        message: String, prompt: String?, activity: [String],
        errorCount: Int = 0, errorText: String? = nil,
        isWorking: Bool = false, needsAttention: Bool = false
    ) async -> Briefing? {
        // The state goes in as well as the words. A summarizer given only the
        // message writes about the message, which reads as a report on a turn
        // that has finished even when the pane is mid-tool or blocked on a
        // question — the two states a board exists to tell apart.
        let state: String
        if needsAttention {
            state = "It has asked the person a question and is blocked on the answer."
        } else if isWorking {
            state = "It is still working: this turn is not finished."
        } else {
            state = "It has stopped and is waiting for the person."
        }
        let errors: String? = errorCount > 0
            ? "Failed tool calls this turn: \(errorCount)."
                + (errorText.map { " The last one said: \($0)" } ?? "")
            : nil
        let body = [
            prompt.map { "The person asked: \($0)" },
            state,
            errors,
            activity.isEmpty ? nil : "Tools it ran, oldest first:\n"
                + activity.map { "- \($0)" }.joined(separator: "\n"),
            "The agent's message:\n\(message)",
        ].compactMap { $0 }.joined(separator: "\n\n")

        do {
            let text = try await Trm.shared.llmClient.complete(
                system: "You are writing one row of a status board for a coding agent working "
                    + "unattended. The person reads the row instead of reading the terminal, so "
                    + "it has to carry the substance of the turn — enough to know what happened "
                    + "without going and looking.\n\n"
                    + "First line: what it did, or what it needs, in one sentence of at most 30 "
                    + "words, past tense, plain text, no markdown. Lead with the outcome, not "
                    + "the process. If the agent is asking the person something, say what it "
                    + "needs. If the message ends by asking the person a question or offering "
                    + "a next step (\"Want me to deploy?\", \"Should I commit this?\"), the "
                    + "first line must end with that question, because it is what the person "
                    + "has to answer. The message may have its middle cut, marked with …; the "
                    + "end is always the real end. If it hit an error it could not resolve, "
                    + "say so plainly.\n\n"
                    + "Then three to five bullets on their own lines starting with \"- \", each "
                    + "a full sentence of roughly 15 to 30 words explaining a piece of the work "
                    + "the headline had no room for: what it changed and why, what it found, "
                    + "what the numbers were, what the error actually said, what is still "
                    + "unfinished and what it plans to do about it. Name files, components and "
                    + "figures. Write about what came of the work, never about the tools that "
                    + "did it: \"Rewrote the retry loop in Session.zig so a dropped socket "
                    + "reconnects instead of killing the pane\" is a bullet; \"Bash: npm test\" "
                    + "and \"Read daemon.zig\" are not — they are commands, and the person can "
                    + "already see those in the terminal. Prefer explaining fewer things "
                    + "properly over listing many things thinly. No other text.",
                user: body,
                maxTokens: 600)
            return parseBriefing(text)
        } catch {
            return nil
        }
    }

    /// What can be said about a pane from what is already known, with no model
    /// involved.
    ///
    /// This is what a row shows until the summarizer answers, and *everything*
    /// it shows where no LLM is configured, so it has to be worth reading on
    /// its own.
    ///
    /// It used to be the message's opening sentence and then the last few tool
    /// calls — "Read daemon.zig", "Bash zig build test". Those are commands,
    /// and a command is the one thing the board does not need to carry: the
    /// terminal one pane away is already showing it, and naming it says
    /// nothing about what came of it. What the row is for is the substance of
    /// the turn, so the detail lines are now the rest of what the agent
    /// actually wrote — the paragraphs under its opening sentence, which is
    /// where an agent puts what it found, what it changed and what is left.
    /// Only the failures keep a line of their own, because a turn's errors are
    /// an outcome rather than a command and the message often doesn't mention
    /// them at all.
    ///
    /// Rebuilt from the live entry every time the board draws rather than
    /// stored, so it cannot describe a turn that has moved on.
    nonisolated static func localBriefing(for entry: Entry) -> Briefing {
        let sentence = firstSentence(of: entry.message, limit: headlineLimit)
        var bullets: [String] = []
        if entry.errorCount > 0 {
            let count = entry.errorCount == 1 ? "1 failed call" : "\(entry.errorCount) failed calls"
            bullets.append(entry.errorText.map { "\(count): \($0)" } ?? "\(count) this turn")
        }
        bullets.append(contentsOf: detail(of: entry.message, after: sentence))
        if bullets.isEmpty, let prompt = entry.prompt, !prompt.isEmpty {
            bullets.append("You asked: \(firstSentence(of: prompt, limit: 160))")
        }
        return Briefing(sentence: sentence, bullets: Array(bullets.prefix(maxBullets)))
    }

    /// How many detail lines a briefing carries, from the model or from the
    /// message itself. The board has the room, and the row is read instead of
    /// the terminal rather than on the way to it.
    static let maxBullets = 5

    /// How long a briefing's headline may run. Two lines' worth: a sentence
    /// that says what happened is longer than one that says a tool ran.
    static let headlineLimit = 240

    /// How long one of those lines may run before it is cut. Generous on
    /// purpose: a sentence of an agent's own prose is worth three of the
    /// clipped phrases this used to show.
    static let detailLimit = 220

    /// The agent's own words after its opening sentence, as whole sentences.
    ///
    /// Fenced code is dropped — a board row is prose, and a diff pasted into
    /// one is unreadable at this size — and list markers come off while their
    /// text stays, since an agent's list items are usually the very things
    /// worth reading. Everything the headline already said is skipped, so the
    /// detail starts where the sentence above it stopped.
    nonisolated static func detail(
        of message: String, after headline: String, limit: Int = maxBullets
    ) -> [String] {
        guard limit > 0 else { return [] }
        var pieces = sentences(in: message)
        // The headline may have been truncated, or joined from several lines,
        // so it is matched by its opening rather than whole.
        let head = headline.hasSuffix("…") ? String(headline.dropLast()) : headline
        if !head.isEmpty {
            while let first = pieces.first,
                  first.hasPrefix(head) || head.hasPrefix(first) {
                pieces.removeFirst()
            }
        }
        return pieces.prefix(limit).map { truncate($0, limit: detailLimit) }
    }

    /// A message split into readable sentences: code fences dropped, block and
    /// list markers stripped, paragraphs kept apart so a heading never runs
    /// into the line under it.
    nonisolated static func sentences(in message: String) -> [String] {
        var out: [String] = []
        var paragraph: [String] = []
        var inFence = false

        func flush() {
            defer { paragraph = [] }
            let joined = withoutInlineMarkdown(paragraph.joined(separator: " "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { return }
            var rest = joined
            while let end = sentenceEnd(in: rest) {
                let piece = String(rest[...end]).trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { out.append(piece) }
                rest = String(rest[rest.index(after: end)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            if !rest.isEmpty { out.append(rest) }
        }

        for raw in message.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                flush()
                continue
            }
            if inFence { continue }
            guard !trimmed.isEmpty else { flush(); continue }
            let line = withoutListMarker(withoutLeadingBlockMarkdown(trimmed))
            guard !line.isEmpty else { continue }
            // A heading, a list item and a lead-in ending in a colon are each
            // a thought on their own; running them together loses the shape
            // the agent wrote them in.
            let standsAlone = trimmed.hasPrefix("#")
                || line.count != withoutLeadingBlockMarkdown(trimmed).count
                || line.hasSuffix(":")
            if standsAlone {
                flush()
                paragraph = [line]
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    /// A list marker at the head of a line — `-`, `*`, `•`, `1.`, `2)` — with
    /// the item's own text left alone.
    nonisolated static func withoutListMarker(_ line: String) -> String {
        var rest = Substring(line)
        if let first = rest.first, "-*•".contains(first) {
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 2,
               let after = rest.dropFirst(digits.count).first, ".)".contains(after) {
                rest = rest.dropFirst(digits.count + 1)
            } else {
                return line
            }
        }
        // "-- flag" and "**bold**" are not lists; only a marker followed by a
        // space introduces an item.
        guard let next = rest.first, next == " " || next == "\t" else { return line }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Cut a line to length at a word boundary.
    nonisolated static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// Pull a briefing out of the model's reply: bullet lines, and the one
    /// line that isn't a bullet.
    ///
    /// Tolerant on purpose — a model that answers with the sentence first, or
    /// uses `•` instead of `-`, still produces something usable rather than
    /// nothing.
    nonisolated static func parseBriefing(_ text: String) -> Briefing? {
        var bullets: [String] = []
        var sentences: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let first = line.first, "-*•".contains(first) {
                let bullet = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !bullet.isEmpty { bullets.append(bullet) }
            } else {
                sentences.append(line)
            }
        }
        // The sentence is the summary; if the model only gave bullets, the
        // last one stands in rather than showing nothing.
        let sentence = sentences.first ?? bullets.popLast() ?? ""
        guard !sentence.isEmpty else { return nil }
        return Briefing(sentence: sentence, bullets: Array(bullets.prefix(maxBullets)))
    }

    /// The opening sentence of a message, capped so a briefing stays one line
    /// rather than a paragraph.
    ///
    /// The lines are walked before they are joined, because three of the four
    /// things that end a thought can only be recognised while they are still
    /// lines: a heading, a trailing colon, and a blank line. Flattening first
    /// and then hunting for a full stop is what made "Three things, all built
    /// and verified:" come out as "Three things, all built and verified: ##
    /// 1." — the stop it found belonged to a numbered heading two lines down.
    nonisolated static func firstSentence(of text: String, limit: Int = 160) -> String {
        var pieces: [String] = []
        var closed = false

        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank line after something is a paragraph break, and the
            // paragraph that just ended is the summary.
            guard !trimmed.isEmpty else {
                if !pieces.isEmpty { closed = true; break }
                continue
            }
            let isHeading = trimmed.hasPrefix("#")
            let line = withoutLeadingBlockMarkdown(trimmed)
            guard !line.isEmpty else { continue }
            pieces.append(line)
            // A heading is a complete thought on its own, and a line ending
            // in a colon is the lead-in to a list — which is exactly the
            // sentence a briefing wants, and exactly the one that gets
            // swallowed if the scan runs on into the list's first item. The
            // colon has to be tested here rather than after joining, since a
            // colon *inside* a line ("Fixed: the retry loop") introduces the
            // rest of that line instead of ending it.
            if isHeading || line.hasSuffix(":") { closed = true; break }
        }

        let flat = withoutInlineMarkdown(pieces.joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }

        var sentence = flat
        if !closed, let end = sentenceEnd(in: flat) {
            sentence = String(flat[...end])
        }
        return truncate(sentence, limit: limit)
    }

    /// Block-level markdown at the head of a line: heading hashes and
    /// blockquote carets.
    ///
    /// Separate from `withoutInlineMarkdown` because these can only be
    /// identified by their position — once the lines are joined there is no
    /// start-of-line left to recognise them by, and a stray `#` mid-sentence
    /// is a channel name or an issue number, not markup.
    nonisolated static func withoutLeadingBlockMarkdown(_ line: String) -> String {
        var rest = Substring(line)
        while let first = rest.first, first == "#" || first == ">" {
            rest = rest.dropFirst()
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Where the first sentence ends, or nil when the text is one unbroken
    /// run.
    ///
    /// A full stop alone isn't enough. Agents number things, and "1." puts a
    /// stop wherever a list is — far enough into the text to clear any length
    /// check, and still not the end of a sentence. A stop counts only when
    /// what precedes it isn't a bare number and what follows it is a space or
    /// the end of the text.
    nonisolated static func sentenceEnd(in text: String) -> String.Index? {
        var searchFrom = text.startIndex
        while let stop = text[searchFrom...].firstIndex(where: { ".!?".contains($0) }) {
            let after = text.index(after: stop)
            let breaksAfter = after == text.endIndex || text[after] == " "
            let head = text[..<stop]
            // A "sentence" a few characters long is an abbreviation, not a
            // sentence.
            if breaksAfter, head.count > 12, !endsInNumber(head) { return stop }
            guard after < text.endIndex else { return nil }
            searchFrom = after
        }
        return nil
    }

    /// Whether a run ends in a bare number — `1`, `0.3`, `v2` — which makes a
    /// stop after it an ordinal or a version rather than a sentence end.
    nonisolated static func endsInNumber(_ text: Substring) -> Bool {
        guard let token = text.split(separator: " ").last, !token.isEmpty else { return false }
        guard token.contains(where: { $0.isNumber }) else { return false }
        return token.allSatisfy { $0.isNumber || $0 == "." || $0 == "v" || $0 == "#" }
    }

    // MARK: - Actions

    /// Bring a row's pane to the front and focus it: the window comes forward
    /// and the terminal takes keyboard focus, so noticing an agent in the list
    /// and typing at it are one gesture.
    func reveal(_ entry: Entry) {
        guard let surface = entry.surface,
              let controller = Self.controller(owning: surface) else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A parked pane has no cell to focus; bring it back to the grid first.
        let id = ObjectIdentifier(surface)
        if controller.sidebarPanes.contains(id) {
            controller.restorePaneFromSidebar(id)
        }
        // A peek covers the grid, so focusing a cell underneath one changes
        // nothing you can see: the pane you asked for stays hidden behind the
        // one you were already reading, and the tap looks like it did nothing.
        // Put the peek away and show the pane itself.
        //
        // Moving the peek to the new pane was the first answer and it was the
        // wrong one. A row names a terminal, and peeking a terminal brings its
        // overview along — so asking for a pane got you a wall of text beside
        // it, or, when the pair could not be resolved, the overview alone and
        // no terminal at all. The tap means "show me that pane", so it shows
        // that pane. A row that is already the peeked one keeps its peek and
        // just takes focus: you are looking at it already.
        if controller.peekedPane != nil, !controller.isPeeked(surface) {
            controller.dismissPeek()
        }
        Ghostty.moveFocus(to: surface)
    }

    /// Close a row's pane for good, the way the grid's own menu closes it.
    ///
    /// The board is where you are standing when you notice a pane is finished,
    /// or wedged, or was never worth starting — and until now the only thing
    /// you could do about it from here was go to the pane and close it there.
    /// It goes through `closePane`, so an agent's terminal still asks before
    /// it is killed: a right-click and a slip must not end a running process.
    func closePane(_ entry: Entry) {
        guard let surface = entry.surface,
              let controller = Self.controller(owning: surface) else { return }
        controller.closePane(.terminal(surface))
        watchForClose(of: surface)
    }

    /// Drop the row once its pane is actually gone.
    ///
    /// The board cannot simply remove the row itself, because the confirmation
    /// may still come back "no" — and it should not have to wait out the 2.5 s
    /// scan either, because a row you just closed lingering on screen reads as
    /// a close that did not work. So it looks more often, briefly, and stops
    /// as soon as the pane has left its window. Ten seconds is the whole
    /// budget: a confirmation left sitting open falls back to the ordinary
    /// scan, which gets there in the end.
    private func watchForClose(of surface: Ghostty.SurfaceView, attempts: Int = 40) {
        guard attempts > 0 else { return }
        Task { @MainActor [weak self, weak surface] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            guard let surface, Self.controller(owning: surface) != nil else {
                self.refresh()
                return
            }
            self.watchForClose(of: surface, attempts: attempts - 1)
        }
    }

    /// Open the row's Agent Overview and peek it — the full reading view of
    /// what the list shows one paragraph of.
    ///
    /// ⌘-click, matching the grid's own convention: a plain click selects or
    /// navigates, ⌘-click expands. Creates the overview when the pane doesn't
    /// have one, so this works for any agent in the list, not only the ones
    /// already being watched.
    func revealOverview(_ entry: Entry) {
        guard let surface = entry.surface,
              let controller = Self.controller(owning: surface) else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // A parked pane is read where it is, as ⌘-click on its shelf tile
        // does. This used to restore it first, so looking at a parked agent
        // from the board quietly put it back in the grid — and closing the
        // peek left it there. Its overview, if it has one, is parked with it
        // and peeks with it; without one it peeks alone, since opening an
        // overview would claim a grid cell for a pane that has none.
        let pane = GridPane.terminal(surface)
        if controller.sidebarPanes.contains(ObjectIdentifier(surface)) {
            if let overview = controller.agentOverviewPanes.first(where: { $0.surface === surface }) {
                controller.peekPane(.agentOverview(overview))
            } else {
                controller.peekPane(pane)
            }
            return
        }

        // An overview opened *here* exists only to answer this click. Escape
        // should leave the grid as it found it — the person wanted to read an
        // agent, not to permanently spend a cell on it. One that was already
        // open is someone's arrangement and outlives the peek.
        let openedForThisReveal = !controller.hasAgentOverview(for: pane)
        if openedForThisReveal {
            controller.showAgentOverview(for: pane)
        }
        guard let overview = controller.agentOverviewPanes.first(where: { $0.surface === surface })
        else { return }
        // Peeking the overview expands its terminal alongside it, so this ends
        // with both halves of the pair on screen.
        controller.peekPane(
            .agentOverview(overview),
            transientOverview: openedForThisReveal ? overview : nil)
    }

    private static func controller(owning surface: Ghostty.SurfaceView) -> BaseTerminalController? {
        TerminalController.all.first { $0.surfaceTree.contains(surface) }
    }
}
