import Foundation

/// A resolved `#` reference from the AI prompt.
struct PaneReference {
    let raw: String
    let resolvedIndex: Int?
}

/// Parses `#` references in the query and resolves them to pane indices.
enum PaneAddressing {

    /// Extract all #references from a prompt string.
    /// "#0" -> by index, "#watermark text" -> by watermark match (case-insensitive).
    static func extractReferences(
        from query: String,
        panes: [PaneContext]
    ) -> (cleanedPrompt: String, references: [PaneReference]) {
        var references: [PaneReference] = []
        var cleaned = query

        // Find all # tokens: # followed by digits, or # followed by text until next # or end
        let pattern = #"#(\d+|[^#,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (query, [])
        }

        let nsRange = NSRange(query.startIndex..., in: query)
        let matches = regex.matches(in: query, range: nsRange)

        // Process matches in reverse so string indices remain valid for replacement
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: query),
                  let tokenRange = Range(match.range(at: 1), in: query) else { continue }

            let token = String(query[tokenRange]).trimmingCharacters(in: .whitespaces)
            let rawRef = String(query[fullRange])
            let resolved = resolve(token: token, panes: panes)

            references.insert(PaneReference(raw: rawRef, resolvedIndex: resolved), at: 0)
            cleaned.replaceSubrange(fullRange, with: "")
        }

        // Clean up extra whitespace from removal
        cleaned = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return (cleaned, references)
    }

    /// Resolve a single # token against available panes.
    /// Checks: numeric paneId first, then watermark match, then title substring.
    static func resolve(token: String, panes: [PaneContext]) -> Int? {
        // Numeric paneId
        if let id = Int(token), panes.contains(where: { $0.index == id }) {
            return id
        }

        let lower = token.lowercased()

        // Watermark match (via Trm API) — use paneId for watermark storage.
        for pane in panes {
            if let watermark = Trm.shared.watermark(forPaneId: UInt32(pane.index)),
               watermark.lowercased().contains(lower) {
                return pane.index
            }
        }

        // Title substring match
        for pane in panes {
            if pane.title.lowercased().contains(lower) {
                return pane.index
            }
        }

        return nil
    }
}
