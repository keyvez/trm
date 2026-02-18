import Testing
import Foundation
import SwiftUI
import Combine
@testable import trm

@MainActor
struct ClaudeAttentionPluginTests {

    /// Helper: create a fresh plugin configured with a registry.
    private func makePlugin() -> ClaudeAttentionPlugin {
        let plugin = ClaudeAttentionPlugin()
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        plugin.configure(registry: registry)
        return plugin
    }

    // MARK: - Lifecycle

    @Test func startRegistersNotificationObserver() {
        let plugin = makePlugin()
        plugin.start()

        // Post a notification and verify the plugin receives it
        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 0]
        )

        #expect(plugin.attentionPanes.contains(0))

        plugin.stop()
    }

    @Test func stopRemovesObserverAndClearsAttentionPanes() {
        let plugin = makePlugin()
        plugin.start()

        // Trigger attention
        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 1]
        )
        #expect(plugin.attentionPanes.contains(1))

        plugin.stop()

        #expect(plugin.attentionPanes.isEmpty)

        // Post again after stop -- should NOT be received
        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 2]
        )
        #expect(!plugin.attentionPanes.contains(2))
    }

    // MARK: - Notification Handling

    @Test func postingNotificationAddsToAttentionPanes() {
        let plugin = makePlugin()
        plugin.start()

        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 5]
        )

        #expect(plugin.attentionPanes.contains(5))
        plugin.stop()
    }

    @Test func multipleNotificationsAddMultiplePanes() {
        let plugin = makePlugin()
        plugin.start()

        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 0]
        )
        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 1]
        )
        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 2]
        )

        #expect(plugin.attentionPanes.count == 3)
        #expect(plugin.attentionPanes.contains(0))
        #expect(plugin.attentionPanes.contains(1))
        #expect(plugin.attentionPanes.contains(2))

        plugin.stop()
    }

    @Test func notificationWithoutPaneIndexIsIgnored() {
        let plugin = makePlugin()
        plugin.start()

        // Post without paneIndex in userInfo
        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: nil
        )

        #expect(plugin.attentionPanes.isEmpty)
        plugin.stop()
    }

    // MARK: - Terminal Output Dismisses Attention

    @Test func terminalOutputDidChangeRemovesPaneFromAttention() {
        let plugin = makePlugin()
        plugin.start()

        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 0]
        )
        #expect(plugin.attentionPanes.contains(0))

        // User types in that pane -> output changes
        plugin.terminalOutputDidChange(paneIndex: 0, text: "user input", hash: "abc")

        #expect(!plugin.attentionPanes.contains(0))
        plugin.stop()
    }

    @Test func terminalOutputOnDifferentPaneDoesNotClearOther() {
        let plugin = makePlugin()
        plugin.start()

        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 0]
        )
        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 1]
        )

        // Output change on pane 0 only
        plugin.terminalOutputDidChange(paneIndex: 0, text: "typed", hash: "x")

        #expect(!plugin.attentionPanes.contains(0))
        #expect(plugin.attentionPanes.contains(1))

        plugin.stop()
    }

    // MARK: - Pane Close

    @Test func terminalPaneDidCloseRemovesPaneFromAttention() {
        let plugin = makePlugin()
        plugin.start()

        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 3]
        )
        #expect(plugin.attentionPanes.contains(3))

        plugin.terminalPaneDidClose(paneIndex: 3)

        #expect(!plugin.attentionPanes.contains(3))
        plugin.stop()
    }

    // MARK: - Overlay Provider

    @Test func overlayViewReturnsNilWhenNoAttention() {
        let plugin = makePlugin()

        #expect(plugin.overlayView(forPane: 0) == nil)
    }

    @Test func overlayViewReturnsNonNilWhenAttentionExists() {
        let plugin = makePlugin()
        plugin.start()

        NotificationCenter.default.post(
            name: .trmClaudeNeedsAttention,
            object: nil,
            userInfo: ["paneIndex": 0]
        )

        #expect(plugin.overlayView(forPane: 0) != nil)
        // Different pane should still be nil
        #expect(plugin.overlayView(forPane: 1) == nil)

        plugin.stop()
    }

    @Test func overlayAlignmentIsTopLeading() {
        let plugin = makePlugin()
        #expect(plugin.overlayAlignment == .topLeading)
    }

    // MARK: - Plugin Identity

    @Test func pluginIdIsCorrect() {
        let plugin = makePlugin()
        #expect(plugin.pluginId == "claude_attention")
    }

    @Test func displayNameIsCorrect() {
        let plugin = makePlugin()
        #expect(plugin.displayName == "Claude Attention")
    }

    @Test func requiredCapabilities() {
        #expect(ClaudeAttentionPlugin.requiredCapabilities == [.terminalOutputRead])
    }
}
