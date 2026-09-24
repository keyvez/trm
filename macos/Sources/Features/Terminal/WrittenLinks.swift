import Foundation

/// Links that are written out as links in the text itself.
///
/// `NSDataDetector` also finds addresses nobody wrote as one: a file name
/// whose extension happens to be a country code — `jobs.rs` (Serbia),
/// `main.py` (Paraguay), `README.md` (Moldova) — comes back as
/// `http://jobs.rs`, with the scheme supplied by the detector. Agents write
/// file names constantly, so every one of those became a link, a page to
/// photograph, and a failed load. A match counts here only when its own text
/// carries a scheme (`https://…`) or starts with `www.`: the forms in which
/// someone actually meant an address.
enum WrittenLinks {
    struct Match {
        let range: NSRange
        let url: URL
    }

    // NSDataDetector, like NSRegularExpression, is immutable and safe to share.
    nonisolated(unsafe) private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    nonisolated static func matches(in text: String) -> [Match] {
        guard !text.isEmpty, let detector else { return [] }
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard let url = match.url,
                      isWrittenOut(ns.substring(with: match.range)) else { return nil }
                return Match(range: match.range, url: url)
            }
    }

    /// Whether the matched text itself spells out an address.
    nonisolated static func isWrittenOut(_ matched: String) -> Bool {
        matched.contains("://") || matched.lowercased().hasPrefix("www.")
    }
}
