import Foundation

/// Pure helpers for applying a broadcast layout snapshot in place.
///
/// The wire format is the session TOML: a flat `[[panes]]` list in visual
/// display order with stacks flattened (children tagged `stack_group`), plus
/// a visual `row_cols` shape. These functions translate that flat form back
/// into the controller's state shape (display order, stacks keyed by host,
/// visual row/column counts) without touching any controller objects, so the
/// reconciliation logic is unit-testable with plain String IDs.
enum LayoutSyncModel {
    /// Group flat pane indices by their `stack_group` tag, in first-appearance
    /// order. Only groups with two or more members form a real stack; the
    /// first member is the stack host. Mirrors `restoreStackGroups`.
    static func stackGroups(forTags tags: [String?]) -> [[Int]] {
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (i, tag) in tags.enumerated() {
            guard let tag else { continue }
            if groups[tag] == nil { order.append(tag) }
            groups[tag, default: []].append(i)
        }
        return order.compactMap { tag in
            guard let members = groups[tag], members.count >= 2 else { return nil }
            return members
        }
    }

    /// Split a serialized pane list into the panes that take grid cells and
    /// the ones parked in the sidebar.
    ///
    /// A parked pane exists and keeps running but claims no cell, so it must
    /// stay out of the display order and out of the row/column arithmetic —
    /// leaving it in makes the grid reserve a cell for a pane that never
    /// renders. The `sidebar` flag rides alongside each entry rather than
    /// being derived from position, because parked panes are serialized after
    /// the grid ones precisely so grid indices stay stable.
    ///
    /// Restoring a window where *everything* was parked would leave an empty
    /// grid with no visible way back, so the first parked pane comes back.
    static func partitionParked<T>(
        _ entries: [(value: T, sidebar: Bool)]
    ) -> (grid: [T], parked: [T]) {
        var grid: [T] = []
        var parked: [T] = []
        for entry in entries {
            if entry.sidebar { parked.append(entry.value) } else { grid.append(entry.value) }
        }
        if grid.isEmpty, !parked.isEmpty {
            grid.append(parked.removeFirst())
        }
        return (grid, parked)
    }

    /// Number of visual grid cells for a flat pane list: every stack of N
    /// panes collapses into one cell.
    static func visualCellCount(flatCount: Int, stackGroups: [[Int]]) -> Int {
        let hidden = stackGroups.reduce(0) { $0 + ($1.count - 1) }
        return max(flatCount - hidden, 0)
    }

    /// The target visual row/column shape: the config's `row_cols` when it
    /// matches the visual cell count, otherwise a uniform shape built from
    /// rows × cols (same fallback the restore path uses).
    static func targetRowCols(visualCount: Int, configRowCols: [Int], rows: Int, cols: Int) -> [Int] {
        guard visualCount > 0 else { return [1] }
        if !configRowCols.isEmpty, configRowCols.reduce(0, +) == visualCount {
            return configRowCols
        }
        return gridShape(totalPanes: visualCount, rows: max(rows, 1), cols: max(cols, 1))
    }

    /// Uniform grid shape: rows of `cols` panes, last row holding the
    /// remainder.
    static func gridShape(totalPanes: Int, rows: Int, cols: Int) -> [Int] {
        guard totalPanes > 0 else { return [1] }
        if rows * cols == totalPanes {
            return Array(repeating: cols, count: rows)
        }
        var remaining = totalPanes
        var result: [Int] = []
        while remaining > 0 {
            let count = min(cols, remaining)
            result.append(count)
            remaining -= count
        }
        return result.isEmpty ? [1] : result
    }

    /// Build the controller's stack state from flat IDs + stack groups:
    /// host ID (first member) → ordered member IDs (host first).
    static func paneStacks<ID: Hashable>(flatIDs: [ID], stackGroups: [[Int]]) -> [ID: [ID]] {
        var result: [ID: [ID]] = [:]
        for group in stackGroups {
            let members = group.compactMap { $0 < flatIDs.count ? flatIDs[$0] : nil }
            guard members.count >= 2, let host = members.first else { continue }
            result[host] = members
        }
        return result
    }
}
