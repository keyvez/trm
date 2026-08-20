import SwiftUI

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
                    monitor.revealOverview(entry)
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
                .help("Open this pane's Agent Overview")

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

        }
        .contentShape(Rectangle())
        // SwiftUI's tap gestures don't carry modifiers, so the flags are read
        // at the moment of the tap — the pattern TrmGridView already uses for
        // ⌘-click peek.
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                monitor.revealOverview(entry)
            } else {
                monitor.reveal(entry)
            }
        }
        .help("Click to go to this pane · ⌘-click for its Agent Overview · click the box to reply")
        .modifier(CardChrome(
            fixedHeight: fixedHeight,
            composer: onSendToPane == nil ? nil : AnyView(composer(entry))
        ))
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
                    Text(entry.watermark)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(status.color)
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

                Text(monitor.briefings[entry.id] ?? CommandCenterMonitor.firstSentence(of: entry.message))
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
                }
                // Only the reading half navigates. The composer sits outside
                // the gesture so clicking into the box puts a cursor there
                // rather than sending you to the pane mid-thought.
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.command) {
                        monitor.revealOverview(entry)
                    } else {
                        monitor.reveal(entry)
                    }
                }
                .help("Click to go to this pane · ⌘-click for its Agent Overview · click the box to reply")

                // Answering is the whole point of a board you read to decide
                // what needs you: the quickest actions — "yes", "go ahead",
                // "use the other approach" — shouldn't need a trip to the pane.
                // In grid mode the box sits at the tile's foot, so it is in
                // the same place on every tile.
                if fixedHeight != nil { Spacer(minLength: 0) }

                if onSendToPane != nil {
                    composer(entry)
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
    }

    /// Briefing tiles are shorter than detail cards: one sentence, one
    /// escalation line, one reply box.
    private static let briefingTileHeight: CGFloat = 176

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

    private func composer(_ entry: CommandCenterMonitor.Entry) -> some View {
        let binding = Binding(
            get: { drafts[entry.id] ?? "" },
            set: { drafts[entry.id] = $0 }
        )
        return HStack(spacing: 6) {
            TextField("Reply…", text: binding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($focusedDraft, equals: entry.id)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
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
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send(_ entry: CommandCenterMonitor.Entry) {
        let text = (drafts[entry.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let surface = entry.surface else { return }
        onSendToPane?(surface, text)
        drafts[entry.id] = ""
        focusedDraft = entry.id
    }
}
