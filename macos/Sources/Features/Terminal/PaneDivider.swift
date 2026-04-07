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

    override var isFlipped: Bool { true }
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
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
    }

    // MARK: - Cursor

    private var resizeCursor: NSCursor {
        axis == .horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        resizeCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if isHovering { resizeCursor.set() }
    }

    // MARK: - Drag

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        dragStartPoint = axis == .horizontal ? loc.y : loc.x
        dragStartFraction = currentFraction
        isDragging = true
        resizeCursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, combinedLength > 0 else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let current = axis == .horizontal ? loc.y : loc.x
        let delta = current - dragStartPoint
        let proposed = dragStartFraction + delta / combinedLength
        let clamped = min(0.95, max(0.05, proposed))
        onDrag?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if isHovering {
            resizeCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Drawing (invisible hit area)

    override func draw(_ dirtyRect: NSRect) {
        // Fully transparent — the gap is between pane borders.
    }
}
