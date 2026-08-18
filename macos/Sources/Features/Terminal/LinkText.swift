import AppKit
import SwiftUI

/// A text paragraph with tappable links, rendered through NSTextView so the
/// mouse shows a pointing hand exactly over each link run. SwiftUI's `Text`
/// makes `.link` runs tappable but never changes the cursor — an arrow over
/// plain paragraphs, an I-beam everywhere once selection is on — and exposes
/// no per-run geometry to fix that from outside. TextKit lays the runs out
/// itself, so it can put a cursor rect on each link.
///
/// Only link-bearing paragraphs render through this (the call sites check);
/// the common linkless paragraph stays on plain `Text`.
struct LinkText: NSViewRepresentable {
    /// Fully AppKit-attributed content — fonts, colors, paragraph style, and
    /// `.link` runs. Built by the caller: SwiftUI-scoped attributes (SwiftUI
    /// `Font`, markdown presentation intents) are silently dropped by
    /// `NSAttributedString(_:)`, so nothing here may rely on them.
    let text: NSAttributedString
    /// Mirrors the overview's `allowsTextSelection`: on in the peek overlay,
    /// off in a grid cell — where non-link clicks must fall through to the
    /// cell's tap-to-peek underneath this view.
    let selectable: Bool
    /// Called with the clicked link. The overview copies rather than opens.
    let onLinkTap: (URL) -> Void

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView()
        view.isEditable = false
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        view.isSelectable = selectable
        view.passesNonLinkClicksThrough = !selectable
        view.onLinkTap = onLinkTap
        if view.textStorage?.isEqual(to: text) != true {
            view.textStorage?.setAttributedString(text)
        }
        view.window?.invalidateCursorRects(for: view)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: LinkTextView, context: Context
    ) -> CGSize? {
        guard let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        // The same one-way negotiation as a wrapping `Text`: accept the
        // proposed width, answer only with the height it needs. With no
        // width proposed (the ideal-size pass), answer the natural
        // unwrapped size.
        let proposed = proposal.width
        let width = (proposed != nil && proposed! > 0) ? proposed! : 100_000
        container.containerSize = NSSize(
            width: width, height: CGFloat.greatestFiniteMagnitude
        )
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(
            width: proposed ?? ceil(used.width),
            height: ceil(used.height)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        // Selectable mode: NSTextView routes link clicks here natively.
        func textView(
            _ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int
        ) -> Bool {
            guard let view = textView as? LinkTextView,
                  let url = LinkTextView.url(from: link) else { return false }
            view.onLinkTap?(url)
            return true
        }
    }
}

/// NSTextView that puts a pointing hand over link runs even when selection is
/// off, and — in that mode — lets non-link clicks pass through to whatever
/// SwiftUI placed underneath.
final class LinkTextView: NSTextView {
    var onLinkTap: ((URL) -> Void)?
    var passesNonLinkClicksThrough = false

    override func resetCursorRects() {
        super.resetCursorRects()
        // A selectable text view tracks its links natively (via
        // linkTextAttributes); a non-selectable one doesn't track them at
        // all, so add the rects ourselves. Doing it in both modes just
        // duplicates a rect, which is harmless.
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        storage.enumerateAttribute(
            .link, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil
            )
            layout.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                self.addCursorRect(
                    rect.offsetBy(dx: origin.x, dy: origin.y),
                    cursor: .pointingHand
                )
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard passesNonLinkClicksThrough else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return linkURL(at: local) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard passesNonLinkClicksThrough else {
            super.mouseDown(with: event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if let url = linkURL(at: local) { onLinkTap?(url) }
    }

    /// The link under a point in view coordinates, if any. A point past the
    /// end of a line maps to that line's last character, so the hit is
    /// confirmed against the character's actual glyph rect.
    private func linkURL(at point: NSPoint) -> URL? {
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let index = layout.characterIndex(
            for: containerPoint, in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index < storage.length else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: index)
        let rect = layout.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: container
        )
        guard rect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        return Self.url(from: storage.attribute(.link, at: index, effectiveRange: nil))
    }

    static func url(from value: Any?) -> URL? {
        (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }
}
