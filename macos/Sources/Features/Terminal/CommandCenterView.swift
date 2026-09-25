import SwiftUI
import UniformTypeIdentifiers

/// Every running agent's current message, in one scrolling list.
///
/// Each row is a pane: its watermark, where it is working, and the paragraph
/// the agent is on right now. Clicking a row reveals that pane, so the list
/// works as a switchboard as well as a status board.
struct CommandCenterView: View {
    @ObservedObject private var monitor = CommandCenterMonitor.shared

    /// Compose a reply straight from the list, so noticing an agent is waiting
    /// and answering it are the same gesture.
    var onSendToPane: ((Ghostty.SurfaceView, String) -> Void)? = nil

    /// Briefing mode: one sentence per agent, sized to be read at a glance
    /// and acted on, rather than a card you settle in to read. Persisted, and
    /// read by the panel header's toggle.
    @AppStorage("CommandCenterBriefingMode") private var briefingMode = false

    @State private var drafts: [ObjectIdentifier: String] = [:]

    /// How far back through a pane's history the reply box has walked, per
    /// pane. -1 is "not in history, this is what you typed".
    @State private var historyIndex: [ObjectIdentifier: Int] = [:]
    /// What was in the box before walking back, so Down returns it.
    @State private var draftBeforeHistory: [ObjectIdentifier: String] = [:]
    /// The last text *we* put in a box. A TextField writes back through its
    /// binding when its contents change, including changes we made — without
    /// this, stepping through history looked like typing and cleared the very
    /// state that remembers the draft.
    @State private var historyEcho: [ObjectIdentifier: String] = [:]
    /// Local key monitor, live only while a reply box has focus.
    @State private var keyMonitor: Any?

    /// The row whose reply box has been opened into a full editor, if any.
    ///
    /// The inline box is one to four lines and Return sends it, which is the
    /// right shape for "yes, go ahead" and the wrong one for a paragraph with
    /// a list in it — where Return means "next line" and pressing it fires off
    /// half an instruction. Expanded, the box becomes an editor: Return breaks
    /// the line, and sending is ⌘↩ or the button, so nothing leaves until you
    /// say so.
    ///
    /// One at a time, because an open editor takes the whole panel. Writing a
    /// paragraph to one agent is not a thing you do out of the corner of your
    /// eye, and the board's other rows are a live feed that moves while you
    /// type — the version that kept them on screen was a card growing inside
    /// a list that rearranged itself underneath it.
    @State private var focusedComposerID: ObjectIdentifier?

    /// The entry the editor is open on, if it is still on the board. A pane
    /// that closes while you are writing to it drops you back to the board
    /// rather than leaving an editor addressed to nothing.
    private var focusedComposerEntry: CommandCenterMonitor.Entry? {
        guard let focusedComposerID else { return nil }
        return monitor.entries.first { $0.id == focusedComposerID }
    }

    /// What each pane's box is doing about an attachment right now: copying
    /// it, or why it couldn't.
    @State private var attachmentStatus: [ObjectIdentifier: String] = [:]

    /// Set briefly after a link is tapped, driving the "copied" pill — the
    /// same confirmation the Agent Overview uses.
    @State private var copiedLink: String?

    /// Which card's reply box has the keyboard.
    ///
    /// Set by tapping the box itself, and kept there after sending so a
    /// follow-up is just more typing. The card *around* the box navigates
    /// instead — tap for the pane, ⌘-tap for the Overview — because a board
    /// you read to decide where to go should take you there.
    @FocusState private var focusedDraft: ObjectIdentifier?

    /// The row whose watermark is being renamed, if any.
    ///
    /// A watermark is the name a pane wears, and the board is where you read
    /// those names — so it is also where you notice one is wrong. Double-click
    /// turns the chip into a field rather than opening the pane's own rename
    /// sheet: the whole point of the row is that you did not have to go there.
    @State private var renamingID: ObjectIdentifier?
    @State private var renameText: String = ""
    @FocusState private var renameField: Bool

    /// Below this, one card per row reads better than a cramped two-up.
    private static let minimumCardWidth: CGFloat = 340

    /// Every card the same height in grid mode. Fixed rather than measured:
    /// "all the same size" is the point, and a height that tracked the
    /// wordiest agent would jump every time any of them spoke.
    private static let gridCardHeight: CGFloat = 260

    /// The gap between the expanded view's two halves.
    private static let focusedSectionGap: CGFloat = 10

    /// The shortest either half is allowed to get. Below this the panel is
    /// too short to divide usefully, and half of nothing is worse than a
    /// section you can scroll.
    private static let minimumFocusedSection: CGFloat = 170

    /// The reading that is playing, wherever it was started from.
    @ObservedObject private var nowPlaying = SpeechNowPlaying.shared

    var body: some View {
        VStack(spacing: 0) {
            nowPlayingBar
            panel
        }
    }

    /// Playback controls for a reading whose own panel has gone.
    ///
    /// Escape on a peek closes the overview it opened, which is where the play
    /// button lived. The voice keeps going — dismissing a view is not a request
    /// for silence — so the controls come here, to the top of the board, which
    /// is the one panel that is about every pane rather than any one of them.
    /// It is only drawn while something is actually playing.
    @ViewBuilder
    private var nowPlayingBar: some View {
        if let speaker = nowPlaying.speaker {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                    Text(nowPlaying.label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        speaker.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Stop reading")
                }
                OverviewPlaybackControls(speaker: speaker)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            Divider().opacity(0.35)
        }
    }

