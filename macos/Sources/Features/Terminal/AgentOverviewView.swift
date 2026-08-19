import SwiftUI

/// Native view for the agent overview pane.
///
/// Renders, top to bottom: a header with the bionic toggle, the last prompt
/// the human sent, a live activity strip of tool calls, and the agent's last
/// message with code in its own blocks. Everything below the header scrolls.
///
/// The message area is a reading surface: comfortable type size, generous
/// line spacing, inline markdown (bold/italic/`code`) rendered rather than
/// shown raw, and headings set off from body text.
struct AgentOverviewView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var pane: AgentOverviewPane
    var isPeeked = false
    var onClose: ((AgentOverviewPane) -> Void)? = nil

    /// Whether body text can be selected with the mouse. Off in a grid cell,
    /// where the overview is a preview and a plain click means "peek this" —
    /// selectable text would swallow those clicks. On in the peek overlay,
    /// where reading (and copying arbitrary spans) is the whole point; the
    /// tap-to-copy links and headings work in both modes.
    var allowsTextSelection: Bool = true

    /// Set briefly after a URL is tapped, driving the "Link copied" pill.
    @State private var didCopyLink = false

    // MARK: - Type scale

    /// Every size in the view is expressed through this, so the whole scale
    /// grows and shrinks together rather than only the body text.
    private var activeFontScale: CGFloat {
        isPeeked ? pane.peekFontScale : pane.fontScale
    }
    private var lineSpacingMultiplier: CGFloat { isPeeked ? 1.6 : 1.0 }
    private func scaled(_ size: CGFloat) -> CGFloat { size * activeFontScale }

    private var proseFont: Font {
        .system(size: scaled(13.5), weight: .light, design: pane.fontFamily.design)
    }
    private var proseBoldFont: Font {
        .system(size: scaled(13.5), weight: .medium, design: pane.fontFamily.design)
    }
    private func readingFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight, design: pane.fontFamily.design)
    }
    private var proseLineSpacing: CGFloat {
        4.5 * activeFontScale * lineSpacingMultiplier
    }
    /// A source blank line should occupy roughly one line of vertical space,
    /// just as it does in the terminal. A fixed gap looked acceptable at the
    /// compact default but collapsed visually at the larger peek scale.
    private var paragraphSpacing: CGFloat {
        scaled(13.5) + proseLineSpacing
    }

    var body: some View {
        content
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if !livePendingQuestions.isEmpty {
                liveQuestionBanner
                Divider().opacity(0.5)
            }
            scrollBody
        }
        // Darker than the standard text background: the overview sits beside
        // terminals, and matching their darker ground keeps the eye from
        // treating it as a bright document panel in a dark workspace.
        .background(terminalBackground)
    }

    private var scrollBody: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                    // Deliberately NOT a LazyVStack. A lazy stack inside a
                    // ScrollView has to estimate the height of blocks it has not
                    // built yet, and `ScrollViewUtilities.contentFrame` feeds that
                    // estimate back in as the proposal — with six overview panes
                    // opening at once the estimates never settled and the app
                    // pinned a core (sampled as LazyStack.measureEstimates under
                    // ScrollViewUtilities.contentFrame). An agent message is a
                    // bounded number of blocks, so sizing them eagerly is cheap and
                    // terminates.
                    VStack(alignment: .leading, spacing: 20) {
                    // An empty selection renders nothing, which just looks
                    // broken — fall back to everything.
                    let sections = pane.sections.isEmpty ? .all : pane.sections
                    let errors = pane.displayedTranscript.activity.filter(\.isError)

                    if pane.turnOffset > 0 {
                        earlierTurnBanner
                    }
                    if sections.contains(.errors) {
                        if errors.isEmpty {
                            Text("No failed tool calls in this turn.")
                                .font(.system(size: scaled(12), weight: .light))
                                .foregroundStyle(.secondary)
                        } else {
                            errorSection(errors)
                        }
                    }
                    if sections.contains(.prompt),
                       let prompt = pane.displayedTranscript.lastUserPrompt {
                        promptSection(
                            prompt,
                            blocks: pane.displayedTranscript.promptBlocks
                        )
                    }
                    if sections.contains(.questions),
                       !historicalQuestions.isEmpty {
                        questionSection(historicalQuestions)
                    }
                    if sections.contains(.activity),
                       !pane.displayedTranscript.activity.isEmpty {
                        activitySection
                    }
                    if sections.contains(.reply),
                       !pane.displayedTranscript.blocks.isEmpty {
                        messageSection(pane.displayedTranscript.blocks)
                    }
                    let urls = overviewURLs(in: pane.displayedTranscript)
                    if !urls.isEmpty {
                        overviewLinksSection(urls)
                    }
                    if let status = pane.statusMessage {
                        Text(status)
                            .font(.system(size: scaled(12), weight: .light))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Tapping any link in the overview copies it instead of opening a
            // browser: the overview is a reading surface, and what you want
            // from a URL an agent printed is almost always the URL itself —
            // to paste into a browser profile, a message, or another pane.
            .environment(\.openURL, OpenURLAction { url in
                copyLink(url)
                return .handled
            })

            if didCopyLink {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Link copied")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .padding(.bottom, 10)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
    }

    private func copyLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { didCopyLink = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeOut(duration: 0.25)) { didCopyLink = false }
        }
    }

    /// Always sourced from the live/latest transcript—not the historical turn
    /// the reader may currently be browsing. A question that is blocking the
    /// live agent must remain visible regardless of history or section mode.
    private var livePendingQuestions: [AgentTranscript.Question] {
        pane.transcript.questions.filter { !$0.finished }
    }

    private var historicalQuestions: [AgentTranscript.Question] {
        let pendingIDs = Set(livePendingQuestions.map(\.id))
        return pane.displayedTranscript.questions.filter { !pendingIDs.contains($0.id) }
    }

    private var liveQuestionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(Color.accentColor)
                Text("\(pane.agentKind.displayName) is waiting for your answer")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("Answer in terminal")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            ScrollView {
                questionSection(livePendingQuestions, includeSectionLabel: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: isPeeked ? 360 : 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
    }

    /// Match the bound terminal exactly, including an OSC/runtime palette
    /// background change and configured transparency. Observing the surface in
    /// a small child view makes those changes repaint without waiting for the
    /// overview's transcript polling cycle.
    @ViewBuilder
    private var terminalBackground: some View {
        if let surface = pane.surface {
            AgentOverviewTerminalBackground(surface: surface)
        } else {
            ghostty.config.backgroundColor
                .opacity(ghostty.config.backgroundOpacity)
        }
    }

    /// Failed tool calls, with the first line of each error.
    private func errorSection(_ errors: [AgentTranscript.ToolActivity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            copyableSectionLabel("Errors") {
                errors.map { item in
                    let head = [item.name, item.detail].compactMap { $0 }.joined(separator: " ")
                    return [head, item.errorText].compactMap { $0 }.joined(separator: "\n")
                }.joined(separator: "\n\n")
            }
            ForEach(errors) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text(item.name)
                            .font(.system(size: scaled(11), weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: scaled(11), weight: .light, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let text = item.errorText {
                        Text(text)
                            .font(.system(size: scaled(11), weight: .light, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .overviewSelectable(allowsTextSelection)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // No grab bar here: every pane cell now carries the shared
            // drag/peek bar above its content, so a second handle inside the
            // overview's own header was redundant.
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(pane.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if pane.displayedTranscript.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }

            if let percent = pane.displayedTranscript.contextUsedPercent {
                contextUsagePill(percent)
            }

            Spacer()

            HStack(spacing: 2) {
                Button(action: { pane.showPreviousTurn() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(!pane.canShowPreviousTurn)
                .help("Previous agent turn")

                if let position = pane.turnPositionLabel {
                    Text(position)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                Button(action: { pane.showNextTurn() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(!pane.canShowNextTurn)
                .help("Next agent turn")
            }
            .foregroundStyle(.secondary)

            // What the pane shows. A long session holds far more than fits in
            // a narrow column, and which part matters depends on the moment —
            // catching up, checking the last answer, watching progress, or
            // finding what broke.
            Menu {
                // Independent toggles: the sections are additive, so watching
                // the agent's commands while reading its reply is one
                // selection rather than a choice between two modes.
                ForEach(AgentOverviewSections.allCases, id: \.rawValue) { section in
                    Toggle(isOn: Binding(
                        get: { pane.sections.contains(section) },
                        set: { isOn in
                            var next = pane.sections
                            if isOn { next.insert(section) } else { next.remove(section) }
                            pane.sections = next
                        }
                    )) {
                        Text("\(section.menuTitle) — \(section.menuSubtitle)")
                    }
                }
                Divider()
                Button("Show Everything") { pane.sections = .all }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: pane.sections.symbolName)
                        .font(.system(size: 10))
                    Text(pane.sections.barLabel)
                        .font(.system(size: 10))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose what this overview shows")

            Menu {
                ForEach(AgentOverviewFontFamily.allCases, id: \.rawValue) { family in
                    Button {
                        pane.fontFamily = family
                    } label: {
                        Label(family.menuTitle, systemImage: pane.fontFamily == family
                              ? "checkmark" : family.symbolName)
                    }
                }
            } label: {
                Image(systemName: pane.fontFamily.symbolName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Overview font: \(pane.fontFamily.menuTitle)")

            // Text size. The overview is a reading surface in a column whose
            // width the user controls, so the comfortable size varies — and
            // it's per pane, not global, so a narrow overview and a wide one
            // can differ. Click the percentage to reset.
            HStack(spacing: 2) {
                Button(action: decreaseActiveFontSize) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!canDecreaseActiveFontSize)
                .help(isPeeked ? "Smaller peek text" : "Smaller pane text")

                Button(action: resetActiveFontSize) {
                    Text("\(Int((activeFontScale * 100).rounded()))%")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .help(isPeeked ? "Reset peek text size" : "Reset pane text size")

                Button(action: increaseActiveFontSize) {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!canIncreaseActiveFontSize)
                .help(isPeeked ? "Larger peek text" : "Larger pane text")
            }
            .foregroundStyle(.secondary)

            Button(action: { pane.toggleBionic() }) {
                Text("B")
                    .font(.system(size: 11, weight: .bold, design: .serif))
                    .foregroundStyle(pane.bionicEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pane.bionicEnabled
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help(pane.bionicEnabled ? "Turn off bionic reading" : "Turn on bionic reading")

            Button(action: { pane.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")

            if let onClose {
                Button(action: { onClose(pane) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close agent overview")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // Dragging lives in the shared pane bar above this header now, so the
        // title row is no longer a drag source — two overlapping drag
        // surfaces in the same strip only compete for the same mouse-down.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Sections

    private func increaseActiveFontSize() {
        if isPeeked { pane.increasePeekFontSize() } else { pane.increaseFontSize() }
    }

    private func decreaseActiveFontSize() {
        if isPeeked { pane.decreasePeekFontSize() } else { pane.decreaseFontSize() }
    }

    private func resetActiveFontSize() {
        if isPeeked { pane.resetPeekFontSize() } else { pane.resetFontSize() }
    }

    private var canIncreaseActiveFontSize: Bool {
        isPeeked ? pane.canIncreasePeekFontSize : pane.canIncreaseFontSize
    }

    private var canDecreaseActiveFontSize: Bool {
        isPeeked ? pane.canDecreasePeekFontSize : pane.canDecreaseFontSize
    }

    /// Banner shown while paging through history, with the way back.
    private var earlierTurnBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
            Text("Turn \(pane.turnCount - pane.turnOffset) of \(pane.turnCount)")
                .font(.system(size: scaled(11), weight: .medium))
            Spacer(minLength: 0)
            Button(action: { pane.goToLatestTurn() }) {
                Text("Latest")
                    .font(.system(size: scaled(11), weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private func promptSection(_ prompt: String, blocks promptBlocks: [AgentTranscript.Block]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            copyableSectionLabel("You asked") { prompt }
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                // Blocks give fenced code the same monospaced treatment the
                // reply gets, and show attached images inline; the plain
                // string remains the fallback (and what copy yields).
                VStack(alignment: .leading, spacing: 8) {
                    if promptBlocks.isEmpty {
                        promptText(prompt)
                    } else {
                        ForEach(promptBlocks) { block in
                            switch block {
                            case .paragraph(let text):
                                promptText(text)
                            case .code(let language, let text):
                                codeBlock(language: language, text: text)
                            case .image(let data):
                                inlineImage(data)
                            }
                        }
                    }
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func promptText(_ text: String) -> some View {
        let linked = Self.linkified(AttributedString(text))
        return Group {
            if Self.hasLink(linked) {
                LinkText(
                    text: nsProse(
                        linked,
                        size: scaled(12.5),
                        color: .secondaryLabelColor,
                        lineSpacing: 3
                    ),
                    selectable: allowsTextSelection,
                    onLinkTap: copyLink
                )
            } else {
                Text(linked)
                    .font(.system(size: scaled(12.5)))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .overviewSelectable(allowsTextSelection)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Whether a linkified paragraph actually picked up a link — the switch
    /// between plain `Text` and the NSTextView-backed `LinkText`.
    private static func hasLink(_ attr: AttributedString) -> Bool {
        attr.runs.contains { $0.link != nil }
    }

    /// Convert a linkified paragraph to AppKit attributes for `LinkText`.
    /// SwiftUI-scoped attributes don't survive `NSAttributedString(_:)` —
    /// bionic bold runs carry a SwiftUI `Font`, markdown emphasis carries
    /// presentation intents — so the runs that matter are mapped by hand.
    private func nsProse(
        _ attr: AttributedString,
        size: CGFloat,
        monospaced: Bool = false,
        color: NSColor,
        lineSpacing: CGFloat,
        swiftBoldFont: Font? = nil
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let base = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size)
        let out = NSMutableAttributedString()
        for run in attr.runs {
            var font = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            if intent.contains(.stronglyEmphasized)
                || (swiftBoldFont != nil && run.font == swiftBoldFont) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            // Link color/underline come from the text view's
            // linkTextAttributes, applied over these.
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(
                string: String(attr.characters[run.range]), attributes: attrs
            ))
        }
        return out
    }

    /// An attached image, shown as a bounded inline thumbnail.
    @ViewBuilder
    private func inlineImage(_ data: Data) -> some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
    }

    /// Structured questions are first-class overview content rather than a
    /// generic tool row. The terminal remains the place to answer them, but
    /// the overview must show exactly what the agent is waiting for and every
    /// choice the terminal UI offers.
    private func questionSection(
        _ questions: [AgentTranscript.Question],
        includeSectionLabel: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if includeSectionLabel {
                copyableSectionLabel("\(pane.agentKind.displayName) asked") {
                    questions.map { question in
                        var lines = [question.text]
                        lines.append(contentsOf: question.options.map { option in
                            if let description = option.description {
                                return "- \(option.label): \(description)"
                            }
                            return "- \(option.label)"
                        })
                        if let answer = question.selectedAnswer {
                            lines.append("Selected answer: \(answer)")
                        }
                        return lines.joined(separator: "\n")
                    }.joined(separator: "\n\n")
                }
            }

            ForEach(questions) { question in
                AgentQuestionCard(
                    question: question,
                    fontScale: activeFontScale,
                    lineSpacingMultiplier: lineSpacingMultiplier,
                    fontDesign: pane.fontFamily.design
                )
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            copyableSectionLabel(
                pane.displayedTranscript.isWorking ? "Working on" : "Recent activity"
            ) {
                pane.displayedTranscript.activity
                    .map { [$0.name, $0.detail].compactMap { $0 }.joined(separator: " ") }
                    .joined(separator: "\n")
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(pane.displayedTranscript.activity) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.finished ? "checkmark.circle.fill" : "circle.dotted")
                            .font(.system(size: 9))
                            .foregroundStyle(item.finished
                                             ? Color.green.opacity(0.55)
                                             : Color.accentColor)
                        Text(item.name)
                            .font(.system(size: scaled(11), weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: scaled(11), weight: .light, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
            )
        }
    }

    private func messageSection(_ blocks: [AgentTranscript.Block]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            copyableSectionLabel("\(pane.agentKind.displayName) said") {
                pane.displayedTranscript.blocks.map { block in
                    switch block {
                    case .paragraph(let text): return text
                    case .code(_, let text): return text
                    case .image: return "[image]"
                    }
                }.joined(separator: "\n\n")
            }
            ForEach(pane.displayedTranscript.blocks) { block in
                switch block {
                case .paragraph(let text):
                    paragraphView(text)
                case .code(let language, let text):
                    codeBlock(language: language, text: text)
                case .image(let data):
                    inlineImage(data)
                }
            }
        }
    }

    // MARK: - Prose rendering

    /// A paragraph block may hold several markdown paragraphs (separated by
    /// blank lines) including headings — split so each gets its own styling
    /// and vertical rhythm.
    @ViewBuilder
    private func paragraphView(_ text: String) -> some View {
        let parts = OverviewMarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: paragraphSpacing) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .heading(let level, let text):
                    Text(overviewStyledMarkdown(
                        text,
                        size: scaled(level == 1 ? 17 : (level == 2 ? 15.5 : 14.5)),
                        weight: .medium,
                        design: pane.fontFamily.design
                    ))
                        .foregroundStyle(.primary)
                        .padding(.top, 4)
                        .overviewSelectable(allowsTextSelection)
                case .paragraph(let text):
                    bodyText(text)
                case .bullets(let items, let ordered):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(ordered ? "\(index + 1)." : "•")
                                    .font(readingFont(12))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: scaled(12), alignment: .trailing)
                                bodyText(item)
                            }
                        }
                    }
                case .quote(let text):
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                        bodyText(text)
                    }
                case .rule:
                    Divider().opacity(0.45)
                }
            }
        }
    }

    /// One body paragraph: bionic emphasis when enabled, otherwise inline
    /// markdown (bold, italics, `code`) rendered instead of shown raw.
    @ViewBuilder
    private func bodyText(_ text: String) -> some View {
        let styled = Self.linkified(overviewStyledMarkdown(
            text,
            size: scaled(13.5),
            weight: .light,
            design: pane.fontFamily.design,
            bionic: pane.bionicEnabled
        ))
        Group {
            if Self.hasLink(styled) {
                // NSTextView-backed so the cursor becomes a pointing hand
                // exactly over each link run; the AppKit conversion keeps
                // links, emphasis, and code spans, trading the finer
                // SwiftUI-side markdown tinting.
                LinkText(
                    text: nsProse(
                        styled,
                        size: scaled(13.5),
                        monospaced: pane.fontFamily.design == .monospaced,
                        color: NSColor.labelColor.withAlphaComponent(0.92),
                        lineSpacing: proseLineSpacing,
                        swiftBoldFont: proseBoldFont
                    ),
                    selectable: allowsTextSelection,
                    onLinkTap: copyLink
                )
            } else {
                Text(styled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overviewLinksSection(_ urls: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(urls.count == 1 ? "Link" : "Links")
            OverviewURLActions(urls: urls)
        }
    }

    /// Mark bare URLs as tappable links (styled so they're discoverable);
    /// ranges that already carry a markdown link are left as they are. Taps
    /// route through the view's `openURL` override, which copies rather than
    /// opens — see `scrollBody`.
    static func linkified(_ attr: AttributedString) -> AttributedString {
        var result = attr
        let plain = String(result.characters)
        // Cheap pre-check: NSDataDetector on every paragraph of every poll
        // would be wasted work for the common linkless paragraph.
        guard plain.contains("://") || plain.contains("www.") else { return result }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return result }

        let matches = detector.matches(
            in: plain,
            range: NSRange(plain.startIndex..., in: plain)
        )
        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: plain) else { continue }
            // Map the String range onto the AttributedString by character
            // offset — both views index the same Character sequence.
            let lowerOffset = plain.distance(from: plain.startIndex, to: stringRange.lowerBound)
            let length = plain.distance(from: stringRange.lowerBound, to: stringRange.upperBound)
            guard let lower = result.characters.index(
                result.startIndex, offsetBy: lowerOffset, limitedBy: result.endIndex
            ), let upper = result.characters.index(
                lower, offsetBy: length, limitedBy: result.endIndex
            ) else { continue }
            let range = lower..<upper
            guard result[range].link == nil else { continue }
            result[range].link = url
            result[range].foregroundColor = .accentColor
            result[range].underlineStyle = .single
        }
        return result
    }

    // MARK: - Code

    /// Code renders monospaced in its own tinted block, wrapping to the pane's
    /// width rather than scrolling sideways.
    private func codeBlock(language: String?, text: String) -> some View {
        CopyableOverviewCodeBlock(
            language: language,
            text: text,
            fontSize: scaled(12),
            lineSpacing: 2.5 * lineSpacingMultiplier
        )
    }

    /// Small "N% ctx" pill showing how full the agent's context window is,
    /// stepping through warning colors as it fills.
    private func contextUsagePill(_ percent: Int) -> some View {
        let color: Color = percent >= 80 ? .red : (percent >= 50 ? .orange : .secondary)
        return Text("\(percent)% ctx")
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .help("Agent context window \(percent)% full")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.9)
    }

    /// A section heading that copies that section's text when tapped.
    ///
    /// The overview is a reading surface, and the thing you most often want
    /// from it is the text itself — a prompt to re-run, a command to paste, an
    /// answer to quote. Selecting inside a narrow scrolling column is fiddly,
    /// so the heading doubles as a copy button for the whole section.
    private func copyableSectionLabel(_ text: String, copying content: @escaping () -> String) -> some View {
        CopyableSectionLabel(title: text, content: content) {
            sectionLabel(text)
        }
    }
}

/// A live projection of the terminal renderer's effective background.
private struct AgentOverviewTerminalBackground: View {
    @ObservedObject var surface: Ghostty.SurfaceView

    var body: some View {
        let color = surface.backgroundColor ?? surface.derivedConfig.backgroundColor
        color.opacity(surface.derivedConfig.backgroundOpacity)
    }
}

/// A fenced block in the agent reply is an independent copy target. Keeping
/// confirmation state here ensures only the tapped block flashes a checkmark.
private struct CopyableOverviewCodeBlock: View {
    let language: String?
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .tracking(0.8)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }

            // Wrapping is intentional. A horizontal ScrollView nested inside
            // the overview's vertical one previously created a non-converging
            // width negotiation during window restore.
            Text(text)
                .font(.system(size: fontSize, weight: .light, design: .monospaced))
                .lineSpacing(lineSpacing)
                .foregroundStyle(.primary.opacity(0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .padding(.top, language == nil ? 9 : 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .topTrailing) {
            if isHovering || didCopy {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    .padding(7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { copy() }
        .help("Copy code block")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }
}

/// Kept outside `AgentOverviewView` to give Swift's release-mode type checker
/// a firm boundary. The overview already contains several deeply nested
/// SwiftUI sections; inlining another conditional card made whole-module
/// compilation exhaust the type-checking expression.
private struct AgentQuestionCard: View {
    let question: AgentTranscript.Question
    let fontScale: CGFloat
    let lineSpacingMultiplier: CGFloat
    let fontDesign: Font.Design

    private func scaled(_ size: CGFloat) -> CGFloat { size * fontScale }
    private func readingFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight, design: fontDesign)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: question.finished
                      ? "checkmark.bubble.fill"
                      : "questionmark.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(question.finished ? Color.green : Color.accentColor)

                if let header = question.header {
                    Text(header)
                        .font(readingFont(10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(question.finished
                     ? "Answered"
                     : (question.allowsMultiple ? "Choose one or more" : "Choose one"))
                    .font(readingFont(9, weight: .medium))
                    .foregroundStyle(question.finished ? Color.green : Color.accentColor)
            }

            Text(overviewStyledMarkdown(
                question.text,
                size: scaled(13),
                weight: .light,
                design: fontDesign
            ))
                .foregroundStyle(.primary)
                .lineSpacing(3 * lineSpacingMultiplier)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let answer = question.selectedAnswer {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SELECTED ANSWER")
                        .font(.system(size: scaled(8.5), weight: .medium))
                        .foregroundStyle(Color.green.opacity(0.85))
                        .tracking(0.8)
                    Text(overviewStyledMarkdown(
                        answer,
                        size: scaled(12),
                        weight: .light,
                        design: fontDesign
                    ))
                        .foregroundStyle(.primary)
                        .lineSpacing(2.5 * lineSpacingMultiplier)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.green.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.25))
                        .allowsHitTesting(false)
                )
            }

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(question.options) { option in
                        AgentQuestionOptionRow(
                            option: option,
                            allowsMultiple: question.allowsMultiple,
                            isSelected: optionIsSelected(option),
                            fontScale: fontScale,
                            lineSpacingMultiplier: lineSpacingMultiplier,
                            fontDesign: fontDesign
                        )
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.07))
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(question.finished ? 0.06 : 0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(question.finished ? 0.18 : 0.35))
                .allowsHitTesting(false)
        )
    }

    private func optionIsSelected(_ option: AgentTranscript.Question.Option) -> Bool {
        guard let answer = question.selectedAnswer else { return false }
        if answer == option.label { return true }
        guard question.allowsMultiple else { return false }
        return answer.localizedCaseInsensitiveContains(option.label)
    }
}

private struct AgentQuestionOptionRow: View {
    let option: AgentTranscript.Question.Option
    let allowsMultiple: Bool
    let isSelected: Bool
    let fontScale: CGFloat
    let lineSpacingMultiplier: CGFloat
    let fontDesign: Font.Design

    private func scaled(_ size: CGFloat) -> CGFloat { size * fontScale }
    private func readingFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight, design: fontDesign)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected
                  ? (allowsMultiple ? "checkmark.square.fill" : "checkmark.circle.fill")
                  : (allowsMultiple ? "square" : "circle"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isSelected ? Color.green : Color.accentColor.opacity(0.8))
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(overviewStyledMarkdown(
                    option.label,
                    size: scaled(11.5),
                    weight: .medium,
                    design: fontDesign
                ))
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let description = option.description {
                    Text(overviewStyledMarkdown(
                        description,
                        size: scaled(10.5),
                        weight: .light,
                        design: fontDesign
                    ))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2 * lineSpacingMultiplier)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isSelected ? 6 : 0)
        .padding(.vertical, isSelected ? 5 : 0)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.green.opacity(0.08) : Color.clear)
        )
    }
}

/// Render overview prose as inline Markdown, falling back to literal text for
/// malformed input. Preserving whitespace keeps line breaks and list markers
/// intact while SwiftUI applies emphasis, links, strikethrough, and inline-code
/// styling. Shared by agent replies and structured question cards so Markdown
/// never leaks through as raw punctuation in one section but not another.
private func overviewStyledMarkdown(
    _ text: String,
    size: CGFloat,
    weight: Font.Weight,
    design: Font.Design,
    bionic: Bool = false
) -> AttributedString {
    var result = (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)

    let normalFont = Font.system(size: size, weight: weight, design: design)
    let strongFont = Font.system(size: size, weight: .semibold, design: design)
    let emphasisFont = Font.system(size: size, weight: weight, design: design).italic()
    let strongEmphasisFont = Font.system(size: size, weight: .semibold, design: design).italic()
    let codeFont = Font.system(size: size * 0.96, weight: .regular, design: .monospaced)
    let codeColor = Color(red: 0.66, green: 0.65, blue: 1.0)

    result.font = normalFont
    let runs = Array(result.runs)
    for run in runs {
        let intents = run.inlinePresentationIntent ?? []
        let isCode = intents.contains(.code)
        let isStrong = intents.contains(.stronglyEmphasized)
        let isEmphasis = intents.contains(.emphasized)

        if isCode {
            result[run.range].font = codeFont
            result[run.range].foregroundColor = codeColor
            result[run.range].backgroundColor = Color(red: 0.42, green: 0.40, blue: 0.75).opacity(0.13)
        } else if isStrong && isEmphasis {
            result[run.range].font = strongEmphasisFont
        } else if isStrong {
            result[run.range].font = strongFont
            result[run.range].foregroundColor = Color.primary
        } else if isEmphasis {
            result[run.range].font = emphasisFont
            result[run.range].foregroundColor = Color.primary.opacity(0.92)
        } else if bionic {
            applyBionicEmphasis(
                to: &result,
                in: run.range,
                font: normalFont,
                boldFont: strongFont
            )
        }

        if run.link != nil {
            result[run.range].foregroundColor = Color.accentColor
            result[run.range].underlineStyle = .single
        }
    }
    return result
}

/// Apply bionic word-prefix emphasis without flattening Markdown runs. Inline
/// code, strong/emphasis, links, and strikethrough retain their own semantic
/// attributes; this only changes the font of otherwise plain word prefixes.
private func applyBionicEmphasis(
    to text: inout AttributedString,
    in range: Range<AttributedString.Index>,
    font: Font,
    boldFont: Font
) {
    let characters = text.characters
    var cursor = range.lowerBound

    while cursor < range.upperBound {
        while cursor < range.upperBound, characters[cursor].isWhitespace {
            cursor = characters.index(after: cursor)
        }
        guard cursor < range.upperBound else { break }

        let tokenStart = cursor
        while cursor < range.upperBound, !characters[cursor].isWhitespace {
            cursor = characters.index(after: cursor)
        }
        let tokenEnd = cursor
        let token = Array(characters[tokenStart..<tokenEnd])
        guard let firstCore = token.firstIndex(where: { $0.isLetter || $0.isNumber }) else {
            text[tokenStart..<tokenEnd].font = font
            continue
        }
        var coreEnd = token.count
        while coreEnd > firstCore,
              !token[coreEnd - 1].isLetter,
              !token[coreEnd - 1].isNumber {
            coreEnd -= 1
        }
        let boldCount = BionicText.boldPrefixLength(for: coreEnd - firstCore)
        var boldEnd = tokenStart
        for _ in 0..<(firstCore + boldCount) {
            boldEnd = characters.index(after: boldEnd)
        }
        text[tokenStart..<boldEnd].font = boldFont
        if boldEnd < tokenEnd { text[boldEnd..<tokenEnd].font = font }
    }
}

/// Block-level Markdown that SwiftUI's inline AttributedString parser does
/// not lay out on its own. Fenced code is split earlier by the transcript
/// reader; this handles the reading structures that remain in prose.
private enum OverviewMarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets(items: [String], ordered: Bool)
    case quote(String)
    case rule

    static func parse(_ source: String) -> [Self] {
        var result: [Self] = []
        var paragraph: [String] = []
        var list: [String] = []
        var listIsOrdered: Bool?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        func flushList() {
            guard let ordered = listIsOrdered, !list.isEmpty else { return }
            result.append(.bullets(items: list, ordered: ordered))
            list.removeAll()
            listIsOrdered = nil
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushList()
                continue
            }

            if let heading = heading(line) {
                flushParagraph()
                flushList()
                result.append(.heading(level: heading.0, text: heading.1))
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                flushList()
                result.append(.rule)
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                flushList()
                result.append(.quote(String(line.dropFirst(2))))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                if let current = listIsOrdered, current != item.0 { flushList() }
                listIsOrdered = item.0
                list.append(item.1)
                continue
            }

            flushList()
            paragraph.append(line)
        }

        flushParagraph()
        flushList()
        return result
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let marks = line.prefix { $0 == "#" }
        guard !marks.isEmpty, marks.count <= 6 else { return nil }
        let rest = line.dropFirst(marks.count)
        guard rest.first == " " else { return nil }
        return (marks.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (Bool, String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            var text = String(line.dropFirst(2))
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
            if text.lowercased().hasPrefix("[x] ") { text = "✓ " + text.dropFirst(4) }
            return (false, text)
        }

        guard let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }) else {
            return nil
        }
        let number = line[..<separator]
        let after = line.index(after: separator)
        guard !number.isEmpty,
              number.allSatisfy(\.isNumber),
              after < line.endIndex,
              line[after] == " " else { return nil }
        return (true, String(line[line.index(after: after)...]))
    }
}

/// Pull every HTTP(S) destination out of the visible turn, including bare
/// URLs and Markdown link destinations. The dedicated rows make each URL a
/// reliable click/copy/Command-hover target even when it is embedded in a
/// long selectable paragraph.
private func overviewURLs(in transcript: AgentTranscript) -> [URL] {
    var pieces: [String] = []
    if let prompt = transcript.lastUserPrompt { pieces.append(prompt) }
    for block in transcript.blocks {
        switch block {
        case .paragraph(let text), .code(_, let text): pieces.append(text)
        case .image: break
        }
    }
    pieces.append(contentsOf: transcript.activity.compactMap(\.detail))
    for question in transcript.questions {
        pieces.append(question.text)
        pieces.append(contentsOf: question.options.flatMap { [$0.label, $0.description].compactMap { $0 } })
        if let answer = question.selectedAnswer { pieces.append(answer) }
    }

    guard let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    ) else { return [] }

    var seen = Set<String>()
    var result: [URL] = []
    for piece in pieces {
        let range = NSRange(piece.startIndex..<piece.endIndex, in: piece)
        detector.enumerateMatches(in: piece, range: range) { match, _, _ in
            guard let url = match?.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  seen.insert(url.absoluteString).inserted else { return }
            result.append(url)
        }
    }
    return result
}

private struct OverviewURLActions: View {
    let urls: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(urls, id: \.absoluteString) { url in
                HStack(spacing: 6) {
                    Button {
                        NotificationCenter.default.post(
                            name: .ghosttyOpenURLInPane,
                            object: nil,
                            userInfo: [Notification.Name.OpenURLInPaneURLKey: url]
                        )
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "link")
                                .font(.system(size: 9, weight: .medium))
                            Text(url.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Button { copy(url) } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Copy URL")
                }
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onHover { hovering in
                    var info: [String: Any] = [:]
                    if hovering { info["url"] = url.absoluteString }
                    NotificationCenter.default.post(
                        name: Trm.hoveredURLDidChange,
                        object: nil,
                        userInfo: info
                    )
                }
                .help("Open URL · Hold Command to preview")
            }
        }
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// Section heading that copies its section on tap, confirming in place.
private struct CopyableSectionLabel<Label: View>: View {
    let title: String
    let content: () -> String
    @ViewBuilder let label: () -> Label

    @State private var didCopy = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            label()
            // The affordance only appears on hover so the heading stays quiet
            // while reading; the confirmation stays visible briefly after.
            if isHovering || didCopy {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8, weight: .semibold))
                    // Two concrete Colors: mixing `.tertiary` (a ShapeStyle)
                    // into a ternary makes the branches disagree on type.
                    .foregroundStyle(didCopy ? Color.accentColor : Color.secondary.opacity(0.6))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { copy() }
        .help("Copy \(title.lowercased())")
    }

    private func copy() {
        let text = content()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }
}

// MARK: - Drag support

/// The overview drag currently in flight, if any.
///
/// The SwiftUI drop delegate needs to know synchronously — during hover, not
/// just at drop time — which overview is being dragged and which terminal pane
/// it is bound to, so it can highlight only the valid target. Pasteboard data
/// can only be read at drop time, hence this side channel set by the drag
/// source for the drag's duration.
@MainActor
enum AgentOverviewDragContext {
    struct Drag {
        let overviewUUID: UUID
        let boundSurfaceID: ObjectIdentifier
        /// The overview's own cell. Dropping an overview back onto itself is
        /// the natural way to pick a different side, so its own cell is a
        /// valid target too — not only its terminal's.
        let overviewPaneID: ObjectIdentifier
    }

    static var current: Drag? = nil
}


private extension View {
    /// `.textSelection` takes its selectability statically, so a runtime
    /// flag needs a branch.
    @ViewBuilder
    func overviewSelectable(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}
