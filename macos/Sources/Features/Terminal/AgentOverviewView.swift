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

    // MARK: - Type scale

    /// Every size in the view is expressed through this, so the whole scale
    /// grows and shrinks together rather than only the body text.
    private func scaled(_ size: CGFloat) -> CGFloat { size * pane.fontScale }

    private var proseFont: Font { .system(size: scaled(13.5)) }
    private var proseBoldFont: Font { .system(size: scaled(13.5), weight: .bold) }
    private var proseLineSpacing: CGFloat { 4.5 * pane.fontScale }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                // Lazy so a long message only lays out the blocks actually on
                // screen. A plain VStack sized every block up front, which a
                // window full of overview panes pays for all at once on
                // restore.
                LazyVStack(alignment: .leading, spacing: 20) {
                    // An empty selection renders nothing, which just looks
                    // broken — fall back to everything.
                    let sections = pane.sections.isEmpty ? .all : pane.sections
                    let errors = pane.transcript.activity.filter(\.isError)

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
                       let prompt = pane.transcript.lastUserPrompt {
                        promptSection(prompt)
                    }
                    if sections.contains(.activity),
                       !pane.transcript.activity.isEmpty {
                        activitySection
                    }
                    if sections.contains(.reply),
                       !pane.transcript.blocks.isEmpty {
                        messageSection
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
        }
        // Darker than the standard text background: the overview sits beside
        // terminals, and matching their darker ground keeps the eye from
        // treating it as a bright document panel in a dark workspace.
        .background(Self.paneBackground)
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
                            .textSelection(.enabled)
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

    private func promptSection(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            copyableSectionLabel("You asked") { prompt }
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                Text(prompt)
                    .font(.system(size: scaled(12.5)))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            copyableSectionLabel(
                pane.transcript.isWorking ? "Working on" : "Recent activity"
            ) {
                pane.transcript.activity
                    .map { [$0.name, $0.detail].compactMap { $0 }.joined(separator: " ") }
                    .joined(separator: "\n")
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(pane.transcript.activity) { item in
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

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            copyableSectionLabel("\(pane.agentKind.displayName) said") {
                pane.transcript.blocks.map { block in
                    switch block {
                    case .paragraph(let text): return text
                    case .code(_, let text): return text
                    }
                }.joined(separator: "\n\n")
            }
            ForEach(pane.transcript.blocks) { block in
                switch block {
                case .paragraph(let text):
                    paragraphView(text)
                case .code(let language, let text):
                    codeBlock(language: language, text: text)
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
                        .textSelection(.enabled)
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
        Group {
            if pane.bionicEnabled {
                Text(BionicText.attributed(text, font: proseFont, boldFont: proseBoldFont))
            } else {
                Text(inlineMarkdown(text))
                    .font(proseFont)
            }
        }
        .lineSpacing(proseLineSpacing)
        .foregroundStyle(.primary.opacity(0.92))
        .textSelection(.enabled)
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

    // MARK: - Code

    /// Height of a code block's scrolling area.
    ///
    /// A GeometryReader fills whatever it is offered vertically instead of
    /// sizing to its content, so the block needs a definite height. Deriving it
    /// from the line count keeps the block exactly as tall as its code, which
    /// is what the previous self-sizing layout produced.
    private func codeBlockHeight(_ text: String) -> CGFloat {
        let lines = text.components(separatedBy: "\n").count
        let lineHeight = scaled(12) * 1.2 + 2.5
        // Cap tall blocks so one long listing can't push everything else out
        // of view; the block scrolls vertically with the message when clipped.
        let contentHeight = min(CGFloat(lines), 40) * lineHeight
        return contentHeight + 18
    }

    /// Code renders monospaced in its own tinted block. It scrolls horizontally
    /// on its own so a long line never widens the whole pane.
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
            // The width here must come from the parent and nothing else.
            //
            // A horizontal ScrollView reports its *ideal* (unbounded) width to
            // its parent, while the `.frame(maxWidth: .infinity)` below wants
            // the parent's width — each answer changed the other's proposal, so
            // SwiftUI's layout never reached a fixed point. With several
            // overview panes on screen it re-ran sizing every frame and pinned
            // a core at 100% (visible in a sample as ScrollViewLayoutComputer →
            // sizeChildrenIdeally → TextLayoutEngine, with ViewSizeCache
            // missing every time).
            //
            // Reading the available width from the enclosing geometry and
            // pinning the scroll view to it breaks the cycle: the proposal now
            // flows one way, parent to child. The long-line behaviour the block
            // is here for is unchanged — the text still scrolls inside this
            // fixed width instead of widening the pane.
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: scaled(12), design: .monospaced))
                        .lineSpacing(2.5)
                        .foregroundStyle(.primary.opacity(0.88))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 9)
                        .padding(.top, language == nil ? 9 : 2)
                }
                .frame(width: geo.size.width)
            }
            .frame(height: codeBlockHeight(text))
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

