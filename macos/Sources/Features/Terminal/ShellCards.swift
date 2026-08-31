import Foundation

/// A shell command, broken into the cards worth reading separately.
///
/// The agent card taxonomy does not fit here: an agent writes prose with
/// sections, a command prints a log. What a person wants from a log is
/// consistently four things — what was run, how it went, what broke, and the
/// output itself — so those are the cards, and only the ones that have
/// something in them are built.
struct ShellCard: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case command
        case summary
        case failure
        case output

        var title: String {
            switch self {
            case .command: return "Command"
            case .summary: return "Summary"
            case .failure: return "What failed"
            case .output: return "Output"
            }
        }

        var symbol: String {
            switch self {
            case .command: return "chevron.right.square"
            case .summary: return "text.magnifyingglass"
            case .failure: return "exclamationmark.triangle"
            case .output: return "text.alignleft"
            }
        }
    }

    /// One piece of a card's content.
    enum Body: Equatable {
        /// Monospaced, in a bordered block — a command line or output.
        case code(String)
        /// A sentence.
        case prose(String)
        /// Short measured lines, one per row.
        case facts([String])
    }

    let kind: Kind
    /// Overrides `kind.title` — the command card is titled by what it is
    /// (`Build`, `Tests`, `Version control`), which says more than "Command".
    let title: String
    /// The line under the title: a category, a count, a state.
    let subtitle: String?
    let body: [Body]
    /// What this card's copy button puts on the pasteboard.
    let copyText: String
    let order: Int

    var id: String { "\(order)|\(kind.rawValue)" }
}

enum ShellCardBuilder {

    /// How much output the card shows before it is only worth copying.
    static let outputCardLines = 40

    static func cards(for command: ShellCommand) -> [ShellCard] {
        var cards: [ShellCard] = []
        let summary = command.summary

        if !command.command.isEmpty {
            cards.append(ShellCard(
                kind: .command,
                title: command.kind.title,
                subtitle: state(of: command, summary: summary),
                body: [.code(command.command)],
                copyText: command.command,
                order: cards.count))
        }

        // A one-line result needs no summary of itself. Above that, the
        // headline and the facts are the reason cards exist here at all.
        if command.output.count > 1 || summary.errorCount > 0 || !command.finished {
            var body: [ShellCard.Body] = []
            if !summary.headline.isEmpty { body.append(.prose(summary.headline)) }
            let facts = summary.facts.filter { $0 != summary.headline }
            if !facts.isEmpty { body.append(.facts(facts)) }
            if !body.isEmpty {
                cards.append(ShellCard(
                    kind: .summary,
                    title: ShellCard.Kind.summary.title,
                    subtitle: "\(command.output.count) lines",
                    body: body,
                    copyText: ([summary.headline] + facts).joined(separator: "\n"),
                    order: cards.count))
            }
        }

        if let excerpt = command.errorExcerpt() {
            cards.append(ShellCard(
                kind: .failure,
                title: ShellCard.Kind.failure.title,
                subtitle: summary.errorCount > 1 ? "\(summary.errorCount) lines" : nil,
                body: [.code(excerpt)],
                // The excerpt is the point: the error line alone rarely says
                // which file or target it came from.
                copyText: excerpt,
                order: cards.count))
        }

        if !command.output.isEmpty {
            let shown = command.outputPreview(lines: outputCardLines)
            cards.append(ShellCard(
                kind: .output,
                title: ShellCard.Kind.output.title,
                subtitle: command.output.count > outputCardLines
                    ? "last \(outputCardLines) of \(command.output.count) lines"
                    : nil,
                body: [.code(shown)],
                // Copy yields the whole thing, not the excerpt on screen.
                copyText: command.fullLog,
                order: cards.count))
        }

        return cards
    }

    /// What the command card says under its title.
    private static func state(
        of command: ShellCommand, summary: ShellOutputSummary
    ) -> String {
        if !command.finished { return "running" }
        if summary.errorCount > 0 { return "failed" }
        return "finished"
    }
}

// MARK: - View

import SwiftUI

/// One shell card. Deliberately the same chrome as `AgentCardView` — an
/// overview of a shell pane and one of an agent pane sit side by side in the
/// same grid, and two card styles in one window would read as two apps.
struct ShellCardView: View {
    let card: ShellCard
    let fontScale: CGFloat
    let fontDesign: Font.Design
    var allowsTextSelection: Bool = true

    @State private var didCopy = false
    @State private var isHovering = false

    private func scaled(_ size: CGFloat) -> CGFloat { size * fontScale }

    private var tint: Color {
        switch card.kind {
        case .command: return .accentColor
        case .summary: return .secondary
        case .failure: return .orange
        case .output: return .secondary
        }
    }

    private var isFailure: Bool { card.kind == .failure }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: card.kind.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(card.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isFailure ? tint : .secondary)
                    .lineLimit(1)
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: copy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: didCopy ? 10 : 9, weight: .semibold))
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                        .opacity(didCopy ? 1 : (isHovering ? 0.9 : 0.35))
                }
                .buttonStyle(.plain)
                .help(copyHelp)
            }

            ForEach(Array(card.body.enumerated()), id: \.offset) { _, part in
                ShellCardBodyView(
                    part: part,
                    fontScale: fontScale,
                    fontDesign: fontDesign,
                    allowsTextSelection: allowsTextSelection)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFailure ? tint.opacity(0.07) : Color.primary.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFailure ? tint.opacity(0.45) : Color.primary.opacity(0.07),
                    lineWidth: 1))
    }

    /// One piece of a card's content.
    ///
    /// Its own view, not a `switch` inside the card body: the overview is
    /// already several levels of nested SwiftUI, and an inline conditional
    /// here is what tips whole-module type checking over.
    private struct ShellCardBodyView: View {
        let part: ShellCard.Body
        let fontScale: CGFloat
        let fontDesign: Font.Design
        let allowsTextSelection: Bool

        private func scaled(_ size: CGFloat) -> CGFloat { size * fontScale }

        var body: some View {
            switch part {
            case .code(let text): code(text)
            case .prose(let text): prose(text)
            case .facts(let items): facts(items)
            }
        }

        @ViewBuilder
        private func code(_ text: String) -> some View {
            // `.textSelection` takes its selectability statically, so a
            // runtime flag needs a branch around the whole block.
            if allowsTextSelection {
                codeText(text).textSelection(.enabled)
            } else {
                codeText(text).textSelection(.disabled)
            }
        }

        private func codeText(_ text: String) -> some View {
            Text(text)
                .font(.system(size: scaled(11), weight: .light, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.22)))
        }

        private func prose(_ text: String) -> some View {
            Text(text)
                .font(.system(size: scaled(12), design: fontDesign))
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func facts(_ items: [String]) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 3, height: 3)
                        Text(item)
                            .font(.system(size: scaled(11), design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var copyHelp: String {
        switch card.kind {
        case .command: return "Copy the command"
        case .summary: return "Copy the summary"
        case .failure: return "Copy the error with context"
        case .output: return "Copy the full log"
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.copyText, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }
}
