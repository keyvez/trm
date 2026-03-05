/// Pure-value type encapsulating grid layout math for pane rows/columns.
///
/// `rowCols` holds the number of columns in each row. `displayOrder` is
/// a flat array of pane identifiers whose logical position is derived
/// from `rowCols`.
///
/// The struct is generic over the identifier type so that
/// `BaseTerminalController` can use `ObjectIdentifier` while unit tests
/// can use lightweight `String` identifiers.
struct GridLayout<ID: Equatable> {
    var rowCols: [Int]
    var displayOrder: [ID]

    // MARK: - Position helpers

    /// Convert a flat index into (row, col).
    func gridPosition(flatIndex: Int) -> (row: Int, col: Int) {
        var offset = 0
        for (row, cols) in rowCols.enumerated() {
            if flatIndex < offset + cols {
                return (row, flatIndex - offset)
            }
            offset += cols
        }
        return (max(rowCols.count - 1, 0), 0)
    }

    /// Convert (row, col) into a flat index.
    func flatIndexFor(row: Int, col: Int) -> Int {
        var offset = 0
        for r in 0..<row {
            if r < rowCols.count {
                offset += rowCols[r]
            }
        }
        return offset + col
    }

    // MARK: - Swap (left/right within the same row)

    /// Swap two entries in `displayOrder` by their flat indices.
    mutating func swap(_ i: Int, _ j: Int) {
        guard i >= 0, j >= 0, i < displayOrder.count, j < displayOrder.count, i != j else { return }
        displayOrder.swapAt(i, j)
    }

    // MARK: - Relocate (move between rows)

    /// Remove the pane at `flatIndex` from `fromRow` and insert it into
    /// `toRow` at the closest matching column position.  `rowCols` is
    /// adjusted accordingly; if the source row becomes empty it is removed.
    mutating func relocate(flatIndex: Int, fromRow: Int, toRow: Int) {
        guard fromRow != toRow else { return }
        guard flatIndex >= 0, flatIndex < displayOrder.count else { return }
        guard fromRow >= 0, fromRow < rowCols.count else { return }
        guard toRow >= 0, toRow < rowCols.count else { return }

        // Remember the source column position to preserve relative placement.
        let (_, srcCol) = gridPosition(flatIndex: flatIndex)
        let srcRowCols = rowCols[fromRow]

        // 1. Remove from display order
        let paneID = displayOrder[flatIndex]
        displayOrder.remove(at: flatIndex)

        // 2. Shrink source row
        rowCols[fromRow] -= 1
        var adjustedToRow = toRow
        if rowCols[fromRow] == 0 {
            rowCols.remove(at: fromRow)
            if fromRow < toRow {
                adjustedToRow -= 1
            }
        }

        // 3. Expand target row
        guard adjustedToRow >= 0, adjustedToRow < rowCols.count else {
            // Safety: put it back if target is now invalid
            displayOrder.insert(paneID, at: min(flatIndex, displayOrder.count))
            return
        }
        let targetColsBefore = rowCols[adjustedToRow]
        rowCols[adjustedToRow] += 1

        // 4. Compute insertion column that best preserves the pane's
        //    relative horizontal position within the row.
        let targetCol: Int
        if srcRowCols <= 1 {
            // Only pane in the source row — place at the nearest edge or
            // the middle of the target row.
            targetCol = min(srcCol, targetColsBefore)
        } else {
            let fraction = Double(srcCol) / Double(srcRowCols - 1)
            targetCol = min(Int((fraction * Double(targetColsBefore)).rounded()), targetColsBefore)
        }

        // 5. Insert into display order at the computed column
        let insertFlat = flatIndexFor(row: adjustedToRow, col: targetCol)
        let insertPos = min(insertFlat, displayOrder.count)
        displayOrder.insert(paneID, at: insertPos)
    }

    // MARK: - Insertion helpers

    // MARK: - Reconciliation

    /// Adjust `rowCols` so the total matches `actualCount`.
    /// Trims excess from the last row or appends leftover panes as a new row.
    mutating func reconcile(actualCount: Int) {
        let total = rowCols.reduce(0, +)
        if total == actualCount { return }
        if actualCount <= 0 {
            rowCols = [0]
            return
        }
        if total > actualCount {
            // Shrink from the last row(s)
            var excess = total - actualCount
            while excess > 0, !rowCols.isEmpty {
                let last = rowCols[rowCols.count - 1]
                if last <= excess {
                    excess -= last
                    rowCols.removeLast()
                } else {
                    rowCols[rowCols.count - 1] -= excess
                    excess = 0
                }
            }
            if rowCols.isEmpty { rowCols = [actualCount] }
        } else {
            // More panes than layout accounts for — add remainder as new row
            rowCols.append(actualCount - total)
        }
    }

    /// Insert `id` at the end of the given `row` in `displayOrder`, and
    /// increment `rowCols[row]`.  If `displayOrder` is empty it is not
    /// modified (caller should initialise it first).
    mutating func insertAtEndOfRow(_ id: ID, row: Int) {
        guard row >= 0, row < rowCols.count else { return }
        rowCols[row] += 1
        let insertPos = flatIndexFor(row: row, col: rowCols[row] - 1)
        let pos = min(insertPos, displayOrder.count)
        if !displayOrder.contains(id) {
            displayOrder.insert(id, at: pos)
        }
    }
}
