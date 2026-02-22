import Testing
@testable import trm

struct GridLayoutTests {

    // MARK: - Position Helpers

    @Test func gridPositionBasic() {
        let layout = GridLayout<String>(rowCols: [3, 2], displayOrder: ["A","B","C","D","E"])
        #expect(layout.gridPosition(flatIndex: 0) == (row: 0, col: 0))
        #expect(layout.gridPosition(flatIndex: 2) == (row: 0, col: 2))
        #expect(layout.gridPosition(flatIndex: 3) == (row: 1, col: 0))
        #expect(layout.gridPosition(flatIndex: 4) == (row: 1, col: 1))
    }

    @Test func flatIndexForBasic() {
        let layout = GridLayout<String>(rowCols: [3, 2], displayOrder: ["A","B","C","D","E"])
        #expect(layout.flatIndexFor(row: 0, col: 0) == 0)
        #expect(layout.flatIndexFor(row: 0, col: 2) == 2)
        #expect(layout.flatIndexFor(row: 1, col: 0) == 3)
        #expect(layout.flatIndexFor(row: 1, col: 1) == 4)
    }

    // MARK: - Relocate Down

    @Test func relocateDown_5x2_becomess_4x3() {
        // Move last col of row 0 (flat 4) down to row 1
        var layout = GridLayout<String>(
            rowCols: [5, 2],
            displayOrder: ["A","B","C","D","E","F","G"]
        )
        layout.relocate(flatIndex: 4, fromRow: 0, toRow: 1)
        #expect(layout.rowCols == [4, 3])
        // "E" should be at end of row 1
        #expect(layout.displayOrder == ["A","B","C","D","F","G","E"])
    }

    @Test func relocateDown_4x3_becomes_3x4() {
        // Move last col of row 0 (flat 3) down to row 1
        var layout = GridLayout<String>(
            rowCols: [4, 3],
            displayOrder: ["A","B","C","D","E","F","G"]
        )
        layout.relocate(flatIndex: 3, fromRow: 0, toRow: 1)
        #expect(layout.rowCols == [3, 4])
        #expect(layout.displayOrder == ["A","B","C","E","F","G","D"])
    }

    @Test func relocateDown_singleColRowRemoved() {
        // rowCols [3, 1, 2] — move flat 3 (row 1's only col) down to row 2
        // Row 1 vanishes; old row 2 absorbs the pane.
        // "D" was at col 0, so it lands at col 0 of the target row.
        var layout = GridLayout<String>(
            rowCols: [3, 1, 2],
            displayOrder: ["A","B","C","D","E","F"]
        )
        layout.relocate(flatIndex: 3, fromRow: 1, toRow: 2)
        #expect(layout.rowCols == [3, 3])
        #expect(layout.displayOrder == ["A","B","C","D","E","F"])
    }

    @Test func relocateDown_singleColTopRowRemoved() {
        // rowCols [1, 3] — move flat 0 down → row 0 disappears → [4]
        // "A" was at col 0, so it lands at col 0 of the merged row.
        var layout = GridLayout<String>(
            rowCols: [1, 3],
            displayOrder: ["A","B","C","D"]
        )
        layout.relocate(flatIndex: 0, fromRow: 0, toRow: 1)
        #expect(layout.rowCols == [4])
        #expect(layout.displayOrder == ["A","B","C","D"])
    }

    @Test func relocateDown_sequentialMoves_9x2x9x1x9() {
        // Start with [9,2,9,1,9], move last col of row 0 down repeatedly
        var layout = GridLayout<String>(
            rowCols: [9, 2, 9, 1, 9],
            displayOrder: (0..<30).map { String($0) }
        )

        // Move flat 8 (last col of row 0) down to row 1
        layout.relocate(flatIndex: 8, fromRow: 0, toRow: 1)
        #expect(layout.rowCols == [8, 3, 9, 1, 9])

        // Move flat 7 (now last col of row 0) down to row 1
        layout.relocate(flatIndex: 7, fromRow: 0, toRow: 1)
        #expect(layout.rowCols == [7, 4, 9, 1, 9])
    }

    // MARK: - Relocate Up

    @Test func relocateUp_2x5_becomes_3x4() {
        // Move first col of row 1 (flat 2) up to row 0
        // "C" was at col 0 of 5, so it lands at col 0 of row 0.
        var layout = GridLayout<String>(
            rowCols: [2, 5],
            displayOrder: ["A","B","C","D","E","F","G"]
        )
        layout.relocate(flatIndex: 2, fromRow: 1, toRow: 0)
        #expect(layout.rowCols == [3, 4])
        #expect(layout.displayOrder == ["C","A","B","D","E","F","G"])
    }

