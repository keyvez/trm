import Foundation
import SwiftUI
import Combine

/// Tracks panes where an agent (Claude Code, etc.) needs user attention.
///
/// Renders both:
/// 1. A pulsing sparkle icon overlay (top-left of the pane)
/// 2. Drives the notification ring border (blue glow) in TrmGridView
///    via the `attentionPanes` set exposed to `BaseTerminalController`.
///
/// Attention is dismissed when:
/// - The user types in the pane (terminal output changes)
/// - The pane is focused by the user
/// - The pane is closed
@MainActor
final class ClaudeAttentionPlugin: ObservableObject, ServicePlugin, ObservableServicePlugin, TerminalOutputSubscriber, ServicePluginOverlayProvider {

    // MARK: - ServicePlugin

    let pluginId = "claude_attention"
    let displayName = "Claude Attention"

    static let requiredCapabilities: Set<PluginCapability> = [.terminalOutputRead]

    private weak var registry: ServicePluginRegistry?
    private var notificationObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?

    func configure(registry: ServicePluginRegistry) {
        self.registry = registry
    }

    func start() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .trmClaudeNeedsAttention,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let paneId = notification.userInfo?["paneId"] as? Int else { return }
            self.attentionPanes.insert(paneId)
        }

        // Dismiss attention when the user focuses a pane (highlight notification).
        focusObserver = NotificationCenter.default.addObserver(
            forName: Trm.highlightPane,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let paneId = notification.userInfo?["paneId"] as? Int else { return }
            if self.attentionPanes.contains(paneId) {
                self.attentionPanes.remove(paneId)
            }
        }
    }

    func stop() {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
        if let observer = focusObserver {
            NotificationCenter.default.removeObserver(observer)
            focusObserver = nil
        }
        attentionPanes.removeAll()
    }

    // MARK: - Published State

    /// Pane IDs that currently need attention.
    @Published var attentionPanes: Set<Int> = []

    // MARK: - TerminalOutputSubscriber

    func terminalOutputDidChange(paneId: Int, text: String, hash: String) {
        // User typed something — dismiss the attention for this pane.
        if attentionPanes.contains(paneId) {
            attentionPanes.remove(paneId)
        }
    }

    func terminalPaneDidClose(paneId: Int) {
        attentionPanes.remove(paneId)
    }

    // MARK: - ServicePluginOverlayProvider

    var overlayAlignment: Alignment { .topLeading }

    func overlayView(forPaneId paneId: Int) -> AnyView? {
        guard attentionPanes.contains(paneId) else { return nil }
        return AnyView(
            ClaudeAttentionIconView()
                .padding(.top, 8)
                .padding(.leading, 8)
        )
    }
}

// MARK: - Icon View

/// A small pulsing sparkle indicator that signals an agent is waiting for input.
struct ClaudeAttentionIconView: View {
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0x58/255, green: 0xa6/255, blue: 0xff/255).opacity(0.85))
            )
            .scaleEffect(isPulsing ? 1.1 : 1.0)
            .opacity(isPulsing ? 1.0 : 0.75)
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            .onAppear { isPulsing = true }
    }
}
