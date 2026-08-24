import Foundation

/// The insignia a worktree pane wears, and how to work out that it is one.
///
/// A worktree is a branch you can be in two places at once, which is the whole
/// reason it needs a mark: two panes sitting in the same project are otherwise
/// labelled identically, and the one difference between them — which branch is
/// checked out — is the only thing you actually wanted to know.
///
/// `⑂` rather than a word, because a watermark is drawn large and faint over a
/// terminal and has room for a name or a label, not both.
enum WorktreeMark {

    /// U+2442 OCR FORK — a branch, at a glance.
    static let insignia = "⑂"

    /// The worktree's own name, when a path is inside one.
    ///
    /// Detected from the path rather than by asking git: this is called while
    /// drawing labels, and a `git` process per pane per redraw is not a thing
    /// to spend on an icon. `…/.worktrees/<branch>` is the shape trm and the
    /// agents here create, and it is unambiguous. The other common shape,
    /// `<repo>-<branch>` beside the repo, is *not* distinguishable from an
    /// ordinary sibling directory — so a pane trm opens for one is marked when
    /// it is created instead, and carries the mark in its watermark from then
    /// on.
    static func name(forPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { $0 == ".worktrees" || $0 == "worktrees" }),
              index + 1 < parts.count else { return nil }
        return parts[(index + 1)...].joined(separator: "/")
    }

    /// `⑂ branch`, when the path is a worktree.
    static func label(forPath path: String?) -> String? {
        name(forPath: path).map { "\(insignia) \($0)" }
    }

    /// Put the insignia on a label that hasn't got one.
    ///
    /// Idempotent: a watermark that already carries the mark — because it was
    /// stamped when the pane was created, or restored from a session — must
    /// not collect a second one every time it is drawn.
    static func marked(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(insignia) else { return trimmed }
        return "\(insignia) \(trimmed)"
    }

    /// Whether a label is already wearing the mark.
    static func isMarked(_ label: String?) -> Bool {
        label?.trimmingCharacters(in: .whitespaces).hasPrefix(insignia) ?? false
    }
}
