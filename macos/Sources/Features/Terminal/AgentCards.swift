import Foundation

/// One part of an agent's reply, on its own.
///
/// The taxonomy is not invented: it comes from reading the assistant text in
/// every Claude Code transcript on both of this user's machines — roughly
/// 17,000 messages — and asking what the sections agents actually write are
/// called. The same titles recur on both: "what was wrong", "the cause",
/// "what changed", "the fix", "verification", "two caveats", "one thing to
/// flag", "the blocker", "still open", "my recommendation". Those headings,
/// and where unheaded signals fall in a message, are the whole basis for the
/// kinds below.
enum AgentCardKind: String, CaseIterable, Equatable {
    /// A question the agent is blocked on. Ends the message 56–60% of the
    /// time it appears, which is why the splitter looks for it last-first.
    case ask
    /// What it changed or shipped. Opens the message ~78% of the time.
    case did
    /// The diagnosis — what was wrong, and why. The single most common
    /// heading in the corpus ("what was wrong", "the cause", "root cause").
    case found
    /// How it knows: tests, builds, the check it ran.
    case verified
    /// What to watch out for, or what it deliberately did not do. Sits in the
    /// middle of a message ~64% of the time.
    case caveat
    /// Why it could not do what was asked.
    case blocked
    /// What it suggests doing next, or what you have to do yourself.
    case next
    /// Everything else. Most blocks are this, and that is correct — an agent
    /// explaining itself is not always filing a report.
    case note

    /// Shown on the card.
    var title: String {
        switch self {
        case .ask: return "Asking you"
        case .did: return "What it did"
        case .found: return "What was wrong"
        case .verified: return "How it checked"
        case .caveat: return "Worth knowing"
        case .blocked: return "Couldn’t do"
        case .next: return "Suggested next"
        case .note: return "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .ask: return "questionmark.bubble"
        case .did: return "checkmark.circle"
        case .found: return "magnifyingglass"
        case .verified: return "checklist"
        case .caveat: return "exclamationmark.triangle"
        case .blocked: return "hand.raised"
        case .next: return "arrow.turn.down.right"
        case .note: return "text.alignleft"
        }
    }

    /// The order cards are shown in, which is the order the corpus says a
    /// message is written in — what happened, what was done about it, how it
    /// was checked, what to watch, what is stuck, what you are being asked.
    /// An ask always sinks to the bottom: it is the thing you act on.
    var rank: Int {
        switch self {
        case .found: return 0
        case .did: return 1
        case .verified: return 2
        case .note: return 3
        case .caveat: return 4
        case .next: return 5
        case .blocked: return 6
        case .ask: return 7
        }
    }
}

struct AgentCard: Identifiable, Equatable {
    let kind: AgentCardKind
    /// The agent's own section title when it wrote one, so a card says what
    /// the agent called it rather than what trm decided to call it.
    let heading: String?
    let blocks: [OverviewMarkdownBlock]
    /// Position in the reply, used to keep a stable identity across streaming
    /// updates so a card that has not changed does not get rebuilt.
    let order: Int

    var id: String { "\(order)|\(kind.rawValue)|\(heading ?? "")" }
    var title: String { heading ?? kind.title }
}

/// Splits an agent's reply into cards.
///
/// Two strategies, because the corpus shows two kinds of message. When the
/// agent wrote its own headings or bold lead-ins — 6% of all messages, far
/// more of the long ones — those are the section boundaries and the titles,
/// and each section is classified by what the agent called it. When it did
/// not, the message is grouped by paragraph and classified by content and
/// position. Most messages are short and become a single card, which is the
/// right answer: a two-sentence reply is not a report.
enum AgentCardSplitter {

    /// Below this a reply is one card. p50 message length in the corpus is
    /// 133–175 characters — shredding those would make eight cards a day
    /// worth reading and hundreds that are not.
    static let minimumLengthToSplit = 320

    static func cards(for transcript: AgentTranscript) -> [AgentCard] {
        cards(markdown: transcript.blocks.compactMap { block in
            if case .paragraph(let text) = block { return text }
            return nil
        }.joined(separator: "\n\n"))
    }