    private var panel: some View {
        Group {
            if let entry = focusedComposerEntry {
                focusedComposerView(entry)
            } else if monitor.entries.isEmpty {
                if monitor.hasSettled { empty } else { checking }
            } else {
                GeometryReader { geo in
                    let columns = Self.columnCount(for: geo.size.width)
                    ScrollView {
                        // Plain stacks, not a LazyVGrid: a lazy grid inside a
                        // ScrollView has to estimate the size of cells it has
                        // not built while the scroll view feeds those
                        // estimates back as the proposal, and that loop has
                        // pinned a core in this app twice already (see
                        // SessionBrowserView, AgentOverviewView). The card
                        // count here is small and its height is fixed, so
                        // laying every row out eagerly is cheap.
                        if briefingMode, columns > 1 {
                            gridRows(columns: columns) { entry in
                                AnyView(briefingRow(entry, fixedHeight: Self.briefingTileHeight))
                            }
                        } else if briefingMode {
                            VStack(spacing: 8) {
                                ForEach(monitor.entries) { entry in
                                    briefingRow(entry, fixedHeight: nil)
                                }
                            }
                            .padding(10)
                        } else if columns <= 1 {
                            VStack(spacing: 0) {
                                ForEach(monitor.entries) { entry in
                                    card(entry, fixedHeight: nil)
                                    Divider().opacity(0.35)
                                }
                            }
                        } else {
                            gridRows(columns: columns) { entry in
                                AnyView(
                                    card(entry, fixedHeight: Self.gridCardHeight)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.primary.opacity(0.04))
                                        )
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            monitor.subscribe()
            monitor.briefingsEnabled = briefingMode
        }
        .onDisappear {
            monitor.briefingsEnabled = false
            monitor.unsubscribe()
            removeKeyMonitor()
        }
        .onChange(of: focusedDraft) { focused in
            // The monitor exists only while a box has the keyboard, so arrow
            // keys anywhere else in the app are untouched.
            if focused != nil { installKeyMonitor() } else { removeKeyMonitor() }
        }
        .onChange(of: briefingMode) { enabled in
            monitor.briefingsEnabled = enabled
        }
    }

    /// Equal-size tiles, `columns` across, in pane order — the layout both
    /// modes use once the panel is wide enough for more than one card.
    @ViewBuilder
    private func gridRows(
        columns: Int, @ViewBuilder cell: @escaping (CommandCenterMonitor.Entry) -> AnyView
    ) -> some View {
        VStack(spacing: 10) {
            ForEach(Self.rows(monitor.entries, columns: columns), id: \.first?.id) { row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { entry in
                        cell(entry).frame(maxWidth: .infinity)
                    }
                    // Keep the last row's tiles the same width as every other
                    // row's rather than letting two share the space three were
                    // sized for.
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(10)
    }

    /// How many equal cards fit across `width`. One column until the panel is
    /// wide enough for two full cards, so a normal-width sidebar keeps the
    /// list layout it has now.
    static func columnCount(for width: CGFloat, minimum: CGFloat = minimumCardWidth) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int(width / minimum))
    }

    /// Chunk entries into rows of `columns`, preserving pane order.
    static func rows(
        _ entries: [CommandCenterMonitor.Entry], columns: Int
    ) -> [[CommandCenterMonitor.Entry]] {
        guard columns > 1 else { return entries.map { [$0] } }
        return stride(from: 0, to: entries.count, by: columns).map {
            Array(entries[$0..<min($0 + columns, entries.count)])
        }
    }

    /// Shown for the moment between opening the panel and the first scan
    /// coming back. Transcripts are parsed off the main actor, so an empty
    /// board at t=0 means "still looking", not "nothing there".
    private var checking: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Checking for agents…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No agents running")
                .font(.system(size: 13, weight: .medium))
            Text("Panes running Claude Code or Codex appear here with whatever they're saying.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    /// Who this row is: state, watermark, agent, where it runs, how long ago
    /// it spoke. Shared by the board's cards and the focused editor, so the
    /// row you were reading and the row you are writing to are labelled the
    /// same way.
    @ViewBuilder
    private func cardHeader(_ entry: CommandCenterMonitor.Entry) -> some View {
        HStack(spacing: 8) {
            statusDot(entry)

            // The watermark is how the pane labels itself on screen, so
            // it's the fastest way to map a row back to a cell.
            watermarkChip(entry, style: .card)

            Text(entry.kind?.displayName ?? "Agent")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(
                    Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 0.8)
                )

            if let location = entry.location {
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let host = entry.host {
                Label(host, systemImage: "network")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let updated = entry.updatedAt {
                Text(updated, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        // The header is the row's nameplate, so double-clicking it does what
        // double-clicking a nameplate does everywhere else in trm: goes to the
        // thing it names. A single click still belongs to the card underneath
        // — repeated here because a gesture on a child otherwise swallows the
        // taps the card was listening for.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { monitor.reveal(entry) }
        .onTapGesture { rowTap(entry) }
        .help("Double-click to go to this pane · double-click the watermark to rename it")
    }

    /// How a watermark chip is drawn where it sits.
    private enum WatermarkStyle {
        /// The board's cards: an accent capsule.
        case card
        /// Briefing rows: bare, in the row's status colour.
        case briefing(Color)
    }

    /// The pane's name, and the place you change it.
    ///
    /// One click goes to the pane; two turn the chip into a field. The field
    /// is seeded with the pane's own watermark rather than the row label,
    /// because the label can carry the worktree insignia or fall back to
    /// "pane 3" — neither is text anyone typed or wants to edit around.
    @ViewBuilder
    private func watermarkChip(
        _ entry: CommandCenterMonitor.Entry, style: WatermarkStyle
    ) -> some View {
        if renamingID == entry.id {
            TextField("Watermark", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .focused($renameField)
                .frame(maxWidth: 160)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.7), lineWidth: 1))
                .onSubmit { commitRename(entry) }
                .onExitCommand { cancelRename() }
                // Clicking away is "done", not "discard": this is a field in a
                // list that moves under you, and losing the name to a stray
                // click elsewhere on the board would be its own bug report.
                .onChange(of: renameField) { focused in
                    if !focused { commitRename(entry) }
                }
                .help("Return to rename · esc to leave it alone · blank clears it")
        } else {
            Group {
                switch style {
                case .card:
                    Text(entry.watermark)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.16))
                        )
                case .briefing(let color):
                    Text(entry.watermark)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                }
            }
            // Double before single: the second click of a rename must not send
            // you to the pane on its way.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginRename(entry) }
            .onTapGesture { monitor.reveal(entry) }
            .help("Click to go to this pane · double-click to rename it")
        }
    }

    /// The row's right-click menu.
    ///
    /// One item, and it is the one thing the board could not do: end a pane.
    /// Reading the board is how you find out an agent has finished, or wedged,
    /// or was never worth starting, and until now noticing that and acting on
    /// it happened in two different places. The row goes when the pane does.
    @ViewBuilder
    private func rowMenu(_ entry: CommandCenterMonitor.Entry) -> some View {
        Button(role: .destructive) {
            monitor.closePane(entry)
        } label: {
            Label("Exit Pane", systemImage: "xmark")
        }
    }

    /// What a plain click on a row does, wherever on the row it lands.
    private func rowTap(_ entry: CommandCenterMonitor.Entry) {
        if NSEvent.modifierFlags.contains(.command) {
            monitor.revealOverview(entry)
        } else {
            focusedDraft = entry.id
        }
    }

    /// Open the rename field on a row.
    ///
    /// Only for panes that are actually here: a remote agent's row has no
    /// local pane id to stamp, and renaming pane 0 by accident would put
    /// someone else's name on the first cell in the grid.
    private func beginRename(_ entry: CommandCenterMonitor.Entry) {
        guard let paneId = entry.surface?.paneId else { return }
        renameText = Trm.shared.watermark(forPaneId: UInt32(paneId)) ?? ""
        renamingID = entry.id
        // A field that appears without the keyboard is a field you click
        // twice to use; the hop lets it exist before it is asked to focus.
        DispatchQueue.main.async { renameField = true }
    }

    private func commitRename(_ entry: CommandCenterMonitor.Entry) {
        guard renamingID == entry.id else { return }
        renamingID = nil
        renameField = false
        guard let paneId = entry.surface?.paneId else { return }
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (Trm.shared.watermark(forPaneId: UInt32(paneId)) ?? "") else { return }
        Trm.shared.setWatermark(forPaneId: UInt32(paneId), text: text)
        // The row's label comes from the last scan, so ask for a new one
        // rather than leaving the old name sitting there for two seconds.
        monitor.refresh()
    }

    private func cancelRename() {
        renamingID = nil
        renameField = false
    }

    /// One agent's card. `fixedHeight` is set in grid mode, where every card
    /// is the same size and the message truncates to fit rather than the card
    /// growing to hold it.
    private func card(
        _ entry: CommandCenterMonitor.Entry, fixedHeight: CGFloat?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader(entry)

            // Same rule as a briefing row: a question that has stopped the
            // work outranks a report on the work.
            if let pending = entry.pendingPrompt {
                promptCard(entry, prompt: pending)
            }

            if let prompt = entry.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(entry.message)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: fixedHeight == nil)
                .lineLimit(fixedHeight == nil ? nil : 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            links(entry)

        }
        .modifier(CardChrome(
            fixedHeight: fixedHeight,
            composer: onSendToPane == nil ? nil : AnyView(composer(entry))
        ))
        // Outside the chrome so the card's padding is part of the target.
        // SwiftUI's tap gestures don't carry modifiers, so the flags are read
        // at the moment of the tap — the pattern TrmGridView already uses for
        // ⌘-click peek.
        .contentShape(Rectangle())
        .onTapGesture { rowTap(entry) }
        // The whole card takes a drop: aiming a dragged screenshot at a
        // reply box a few points tall is a game nobody wants to play.
        .onDrop(of: [.fileURL, .image, .png, .tiff], isTargeted: nil) { providers in
            attach(providers: providers, to: entry)
            return true
        }
        .contextMenu { rowMenu(entry) }
        .help("Click to reply · ⌘-click for the Agent Overview · double-click the header for the pane · double-click the watermark to rename")
    }

    /// Card padding and the reply box, kept out of the card's tap gesture so
    /// clicking into the box puts a cursor there instead of navigating.
    private struct CardChrome: ViewModifier {
        let fixedHeight: CGFloat?
        let composer: AnyView?

        func body(content: Content) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                content
                // In grid mode the box sits at the card's foot, so it is in
                // the same place on every card.
                if fixedHeight != nil { Spacer(minLength: 0) }
                composer
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: fixedHeight, alignment: .top)
        }
    }

    // MARK: - Briefing mode

    /// One agent, one line, at a size you can read without leaning in.
    ///
    /// The shape is a status board: a coloured bar down the left saying how
    /// much of your attention this needs, the pane's watermark, the sentence,
    /// and — only when there is one — the thing that would make you stop and
    /// look properly. Tapping goes to the pane, which is the point: the
    /// briefing decides *whether* to go, not what to do once you're there.
    private func briefingRow(
        _ entry: CommandCenterMonitor.Entry, fixedHeight: CGFloat?
    ) -> some View {
        let status = Self.status(for: entry)
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(status.color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    watermarkChip(entry, style: .briefing(status.color))
                    Text(status.label.uppercased())
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(status.color.opacity(0.9))
                    Text(entry.kind?.displayName ?? "Agent")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let location = entry.location {
                        Text(location)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let updated = entry.updatedAt {
                        Text(updated, style: .relative)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                // Same as a card's header: two clicks on the nameplate go to
                // the pane it names, one click stays with the row.
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { monitor.reveal(entry) }
                .onTapGesture { rowTap(entry) }

                // A question being asked on screen comes before anything
                // else the row has to say. Everything below is a report on
                // work already done; this is work that has stopped until you
                // answer, and the answer is one click away.
                if let prompt = entry.pendingPrompt {
                    promptCard(entry, prompt: prompt)
                }

                // What was done, above the conclusion it led to: read down
                // the detail to judge whether the sentence is the whole
                // story, or skip it and take the sentence.
                if !briefingBullets(entry).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(briefingBullets(entry), id: \.self) { bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                // Three lines, ending at the end. A bullet is
                                // a whole sentence about what came of the work
                                // — a path, a figure, an error in its own
                                // words — and a line with its middle cut out
                                // loses exactly those.
                                Text(bullet)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.bottom, 1)
                }

                Text(briefingSentence(entry))
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: fixedHeight == nil)
                    .lineLimit(fixedHeight == nil ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // What the reply ends by asking, in the agent's words. The
                // sentence above is a summary and may not carry it — the
                // question closing a long reply is the part both a capped
                // message and a one-line summary lose, and the only part
                // you have to act on.
                if let question = entry.closingQuestion,
                   entry.pendingPrompt == nil,
                   !briefingSentence(entry).contains(question) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange.opacity(0.9))
                        Text(question)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help("The question this reply ends on")
                }

                // The escalation line: only drawn when something actually
                // wants a decision, so its presence is the signal.
                if let detail = Self.escalation(for: entry) {
                    Text(detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(status.color.opacity(0.95))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                links(entry)
                }

                // Answering is the whole point of a board you read to decide
                // what needs you: the quickest actions — "yes", "go ahead",
                // "use the other approach" — shouldn't need a trip to the pane.
                // In grid mode the box sits at the tile's foot, so it is in
                // the same place on every tile.
                if fixedHeight != nil { Spacer(minLength: 0) }

                if onSendToPane != nil {
                    composer(entry, large: true)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: fixedHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(status.color.opacity(status.emphasis))
        )
        // The whole card, not just the words on it: padding, the status bar,
        // and the empty space beside a short sentence are all places a person
        // aims at when they mean "this one". The text field and the send
        // button consume their own clicks, so the composer still behaves.
        .contentShape(Rectangle())
        .onTapGesture { rowTap(entry) }
        // The whole card takes a drop: aiming a dragged screenshot at a
        // reply box a few points tall is a game nobody wants to play.
        .onDrop(of: [.fileURL, .image, .png, .tiff], isTargeted: nil) { providers in
            attach(providers: providers, to: entry)
            return true
        }
        .contextMenu { rowMenu(entry) }
        .help("Click to reply · ⌘-click for the Agent Overview · double-click the header for the pane · double-click the watermark to rename")
    }

    // MARK: - The question a pane is asking

    /// A pane's on-screen question, with whatever it is asking *about*.
    ///
    /// The preview is the part that makes this worth building. "Do you want to
    /// make this edit?" is unanswerable from a board; the same words over six
    /// lines of the actual diff, in the colours the terminal drew them in, is
    /// a decision you can take from a phone.
    @ViewBuilder
    private func promptCard(
        _ entry: CommandCenterMonitor.Entry, prompt: PanePrompt
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("WAITING ON YOU")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.orange.opacity(0.9))
            }

            // What it is asking about: the diff, the plan, the command. Drawn
            // from the pane's own cells, so it looks like what is on screen
            // rather than a description of it.
            if let rows = prompt.previewRows, let screen = monitor.screen(for: entry) {
                ScrollView(.horizontal, showsIndicators: false) {
                    PaneMiniature(screen: screen, fontSize: 9, rowRange: rows)
                }
                .frame(maxHeight: 132)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
            }

            Text(prompt.question)
                .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // One button per choice, sending the digit the menu offers it
            // under. Wrapped rather than in a row: these are whole sentences
            // ("No, and tell Claude what to do differently"), not "OK".
            VStack(alignment: .leading, spacing: 4) {
                ForEach(prompt.options) { option in
                    Button {
                        monitor.answer(option, for: entry)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(option.number)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(option.isSelected ? Color.orange : .secondary)
                                .frame(width: 12, alignment: .trailing)
                            Text(option.label)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(option.isSelected
                                      ? Color.orange.opacity(0.14)
                                      : Color.primary.opacity(0.05)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(option.isSelected
                                              ? Color.orange.opacity(0.5)
                                              : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help("Answer the pane with \(option.number)")
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28)))
    }

    /// Briefing tiles: up to five detail lines of three lines each, the
    /// headline, one escalation line, and a reply box twice the height of the
    /// detail view's — grown to fit them. Every tile is the same height so the
    /// board reads as a grid, which means the tallest thing a row can say sets
    /// it. A tile is read instead of the pane, so it is sized for a paragraph
    /// of the agent's own account rather than for a glance.
    private static let briefingTileHeight: CGFloat = 420

    /// The headline for a row: the model's sentence when it has answered, the
    /// message's own opening sentence until then.
    ///
    /// The agent's own recap comes first when there is a current one: it is
    /// Claude summing up its session with everything it knows, which beats a
    /// summary of it written from the outside.
    private func briefingSentence(_ entry: CommandCenterMonitor.Entry) -> String {
        entry.recap
            ?? monitor.briefings[entry.id]?.sentence
            ?? CommandCenterMonitor.localBriefing(for: entry).sentence
    }

    /// The detail above it: what the agent has actually done this turn, what
    /// failed, what it is waiting on.
    ///
    /// The model's lines when it has answered, and the live ones built from
    /// the entry until then — which is also the whole of the detail on a
    /// machine with no LLM configured. Either way these are sentences about
    /// the work, not the tool calls that did it: the commands were here once,
    /// and a column of them told you less than the agent's own next paragraph
    /// does.
    private func briefingBullets(_ entry: CommandCenterMonitor.Entry) -> [String] {
        if let bullets = monitor.briefings[entry.id]?.bullets, !bullets.isEmpty {
            return bullets
        }
        return CommandCenterMonitor.localBriefing(for: entry).bullets
    }

    /// How much of your attention a pane is asking for. Ordered by how much
    /// it costs to ignore.
    struct Status {
        let label: String
        let color: Color
        /// How strongly the row is tinted. Only the states that want action
        /// get a wash; the rest stay quiet so the board reads at a glance.
        let emphasis: Double
        /// Nothing in flight and nothing being asked: the pane has finished
        /// and is waiting on you. The only state that gets the idle fidget,
        /// because it is the only one a colour can't say out loud.
        var isIdle: Bool = false
    }

    static func status(for entry: CommandCenterMonitor.Entry) -> Status {
        // A question on screen counts the same as one in the transcript — it
        // is the same agent, stopped for the same reason. It is checked first
        // because it is the earlier of the two: the box is drawn while the
        // transcript still says the turn is running.
        if entry.isAskingYou || entry.pendingPrompt != nil {
            return Status(label: "needs you", color: .orange, emphasis: 0.14)
        }
        if entry.errorCount > 0 {
            return Status(label: "check this", color: .red, emphasis: 0.12)
        }
        if entry.isWorking {
            return Status(label: "working", color: .green, emphasis: 0.05)
        }
        return Status(label: "idle", color: .secondary, emphasis: 0.03, isIdle: true)
    }

    /// The one extra line worth showing under the sentence, or nothing.
    static func escalation(for entry: CommandCenterMonitor.Entry) -> String? {
        // Nothing to add when the question itself is on the row: the card
        // above says what is being asked and offers the answers.
        if entry.pendingPrompt != nil { return nil }
        if entry.needsAttention {
            return "Waiting on your answer."
        }
        if entry.errorCount > 0, let text = entry.errorText {
            let count = entry.errorCount == 1 ? "1 error" : "\(entry.errorCount) errors"
            return "\(count) this turn — \(text)"
        }
        if entry.errorCount > 0 {
            return entry.errorCount == 1 ? "1 error this turn." : "\(entry.errorCount) errors this turn."
        }
        return nil
    }

    @ViewBuilder
    private func statusDot(_ entry: CommandCenterMonitor.Entry) -> some View {
        let color: Color = entry.isAskingYou ? .orange : (entry.isWorking ? .green : .secondary)
        Circle()
            .fill(color.opacity(entry.isWorking || entry.isAskingYou ? 0.9 : 0.35))
            .frame(width: 7, height: 7)
            .help(entry.isAskingYou ? "Waiting on you"
                  : (entry.isWorking ? "Working" : "Idle"))
    }

    /// `large` doubles the box for briefing mode, where the row is a
    /// decision to act on and the reply is the action — a one-line field you
    /// have to squint at is the wrong shape for that.
    private func composer(_ entry: CommandCenterMonitor.Entry, large: Bool = false) -> some View {
        inlineComposer(entry, text: draftBinding(entry), large: large)
        // Drop a screenshot, a log, a diff: it is staged where the agent can
        // read it and its path goes in the message.
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            attach(providers: providers, to: entry)
            return true
        }
        .overlay(alignment: .topLeading) {
            if let status = attachmentStatus[entry.id] {
                Text(status)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: -14)
                    .transition(.opacity)
            }
        }
    }

