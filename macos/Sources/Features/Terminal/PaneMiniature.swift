import GhosttyKit
import SwiftUI

/// A pane drawn as it looks, very small.
///
/// Not a live view of the surface and it cannot be one: an `NSView` has exactly
/// one superview, so putting a parked pane's surface in the shelf would take it
/// out of its grid cell, and drawing it small would reflow the terminal to a
/// few columns — the pane would change shape because something was looking at
/// it. So the cells are read and redrawn instead: same characters, same
/// colours, same grid, at whatever size the tile has.
///
/// The whole viewport by default, never a crop *of a pane you are
/// identifying*: a terminal's meaning is often in its shape — a column of test
/// results, a diff, a progress table — and the last six lines of that is not a
/// smaller version of it, it is a different thing.
///
/// `rowRange` is the exception, and it is a different job. When the thing
/// being shown is one piece of the screen that stands on its own — the diff
/// inside a permission prompt, the plan above "shall I proceed" — the rest of
/// the viewport is not context, it is everything the question is *not* about.
struct PaneMiniature: View {
    let screen: Trm.PaneScreen
    /// Point size for a cell. Tiny on purpose when the whole viewport is
    /// shown: legibility is not the job there, recognisability is — you are
    /// looking for which pane this is. A cropped region is meant to be read,
    /// so it is given a real size by its caller.
    var fontSize: CGFloat = 3.5
    /// Rows to draw, inclusive. Nil draws the viewport.
    var rowRange: ClosedRange<Int>? = nil

    private var drawnRows: [Int] {
        guard let rowRange else { return Array(0..<screen.rows) }
        let low = max(0, rowRange.lowerBound)
        let high = min(screen.rows - 1, rowRange.upperBound)
        guard low <= high else { return [] }
        return Array(low...high)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(drawnRows, id: \.self) { row in
                line(row)
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .lineSpacing(0)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One row, built from runs of equally-styled cells.
    ///
    /// Merged rather than one `Text` per cell: a 24×80 viewport is nineteen
    /// hundred cells, and a view per cell per redraw is how a shelf of tiles
    /// would come to cost more than the terminals it describes. Runs collapse
    /// that to a handful of spans, because terminal output is overwhelmingly
    /// long stretches of one colour.
    private func line(_ row: Int) -> some View {
        var spans: [(text: String, cell: termania_cell_s)] = []
        for col in 0..<screen.cols {
            guard let cell = screen.cell(row: row, col: col) else { continue }
            let character = Self.character(cell)
            if var last = spans.last, Self.sameStyle(last.cell, cell) {
                last.text.append(character)
                spans[spans.count - 1] = last
            } else {
                spans.append((String(character), cell))
            }
        }
        return HStack(spacing: 0) {
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                Text(span.text)
                    .foregroundStyle(Self.foreground(span.cell))
                    .background(Self.background(span.cell))
                    .bold(span.cell.flags & 0x1 != 0)
                    .italic(span.cell.flags & 0x2 != 0)
            }
            Spacer(minLength: 0)
        }
    }

    private static func character(_ cell: termania_cell_s) -> Character {
        // 0 is an unwritten cell, not a NUL to draw.
        guard cell.codepoint != 0, let scalar = Unicode.Scalar(cell.codepoint) else { return " " }
        return Character(scalar)
    }

    private static func sameStyle(_ a: termania_cell_s, _ b: termania_cell_s) -> Bool {
        a.fg_r == b.fg_r && a.fg_g == b.fg_g && a.fg_b == b.fg_b && a.fg_type == b.fg_type
            && a.bg_r == b.bg_r && a.bg_g == b.bg_g && a.bg_b == b.bg_b && a.bg_type == b.bg_type
            && a.flags == b.flags
    }

    /// Inverse swaps the pair, the way the terminal draws it — otherwise a
    /// selected or highlighted run comes out as a block of one colour.
    private static func foreground(_ cell: termania_cell_s) -> Color {
        let inverse = cell.flags & 0x8 != 0
        if inverse { return colour(cell.bg_r, cell.bg_g, cell.bg_b, cell.bg_type, fallback: .black) }
        return colour(cell.fg_r, cell.fg_g, cell.fg_b, cell.fg_type, fallback: .primary)
    }

    private static func background(_ cell: termania_cell_s) -> Color {
        let inverse = cell.flags & 0x8 != 0
        if inverse { return colour(cell.fg_r, cell.fg_g, cell.fg_b, cell.fg_type, fallback: .primary) }
        return colour(cell.bg_r, cell.bg_g, cell.bg_b, cell.bg_type, fallback: .clear)
    }

    /// Type 0 means "whatever the theme says", which is not a colour this view
    /// knows — so it defers rather than guessing at black or white and being
    /// wrong in one of the two appearances.
    private static func colour(
        _ r: UInt8, _ g: UInt8, _ b: UInt8, _ type: UInt8, fallback: Color
    ) -> Color {
        guard type != 0 else { return fallback }
        return Color(.sRGB,
                     red: Double(r) / 255,
                     green: Double(g) / 255,
                     blue: Double(b) / 255)
    }
}
