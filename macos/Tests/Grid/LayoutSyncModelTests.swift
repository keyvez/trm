import Testing
@testable import trm

/// Tests for the pure reconciliation helpers behind live layout sync
/// (mirror windows applying the primary's broadcast layout in place).
struct LayoutSyncModelTests {

    // MARK: stackGroups

    @Test func groupsConsecutiveTags() {
        let groups = LayoutSyncModel.stackGroups(forTags: [nil, "s0", "s0", nil, "s1", "s1", "s1"])
        #expect(groups == [[1, 2], [4, 5, 6]])
    }

    @Test func singletonTagIsNotAStack() {
        let groups = LayoutSyncModel.stackGroups(forTags: [nil, "s0", nil])
        #expect(groups.isEmpty)
    }

    @Test func nonConsecutiveSameTagStillGroups() {
        // Mirrors restoreStackGroups: grouping is by name, not adjacency.
        let groups = LayoutSyncModel.stackGroups(forTags: ["s0", nil, "s0"])
        #expect(groups == [[0, 2]])
    }

    @Test func noTagsNoGroups() {
        #expect(LayoutSyncModel.stackGroups(forTags: [nil, nil]).isEmpty)
        #expect(LayoutSyncModel.stackGroups(forTags: []).isEmpty)
    }

    // MARK: visualCellCount

    @Test func stacksCollapseIntoOneCell() {
        // 5 flat panes, one 3-pane stack → 3 visual cells.
        let groups = LayoutSyncModel.stackGroups(forTags: [nil, "s0", "s0", "s0", nil])
        #expect(LayoutSyncModel.visualCellCount(flatCount: 5, stackGroups: groups) == 3)
    }

    @Test func noStacksAllCellsVisible() {
        #expect(LayoutSyncModel.visualCellCount(flatCount: 4, stackGroups: []) == 4)
    }

    // MARK: targetRowCols

    @Test func usesConfigRowColsWhenSumMatches() {
        let rowCols = LayoutSyncModel.targetRowCols(
            visualCount: 3, configRowCols: [2, 1], rows: 1, cols: 3)
        #expect(rowCols == [2, 1])
    }

    @Test func fallsBackToUniformShapeWhenRowColsMissing() {
        let rowCols = LayoutSyncModel.targetRowCols(
            visualCount: 4, configRowCols: [], rows: 2, cols: 2)
        #expect(rowCols == [2, 2])
    }

    @Test func fallsBackWhenRowColsSumMismatches() {
        // A skipped pane (dead zmx session) makes the config shape stale.
        let rowCols = LayoutSyncModel.targetRowCols(
            visualCount: 3, configRowCols: [2, 2], rows: 2, cols: 2)
        #expect(rowCols.reduce(0, +) == 3)
    }

    @Test func zeroPanesYieldsSingleCell() {
        #expect(LayoutSyncModel.targetRowCols(
            visualCount: 0, configRowCols: [], rows: 1, cols: 1) == [1])
    }

    // MARK: paneStacks

    @Test func stacksKeyedByHostFirstMember() {
        let ids = ["a", "b", "c", "d"]
        let groups = LayoutSyncModel.stackGroups(forTags: [nil, "s0", "s0", nil])
        let stacks = LayoutSyncModel.paneStacks(flatIDs: ids, stackGroups: groups)
        #expect(stacks == ["b": ["b", "c"]])
    }

    @Test func outOfRangeGroupIndicesAreDropped() {
        let stacks = LayoutSyncModel.paneStacks(flatIDs: ["a"], stackGroups: [[0, 5]])
        #expect(stacks.isEmpty)
    }

    @Test func overviewFirstStackKeepsSerializedOrderAndVisualShape() {
        // Real Reload Latest UI regression: the overview is the stack host and
        // therefore appears before its terminal in the flat TOML. Initial
        // restore used to create all terminals first and overviews last,
        // turning the saved visual rows [3, 2, 1] into [4, 1, 1].
        let ids = ["overview-fasmac", "gooshi", "fasmac", "tow", "overview-tow", "overview-gooshi", "mini"]
        let tags: [String?] = ["s0", "s0", nil, nil, nil, nil, nil]
        let groups = LayoutSyncModel.stackGroups(forTags: tags)

        #expect(groups == [[0, 1]])
        #expect(LayoutSyncModel.paneStacks(flatIDs: ids, stackGroups: groups) == [
            "overview-fasmac": ["overview-fasmac", "gooshi"]
        ])
        #expect(LayoutSyncModel.targetRowCols(
            visualCount: LayoutSyncModel.visualCellCount(
                flatCount: ids.count,
                stackGroups: groups
            ),
            configRowCols: [3, 2, 1],
            rows: 3,
            cols: 3
        ) == [3, 2, 1])
    }
}

/// Tests for the layout-sync TOML extras scanner (top-level window identity
/// keys + [grid] fraction keys the C API doesn't know about).
struct LayoutExtrasParsingTests {

    @Test func parsesTopLevelIdentityKeys() {
        let toml = """
        # trm session config
        window_id = "ABC-123"
        text_tap_socket = "/tmp/trm-e2e.sock"
        layout_mirror = true

        [grid]
        rows = 1
        """
        let extras = Trm.parseLayoutExtras(fromToml: toml)
        #expect(extras.windowId == "ABC-123")
        #expect(extras.textTapSocket == "/tmp/trm-e2e.sock")
        #expect(extras.layoutMirror)
    }

    @Test func ignoresIdentityKeysInsideSections() {
        let toml = """
        [grid]
        rows = 1

        [[panes]]
        window_id = "should-not-count"
        """
        let extras = Trm.parseLayoutExtras(fromToml: toml)
        #expect(extras.windowId == nil)
        #expect(!extras.layoutMirror)
    }

    @Test func parsesGridFractions() {
        let toml = """
        window_id = "w"

        [grid]
        rows = 2
        row_fractions = "0.2500,0.7500"
        col_fractions = "0.5000,0.5000;1.0000"
        """
        let extras = Trm.parseLayoutExtras(fromToml: toml)
        #expect(extras.rowFractions == [0.25, 0.75])
        #expect(extras.colFractions == [[0.5, 0.5], [1.0]])
    }

    @Test func fractionKeysOutsideGridSectionAreIgnored() {
        let toml = """
        row_fractions = "0.5,0.5"

        [[panes]]
        col_fractions = "1.0"
        """
        let extras = Trm.parseLayoutExtras(fromToml: toml)
        #expect(extras.rowFractions.isEmpty)
        #expect(extras.colFractions.isEmpty)
    }

    @Test func parseFractionListSkipsGarbage() {
        #expect(Trm.parseFractionList("0.25, 0.75") == [0.25, 0.75])
        #expect(Trm.parseFractionList("a,0.5") == [0.5])
        #expect(Trm.parseFractionList("") == [])
    }
}
