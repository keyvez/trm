import Foundation

/// A question an agent is asking *in its terminal*, read off the screen.
///
/// The transcript cannot answer this one. Claude Code's permission prompts —
/// "may I run this", "may I make this edit", "shall I leave plan mode" — are
/// drawn and answered entirely in the terminal UI and never reach the JSONL;
/// `AskUserQuestion` does reach it, but only once the message it belongs to is
/// flushed, which is after you have answered. Either way the board learns
/// about the question when it stops being a question.
///
/// So it is read from the pane's own screen, which has the further advantage
/// of working identically for remote panes: the surface renders here, whatever
/// machine the shell is on.
struct PanePrompt: Equatable {
    /// The question, flattened to a line.
    let question: String
    /// The numbered choices, in the order they are offered.
    let options: [Option]
    /// Viewport rows the whole prompt occupies, inclusive — the frame if it
    /// has one, otherwise the question and its choices.
    let rows: ClosedRange<Int>
    /// Rows above the question and inside the same frame: the diff, the plan,
    /// the command about to be run. Nil when the prompt is just a question.
    ///
    /// This is the half that makes the question answerable. "Do you want to
    /// make this edit?" is not a question anyone can answer from a board; the
    /// same words above six lines of diff are.
    let previewRows: ClosedRange<Int>?
    /// The same preview as plain lines, frames stripped.
    ///
    /// The Mac draws the preview from the pane's cells, colours and all. A
    /// phone has no cells to draw — it is reading a board over a socket — so
    /// the text travels with the question.
    var previewText: [String] = []

    struct Option: Equatable, Identifiable {
        /// The digit the menu offers it under, which is also the keystroke
        /// that picks it.
        let number: Int
        let label: String
        /// Whether the cursor is resting on it.
        let isSelected: Bool

        var id: Int { number }
    }

    /// The choice the cursor is on, which is what a Return would take.
    var selected: Option? { options.first(where: \.isSelected) }
}

/// Finds an agent's on-screen question in a pane's viewport.
///
/// Deliberately conservative: a wrong box on the board is worse than no box,
/// because the whole point of the row is to be believed. Every rule here is a
/// reason to *reject* a candidate, and the detector returns nil whenever the
/// shape isn't unmistakable.
enum PanePromptDetector {

    /// How far up from the bottom to look. A prompt is the thing the terminal
    /// is showing *now*; one further up the scrollback is one that has already
    /// been answered.
    static let searchDepth = 60

    /// How many rows may sit between the end of the prompt and the last thing
    /// on screen. The agent draws a couple of blank lines and a hint line
    /// under its menu, and a redraw in progress can add one more.
    static let tailSlack = 8

