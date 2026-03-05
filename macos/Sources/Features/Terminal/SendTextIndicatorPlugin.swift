import Foundation
import SwiftUI
import Combine
import os

/// Shows a small indicator pill on terminal panes that are connected to
/// an external app via the Text Tap Unix socket (`/tmp/trm.sock` for
/// release builds, `/tmp/trm-debug.sock` for debug builds).
///
/// Detection: The Zig Text Tap server tracks active panes by stable ID.
/// Every 2s the plugin triggers a SwiftUI re-evaluation; each pane's
/// overlay queries `Trm.shared.isTextTapActive(paneId:)` directly.
@MainActor
final class SendTextIndicatorPlugin: ObservableObject, ServicePlugin, ObservableServicePlugin, ServicePluginOverlayProvider {

    // MARK: - ServicePlugin

    let pluginId = "send_text_indicator"
    let displayName = "Send Text Indicator"

    static let requiredCapabilities: Set<PluginCapability> = []

    private weak var registry: ServicePluginRegistry?
    private var pollTimer: Timer?

    private static let log = Logger(subsystem: "com.trm", category: "SendTextIndicator")

    func configure(registry: ServicePluginRegistry) {
        self.registry = registry
    }

    func start() {
        // Poll the Text Tap active panes bitset every 2 seconds, independent
        // of terminal output changes. A socket client may target a pane
        // even when the terminal content hasn't changed.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshActivePanes()
            }
        }
        // Initial check
        refreshActivePanes()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Published State

    /// Incremented each poll cycle to trigger SwiftUI re-evaluation.
    @Published var pollGeneration: UInt = 0

    // MARK: - ServicePluginOverlayProvider

    var overlayAlignment: Alignment { .bottomLeading }

    func overlayView(forPaneId paneId: Int) -> AnyView? {
        // Read pollGeneration to establish SwiftUI dependency.
        _ = pollGeneration
        guard Trm.shared.isTextTapActive(paneId: paneId) else { return nil }
        return AnyView(
            SendTextIndicatorView()
                .padding(.bottom, 8)
                .padding(.leading, 8)
        )
    }

    // MARK: - Text Tap Polling

    /// Trigger a SwiftUI refresh so `overlayView(forPaneId:)` re-evaluates.
    private func refreshActivePanes() {
        // Force a publish so overlay views re-query the Zig stable-ID API.
        // The actual per-pane check happens in overlayView(forPaneId:).
        pollGeneration += 1
    }
}

// MARK: - Indicator View

/// A small rounded pill indicating this pane is connected to an external app.
struct SendTextIndicatorView: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
            Text("flan")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.teal.opacity(0.8))
        )
        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}
