import Testing
import Foundation
@testable import trm

/// The context reading is process-wide (one agent hook writes it for the
/// whole app), so each window filters it to its own panes — otherwise every
/// window shows a pill for an agent running somewhere else.
@MainActor
struct ContextUsageAttributionTests {

    private func usage(
        paneId: Int?,
        lastUpdate: Date = Date()
    ) -> Trm.ContextUsageData {
        Trm.ContextUsageData(
            usedTokens: 1000,
            totalTokens: 200_000,
            percentage: 1,
            isPreCompact: false,
            sessionId: "session-1",
            lastUpdate: lastUpdate,
            paneId: paneId
        )
    }

    @Test func showsReadingForAnOwnedPane() {
        let manager = ContextUsageManager()
        manager.ownedPaneIds = { [1, 2, 3] }
        #expect(manager.shouldDisplay(usage(paneId: 2)))
    }

    @Test func hidesReadingForAnotherWindowsPane() {
        let manager = ContextUsageManager()
        manager.ownedPaneIds = { [1, 2, 3] }
        #expect(!manager.shouldDisplay(usage(paneId: 99)))
    }

    @Test func hidesEverythingWhenWindowHasNoPanes() {
        let manager = ContextUsageManager()
        manager.ownedPaneIds = { [] }
        #expect(!manager.shouldDisplay(usage(paneId: 1)))
    }

    @Test func unattributedReadingShowsEverywhere() {
        // Older hook scripts don't send a pane; preserve the previous
        // global behavior rather than hiding the pill entirely.
        let manager = ContextUsageManager()
        manager.ownedPaneIds = { [1, 2] }
        #expect(manager.shouldDisplay(usage(paneId: nil)))
    }

    @Test func noOwnershipProviderKeepsGlobalBehavior() {
        let manager = ContextUsageManager()
        #expect(manager.shouldDisplay(usage(paneId: 42)))
    }

    @Test func staleReadingIsHiddenEvenForAnOwnedPane() {
        // An agent that goes idle stops sending hooks; the pill must not
        // linger forever showing a stale number.
        let manager = ContextUsageManager()
        manager.ownedPaneIds = { [1] }
        let old = Date().addingTimeInterval(-(ContextUsageManager.stalenessInterval + 60))
        #expect(!manager.shouldDisplay(usage(paneId: 1, lastUpdate: old)))
    }

    @Test func recentReadingJustInsideTheWindowStillShows() {
        let manager = ContextUsageManager()
        manager.ownedPaneIds = { [1] }
        let recent = Date().addingTimeInterval(-(ContextUsageManager.stalenessInterval - 60))
        #expect(manager.shouldDisplay(usage(paneId: 1, lastUpdate: recent)))
    }

    @Test func staleUnattributedReadingIsAlsoHidden() {
        let manager = ContextUsageManager()
        let old = Date().addingTimeInterval(-(ContextUsageManager.stalenessInterval + 1))
        #expect(!manager.shouldDisplay(usage(paneId: nil, lastUpdate: old)))
    }
}
