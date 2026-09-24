import Testing
@testable import trm

/// Moving focus one cell at a time through the grid.
///
/// Ghostty's own `goto_split` walks the split tree, which remembers the order
/// panes were created in rather than where they ended up. These are the rules
/// for the thing actually on screen: rows of cells, possibly jagged, in the
/// order the user arranged them.
struct GridFocusMoveTests {

    // MARK: The shape being navigated

    @Test func theLayoutsOwnRowsAreUsedWhenTheyAddUp() {
        #expect(BaseTerminalController.rowShape(cellCount: 5, rowCols: [3, 2]) == [3, 2])
    }

    @Test func aShapeThatDisagreesWithRealityIsOneRow() {
        // gridRowCols is updated on its own schedule, so a pane parked a
        // moment ago can leave it describing a cell that is not there.
        // Navigating a shape that does not exist is worse than navigating a
        // flat one.
        #expect(BaseTerminalController.rowShape(cellCount: 4, rowCols: [3, 2]) == [4])
        #expect(BaseTerminalController.rowShape(cellCount: 4, rowCols: []) == [4])
        #expect(BaseTerminalController.rowShape(cellCount: 4, rowCols: [4, 0]) == [4])
    }

    // MARK: Left and right

    @Test func movingAlongARow() {
        // [0 1 2]
        // [3 4]
        let rows = [3, 2]
        #expect(BaseTerminalController.neighbour(of: 0, direction: .right, rows: rows) == 1)
        #expect(BaseTerminalController.neighbour(of: 1, direction: .left, rows: rows) == 0)
        #expect(BaseTerminalController.neighbour(of: 4, direction: .left, rows: rows) == 3)
    }

    @Test func anEdgeIsAnEdge() {
        // Nil rather than wrapping: the key is then left unconsumed and the
        // arrow reaches the terminal, which is where a left arrow at the left
        // edge of the window belongs.
        let rows = [3, 2]
        #expect(BaseTerminalController.neighbour(of: 0, direction: .left, rows: rows) == nil)
        #expect(BaseTerminalController.neighbour(of: 2, direction: .right, rows: rows) == nil)
        #expect(BaseTerminalController.neighbour(of: 4, direction: .right, rows: rows) == nil)
    }

    // MARK: Up and down

    @Test func movingBetweenRowsKeepsTheColumn() {
        // [0 1 2]
        // [3 4 5]
        let rows = [3, 3]
        #expect(BaseTerminalController.neighbour(of: 1, direction: .down, rows: rows) == 4)
        #expect(BaseTerminalController.neighbour(of: 5, direction: .up, rows: rows) == 2)
    }

    @Test func aShorterRowTakesTheNearestCell() {
        // [0 1 2]
        // [3 4]
        // Down from the third cell has no third cell to land on, so it takes
        // the last one rather than refusing to move.
        let rows = [3, 2]
        #expect(BaseTerminalController.neighbour(of: 2, direction: .down, rows: rows) == 4)
        #expect(BaseTerminalController.neighbour(of: 4, direction: .up, rows: rows) == 1)
    }

    @Test func thereIsNothingAboveTheTopOrBelowTheBottom() {
        let rows = [2, 2]
        #expect(BaseTerminalController.neighbour(of: 0, direction: .up, rows: rows) == nil)
        #expect(BaseTerminalController.neighbour(of: 3, direction: .down, rows: rows) == nil)
    }

    // MARK: Odd shapes

    @Test func oneRowHasNoUpOrDown() {
        let rows = [4]
        #expect(BaseTerminalController.neighbour(of: 1, direction: .up, rows: rows) == nil)
        #expect(BaseTerminalController.neighbour(of: 1, direction: .down, rows: rows) == nil)
        #expect(BaseTerminalController.neighbour(of: 1, direction: .right, rows: rows) == 2)
    }

    @Test func aJaggedGridIsWalkedRowByRow() {
        // [0]
        // [1 2 3]
        // [4 5]
        let rows = [1, 3, 2]
        #expect(BaseTerminalController.neighbour(of: 0, direction: .down, rows: rows) == 1)
        #expect(BaseTerminalController.neighbour(of: 3, direction: .down, rows: rows) == 5)
        #expect(BaseTerminalController.neighbour(of: 3, direction: .up, rows: rows) == 0)
        #expect(BaseTerminalController.neighbour(of: 5, direction: .up, rows: rows) == 2)
    }

    @Test func nextAndPreviousAreNotDirections() {
        // They cycle through the window rather than pointing anywhere, so the
        // caller handles them and this returns nothing.
        let rows = [2, 2]
        #expect(BaseTerminalController.neighbour(of: 0, direction: .next, rows: rows) == nil)
        #expect(BaseTerminalController.neighbour(of: 0, direction: .previous, rows: rows) == nil)
    }

    @Test func anIndexOutsideTheShapeGoesNowhere() {
        #expect(BaseTerminalController.neighbour(of: 9, direction: .left, rows: [2, 2]) == nil)
    }
}

/// Where focus goes when the focused pane is parked: where moving focus right
/// would have taken it, not the window's first pane.
struct ParkingFocusTests {
    private func target(_ index: Int, vacated: Set<Int> = [], rows: [Int]) -> Int? {
        BaseTerminalController.focusTargetAfterParking(
            from: index, vacated: vacated.union([index]), rows: rows)
    }

    @Test func focusStepsRight() {
        #expect(target(1, rows: [3, 2]) == 2)
        #expect(target(3, rows: [3, 2]) == 4)
    }

    @Test func anOverviewLeavingWithItsTerminalIsSteppedOver() {
        // Terminal at 0, its overview at 1, both parked.
        #expect(target(0, vacated: [1], rows: [3, 2]) == 2)
    }

    @Test func atTheRightEdgeTheNextCellInReadingOrder() {
        #expect(target(2, rows: [3, 2]) == 3)
        // Last cell wraps to the first.
        #expect(target(4, rows: [3, 2]) == 0)
    }

    @Test func nothingLeftIsNil() {
        #expect(target(0, rows: [1]) == nil)
        #expect(target(0, vacated: [1], rows: [2]) == nil)
    }
}
