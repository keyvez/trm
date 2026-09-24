import Testing
@testable import trm

/// What a window opened with no layout of its own starts from.
///
/// The app-wide config is whatever trm was launched with, and after a Reload
/// Latest UI or a `--config` launch that is a snapshot of a whole session. It
/// seeds the first window; every window after that drops the layout and keeps
/// the preferences.
struct StartupLayoutTests {

    private func sessionSnapshot() -> Trm.TrmGridConfig {
        var config = Trm.TrmGridConfig(
            rows: 2, cols: 3, gap: 6, padding: 10,
            panes: (0..<5).map { i in
                Trm.TrmPaneConfig(
                    paneType: "terminal", command: "claude", cwd: "/Users/g/dev/trm",
                    watermark: "pane\(i)", title: nil, url: nil, file: nil, content: nil,
                    target: nil, targetTitle: nil, path: nil, refreshMs: nil, repo: nil,
                    initialCommands: [], patterns: [])
            },
            rowCols: [3, 2])
        config.windowId = "247D2CFC"
        config.rowFractions = [0.6, 0.4]
        config.colFractions = [[0.5, 0.25, 0.25], [0.5, 0.5]]
        config.windowSize = CGSize(width: 2056, height: 1290)
        config.windowOrigin = CGPoint(x: 0, y: 0)
        config.sidebarWidth = 260
        config.textTapSocket = "/tmp/trm.sock"
        return config
    }

    @Test func aWindowWithNoLayoutOfItsOwnGetsOnePane() {
        let bare = sessionSnapshot().withoutLayout
        #expect(bare.panes.isEmpty)
        #expect(bare.rows == 1)
        #expect(bare.cols == 1)
        #expect(bare.rowCols.isEmpty)
    }

    @Test func theSavedGeometryDoesNotComeWithIt() {
        // A new window cascades to its own place and size. Inheriting the
        // snapshot's frame would stack it exactly on the window it was
        // copied from.
        let bare = sessionSnapshot().withoutLayout
        #expect(bare.windowSize == nil)
        #expect(bare.windowOrigin == nil)
        #expect(bare.rowFractions.isEmpty)
        #expect(bare.colFractions.isEmpty)
    }

    @Test func theWindowIdIsNotReused() {
        // The identity belongs to the window the snapshot was written for;
        // two windows claiming it would checkpoint over each other.
        #expect(sessionSnapshot().withoutLayout.windowId == nil)
    }

    @Test func preferencesSurvive() {
        // Gap, padding, the sidebar's width and the Text Tap socket are how
        // this trm is set up, not a layout — a blank window keeps them.
        let original = sessionSnapshot()
        let bare = original.withoutLayout
        #expect(bare.gap == original.gap)
        #expect(bare.padding == original.padding)
        #expect(bare.sidebarWidth == original.sidebarWidth)
        #expect(bare.textTapSocket == original.textTapSocket)
    }
}
