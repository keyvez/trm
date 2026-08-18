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
    @ObservedObject var pane: AgentOverviewPane
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
    private func scaled(_ size: CGFloat) -> CGFloat { size * pane.fontScale }

    private var proseFont: Font { .system(size: scaled(13.5)) }
    private var proseBoldFont: Font { .system(size: scaled(13.5), weight: .bold) }
    private var proseLineSpacing: CGFloat { 4.5 * pane.fontScale }

    var body: some View {
        content
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            scrollBody
        }
        // Darker than the standard text background: the overview sits beside
        // terminals, and matching their darker ground keeps the eye from
        // treating it as a bright document panel in a dark workspace.
        .background(Self.paneBackground)
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
                    // When browsing history, every section renders the
                    // archived turn; live (offset 0) renders the transcript's
                    // top-level fields.
                    let viewed = pane.displayedTurn
                    let prompt = viewed?.prompt ?? pane.transcript.lastUserPrompt
                    let promptBlocks = viewed?.promptBlocks ?? pane.transcript.promptBlocks
                    let activity = viewed?.activity ?? pane.transcript.activity
                    let blocks = viewed?.blocks ?? pane.transcript.blocks
                    let errors = activity.filter(\.isError)

                    if pane.turnOffset > 0 {
                        earlierTurnBanner
                    }
                    if sections.contains(.errors) {
                        if errors.isEmpty {
                            Text("No failed tool calls in this turn.")
                                .font(.system(size: scaled(12)))
                                .foregroundStyle(.secondary)
                        } else {
                            errorSection(errors)
                        }
                    }
                    if sections.contains(.prompt),
                       let prompt {
                        promptSection(prompt, blocks: promptBlocks)
                    }
                    if sections.contains(.activity),
                       !activity.isEmpty {
                        activitySection(activity)
                    }
                    if sections.contains(.reply),
                       !blocks.isEmpty {
                        messageSection(blocks)
                    }
                    if let status = pane.statusMessage {
                        Text(status)
                            .font(.system(size: scaled(12)))
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

    /// The overview's ground colour — a dark slate that reads as part of the
    /// terminal grid rather than as a light document surface.
    private static let paneBackground = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.09, alpha: 1.0)
                : NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1.0)
        }
    )

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
                            .font(.system(size: scaled(11), weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: scaled(11), design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let text = item.errorText {
                        Text(text)
                            .font(.system(size: scaled(11), design: .monospaced))
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

            if pane.transcript.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }

            if let percent = pane.transcript.contextUsedPercent {
                contextUsagePill(percent)
            }

            Spacer()

            // Turn navigation: page back through the session's earlier
            // prompts and replies. Hidden until there is history to visit.
            if pane.turnCount > 1 || pane.turnOffset > 0 {
                HStack(spacing: 2) {
                    Button(action: { pane.goToOlderTurn() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(pane.canGoOlderTurn ? 1 : 0.3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!pane.canGoOlderTurn)
                    .help("Previous turn")

                    if pane.turnOffset > 0 {
                        Button(action: { pane.goToLatestTurn() }) {
                            Text("\(pane.turnCount - pane.turnOffset)/\(pane.turnCount)")
                                .font(.system(size: 9, weight: .medium))
                                .monospacedDigit()
                        }
                        .buttonStyle(.plain)
                        .help("Back to latest turn")
                    }

                    Button(action: { pane.goToNewerTurn() }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(pane.canGoNewerTurn ? 1 : 0.3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!pane.canGoNewerTurn)
                    .help("Next turn")
                }
                .foregroundStyle(pane.turnOffset > 0 ? Color.accentColor : Color.secondary)
            }

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

            // Text size. The overview is a reading surface in a column whose
            // width the user controls, so the comfortable size varies — and
            // it's per pane, not global, so a narrow overview and a wide one
            // can differ. Click the percentage to reset.
            HStack(spacing: 2) {
                Button(action: { pane.decreaseFontSize() }) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!pane.canDecreaseFontSize)
                .help("Smaller text")

                Button(action: { pane.resetFontSize() }) {
                    Text("\(Int((pane.fontScale * 100).rounded()))%")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .help("Reset text size")

                Button(action: { pane.increaseFontSize() }) {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!pane.canIncreaseFontSize)
                .help("Larger text")
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

    private func activitySection(_ activity: [AgentTranscript.ToolActivity]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            copyableSectionLabel(
                pane.turnOffset == 0 && pane.transcript.isWorking
                    ? "Working on" : "Recent activity"
            ) {
                activity
                    .map { [$0.name, $0.detail].compactMap { $0 }.joined(separator: " ") }
                    .joined(separator: "\n")
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(activity) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.finished ? "checkmark.circle.fill" : "circle.dotted")
                            .font(.system(size: 9))
                            .foregroundStyle(item.finished
                                             ? Color.green.opacity(0.55)
                                             : Color.accentColor)
                        Text(item.name)
                            .font(.system(size: scaled(11), weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: scaled(11), design: .monospaced))
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
                blocks.map { block in
                    switch block {
                    case .paragraph(let text): return text
                    case .code(_, let text): return text
                    case .image: return "[image]"
                    }
                }.joined(separator: "\n\n")
            }
            ForEach(blocks) { block in
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
        let parts = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if let heading = headingText(part) {
                    Text(heading)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 4)
                        .overviewSelectable(allowsTextSelection)
                } else {
                    bodyText(part)
                }
            }
        }
    }

    /// One body paragraph: bionic emphasis when enabled, otherwise inline
    /// markdown (bold, italics, `code`) rendered instead of shown raw.
    @ViewBuilder
    private func bodyText(_ text: String) -> some View {
        let linked = pane.bionicEnabled
            ? Self.linkified(BionicText.attributed(text, font: proseFont, boldFont: proseBoldFont))
            : Self.linkified(inlineMarkdown(text))
        Group {
            if Self.hasLink(linked) {
                LinkText(
                    text: nsProse(
                        linked,
                        size: scaled(13.5),
                        color: NSColor.labelColor.withAlphaComponent(0.92),
                        lineSpacing: proseLineSpacing,
                        swiftBoldFont: proseBoldFont
                    ),
                    selectable: allowsTextSelection,
                    onLinkTap: copyLink
                )
            } else if pane.bionicEnabled {
                Text(linked)
                    .lineSpacing(proseLineSpacing)
                    .foregroundStyle(.primary.opacity(0.92))
                    .overviewSelectable(allowsTextSelection)
            } else {
                Text(linked)
                    .font(proseFont)
                    .lineSpacing(proseLineSpacing)
                    .foregroundStyle(.primary.opacity(0.92))
                    .overviewSelectable(allowsTextSelection)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `# Heading` → heading text, or nil for body paragraphs.
    private func headingText(_ part: String) -> String? {
        guard part.hasPrefix("#") else { return nil }
        let stripped = part.drop { $0 == "#" }
        guard stripped.first == " " else { return nil }
        // Only single-line paragraphs are headings.
        guard !stripped.contains("\n") else { return nil }
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    /// Render inline markdown, falling back to the raw text when parsing
    /// fails. Whitespace (line breaks within a paragraph, list indents) is
    /// preserved — full markdown block parsing would collapse it.
    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
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
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .tracking(0.8)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            // Code wraps instead of scrolling sideways.
            //
            // This block previously put the text in a horizontal ScrollView so
            // long lines would not widen the pane. Nested inside the overview's
            // own vertical ScrollView that never settles: a horizontal scroll
            // view answers with its *ideal* (unbounded) width, the enclosing
            // `.frame(maxWidth: .infinity)` answers with the parent's, and each
            // answer invalidates the other. A GeometryReader around it does not
            // help — it only moves the same negotiation up a level, and a
            // window of overview panes still pinned a core from launch.
            //
            // Wrapping removes the cycle outright: the text accepts the width
            // it is offered and reports only a height, so the proposal flows
            // one way. `fixedSize(vertical:)` lets it grow downward for the
            // wrapped lines rather than being clipped to one.
            let linked = Self.linkified(AttributedString(text))
            Group {
                if Self.hasLink(linked) {
                    LinkText(
                        text: nsProse(
                            linked,
                            size: scaled(12),
                            monospaced: true,
                            color: NSColor.labelColor.withAlphaComponent(0.88),
                            lineSpacing: 2.5
                        ),
                        selectable: allowsTextSelection,
                        onLinkTap: copyLink
                    )
                } else {
                    Text(linked)
                        .font(.system(size: scaled(12), design: .monospaced))
                        .lineSpacing(2.5)
                        .foregroundStyle(.primary.opacity(0.88))
                        .overviewSelectable(allowsTextSelection)
                }
            }
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
