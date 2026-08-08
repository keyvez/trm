import Testing
import Foundation
import SwiftUI
@testable import trm

/// The SendTextIndicatorPlugin is a thin poller over the Zig Text Tap
/// state (via `Trm.shared`), so unit tests cover the plugin's own surface:
/// identity, capabilities, overlay alignment, and lifecycle safety. The
/// pane-active behavior lives in the Zig `text_tap.zig` tests.
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

    // MARK: - Plugin Identity

    @Test func pluginIdIsCorrect() {
        let plugin = makePlugin()
        #expect(plugin.pluginId == "send_text_indicator")
    }

    @Test func displayNameIsCorrect() {
        let plugin = makePlugin()
        #expect(plugin.displayName == "Send Text Indicator")
    }

    @Test func requiredCapabilitiesIsEmpty() {
        // The plugin reads connection state from the Zig backend, not
        // terminal output, so it requires no capabilities.
        #expect(SendTextIndicatorPlugin.requiredCapabilities.isEmpty)
    }

    // MARK: - Overlay Provider

    @Test func overlayAlignmentIsBottomLeading() {
        let plugin = makePlugin()
        #expect(plugin.overlayAlignment == .bottomLeading)
    }

    // MARK: - Lifecycle

    // Note: start() is intentionally not exercised here — it polls
    // Trm.shared, whose lazy init creates the real Zig app and binds the
    // debug Text Tap socket, which would fight a running debug instance.
    @Test func stopWithoutStartIsSafe() {
        let plugin = makePlugin()
        plugin.stop()
    }

    @Test func pollGenerationStartsAtZero() {
        let plugin = makePlugin()
        #expect(plugin.pollGeneration == 0)
    }
}
