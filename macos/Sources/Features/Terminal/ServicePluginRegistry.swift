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

    /// Per-pane disabled plugins: paneId → set of pluginIds whose overlays/notifications are suppressed.
    @Published private(set) var disabledPlugins: [Int: Set<String>] = [:]

    /// Plugins that are disabled globally by default (opt-in plugins).
    /// These are suppressed for all panes unless explicitly enabled per-pane.
    private(set) var globallyDisabledPlugins: Set<String> = []

    /// Per-pane explicitly enabled plugins (overrides globallyDisabledPlugins).
    @Published private(set) var enabledPlugins: [Int: Set<String>] = [:]

    /// The shared terminal output scanner.
    let scanner: TerminalOutputScanner

    /// Subscriptions forwarding plugin objectWillChange to the registry, keyed by pluginId.
    private var pluginCancellables: [String: AnyCancellable] = [:]

    init(scanner: TerminalOutputScanner) {
        self.scanner = scanner
        scanner.disabledPluginFilter = { [weak self] pluginId, paneId in
            self?.isPluginDisabled(pluginId, forPaneId: paneId) ?? false
        }
        scanner.onPaneClose = { [weak self] paneId in
            self?.clearDisabledPlugins(forPaneId: paneId)
        }
    }

    // ------------------------------------------------------------------
    // MARK: Registration
    // ------------------------------------------------------------------

    /// Register a plugin. Capabilities are granted based on the plugin's
    /// declared requirements, except `.networkAccess` which is denied by
    /// default.
    func register(_ plugin: any ServicePlugin, disabledByDefault: Bool = false) {
        if disabledByDefault {
            globallyDisabledPlugins.insert(plugin.pluginId)
        }
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
    // MARK: Per-Pane Plugin Toggle
    // ------------------------------------------------------------------

    /// Whether a plugin's overlay/notifications are suppressed for a specific pane.
    ///
    /// For opt-in plugins (registered with `disabledByDefault: true`), the plugin
    /// is disabled unless the user has explicitly enabled it for this pane.
    /// For opt-out plugins (the default), the plugin is enabled unless explicitly disabled.
    func isPluginDisabled(_ pluginId: String, forPaneId paneId: Int) -> Bool {
        if globallyDisabledPlugins.contains(pluginId) {
            // Opt-in plugin: disabled unless explicitly enabled for this pane
            return !(enabledPlugins[paneId]?.contains(pluginId) ?? false)
        }
        // Opt-out plugin: enabled unless explicitly disabled for this pane
        return disabledPlugins[paneId]?.contains(pluginId) ?? false
    }

    /// Toggle a plugin's disabled state for a specific pane.
    ///
    /// For opt-in plugins, toggling adds/removes from the `enabledPlugins` set.
    /// For opt-out plugins, toggling adds/removes from the `disabledPlugins` set.
    func togglePlugin(_ pluginId: String, forPaneId paneId: Int) {
        if globallyDisabledPlugins.contains(pluginId) {
            // Opt-in plugin: toggle the enabled set
            if enabledPlugins[paneId]?.contains(pluginId) == true {
                enabledPlugins[paneId]?.remove(pluginId)
                if enabledPlugins[paneId]?.isEmpty == true {
                    enabledPlugins.removeValue(forKey: paneId)
                }
            } else {
                enabledPlugins[paneId, default: []].insert(pluginId)
            }
        } else {
            // Opt-out plugin: toggle the disabled set
            if disabledPlugins[paneId]?.contains(pluginId) == true {
                disabledPlugins[paneId]?.remove(pluginId)
                if disabledPlugins[paneId]?.isEmpty == true {
                    disabledPlugins.removeValue(forKey: paneId)
                }
            } else {
                disabledPlugins[paneId, default: []].insert(pluginId)
            }
        }
    }

    /// Remove all disabled/enabled plugin state for a pane (called when the pane closes).
    func clearDisabledPlugins(forPaneId paneId: Int) {
        disabledPlugins.removeValue(forKey: paneId)
        enabledPlugins.removeValue(forKey: paneId)
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
        disabledPlugins.removeAll()
        enabledPlugins.removeAll()
        globallyDisabledPlugins.removeAll()
        objectWillChange.send()
    }
}
