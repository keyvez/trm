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

    private var proseFont: Font { .system(size: 13.5) }
    private var proseBoldFont: Font { .system(size: 13.5, weight: .bold) }
    private let proseLineSpacing: CGFloat = 4.5

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let prompt = pane.transcript.lastUserPrompt {
                        promptSection(prompt)
                    }
                    if !pane.transcript.activity.isEmpty {
                        activitySection
                    }
                    if !pane.transcript.blocks.isEmpty {
                        messageSection
                    }
                    if let status = pane.statusMessage {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // Grab bar: drag onto the bound terminal pane to re-place the
            // overview left/right/above/below it.
            AgentOverviewDragBar(pane: pane)
                .frame(width: 26, height: 16)
                .overlay(
                    Image(systemName: "dot.grid.2x3.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                )
                .help("Drag onto this overview's terminal pane to move it (left, right, above, below)")

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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Sections

    private func promptSection(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("You asked")
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                Text(prompt)
                    .font(.system(size: 12.5))
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
            sectionLabel(pane.transcript.isWorking ? "Working on" : "Recent activity")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(pane.transcript.activity) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.finished ? "checkmark.circle.fill" : "circle.dotted")
                            .font(.system(size: 9))
                            .foregroundStyle(item.finished
                                             ? Color.green.opacity(0.55)
                                             : Color.accentColor)
                        Text(item.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
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
            sectionLabel("\(pane.agentKind.displayName) said")
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
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2.5)
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
                    .padding(.top, language == nil ? 9 : 2)
            }
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
    }

    static var current: Drag? = nil
}

/// A grab bar for the agent overview pane, shown in its header.
///
/// Starts an `NSDraggingSession` carrying the overview's UUID under the
/// `trmAgentOverviewId` pasteboard type. Dropping on the overview's own
/// terminal pane repositions it (left/right/above/below); anywhere else the
/// drag simply ends and the overview stays where it was.
struct AgentOverviewDragBar: NSViewRepresentable {
    let pane: AgentOverviewPane

    func makeNSView(context: Context) -> OverviewDragBarNSView {
        let view = OverviewDragBarNSView()
        view.pane = pane
        return view
    }

    func updateNSView(_ nsView: OverviewDragBarNSView, context: Context) {
        nsView.pane = pane
    }
}

final class OverviewDragBarNSView: NSView, NSDraggingSource {
    weak var pane: AgentOverviewPane?
    private var dragStart: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pane, let start = dragStart else { return }
        let location = convert(event.locationInWindow, from: nil)
        let dx = location.x - start.x, dy = location.y - start.y
        guard dx * dx + dy * dy > 9 else { return }
        dragStart = nil

        guard let surface = pane.surface else { return }

        let item = NSPasteboardItem()
        var uuid = pane.id.uuid
        let data = withUnsafeBytes(of: &uuid) { Data($0) }
        item.setData(data, forType: .trmAgentOverviewId)

        let draggingItem = NSDraggingItem(pasteboardWriter: item)

        // A small translucent card as the drag image — the overview itself is
        // large and text-heavy, and the placement targets matter more than a
        // faithful preview.
        let size = NSSize(width: 120, height: 72)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        image.unlockFocus()

        let mouse = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2,
                   width: size.width, height: size.height),
            contents: image
        )

        AgentOverviewDragContext.current = .init(
            overviewUUID: pane.id,
            boundSurfaceID: ObjectIdentifier(surface)
        )

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        AgentOverviewDragContext.current = nil
    }
}
