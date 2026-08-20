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
    /// Local key monitor, live only while a reply box has focus.
    @State private var keyMonitor: Any?

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

    /// Below this, one card per row reads better than a cramped two-up.
    private static let minimumCardWidth: CGFloat = 340

    /// Every card the same height in grid mode. Fixed rather than measured:
    /// "all the same size" is the point, and a height that tracked the
    /// wordiest agent would jump every time any of them spoke.
    private static let gridCardHeight: CGFloat = 260

    var body: some View {
        Group {
            if monitor.entries.isEmpty {
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

    /// One agent's card. `fixedHeight` is set in grid mode, where every card
    /// is the same size and the message truncates to fit rather than the card
    /// growing to hold it.
    private func card(
        _ entry: CommandCenterMonitor.Entry, fixedHeight: CGFloat?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusDot(entry)

                // The watermark is how the pane labels itself on screen, so
                // it's the fastest way to map a row back to a cell.
                Button {
                    monitor.reveal(entry)
                } label: {
                    Text(entry.watermark)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.16))
                        )
                }
                .buttonStyle(.plain)
                .help("Go to this pane")

                Text(entry.kind.displayName)
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
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                monitor.revealOverview(entry)
            } else {
                focusedDraft = entry.id
            }
        }
        // The whole card takes a drop: aiming a dragged screenshot at a
        // reply box a few points tall is a game nobody wants to play.
        .onDrop(of: [.fileURL, .image, .png, .tiff], isTargeted: nil) { providers in
            attach(providers: providers, to: entry)
            return true
        }
        .help("Click to reply · ⌘-click for the Agent Overview · watermark to go to the pane")
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
                    Button {
                        monitor.reveal(entry)
                    } label: {
                        Text(entry.watermark)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(status.color)
                    }
                    .buttonStyle(.plain)
                    .help("Go to this pane")
                    Text(status.label.uppercased())
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(status.color.opacity(0.9))
                    Text(entry.kind.displayName)
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

                // What was done, above the conclusion it led to: read down
                // the bullets to judge whether the sentence is the whole
                // story, or skip them and take the sentence.
                if !briefingBullets(entry).isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(briefingBullets(entry), id: \.self) { bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(bullet)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
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
                    .lineLimit(fixedHeight == nil ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                monitor.revealOverview(entry)
            } else {
                focusedDraft = entry.id
            }
        }
        // The whole card takes a drop: aiming a dragged screenshot at a
        // reply box a few points tall is a game nobody wants to play.
        .onDrop(of: [.fileURL, .image, .png, .tiff], isTargeted: nil) { providers in
            attach(providers: providers, to: entry)
            return true
        }
        .help("Click to reply · ⌘-click for the Agent Overview · watermark to go to the pane")
    }

    /// Briefing tiles: a few bullets, one sentence, one escalation line, and a
    /// reply box twice the height of the detail view's — grown to fit them.
    private static let briefingTileHeight: CGFloat = 254

    /// The headline for a row: the model's sentence when it has answered,
    /// the message's own opening sentence until then.
    private func briefingSentence(_ entry: CommandCenterMonitor.Entry) -> String {
        monitor.briefings[entry.id]?.sentence
            ?? CommandCenterMonitor.firstSentence(of: entry.message)
    }

    /// The lines above it. Falls back to the raw tool calls, which are a
    /// plainer answer to "what did it do" than nothing at all.
    private func briefingBullets(_ entry: CommandCenterMonitor.Entry) -> [String] {
        let summarized = monitor.briefings[entry.id]?.bullets ?? []
        return summarized.isEmpty ? Array(entry.activity.suffix(3)) : summarized
    }

    /// How much of your attention a pane is asking for. Ordered by how much
    /// it costs to ignore.
    struct Status {
        let label: String
        let color: Color
        /// How strongly the row is tinted. Only the states that want action
        /// get a wash; the rest stay quiet so the board reads at a glance.
        let emphasis: Double
    }

    static func status(for entry: CommandCenterMonitor.Entry) -> Status {
        if entry.needsAttention {
            return Status(label: "needs you", color: .orange, emphasis: 0.14)
        }
        if entry.errorCount > 0 {
            return Status(label: "check this", color: .red, emphasis: 0.12)
        }
        if entry.isWorking {
            return Status(label: "working", color: .green, emphasis: 0.05)
        }
        return Status(label: "idle", color: .secondary, emphasis: 0.03)
    }

    /// The one extra line worth showing under the sentence, or nothing.
    static func escalation(for entry: CommandCenterMonitor.Entry) -> String? {
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
        let color: Color = entry.needsAttention ? .orange : (entry.isWorking ? .green : .secondary)
        Circle()
            .fill(color.opacity(entry.isWorking || entry.needsAttention ? 0.9 : 0.35))
            .frame(width: 7, height: 7)
            .help(entry.needsAttention ? "Waiting on you"
                  : (entry.isWorking ? "Working" : "Idle"))
    }

    /// `large` doubles the box for briefing mode, where the row is a
    /// decision to act on and the reply is the action — a one-line field you
    /// have to squint at is the wrong shape for that.
    private func composer(_ entry: CommandCenterMonitor.Entry, large: Bool = false) -> some View {
        let binding = Binding(
            get: { drafts[entry.id] ?? "" },
            set: { newValue in
                // Editing means you have left the history and are writing
                // again; the next Up starts from the newest message.
                if newValue != drafts[entry.id] { historyIndex[entry.id] = -1 }
                drafts[entry.id] = newValue
            }
        )
        return HStack(spacing: 6) {
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
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.accentColor.opacity(focusedDraft == entry.id ? 0.55 : 0))
                )
                .onSubmit { send(entry) }

            Button {
                send(entry)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: large ? 22 : 15))
            }
            .buttonStyle(.plain)
            .disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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

            // The terminal beside this box answers ⌘C and ⌘V for the whole
            // window, so without this the reply box could be typed into but
            // never copied from or pasted into.
            if TextFieldKeyRelay.handle(event) { return nil }

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
            if current < 0 { draftBeforeHistory[entry.id] = drafts[entry.id] ?? "" }
            historyIndex[entry.id] = current + 1
            drafts[entry.id] = history[current + 1]
            return true
        }

        guard current >= 0 else { return false }
        if current == 0 {
            historyIndex[entry.id] = -1
            drafts[entry.id] = draftBeforeHistory[entry.id] ?? ""
        } else {
            historyIndex[entry.id] = current - 1
            drafts[entry.id] = history[current - 1]
        }
        return true
    }

    private func send(_ entry: CommandCenterMonitor.Entry) {
        let text = (drafts[entry.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let surface = entry.surface else { return }
        onSendToPane?(surface, text)
        drafts[entry.id] = ""
        historyIndex[entry.id] = -1
        draftBeforeHistory[entry.id] = ""
        focusedDraft = entry.id
    }
}