    @Test func relocateUp_singleColBottomRowRemoved() {
        // rowCols [3, 1] — move flat 3 up → row 1 disappears → [4]
        // "D" was at col 0, so it lands at col 0 of the merged row.
        var layout = GridLayout<String>(
            rowCols: [3, 1],
            displayOrder: ["A","B","C","D"]
        )
        layout.relocate(flatIndex: 3, fromRow: 1, toRow: 0)
        #expect(layout.rowCols == [4])
        #expect(layout.displayOrder == ["D","A","B","C"])
    }

    @Test func relocateUp_middleRowToTop() {
        // rowCols [2, 3, 2] — move flat 3 (row 1 col 1 of 3) up to row 0
        // fraction = 1/2 = 0.5, target has 2 cols → col 1 (middle).
        var layout = GridLayout<String>(
            rowCols: [2, 3, 2],
            displayOrder: ["A","B","C","D","E","F","G"]
        )
        layout.relocate(flatIndex: 3, fromRow: 1, toRow: 0)
        #expect(layout.rowCols == [3, 2, 2])
        #expect(layout.displayOrder == ["A","D","B","C","E","F","G"])
    }

    // MARK: - Swap (left/right)

    @Test func swapLeftInRow() {
        var layout = GridLayout<String>(
            rowCols: [3, 2],
            displayOrder: ["A","B","C","D","E"]
        )
        // Swap flat 1 with flat 0 (left swap)
        layout.swap(1, 0)
        #expect(layout.rowCols == [3, 2]) // unchanged
        #expect(layout.displayOrder == ["B","A","C","D","E"])
    }

    @Test func swapRightInRow() {
        var layout = GridLayout<String>(
            rowCols: [3, 2],
            displayOrder: ["A","B","C","D","E"]
        )
        // Swap flat 0 with flat 1 (right swap)
        layout.swap(0, 1)
        #expect(layout.rowCols == [3, 2]) // unchanged
        #expect(layout.displayOrder == ["B","A","C","D","E"])
    }

    // MARK: - Insert at end of row

    @Test func insertAtEndOfFocusedRow() {
        // rowCols [3, 2], insert new pane into row 0 → [4, 2]
        var layout = GridLayout<String>(
            rowCols: [3, 2],
            displayOrder: ["A","B","C","D","E"]
        )
        layout.insertAtEndOfRow("X", row: 0)
        #expect(layout.rowCols == [4, 2])
        #expect(layout.displayOrder == ["A","B","C","X","D","E"])
    }

    @Test func insertAtEndOfLastRow() {
        // rowCols [3, 2], insert new pane into row 1 → [3, 3]
        var layout = GridLayout<String>(
            rowCols: [3, 2],
            displayOrder: ["A","B","C","D","E"]
        )
        layout.insertAtEndOfRow("X", row: 1)
        #expect(layout.rowCols == [3, 3])
        #expect(layout.displayOrder == ["A","B","C","D","E","X"])
    }

    // MARK: - Edge Cases

    @Test func relocateSameRowIsNoOp() {
        var layout = GridLayout<String>(
            rowCols: [3, 2],
            displayOrder: ["A","B","C","D","E"]
        )
        layout.relocate(flatIndex: 1, fromRow: 0, toRow: 0)
        #expect(layout.rowCols == [3, 2])
        #expect(layout.displayOrder == ["A","B","C","D","E"])
    }

    @Test func relocateOutOfBoundsIsNoOp() {
        var layout = GridLayout<String>(
            rowCols: [3, 2],
            displayOrder: ["A","B","C","D","E"]
        )
        layout.relocate(flatIndex: 1, fromRow: 0, toRow: 5)
        #expect(layout.rowCols == [3, 2])
        #expect(layout.displayOrder == ["A","B","C","D","E"])
    }

    @Test func swapOutOfBoundsIsNoOp() {
        var layout = GridLayout<String>(
            rowCols: [3],
            displayOrder: ["A","B","C"]
        )
        layout.swap(0, 10)
        #expect(layout.displayOrder == ["A","B","C"])
    }

    @Test func relocateDown_firstColOfRow() {
        // Move first col of row 0 (flat 0, col 0 of 3) down to row 1 (has 2 cols)
        // fraction = 0/2 = 0.0, so "A" lands at col 0 of row 1.
        var layout = GridLayout<String>(
            rowCols: [3, 2],
            displayOrder: ["A","B","C","D","E"]
        )
        layout.relocate(flatIndex: 0, fromRow: 0, toRow: 1)
        #expect(layout.rowCols == [2, 3])
        #expect(layout.displayOrder == ["B","C","A","D","E"])
    }

    @Test func relocateUp_lastColOfBottomRow() {
        // Move last col of row 1 (flat 4) up to row 0
        var layout = GridLayout<String>(
            rowCols: [3, 2],
            displayOrder: ["A","B","C","D","E"]
        )
        layout.relocate(flatIndex: 4, fromRow: 1, toRow: 0)
        #expect(layout.rowCols == [4, 1])
        // "E" appended at end of row 0
        #expect(layout.displayOrder == ["A","B","C","E","D"])
    }
}
