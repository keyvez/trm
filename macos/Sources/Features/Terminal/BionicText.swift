import SwiftUI

/// Bionic-reading text rendering.
///
/// Bolds the leading fraction of each word so the eye can fixate on word
/// openings and skim the rest. Applied to prose only — code keeps its exact
/// glyphs, since bolding fragments of identifiers hurts more than it helps.
enum BionicText {
    /// How much of each word to bold, by word length.
    ///
    /// Short words get proportionally more emphasis (a 2-letter word bolds one
    /// letter) while long words get less, which is what keeps the effect
    /// readable instead of turning the paragraph mostly bold.
    static func boldPrefixLength(for wordLength: Int) -> Int {
        switch wordLength {
        case ..<1: return 0
        case 1: return 1
        case 2...3: return 1
        case 4...6: return 2
        case 7...9: return 3
        default: return Int((Double(wordLength) * 0.4).rounded(.down))
        }
    }

    /// Build an AttributedString with each word's leading fraction bolded.
    ///
    /// Splitting preserves the original whitespace runs so line breaks and
    /// indentation in the source text survive the transformation.
    static func attributed(_ text: String, font: Font, boldFont: Font) -> AttributedString {
        var out = AttributedString()
        var current = ""
        var isWhitespaceRun: Bool? = nil

        func flush() {
            guard !current.isEmpty else { return }
            if isWhitespaceRun == true {
                var run = AttributedString(current)
                run.font = font
                out.append(run)
            } else {
                out.append(styledWord(current, font: font, boldFont: boldFont))
            }
            current = ""
        }

        for ch in text {
            let isWS = ch.isWhitespace
            if isWhitespaceRun == nil { isWhitespaceRun = isWS }
            if isWS != isWhitespaceRun {
                flush()
                isWhitespaceRun = isWS
            }
            current.append(ch)
        }
        flush()
        return out
    }

    /// Style one whitespace-free token: bold its leading letters, leave the rest.
    ///
    /// Leading punctuation (quotes, brackets, backticks) is skipped so the bold
    /// lands on actual letters rather than being spent on a quote mark.
    private static func styledWord(_ word: String, font: Font, boldFont: Font) -> AttributedString {
        let chars = Array(word)
        var start = 0
        while start < chars.count, !chars[start].isLetter, !chars[start].isNumber {
            start += 1
        }

        // No letters at all (pure punctuation) — nothing to emphasise.
        guard start < chars.count else {
            var plain = AttributedString(word)
            plain.font = font
            return plain
        }

        // Count only the alphanumeric core when deciding how much to bold, so
        // trailing punctuation doesn't inflate the emphasis.
        var end = chars.count
        while end > start, !chars[end - 1].isLetter, !chars[end - 1].isNumber {
            end -= 1
        }

        let coreLength = end - start
        let boldCount = boldPrefixLength(for: coreLength)
        let splitIndex = start + boldCount

        var result = AttributedString()
        if splitIndex > 0 {
            var head = AttributedString(String(chars[0..<splitIndex]))
            head.font = boldFont
            result.append(head)
        }
        if splitIndex < chars.count {
            var tail = AttributedString(String(chars[splitIndex...]))
            tail.font = font
            result.append(tail)
        }
        return result
    }
}
