import Foundation

/// Turns a terminal dump back into something readable on a phone.
///
/// The scrollback arrives already hard-wrapped to the width of the pane it was
/// drawn in — often forty-odd columns — so a phone wraps text that has been
/// wrapped once already, and a paragraph arrives as a column of fragments.
/// Rejoining those into real paragraphs is most of what makes it readable; the
/// phone can then wrap them to its own width like any other text.
///
/// The rest is chrome. A Claude Code pane spends several lines on rules, a
/// prompt caret and a status footer, none of which mean anything once the pane
/// is not being typed into.
///
/// This is deliberately reversible — the raw view is one tap away — because
/// heuristics on someone else's output are wrong eventually, and the moment
/// you doubt the formatting is the moment you want the bytes.
enum ScrollbackFormatter {

    enum Block: Identifiable {
        case prose(String)
        case code(String)

        var id: String {
            switch self {
            case .prose(let text): return "p:" + text
            case .code(let text): return "c:" + text
            }
        }
    }

    /// A horizontal rule: the border of the input box, not content.
    private static let rule = /^[─━—\-_=]{8,}$/
    /// The status furniture along the bottom of a Claude Code pane.
    private static let chrome = /^(⏵⏵|✔ Update|✻ |❯$|❯ |\/[a-z-]+ to |new task\?)/
    /// Something that begins a block rather than continuing one.
    private static let bullet = /^\s*([⏺•▪◦▸›]|[-*]\s|\d+\.\s)/

    static func format(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: String?
        var codeLines: [String]?
        var skippingChrome = false

        func flushParagraph() {
            if let text = paragraph?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                blocks.append(.prose(text))
            }
            paragraph = nil
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fence opens or closes verbatim text. Code is never rejoined:
            // its line breaks are the content.
            if trimmed.hasPrefix("```") {
                if var open = codeLines {
                    blocks.append(.code(open.joined(separator: "\n")))
                    codeLines = nil
                    open.removeAll()
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                skippingChrome = false
                continue
            }
            if trimmed.wholeMatch(of: rule) != nil {
                flushParagraph()
                skippingChrome = false
                continue
            }
            // Chrome runs on past its own first line — "Crunched for 4m 33s ·
            // 1 shell still / running" is one wrapped status line — so its
            // continuations are dropped with it rather than left behind as a
            // paragraph that says "running".
            if trimmed.firstMatch(of: chrome) != nil {
                flushParagraph()
                skippingChrome = true
                continue
            }
            let isContinuation = line.hasPrefix("  ") && line.first(where: { $0 != " " }) != nil
            if skippingChrome {
                if isContinuation, line.firstMatch(of: bullet) == nil { continue }
                skippingChrome = false
            }

            if paragraph != nil, isContinuation, line.firstMatch(of: bullet) == nil {
                paragraph! += " " + trimmed
            } else {
                flushParagraph()
                paragraph = trimmed
            }
        }
        if let open = codeLines, !open.isEmpty {
            blocks.append(.code(open.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }
}