    /// Vertical box-drawing characters that frame a prompt.
    private static let frameEdges: Set<Character> = ["│", "┃", "|", "┆", "┊", "║"]
    /// Corner and horizontal characters — a border row rather than content.
    private static let frameBorders: Set<Character> =
        ["╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "─", "━", "═", "╔", "╗", "╚", "╝", "┈", "┄"]
    /// Cursors an agent draws beside the choice you are on.
    private static let cursors: Set<Character> = ["❯", "›", "▸", ">", "»", "→"]

    /// Read a prompt out of a viewport, or nil when there isn't one.
    ///
    /// - Parameter text: the viewport as the terminal would copy it.
    static func detect(inViewport text: String) -> PanePrompt? {
        detect(inRows: text.components(separatedBy: "\n"))
    }

    static func detect(inRows rows: [String]) -> PanePrompt? {
        guard !rows.isEmpty else { return nil }

        // Where the screen actually ends. Terminals pad the viewport with
        // blank rows, and measuring "is this at the bottom" against those
        // would reject every prompt on a half-empty screen.
        guard let lastContent = rows.lastIndex(where: { !isBlank($0) }) else { return nil }
        let from = max(0, lastContent - searchDepth + 1)

        // Inner text per row, with any frame edge taken off, so a boxed prompt
        // and a bare one are read by the same rules.
        var inner: [Int: String] = [:]
        for index in from...lastContent { inner[index] = unframed(rows[index]) }

        // The choices: the last run of consecutively numbered lines, counting
        // from 1. "1." alone is a list item somewhere in a reply; "1." and
        // "2." under a question are a menu.
        guard let options = lastOptionRun(in: inner, from: from, to: lastContent) else { return nil }
        guard options.count >= 2 else { return nil }
        // A menu has a cursor resting on one of its choices; a numbered list
        // in a reply does not. This is the line between "the agent is waiting
        // for you to pick one of these" and "the agent listed three things it
        // fixed", and nothing else in the shape tells them apart — both are
        // consecutive numbered lines under a sentence ending in a colon.
        //
        // It doubles as the liveness test. The cursor is drawn by the menu
        // that is taking input; once the answer lands, what is left on screen
        // is the echoed choice without it.
        guard options.contains(where: { $0.option.isSelected }) else { return nil }
        guard let firstOptionRow = options.first?.row, let lastOptionRow = options.last?.row
        else { return nil }

        // The frame, when there is one: walk out from the choices while the
        // rows are still part of the same box.
        let frame = frameBounds(around: firstOptionRow...lastOptionRow, in: rows, from: from, to: lastContent)

        // Still on screen? A prompt that has scrolled up is one that was
        // answered, and re-offering it is how a board starts lying.
        let bottom = frame?.upperBound ?? lastOptionRow
        guard lastContent - bottom <= tailSlack else { return nil }

        // The question: the prose above the first choice, up to a blank line
        // or the frame's inner edge. Multi-line because a long one wraps, and
        // half a question is not one.
        //
        // The floor is the row *inside* the frame, or the top of the search
        // window when there is no frame — off by one here and an unboxed
        // prompt loses its question entirely.
        let floor = frame.map { $0.lowerBound + 1 } ?? from
        var row = firstOptionRow - 1
        // A blank line between the question and its choices is ordinary when
        // nothing is drawing a box, so a couple are stepped over rather than
        // treated as the end of the prompt.
        var skipped = 0
        while row >= floor, isBlank(inner[row] ?? ""), skipped < 2 {
            row -= 1
            skipped += 1
        }
        var questionRows: [Int] = []
        while row >= floor {
            let line = inner[row] ?? ""
            if isBlank(line) { break }
            if isBorder(line) { break }
            if optionParts(line) != nil { break }
            questionRows.append(row)
            row -= 1
        }
        questionRows.reverse()
        let question = questionRows
            .compactMap { inner[$0] }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return nil }

        // Everything above the question but inside the frame is the preview:
        // the diff, the plan, the command. Only counted when it has content —
        // a blank strip is not a preview.
        var preview: ClosedRange<Int>? = nil
        if let frame, let questionTop = questionRows.first {
            let previewTop = frame.lowerBound + 1
            let previewBottom = questionTop - 1
            if previewTop <= previewBottom,
               (previewTop...previewBottom).contains(where: { !isBlank(inner[$0] ?? "") }) {
                preview = previewTop...previewBottom
            }
        }

        return PanePrompt(
            question: question,
            options: options.map(\.option),
            rows: (frame?.lowerBound ?? (questionRows.first ?? firstOptionRow))...bottom,
            previewRows: preview,
            previewText: preview.map { range in
                range.map { inner[$0] ?? "" }
            } ?? [])
    }

    // MARK: - Pieces

    private struct NumberedRow {
        let row: Int
        let option: PanePrompt.Option
    }

