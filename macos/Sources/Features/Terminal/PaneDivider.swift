import SwiftUI
import AppKit

// MARK: - PaneDivider

/// A transparent NSView that sits over a pane border and handles drag-to-resize.
///
/// We use AppKit rather than SwiftUI gestures because the GPU-rendered terminal
/// surfaces underneath absorb SwiftUI hit tests — the same reason PaneDragBar
/// uses an NSViewRepresentable.
struct PaneDivider: NSViewRepresentable {
    /// Whether this divider splits rows (vertical drag) or columns (horizontal drag).
    let axis: Axis

    /// Current fraction [0,1] representing where this divider currently sits between
    /// the two adjacent panes (0 = fully at start, 1 = fully at end).
    let currentFraction: CGFloat

    /// The combined length (in points) of the two adjacent panes plus the gap.
    /// Used to convert pixel deltas to fraction deltas.
    let combinedLength: CGFloat

    /// Called continuously while dragging with the proposed new fraction [0.05, 0.95].
    var onDrag: ((CGFloat) -> Void)?

    enum Axis {
        /// Horizontal divider — sits between two rows, drag up/down changes row heights.
        case horizontal
        /// Vertical divider — sits between two columns, drag left/right changes col widths.
        case vertical
    }

    func makeNSView(context: Context) -> DividerNSView {
        let v = DividerNSView()
        v.axis = axis
        v.currentFraction = currentFraction
        v.combinedLength = combinedLength
        v.onDrag = onDrag
        return v
    }

    func updateNSView(_ nsView: DividerNSView, context: Context) {
        nsView.axis = axis
        // Only update currentFraction when not dragging (otherwise the fraction
        // would jump back to the last committed value mid-drag).
        if !nsView.isDragging {
            nsView.currentFraction = currentFraction
        }
        nsView.combinedLength = combinedLength
        nsView.onDrag = onDrag
    }
}

// MARK: - DividerNSView

final class DividerNSView: NSView {
    var axis: PaneDivider.Axis = .horizontal
    var currentFraction: CGFloat = 0.5
    var combinedLength: CGFloat = 0
    var onDrag: ((CGFloat) -> Void)?

    private var isHovering = false
    private(set) var isDragging = false
    private var dragStartPoint: CGFloat = 0
    private var dragStartFraction: CGFloat = 0

    // NSView default is Y=0 at bottom (unflipped). locationInWindow is also
    // Y=0 at bottom, so convert(locationInWindow, from: nil) needs no flip.
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTracking()
    }

    private func setupTracking() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
    }

    // MARK: - Cursor

    private var resizeCursor: NSCursor {
        axis == .horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight
    }

    // cursorUpdate is called by AppKit whenever the cursor needs to be set
    // within this view's tracking area — more reliable than mouseEntered/mouseMoved
    // because it survives cursor resets from GPU-rendered terminal surfaces underneath.
    override func cursorUpdate(with event: NSEvent) {
        resizeCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        resizeCursor.push()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if !isDragging {
            NSCursor.pop()
        }
    }

    // MARK: - Drag

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // Y=0 at bottom: dragging the horizontal divider DOWN decreases loc.y,
        // which means the top pane shrinks — so we negate the horizontal delta.
        dragStartPoint = axis == .horizontal ? loc.y : loc.x
        dragStartFraction = currentFraction
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, combinedLength > 0 else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let current = axis == .horizontal ? loc.y : loc.x
        // Horizontal (row) divider: Y=0 at bottom, so dragging DOWN decreases Y.
        // Decreasing Y means the divider moved down → top pane grows → fraction should increase.
        // But delta = current - start is NEGATIVE when dragging down in unflipped coords.
        // We need to negate for horizontal so the drag direction feels natural.
        let rawDelta = current - dragStartPoint
        let delta = axis == .horizontal ? -rawDelta : rawDelta
        let proposed = dragStartFraction + delta / combinedLength
        let clamped = min(0.95, max(0.05, proposed))
        onDrag?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if !isHovering {
            NSCursor.pop()
        }
    }

    // MARK: - Drawing (invisible hit area)

    override func draw(_ dirtyRect: NSRect) {
        // Fully transparent — the gap between pane borders provides the visual.
    }
}