    /// A row's draft, shared by its one-line box and its editor — open the
    /// editor mid-sentence and the sentence is there.
    private func draftBinding(_ entry: CommandCenterMonitor.Entry) -> Binding<String> {
        Binding(
            get: { drafts[entry.id] ?? "" },
            set: { newValue in
                // Editing means you have left the history and are writing
                // again; the next Up starts from the newest message. A write
                // that matches what history just put there is our own echo,
                // not the user, and must not reset anything.
                if newValue != drafts[entry.id], newValue != historyEcho[entry.id] {
                    historyIndex[entry.id] = -1
                    draftBeforeHistory[entry.id] = nil
                }
                drafts[entry.id] = newValue
            }
        )
    }

    /// The everyday box: a few lines, Return sends.
    private func inlineComposer(
        _ entry: CommandCenterMonitor.Entry, text binding: Binding<String>, large: Bool
    ) -> some View {
        HStack(spacing: 6) {
            TextField("Reply…", text: binding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(large ? 2...8 : 1...4)
                .font(.system(size: large ? 13 : 11.5, design: .monospaced))
                .focused($focusedDraft, equals: entry.id)
                .padding(.horizontal, large ? 10 : 8)
                .padding(.vertical, large ? 10 : 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(focusedDraft == entry.id ? 0.10 : 0.06))
                )
                // An idle pane's dog waits inside the box you would answer it
                // in, which is the only place on the card where "throw me the
                // next one" is an instruction rather than an ornament. It sits
                // at the trailing edge so it is never under the placeholder or
                // the first words of a draft, and goes the moment the agent
                // has something to say.
                .background(alignment: .trailing) {
                    if Self.status(for: entry).isIdle {
                        FetchIdleAnimation(size: large ? 9 : 7)
                            .padding(.trailing, 8)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.accentColor.opacity(focusedDraft == entry.id ? 0.55 : 0))
                )
                .onSubmit { send(entry) }
                // ⌘-click opens the editor. The box already answers a plain
                // click by putting a cursor in it, so the gesture that means
                // "more of this" is the one the rest of trm uses for "show me
                // this properly" — ⌘-click on a card opens its Overview, and
                // on a pane it peeks.
                .simultaneousGesture(TapGesture().onEnded {
                    guard NSEvent.modifierFlags.contains(.command),
                          NSEvent.modifierFlags.isDisjoint(with: [.shift, .control, .option])
                    else { return }
                    expand(entry)
                })

            Button {
                expand(entry)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: large ? 13 : 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Write a longer message (⌘-click the box)")

            Button {
                send(entry)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: large ? 22 : 15))
            }
            .buttonStyle(.plain)
            .disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// One agent, alone, with the editor.
    ///
    /// The board is a live feed — rows move as agents speak — and writing a
    /// paragraph inside something that rearranges itself is unpleasant in a
    /// way that a bigger box does not fix. So the editor takes the panel: the
    /// row you are writing to at the top, what it said under that, and the
    /// rest is yours. Escape puts the board back.
    private func focusedComposerView(_ entry: CommandCenterMonitor.Entry) -> some View {
        let binding = draftBinding(entry)
        return GeometryReader { geo in
            // Half the panel each, measured rather than negotiated. Reading
            // what the agent said and writing back to it are the two halves
            // of this screen and neither is the junior partner: an editor
            // given the lion's share leaves the message it is answering in a
            // letterbox, and a message given it puts the cursor at the foot
            // of the panel. Below a certain height there is no useful split
            // to make, so the sections keep a floor and the panel scrolls
            // them instead.
            let split = max(
                Self.minimumFocusedSection,
                (geo.size.height - Self.focusedSectionGap) / 2)
            VStack(spacing: Self.focusedSectionGap) {
                focusedSummary(entry)
                    .frame(height: split, alignment: .top)
                expandedComposer(entry, text: binding)
                    .frame(height: split, alignment: .top)
            }
        }
        .padding(12)
        // The keyboard belongs in the editor the moment the panel becomes
        // one. `expand` sets this too, but the view it applies to is built
        // after that, and a focus request that lands before its field exists
        // is a focus request that quietly does nothing.
        .onAppear { focusedDraft = entry.id }
        // Same as the board's cards: drop a screenshot, a log, a diff.
        .onDrop(of: [.fileURL, .image, .png, .tiff], isTargeted: nil) { providers in
            attach(providers: providers, to: entry)
            return true
        }
    }

    /// The top half: everything known about the row you are answering.
    ///
    /// The board's card shows one paragraph because it is one of many on a
    /// wall. Here there is only this agent, and half a panel to say it in, so
    /// the things a card leaves out are worth having: what state it is in and
    /// whether it is waiting on you, what you last asked it, what it actually
    /// did this turn, what went wrong if anything did, and the reply in full
    /// rather than clipped. It scrolls within its half — an agent that has
    /// just written six paragraphs must not push the editor off the panel.
    @ViewBuilder
    private func focusedSummary(_ entry: CommandCenterMonitor.Entry) -> some View {
        let status = Self.status(for: entry)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    collapse(entry)
                } label: {
                    Label("Board", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Back to the board (esc)")
                Spacer(minLength: 0)
                Text(status.label.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(status.color)
            }
            .foregroundStyle(.secondary)

            cardHeader(entry)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // The line that says something wants a decision. Only
                    // drawn when there is one, so its presence is the signal.
                    if let escalation = Self.escalation(for: entry) {
                        Text(escalation)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(status.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // What you last asked, whole. It was two lines before,
                    // which is enough to recognise a question and not enough
                    // to re-read one — and re-reading it is the reason you
                    // are looking at this panel.
                    if let prompt = entry.prompt, !prompt.isEmpty {
                        labelled("You asked", copying: prompt) {
                            AgentMarkdownProse(
                                blocks: [.paragraph(prompt)],
                                fontSize: 11,
                                design: .monospaced,
                                spacing: 8)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // What it did to get here: the turn's tool calls, newest
                    // last. This is the difference between "it says it fixed
                    // the test" and seeing that it edited one file and ran
                    // nothing.
                    if !entry.activity.isEmpty {
                        labelled(
                            "This turn",
                            copying: entry.activity.joined(separator: "\n")
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(entry.activity, id: \.self) { line in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                        Text(line)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // The reply as markdown, not as the board's one-line
                    // summary of it. `message` has had its markers stripped
                    // and its code dropped to fit a row; here there is half a
                    // panel, so the blocks the Overview renders are rendered.
                    let said = "\(entry.kind?.displayName ?? "Agent") said"
                    if !entry.messageBlocks.isEmpty {
                        labelled(
                            said,
                            copying: AgentMarkdownProse.plainText(entry.messageBlocks)
                        ) {
                            AgentMarkdownProse(
                                blocks: entry.messageBlocks,
                                fontSize: 12,
                                design: .default)
                        }
                    } else if !entry.message.isEmpty {
                        labelled(said, copying: entry.message) {
                            Text(entry.message)
                                .font(.system(size: 12, design: .monospaced))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    links(entry)
                }
                .padding(.bottom, 2)
            }
        }
    }

    /// A small caption over a block, so the halves read as sections rather
    /// than as one run of grey monospace — and the caption line is the way to
    /// take that section's text.
    ///
    /// The whole line, not the words: this is offered as the easy alternative
    /// to selecting text in a scrolling column, and a heading you have to hit
    /// exactly is not easier than selecting. The Overview's headings work the
    /// same way, and this is the same control.
    @ViewBuilder
    private func labelled<Content: View>(
        _ caption: String,
        copying content: @autoclosure @escaping () -> String,
        @ViewBuilder body: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            CopyableSectionLabel(title: caption, content: content) {
                Text(caption.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
            }
            body()
        }
    }

    /// The editor: as many lines as you like, and Return is one of them.
    private func expandedComposer(
        _ entry: CommandCenterMonitor.Entry, text binding: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // No title and no close button: the row above already says who
            // this is going to, and the way out is the Board button in the
            // corner. Only the two keys are worth saying, because neither is
            // guessable from a box.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text("⌘↩ send · esc back to the board")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: binding)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($focusedDraft, equals: entry.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.accentColor.opacity(focusedDraft == entry.id ? 0.55 : 0.15))
                )

            HStack(spacing: 8) {
                // Said plainly, because it is the one thing about this box
                // that is not obvious and cannot be undone after sending. A
                // message goes down as a paste, so an agent's input box keeps
                // the lines you wrote — but a pane sitting at a plain shell
                // prompt has nothing framing a paste, where a newline means
                // "run this", and there the message is flattened instead.
                Text(keepsLineBreaks(entry)
                     ? "Line breaks are kept"
                     : "Line breaks become spaces in this pane")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    send(entry)
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Give the panel over to one row's editor, and put the keyboard in it.
    private func expand(_ entry: CommandCenterMonitor.Entry) {
        focusedComposerID = entry.id
        focusedDraft = entry.id
    }

    /// Put the board back, keeping whatever is written.
    private func collapse(_ entry: CommandCenterMonitor.Entry) {
        focusedComposerID = nil
        focusedDraft = entry.id
    }

    /// Links the agent printed, whole and tappable.
    ///
    /// A card truncates its prose, and a truncated URL is worthless — so they
    /// are pulled out of the message and given their own row, where they
    /// survive the line limits. Tapping copies, which is what the Agent
    /// Overview does with a link and what you almost always want from an
    /// address an agent just printed: somewhere else to paste it.
    @ViewBuilder
    private func links(_ entry: CommandCenterMonitor.Entry) -> some View {
        if !entry.links.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(entry.links, id: \.self) { link in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        copiedLink = link
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedLink == link { copiedLink = nil }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copiedLink == link ? "checkmark" : "link")
                                .font(.system(size: 9, weight: .semibold))
                            Text(copiedLink == link ? "Copied" : link)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                // Trim the front, not the back: the end of a
                                // URL — the path, the port — is the part that
                                // tells you which one this is.
                                .truncationMode(.head)
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Copy \(link)")
                }
            }
        }
    }

    // MARK: - Attachments

    /// Take dropped items, put them where the pane's agent can read them, and
    /// leave the path in the box.
    ///
    /// The path goes in the draft rather than being sent on its own: an
    /// attachment almost always comes with a sentence about what to do with
    /// it, and a path you can see before you send is a path you can correct.
    private func attach(providers: [NSItemProvider], to entry: CommandCenterMonitor.Entry) {
        guard let surface = entry.surface else { return }
        for provider in providers {
            // A drag from Finder is a file URL — the original bytes and name.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
                    data, _ in
                    guard let data,
                          let path = String(data: data, encoding: .utf8),
                          let url = URL(string: path)
                            ?? URL(string: path.removingPercentEncoding ?? "")
                    else { return }
                    Task { @MainActor in
                        guard let bytes = try? Data(contentsOf: url) else {
                            attachmentStatus[entry.id] = "Couldn't read \(url.lastPathComponent)."
                            clearStatusLater(entry.id)
                            return
                        }
                        await stage(
                            .init(
                                data: bytes,
                                filename: CommandCenterAttachments.uniqueName(
                                    for: url.lastPathComponent, now: Date())),
                            to: entry, on: surface)
                    }
                }
                continue
            }

            // A drag out of Preview, Photos, or a browser hands over image
            // data with no file behind it, so it gets a name here.
            for identifier in [UTType.png.identifier, UTType.tiff.identifier, UTType.image.identifier]
            where provider.hasItemConformingToTypeIdentifier(identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    let isTIFF = identifier == UTType.tiff.identifier
                    let bytes: Data
                    if isTIFF, let rep = NSBitmapImageRep(data: data),
                       let png = rep.representation(using: .png, properties: [:]) {
                        bytes = png
                    } else {
                        bytes = data
                    }
                    Task { @MainActor in
                        await stage(
                            .init(
                                data: bytes,
                                filename: CommandCenterAttachments.generatedName(
                                    ext: "png", now: Date())),
                            to: entry, on: surface)
                    }
                }
                break
            }
        }
    }

    /// Attach whatever is on the pasteboard, if it is a file or an image.
    /// Returns false when it is ordinary text, which should paste normally.
    private func attachFromPasteboard(to entry: CommandCenterMonitor.Entry) -> Bool {
        guard let surface = entry.surface else { return false }
        let payloads = CommandCenterAttachments.payloads(from: .general)
        guard !payloads.isEmpty else { return false }
        Task { @MainActor in
            for payload in payloads { await stage(payload, to: entry, on: surface) }
        }
        return true
    }

    @MainActor
    private func stage(
        _ payload: CommandCenterAttachments.Payload,
        to entry: CommandCenterMonitor.Entry,
        on surface: Ghostty.SurfaceView
    ) async {
        if surface.remoteHost != nil {
            attachmentStatus[entry.id] = "Copying \(payload.filename) to \(surface.remoteHost ?? "")…"
        }
        let result = await CommandCenterAttachments.stage(payload, for: surface)
        switch result {
        case .success(let path):
            drafts[entry.id] = CommandCenterAttachments.draft(drafts[entry.id] ?? "", appending: path)
            historyIndex[entry.id] = -1
            focusedDraft = entry.id
            attachmentStatus[entry.id] = nil
        case .failure(let error):
            attachmentStatus[entry.id] = error.message
            clearStatusLater(entry.id)
        }
    }

    private func clearStatusLater(_ id: ObjectIdentifier) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { attachmentStatus[id] = nil }
    }

    // MARK: - History

    /// Up walks back through what you have said to this pane, Down comes
    /// forward again — the shell convention, in the box that behaves most like
    /// a prompt. The history merges what trm sent with what the agent recorded,
    /// so a message typed at the pane and one sent from here are the same
    /// history.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 126 = up, 125 = down. Plain presses only: modified arrows still
            // mean selection and word movement.
            guard let id = focusedDraft,
                  let entry = monitor.entries.first(where: { $0.id == id })
            else { return event }

            // ⌘V of a file or an image attaches it; ⌘V of text pastes as
            // usual, which is why this only swallows the event when there was
            // something to attach.
            if event.keyCode == 9,
               event.modifierFlags.contains(.command),
               event.modifierFlags.intersection([.option, .control]).isEmpty,
               attachFromPasteboard(to: entry) {
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌃⌘⇧N: a new remote pane beside this row's pane, in its folder,
            // running its agent — the grid's shortcut, aimed at the row you
            // are on rather than the pane with focus. Focus stays here: the
            // board is where you are working, and the new agent turns up on
            // it as a row of its own.
            if event.keyCode == 45, flags == [.command, .shift, .control],
               let surface = entry.surface,
               let controller = TerminalController.all.first(where: { $0.surfaceTree.contains(surface) }) {
                controller.newRemotePaneHere(from: surface, takeFocus: false)
                return nil
            }

            // ⌘↩ sends from the expanded editor, where Return is a line
            // break. Checked before the relay, which has its own opinion
            // about Return with modifiers.
            if focusedComposerID == id,
               event.keyCode == 36 || event.keyCode == 76,
               flags == .command {
                send(entry)
                return nil
            }

            // Escape closes the editor rather than the panel. One level at a
            // time: a second Escape does whatever it did before.
            if event.keyCode == 53, focusedComposerID == id {
                collapse(entry)
                return nil
            }

            // The terminal beside this box answers ⌘C and ⌘V for the whole
            // window, so without this the reply box could be typed into but
            // never copied from or pasted into.
            if TextFieldKeyRelay.handle(event) { return nil }

            // History walking is for the one-line box. In an editor the
            // arrows have an obvious job — moving through what you are
            // writing — and replacing that with someone else's sentence
            // mid-paragraph would be indefensible.
            guard focusedComposerID != id else { return event }

            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  event.keyCode == 126 || event.keyCode == 125
            else { return event }
            return step(entry, back: event.keyCode == 126) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Move one step through `entry`'s history. Returns false when there is
    /// nowhere to go, so the key press falls through to the text field and
    /// still moves the cursor.
    private func step(_ entry: CommandCenterMonitor.Entry, back: Bool) -> Bool {
        let history = monitor.messageHistory(for: entry)
        guard !history.isEmpty else { return false }
        let current = historyIndex[entry.id] ?? -1

        if back {
            guard current + 1 < history.count else { return false }
            // Whatever is in the box on the way in is kept, so walking all the
            // way back down returns you to it — half-written and all.
            if current < 0 { draftBeforeHistory[entry.id] = drafts[entry.id] ?? "" }
            historyIndex[entry.id] = current + 1
            apply(history[current + 1], to: entry)
            return true
        }

        guard current >= 0 else { return false }
        if current == 0 {
            historyIndex[entry.id] = -1
            apply(draftBeforeHistory[entry.id] ?? "", to: entry)
            draftBeforeHistory[entry.id] = nil
        } else {
            historyIndex[entry.id] = current - 1
            apply(history[current - 1], to: entry)
        }
        return true
    }

    /// Put text in a box without it counting as typing.
    private func apply(_ text: String, to entry: CommandCenterMonitor.Entry) {
        historyEcho[entry.id] = text
        drafts[entry.id] = text
    }

    /// Whether what is in this pane takes a paste whole. Every agent's input
    /// box does; a bare shell prompt does not.
    private func keepsLineBreaks(_ entry: CommandCenterMonitor.Entry) -> Bool {
        guard let surface = entry.surface else { return true }
        return surface.keepsPastedLineBreaks
    }

    private func send(_ entry: CommandCenterMonitor.Entry) {
        let text = (drafts[entry.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let surface = entry.surface else { return }
        onSendToPane?(surface, text)
        apply("", to: entry)
        historyIndex[entry.id] = -1
        draftBeforeHistory[entry.id] = nil
        focusedDraft = entry.id
    }
}