    static func cards(markdown: String) -> [AgentCard] {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sections = self.sections(in: trimmed)
        // A reply the agent titled itself is split however short it is. The
        // length floor guards only the unheaded fallback — applying it to
        // headed text made a streaming reply start as one card and then
        // re-split into five the moment it crossed the threshold, which is
        // precisely the rearranging that cards are supposed to avoid.
        let titled = sections.contains { $0.heading != nil }
        guard sections.count > 1, titled || trimmed.count >= minimumLengthToSplit else {
            let blocks = OverviewMarkdownBlock.parse(trimmed)
            let kind = classify(text: trimmed, heading: nil, index: 0, of: 1)
            return blocks.isEmpty ? [] : [
                AgentCard(kind: kind, heading: nil, blocks: blocks, order: 0)
            ]
        }

        var cards: [AgentCard] = []
        for (index, section) in sections.enumerated() {
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty || section.heading != nil else { continue }
            let blocks = OverviewMarkdownBlock.parse(body)
            guard !blocks.isEmpty else { continue }
            let kind = classify(
                text: body, heading: section.heading,
                index: index, of: sections.count)
            cards.append(AgentCard(
                kind: kind, heading: section.heading, blocks: blocks, order: cards.count))
        }
        return cards
    }

    // MARK: Sectioning

    struct Section: Equatable {
        let heading: String?
        let body: String
    }

    /// Split on the agent's own headings and bold lead-ins, else on blank
    /// lines. A bold lead-in only counts when it opens a line and is followed
    /// by prose — `**Done —** everything on mini` is a section title, a bold
    /// phrase mid-sentence is not.
    static func sections(in markdown: String) -> [Section] {
        let lines = markdown.components(separatedBy: .newlines)
        var sections: [Section] = []
        var heading: String?
        var body: [String] = []
        var inFence = false

        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if heading != nil || !text.isEmpty {
                sections.append(Section(heading: heading, body: text))
            }
            heading = nil
            body = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence, let found = sectionHeading(in: trimmed) {
                flush()
                heading = found.title
                if let remainder = found.remainder, !remainder.isEmpty {
                    body.append(remainder)
                }
                continue
            }
            body.append(line)
        }
        flush()

