import SwiftUI

/// One turn of an agent's conversation, as the Mac's overview pane sees it.
///
/// The phone reads the same structure the Mac draws rather than parsing a text
/// dump a second time: two parsers over one transcript is two things to keep
/// agreeing, and the one on the Mac already knows where a turn begins.
struct AgentOverview: Equatable {
    struct Block: Identifiable, Equatable {
        enum Kind: String { case paragraph, code, image }
        let kind: Kind
        let text: String
        let language: String?
        let index: Int
        var id: Int { index }
    }

    struct Activity: Identifiable, Equatable {
        let name: String
        let detail: String?
        let finished: Bool
        let isError: Bool
        let index: Int
        var id: Int { index }
    }

    struct Question: Identifiable, Equatable {
        let header: String?
        let text: String
        let options: [String]
        let finished: Bool
        let index: Int
        var id: Int { index }
    }

    /// Which turn this is, counting back from the newest: 0 is the latest.
    let turn: Int
    let turnCount: Int
    let prompt: String?
    let blocks: [Block]
    let activity: [Activity]
    let questions: [Question]
    /// Why there is nothing to show, when there isn't.
    let note: String?

    var isLatest: Bool { turn == 0 }
    var hasOlder: Bool { turn + 1 < turnCount }

    init?(json: [String: Any]) {
        guard let turn = json["turn"] as? Int else {
            // A row with no transcript still answers, with a reason.
            guard let note = json["note"] as? String else { return nil }
            self.turn = 0; self.turnCount = 0; self.prompt = nil
            self.blocks = []; self.activity = []; self.questions = []
            self.note = note
            return
        }
        self.turn = turn
        self.turnCount = json["turnCount"] as? Int ?? 1
        self.prompt = json["prompt"] as? String
        self.note = nil
        self.blocks = ((json["blocks"] as? [[String: Any]]) ?? []).enumerated().map { index, raw in
            Block(
                kind: Block.Kind(rawValue: raw["kind"] as? String ?? "paragraph") ?? .paragraph,
                text: raw["text"] as? String ?? "",
                language: (raw["language"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                index: index
            )
        }
        self.activity = ((json["activity"] as? [[String: Any]]) ?? []).enumerated().map { index, raw in
            Activity(
                name: raw["name"] as? String ?? "tool",
                detail: raw["detail"] as? String,
                finished: raw["finished"] as? Bool ?? true,
                isError: raw["isError"] as? Bool ?? false,
                index: index
            )
        }
        self.questions = ((json["questions"] as? [[String: Any]]) ?? []).enumerated().map { index, raw in
            Question(
                header: raw["header"] as? String,
                text: raw["text"] as? String ?? "",
                options: raw["options"] as? [String] ?? [],
                finished: raw["finished"] as? Bool ?? false,
                index: index
            )
        }
    }
}

/// Which parts of a turn to show. Mirrors the Mac's section menu, so a pane and
/// a phone looking at the same agent can be made to show the same thing.
struct OverviewSections: OptionSet {
    let rawValue: Int
    static let prompt = OverviewSections(rawValue: 1 << 0)
    static let questions = OverviewSections(rawValue: 1 << 1)
    static let activity = OverviewSections(rawValue: 1 << 2)
    static let reply = OverviewSections(rawValue: 1 << 3)

    /// What a turn opens as: the conversation, and nothing else.
    ///
    /// Activity is off for the same reason it is off on the Mac — the summary
    /// exists to be read, and a strip of tool calls pushes what was said down
    /// the screen to make room for a list the terminal already has.
    static let `default`: OverviewSections = [.prompt, .questions, .reply]
    static let all: OverviewSections = [.prompt, .questions, .activity, .reply]

    static let allCases: [(section: OverviewSections, title: String)] = [
        (.prompt, "What I Asked"),
        (.questions, "Questions"),
        (.activity, "Recent Activity"),
        (.reply, "What Claude Said"),
    ]
}

/// Bold the leading fraction of each word, so the eye lands on the shape of a
/// word instead of reading it letter by letter.
///
/// Ported from the Mac's `BionicText` rather than reinvented, so the two render
/// the same paragraph identically. Punctuation-only tokens are left alone —
/// there is no prefix of "---" worth emboldening.
enum BionicText {
    static func attributed(_ text: String, size: CGFloat) -> AttributedString {
        var out = AttributedString()
        for token in text.split(separator: " ", omittingEmptySubsequences: false) {
            var piece = fragment(String(token), size: size)
            if !out.characters.isEmpty { out += AttributedString(" ") }
            out += piece
            piece = AttributedString()
        }
        return out
    }

    private static func fragment(_ token: String, size: CGFloat) -> AttributedString {
        let letters = token.filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty else { return AttributedString(token) }
        // Roughly the first half, which is where the recognisable shape is.
        let boldCount = max(1, Int((Double(token.count) * 0.45).rounded()))
        let split = token.index(token.startIndex, offsetBy: min(boldCount, token.count))

        var head = AttributedString(String(token[..<split]))
        head.font = .system(size: size, weight: .bold)
        var tail = AttributedString(String(token[split...]))
        tail.font = .system(size: size)
        return head + tail
    }
}
