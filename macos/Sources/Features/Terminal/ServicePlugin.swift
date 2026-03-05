import SwiftUI
import Combine

// MARK: - Capabilities

/// Capabilities that a service plugin can request.
/// The registry grants or denies each capability at registration time.
enum PluginCapability: Hashable, Sendable {
    /// Read terminal pane output via the shared scanner.
    case terminalOutputRead
    /// Make outbound network requests (denied by default).
    case networkAccess
    /// Read from the local file system.
    case fileSystemRead
    /// Write to the system clipboard.
    case clipboardWrite
    /// Post user-facing notifications.
    case userNotifications
}

// MARK: - ServicePlugin

/// A service plugin monitors terminal panes and optionally renders overlays.
/// Unlike pane plugins (which occupy a grid cell), service plugins run
/// alongside terminal panes without taking up layout space.
@MainActor
protocol ServicePlugin: AnyObject {
    /// Unique identifier for this plugin instance.
    var pluginId: String { get }

    /// Human-readable name shown in diagnostics / UI.
    var displayName: String { get }

    /// The capabilities this plugin needs to function.
    static var requiredCapabilities: Set<PluginCapability> { get }

    /// Called once after registration so the plugin can store a reference
    /// to the registry for runtime capability checks.
    func configure(registry: ServicePluginRegistry)

    /// Start the plugin (called after all plugins are registered).
    func start()

    /// Stop the plugin and release resources.
    func stop()
}

// MARK: - ObservableServicePlugin

/// Adopted by service plugins that are also `ObservableObject`, so the
/// registry can forward their `objectWillChange` to drive SwiftUI updates.
@MainActor
protocol ObservableServicePlugin: ServicePlugin {
    func makeObjectWillChangeCancellable(forwarding registry: ServicePluginRegistry) -> AnyCancellable
}

extension ObservableServicePlugin where Self: ObservableObject {
    func makeObjectWillChangeCancellable(forwarding registry: ServicePluginRegistry) -> AnyCancellable {
        self.objectWillChange.sink { [weak registry] _ in
            registry?.objectWillChange.send()
        }
    }
}

// MARK: - TerminalOutputSubscriber

/// Receives terminal output change notifications from `TerminalOutputScanner`.
@MainActor
protocol TerminalOutputSubscriber: AnyObject {
    /// Called when the visible text of a pane changes.
    func terminalOutputDidChange(paneId: Int, text: String, hash: String)

    /// Called when a terminal pane is removed.
    func terminalPaneDidClose(paneId: Int)

    /// Called when a shell command finishes in a pane (OSC 133;D).
    /// Plugins can use this to reset state that was locked to the previous command.
    func terminalCommandDidFinish(paneId: Int)
}

extension TerminalOutputSubscriber {
    func terminalCommandDidFinish(paneId: Int) {}
}

// MARK: - ServicePluginOverlayProvider

/// A service plugin that provides a SwiftUI overlay for terminal panes.
@MainActor
protocol ServicePluginOverlayProvider: ServicePlugin {
    /// Returns an overlay view for the given pane index, or `nil` if none.
    func overlayView(forPaneId paneId: Int) -> AnyView?

    /// Where to anchor the overlay within the pane.
    var overlayAlignment: Alignment { get }
}