        // A lead-in with nothing under it is a sentence, not a section.
        return sections.filter { !($0.body.isEmpty && $0.heading == nil) }
    }

    private static func sectionHeading(in line: String) -> (title: String, remainder: String?)? {
        if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let title = String(line[match.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : (cleanHeading(title), nil)
        }
        // `**Title**` or `**Title:**` opening a line, optionally with the
        // paragraph continuing after it on the same line.
        guard line.hasPrefix("**"), let close = line.range(of: "**", range:
            line.index(line.startIndex, offsetBy: 2)..<line.endIndex) else { return nil }
        let title = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        guard !title.isEmpty, title.count <= 64, !title.contains("**") else { return nil }
        var remainder = String(line[close.upperBound...])
        // A lead-in that the sentence continues through is not a title:
        // `**What would make it flawless**, in order of size` is one clause,
        // and splitting it produced a card whose entire body was ", in order
        // of size". A real title is followed by nothing, by a separator, or
        // by a new sentence.
        if let first = remainder.trimmingCharacters(in: .whitespaces).first,
           first == "," || first == ")" || first == "(" || first == ";"
            || first.isLowercase {
            return nil
        }
        remainder = remainder.trimmingCharacters(in: CharacterSet(charactersIn: " :—-–"))
        return (cleanHeading(title), remainder.isEmpty ? nil : remainder)
    }

    private static func cleanHeading(_ title: String) -> String {
        title.trimmingCharacters(in: CharacterSet(charactersIn: " :—-–.")).isEmpty
            ? title
            : title.trimmingCharacters(in: CharacterSet(charactersIn: " :—-–."))
    }

    // MARK: Classification

    /// Title first, because an agent that named its own section has already
    /// answered the question better than any keyword search of the body will.
    static func classify(
        text: String, heading: String?, index: Int, of count: Int
    ) -> AgentCardKind {
        if let heading, let kind = kindFromHeading(heading) { return kind }
        return kindFromBody(text, index: index, of: count)
    }

    /// The titles agents actually write, taken from the corpus.
    static func kindFromHeading(_ heading: String) -> AgentCardKind? {
        let value = heading.lowercased()
        func any(_ needles: [String]) -> Bool { needles.contains { value.contains($0) } }

        if any(["what was wrong", "what actually happened", "what happened",
                "the bug", "the problem", "root cause", "the cause", "diagnosis",
                "what i found", "found it", "this is the bug", "why it"]) {
            return .found
        }
        if any(["verification", "verified", "how i checked", "how it was checked",
                "evidence", "proof", "tests"]) {
            return .verified
        }
        if any(["what changed", "what i changed", "what i did", "the fix", "fixed",
                "what shipped", "shipped", "deployed", "done", "what lands",
                "what landed", "implementation"]) {
            return .did
        }
        if any(["caveat", "worth knowing", "worth noting", "to flag", "one thing",
                "two things", "three things", "limitation", "tradeoff", "trade-off",
                "known issue", "gotcha", "heads up"]) {
            return .caveat
        }
        if any(["blocker", "the blocker", "still open", "not done", "couldn't",
                "could not", "unresolved", "what i can't", "what i cannot",
                "outstanding"]) {
            return .blocked
        }
        if any(["recommendation", "what you need to do", "next step", "next",
                "how to use", "from here", "suggested", "your call", "options"]) {
            return .next
        }
        if any(["question", "asking", "decision", "which"]) { return .ask }
        if any(["where things stand", "status", "state", "summary"]) { return .note }
        return nil
    }

    private static func kindFromBody(
        _ text: String, index: Int, of count: Int
    ) -> AgentCardKind {
        let value = text.lowercased()
        func any(_ patterns: [String]) -> Bool {
            patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
        }
        let isLast = index == count - 1
        let isFirst = index == 0

        // An ask outranks everything: it is the only kind that is a request
        // rather than a report, and burying it under a caveat is how a
        // blocked agent goes unnoticed. Weighted to the end of a message,
        // where the corpus puts it 56–60% of the time.
        // A question mark, or a phrase that is unambiguously a request. The
        // weaker signals ("which", "ok to") matched ordinary prose and filed
        // statements as questions, so they are gone.
        let asksOutright = value.range(of: #"\?(\s|\*|`|\)|")*$"#,
                                       options: .regularExpression) != nil
        let requests = any([#"\b(should i|do you want|would you like|shall i|"#
                            + #"want me to|say the word|your call|let me know if you|"#
                            + #"tell me which|confirm whether)\b"#])
        if asksOutright || (requests && isLast) { return .ask }
        if any([#"\b(i (couldn't|could not|can't|cannot|wasn't able|was unable)|"#
                + #"unable to|blocked (on|by)|don't have (access|permission)|"#
                + #"not possible|you'll need to|needs? you to)\b"#]) {
            return .blocked
        }
        if any([#"\b(one thing|worth (knowing|noting|flagging)|caveat|note that|"#
                + #"be aware|keep in mind|heads.?up|the catch|tradeoff|trade-off|"#
                + #"limitation|i did not |i have not |but note)\b"#]) {
            return .caveat
        }
        if any([#"\b(tests? (pass|passed|passing)|all green|build succeeded|"#
                + #"suite (passes|green)|verified|\d+ tests? pass|no failures)\b"#]) {
            return .verified
        }
        if isFirst, any([#"^(\*\*)?(done|fixed|added|implemented|committed|installed|"#
                         + #"shipped|i've |i have |i added|i fixed|i changed|i updated)"#]) {
            return .did
        }
        if any([#"\b(the (bug|problem|issue|cause) (is|was)|turns out|root cause|"#
                + #"the reason (is|was))\b"#,
                #"^(found it|confirmed the|here is (what|why)|here's (what|why))\b"#]) {
            return .found
        }
        if any([#"\b(next steps?|you can now|from here|remaining|still (to do|need))\b"#]) {
            return .next
        }
        return .note
    }
}

// MARK: - View

import SwiftUI

/// One card. Its heading is the agent's own when it wrote one, so the card
/// says what the agent called this rather than what trm decided to call it.
struct AgentCardView: View {
    let card: AgentCard
    @ObservedObject var pane: AgentOverviewPane
    let content: (OverviewMarkdownBlock) -> AnyView

    /// An ask is the only kind that is a request rather than a report, so it
    /// is the only one that gets the accent — everything else is information
    /// and would be competing for an urgency it does not have.
    private var isAsk: Bool { card.kind == .ask }

    private var tint: Color {
        switch card.kind {
        case .ask: return .accentColor
        case .blocked: return .orange
        case .caveat: return .yellow
        case .did, .verified: return .green
        case .found: return .purple
        case .next: return .teal
        case .note: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: card.kind.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(card.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isAsk ? tint : .secondary)
                    .lineLimit(1)
                // The kind is worth saying only when the agent's own title
                // does not already say it.
                if card.heading != nil, card.kind != .note {
                    Text(card.kind.title.lowercased())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(card.blocks.enumerated()), id: \.offset) { _, block in
                    content(block)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isAsk ? tint.opacity(0.07) : Color.primary.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isAsk ? tint.opacity(0.5) : Color.primary.opacity(0.07),
                    lineWidth: 1))
    }
}
