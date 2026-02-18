import Testing
import Foundation
import SwiftUI
@testable import trm

@MainActor
struct SendTextIndicatorPluginTests {

    /// Helper: create a fresh plugin configured with a registry.
    private func makePlugin() -> SendTextIndicatorPlugin {
        let plugin = SendTextIndicatorPlugin()
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        plugin.configure(registry: registry)
        return plugin
    }

    // MARK: - stop()

    @Test func stopClearsActivePanes() {
        let plugin = makePlugin()
        // Manually set activePanes to simulate detected processes
        plugin.activePanes = [0: "claude", 1: "node"]

        plugin.stop()

        #expect(plugin.activePanes.isEmpty)
    }

    // MARK: - Empty watchedProcessNames

    @Test func emptyWatchedProcessNamesClearsActivePanesOnOutputChange() {
        let plugin = makePlugin()
        plugin.watchedProcessNames = []
        // Manually populate activePanes
        plugin.activePanes = [0: "claude"]

        // Trigger output change -- with empty watchedProcessNames, checkProcess
        // should clear the pane
        plugin.terminalOutputDidChange(paneIndex: 0, text: "some output", hash: "a")

        #expect(plugin.activePanes[0] == nil)
    }

    // MARK: - terminalPaneDidClose

    @Test func terminalPaneDidCloseRemovesPane() {
        let plugin = makePlugin()
        plugin.activePanes = [0: "claude", 1: "node"]

        plugin.terminalPaneDidClose(paneIndex: 0)

        #expect(plugin.activePanes[0] == nil)
        #expect(plugin.activePanes[1] == "node")
    }

    @Test func terminalPaneDidCloseForNonexistentPaneIsNoOp() {
        let plugin = makePlugin()
        plugin.activePanes = [0: "claude"]

        plugin.terminalPaneDidClose(paneIndex: 99)

        #expect(plugin.activePanes.count == 1)
        #expect(plugin.activePanes[0] == "claude")
    }

    // MARK: - Overlay Provider

    @Test func overlayViewReturnsNilWhenNoActivePanes() {
        let plugin = makePlugin()

        #expect(plugin.overlayView(forPane: 0) == nil)
    }

    @Test func overlayViewReturnsNonNilWhenActivePaneExists() {
        let plugin = makePlugin()
        plugin.activePanes = [0: "claude"]

        #expect(plugin.overlayView(forPane: 0) != nil)
    }

    @Test func overlayViewReturnsNilForInactivePane() {
        let plugin = makePlugin()
        plugin.activePanes = [0: "claude"]

        #expect(plugin.overlayView(forPane: 1) == nil)
    }

    @Test func overlayAlignmentIsBottomLeading() {
        let plugin = makePlugin()
        #expect(plugin.overlayAlignment == .bottomLeading)
    }

    // MARK: - watchedProcessNames Configuration

    @Test func settingWatchedProcessNamesPersists() {
        let plugin = makePlugin()

        plugin.watchedProcessNames = ["claude", "node", "python"]

        #expect(plugin.watchedProcessNames.count == 3)
        #expect(plugin.watchedProcessNames.contains("claude"))
        #expect(plugin.watchedProcessNames.contains("node"))
        #expect(plugin.watchedProcessNames.contains("python"))
    }

    @Test func watchedProcessNamesStartsEmpty() {
        let plugin = makePlugin()
        #expect(plugin.watchedProcessNames.isEmpty)
    }

    // MARK: - Plugin Identity

    @Test func pluginIdIsCorrect() {
        let plugin = makePlugin()
        #expect(plugin.pluginId == "send_text_indicator")
    }

    @Test func displayNameIsCorrect() {
        let plugin = makePlugin()
        #expect(plugin.displayName == "Send Text Indicator")
    }

    @Test func requiredCapabilities() {
        #expect(SendTextIndicatorPlugin.requiredCapabilities == [.terminalOutputRead])
    }

    // MARK: - Multiple Pane Management

    @Test func multipleActivePanesTrackedIndependently() {
        let plugin = makePlugin()
        plugin.activePanes = [0: "claude", 1: "node", 2: "python"]

        #expect(plugin.activePanes.count == 3)

        plugin.terminalPaneDidClose(paneIndex: 1)

        #expect(plugin.activePanes.count == 2)
        #expect(plugin.activePanes[0] == "claude")
        #expect(plugin.activePanes[1] == nil)
        #expect(plugin.activePanes[2] == "python")
    }

    @Test func stopAfterMultiplePanesActiveClearsAll() {
        let plugin = makePlugin()
        plugin.activePanes = [0: "claude", 1: "node", 2: "python"]

        plugin.stop()

        #expect(plugin.activePanes.isEmpty)
    }
}
