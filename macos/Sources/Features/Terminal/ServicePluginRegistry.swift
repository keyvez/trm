import SwiftUI
import Combine

/// Manages the lifecycle of service plugins and enforces capability-based
/// permissions. Owns the shared `TerminalOutputScanner` and automatically
/// subscribes plugins that have been granted `.terminalOutputRead`.
@MainActor
final class ServicePluginRegistry: ObservableObject {

    /// Registered plugins keyed by `pluginId`.
    private(set) var plugins: [String: any ServicePlugin] = [:]

    /// Granted capabilities per plugin.
    private var grantedCapabilities: [String: Set<PluginCapability>] = [:]

    /// The shared terminal output scanner.
    let scanner: TerminalOutputScanner

    /// Subscriptions forwarding plugin objectWillChange to the registry, keyed by pluginId.
    private var pluginCancellables: [String: AnyCancellable] = [:]

    init(scanner: TerminalOutputScanner) {
        self.scanner = scanner
    }

    // ------------------------------------------------------------------
    // MARK: Registration
    // ------------------------------------------------------------------

    /// Register a plugin. Capabilities are granted based on the plugin's
    /// declared requirements, except `.networkAccess` which is denied by
    /// default.
    func register(_ plugin: any ServicePlugin) {
        let id = plugin.pluginId
        plugins[id] = plugin

        // Grant all requested capabilities except networkAccess
        var granted = type(of: plugin).requiredCapabilities
        granted.remove(.networkAccess)
        grantedCapabilities[id] = granted

        plugin.configure(registry: self)

        // Auto-subscribe to terminal output if granted
        if granted.contains(.terminalOutputRead),
           let subscriber = plugin as? any TerminalOutputSubscriber {
            scanner.addSubscriber(subscriber)
        }

        // Forward the plugin's objectWillChange so SwiftUI views
        // observing this registry re-render when plugin state changes.
        if let forwarder = plugin as? any ObservableServicePlugin {
            pluginCancellables[id] = forwarder.makeObjectWillChangeCancellable(forwarding: self)
        }
    }

    /// Check whether a plugin has been granted a specific capability.
    func hasCapability(_ capability: PluginCapability, pluginId: String) -> Bool {
        grantedCapabilities[pluginId]?.contains(capability) ?? false
    }

    // ------------------------------------------------------------------
    // MARK: Overlay Providers
    // ------------------------------------------------------------------

    /// All registered plugins that provide overlays.
    var overlayProviders: [any ServicePluginOverlayProvider] {
        plugins.values.compactMap { $0 as? any ServicePluginOverlayProvider }
    }

    // ------------------------------------------------------------------
    // MARK: Lifecycle
    // ------------------------------------------------------------------

    func startAll() {
        for plugin in plugins.values {
            plugin.start()
        }
    }

    func stopAll() {
        for plugin in plugins.values {
            plugin.stop()
            if let subscriber = plugin as? any TerminalOutputSubscriber {
                scanner.removeSubscriber(subscriber)
            }
        }
        pluginCancellables.removeAll()
    }

    /// Tear down all plugins completely: stop, remove scanner subscribers,
    /// clear all state, and notify SwiftUI observers.
    func unregisterAll() {
        stopAll()
        plugins.removeAll()
        grantedCapabilities.removeAll()
        objectWillChange.send()
    }
}