    /// The last run of choices numbered 1, 2, 3… on adjacent rows.
    ///
    /// Adjacency matters: an agent's prose often contains a numbered list, and
    /// the thing that tells a list from a menu is that a menu's items are a
    /// block with nothing between them.
    private static func lastOptionRun(
        in inner: [Int: String], from: Int, to: Int
    ) -> [NumberedRow]? {
        var run: [NumberedRow] = []
        var best: [NumberedRow]? = nil

        for row in from...to {
            let line = inner[row] ?? ""
            if let parts = optionParts(line) {
                // A menu counts from 1. A run that starts at 3 is the tail of
                // a list whose head scrolled off, or prose.
                let expected = (run.last?.option.number ?? 0) + 1
                if parts.number != expected {
                    run = parts.number == 1 ? [] : run
                    if parts.number != 1 { continue }
                }
                run.append(NumberedRow(
                    row: row,
                    option: .init(number: parts.number,
                                  label: parts.label,
                                  isSelected: parts.selected)))
                continue
            }
            // A wrapped option label keeps the run alive: the continuation is
            // indented under its own number and carries no number of its own.
            if !run.isEmpty, !isBlank(line), !isBorder(line), line.hasPrefix("  ") { continue }
            if !run.isEmpty { best = run }
            run = []
        }
        if !run.isEmpty { best = run }
        return best
    }

    /// `1. Yes` / `❯ 2. No` / `3) Something`, with the cursor if it has one.
    static func optionParts(_ line: String) -> (number: Int, label: String, selected: Bool)? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }

        var selected = false
        if let first = rest.first, cursors.contains(first) {
            selected = true
            rest = rest.dropFirst().drop { $0 == " " }
        }

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        rest = rest.dropFirst()
        // A number and a full stop with nothing after it is a decimal, or a
        // version, or the end of a sentence.
        guard let next = rest.first, next == " " || next == "\t" else { return nil }

        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (number, label, selected)
    }

    /// The box the choices sit in, when they sit in one.
    ///
    /// Found by walking out row by row while the *original* rows still begin
    /// with a frame edge, and stopping on the border that closes it. Nil when
    /// the prompt is drawn without a box, which some agents do.
    private static func frameBounds(
        around options: ClosedRange<Int>, in rows: [String], from: Int, to: Int
    ) -> ClosedRange<Int>? {
        guard isFramed(rows[options.lowerBound]) else { return nil }

        var top = options.lowerBound
        while top - 1 >= from {
            let line = rows[top - 1]
            if isFramed(line) { top -= 1; continue }
            if isBorderRow(line) { top -= 1 }
            break
        }

        var bottom = options.upperBound
        while bottom + 1 <= to {
            let line = rows[bottom + 1]
            if isFramed(line) { bottom += 1; continue }
            if isBorderRow(line) { bottom += 1 }
            break
        }
        return top...bottom
    }

    /// Whether a row is drawn as part of a box: it opens with a vertical edge.
    private static func isFramed(_ line: String) -> Bool {
        guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
        return frameEdges.contains(first)
    }

    /// Whether a row is a box's top or bottom rule.
    private static func isBorderRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, frameBorders.contains(first) else { return false }
        return trimmed.allSatisfy { frameBorders.contains($0) || $0 == " " }
    }

    private static func isBorder(_ line: String) -> Bool { isBorderRow(line) }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A row with its frame edges taken off, so the text inside a box reads
    /// the same as the same text drawn without one.
    ///
    /// Indentation survives. It is not decoration here: a line indented under
    /// a numbered choice is that choice's label continuing, and a line that
    /// starts at the margin is something new. Strip it and a wrapped option
    /// ends the menu it belongs to.
    static func unframed(_ line: String) -> String {
        var text = Substring(line)
        let afterIndent = text.drop { $0 == " " || $0 == "\t" }
        if let first = afterIndent.first, frameEdges.contains(first) {
            text = afterIndent.dropFirst()
            // One space of padding belongs to the frame; further indentation
            // is the content's own.
            if text.first == " " { text = text.dropFirst() }
        }
        while let last = text.last, last == " " || last == "\t" || frameEdges.contains(last) {
            text = text.dropLast()
        }
        return String(text)
    }
}
