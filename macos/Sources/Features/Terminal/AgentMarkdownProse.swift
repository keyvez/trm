import SwiftUI

/// An agent's message, laid out as the markdown it is.
///
/// The Overview has had this for a while, but its renderer is wound through
/// the pane it belongs to — the speaker that marks the sentence being read,
/// the bionic setting, the per-pane type scale. Anywhere else that shows what
/// an agent said had a plain `Text` and got raw `**markers**` and code without
/// a code block. This is the same parse and the same inline styling with none
/// of the pane: headings look like headings, lists like lists, and fenced code
/// arrives in the block that copies when you click it.
struct AgentMarkdownProse: View {
    let blocks: [AgentTranscript.Block]
    var fontSize: CGFloat = 12
    var design: Font.Design = .default
    var allowsSelection: Bool = true
    /// Gap between top-level blocks. Paragraphs inside one block get a gap of
    /// roughly a line, the way a blank line reads in the source.
    var spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(let text):
                    prose(text)
                case .code(let language, let text):
                    CopyableOverviewCodeBlock(
                        language: language,
                        text: text,
                        fontSize: fontSize,
                        lineSpacing: 2.5)
                case .image(let data):
                    image(data)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One paragraph block, which may hold several markdown blocks: a heading
    /// and the list under it arrive as one string.
    private func prose(_ text: String) -> some View {
        let parts = OverviewMarkdownBlock.parse(text)
        return VStack(alignment: .leading, spacing: fontSize + 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                markdownBlock(part)
            }
        }
    }

    @ViewBuilder
    private func markdownBlock(_ part: OverviewMarkdownBlock) -> some View {
        switch part {
        case .heading(let level, let text):
            styled(
                text,
                size: level == 1 ? fontSize + 4 : (level == 2 ? fontSize + 2.5 : fontSize + 1.5),
                weight: .medium)
                .foregroundStyle(.primary)
                .padding(.top, 2)
        case .paragraph(let text):
            styled(text, size: fontSize, weight: .regular)
                .foregroundStyle(.primary.opacity(0.92))
        case .bullets(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: fontSize, design: design))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 12, alignment: .trailing)
                        styled(item, size: fontSize, weight: .regular)
                            .foregroundStyle(.primary.opacity(0.92))
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                styled(text, size: fontSize, weight: .regular)
                    .foregroundStyle(.secondary)
            }
        case .rule:
            Divider().opacity(0.45)
        case .table(let headers, let rows):
            table(headers: headers, rows: rows)
        }
    }

    private func styled(
        _ text: String, size: CGFloat, weight: Font.Weight
    ) -> some View {
        Text(overviewStyledMarkdown(text, size: size, weight: weight, design: design))
            .lineSpacing(2.5)
            .overviewSelectable(allowsSelection)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(headers: [String], rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                    Text(overviewStyledMarkdown(
                        cell, size: fontSize, weight: .semibold, design: design))
                        .fixedSize(horizontal: false, vertical: true)
                        .gridColumnAlignment(.leading)
                }
            }
            Divider().opacity(0.5)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(overviewStyledMarkdown(
                            cell, size: fontSize, weight: .regular, design: design))
                            .foregroundStyle(.primary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .gridColumnAlignment(.leading)
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    @ViewBuilder
    private func image(_ data: Data) -> some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    /// The same message as plain text, for the copy a heading offers.
    static func plainText(_ blocks: [AgentTranscript.Block]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let text): return text
            case .code(_, let text): return text
            case .image: return "[image]"
            }
        }.joined(separator: "\n\n")
    }
}
