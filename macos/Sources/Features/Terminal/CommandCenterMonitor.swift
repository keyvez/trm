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
        let kind: AgentKind
        /// Where the work is: the project directory, and the machine when the
        /// pane is remote.
        let location: String?
        let host: String?
        /// The agent's current message — the paragraph an overview would show.
        let message: String
        /// The last thing the human asked, for context when the reply is terse.
        let prompt: String?
        /// True while the newest transcript entry is a tool call with no
        /// result yet: the agent is mid-task rather than waiting on you.
        let isWorking: Bool
        /// True when the agent asked a question and is blocked on the answer.
        let needsAttention: Bool
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

    /// One-sentence summaries, keyed by pane id. Populated only in briefing
    /// mode, and only when a pane's message actually changes.
    @Published private(set) var briefings: [ObjectIdentifier: String] = [:]

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
                    let pane = headless[key] ?? AgentOverviewPane(surface: surface)
                    headless[key] = pane
                    // Only headless panes need driving; an on-screen overview
                    // is already on its own timer.
                    pane.refresh()
                    source = pane
                }

                guard let entry = Self.entry(for: surface, from: source) else { continue }
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
        let errors = transcript.activity.filter(\.isError)

        let paneId = surface.paneId ?? 0
        let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = AgentOverviewPane.workingDirectory(for: surface)

        return Entry(
            id: ObjectIdentifier(surface),
            paneId: paneId,
            watermark: (watermark?.isEmpty == false ? watermark! : "pane \(paneId)"),
            kind: pane.agentKind,
            location: cwd.map { ($0 as NSString).lastPathComponent },
            host: surface.remoteHost,
            message: message,
            prompt: transcript.lastUserPrompt,
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
        let reply = summarize(transcript.blocks)
        if !reply.isEmpty { return reply }
        if let question = transcript.questions.first?.text, !question.isEmpty {
            return question
        }
        if let tool = transcript.activity.last {
            let detail = tool.detail.map { ": \($0)" } ?? ""
            return (tool.finished ? "Ran \(tool.name)" : "Running \(tool.name)") + detail
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
            // A remote pane trm can't ask about — no session name recorded —
            // is worth saying so once, since from the outside it looks
            // identical to a pane with no agent.
            if surface.remoteZmxSession == nil, let paneId = surface.paneId,
               !reportedUnresolvableRemotePanes.contains(paneId) {
                reportedUnresolvableRemotePanes.insert(paneId)
                TrmDiagnostics.log(
                    "[command-center] pane \(paneId) on \(surface.remoteHost ?? "?") has no " +
                    "recorded zmx session; its agent can't be resolved. Reconnect the pane.")
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
            kind: .claude,
            location: cwd.map { ($0 as NSString).lastPathComponent },
            host: surface.remoteHost,
            message: resolving
                ? "Connecting…"
                : (status ?? "Reading the transcript…"),
            prompt: nil,
            isWorking: false,
            needsAttention: false,
            errorCount: 0,
            errorText: nil,
            updatedAt: nil,
            surface: surface
        )
    }

    /// The agent's message as one paragraph of plain text.
    ///
    /// Code blocks and images are dropped rather than flattened: this is a
    /// glanceable summary, and a wall of code in a one-line row tells you
    /// nothing about what the agent is doing.
    static func summarize(_ blocks: [AgentTranscript.Block], limit: Int = 600) -> String {
        var parts: [String] = []
        for block in blocks {
            guard case .paragraph(let text) = block else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        let joined = parts.joined(separator: "\n\n")
        guard joined.count > limit else { return joined }
        let cut = joined.prefix(limit)
        // Break at the last sentence end so the summary doesn't stop mid-word.
        if let stop = cut.lastIndex(where: { ".!?".contains($0) }) {
            return String(cut[...stop])
        }
        return String(cut) + "…"
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
            briefings[entry.id] = Self.firstSentence(of: entry.message)

            guard !briefingsInFlight.contains(entry.id) else { continue }
            briefingsInFlight.insert(entry.id)
            let message = entry.message
            let prompt = entry.prompt
            Task { [weak self] in
                let summary = await Self.summarize(message: message, prompt: prompt)
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
    private static func summarize(message: String, prompt: String?) async -> String? {
        let body = [
            prompt.map { "The person asked: \($0)" },
            "The agent's message:\n\(message)",
        ].compactMap { $0 }.joined(separator: "\n\n")

        do {
            let text = try await Trm.shared.llmClient.complete(
                system: "Summarize what a coding agent just did in ONE sentence, at most 18 "
                    + "words, in past tense, plain text, no markdown. Lead with the outcome, "
                    + "not the process. If the agent is asking the person something, say what "
                    + "it needs. If it hit an error it could not resolve, say so plainly. "
                    + "Return only the sentence.",
                user: body,
                maxTokens: 80)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

    /// The opening sentence of a message, capped so a briefing stays one line
    /// rather than a paragraph.
    nonisolated static func firstSentence(of text: String, limit: Int = 160) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }

        var sentence = flat
        if let end = flat.firstIndex(where: { ".!?".contains($0) }) {
            let candidate = String(flat[...end])
            // A "sentence" that ends after a few characters is an abbreviation
            // or a version number, not a sentence.
            if candidate.count > 12 { sentence = candidate }
        }
        guard sentence.count > limit else { return sentence }
        let cut = sentence.prefix(limit)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
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
        Ghostty.moveFocus(to: surface)
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

        let id = ObjectIdentifier(surface)
        if controller.sidebarPanes.contains(id) {
            controller.restorePaneFromSidebar(id)
        }

        let pane = GridPane.terminal(surface)
        if !controller.hasAgentOverview(for: pane) {
            controller.showAgentOverview(for: pane)
        }
        guard let overview = controller.agentOverviewPanes.first(where: { $0.surface === surface })
        else { return }
        // Peeking the overview expands its terminal alongside it, so this ends
        // with both halves of the pair on screen.
        controller.peekPane(.agentOverview(overview))
    }

    private static func controller(owning surface: Ghostty.SurfaceView) -> BaseTerminalController? {
        TerminalController.all.first { $0.surfaceTree.contains(surface) }
    }
}
