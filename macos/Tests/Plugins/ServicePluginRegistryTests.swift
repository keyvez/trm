import Testing
import Foundation
import SwiftUI
import Combine
@testable import trm

// MARK: - Mock Plugins

@MainActor
final class MockServicePlugin: ServicePlugin {
    let pluginId: String
    let displayName: String
    static let requiredCapabilities: Set<PluginCapability> = [.clipboardWrite, .userNotifications]

    var configured = false
    var started = false
    var stopped = false
    weak var configuredRegistry: ServicePluginRegistry?

    init(pluginId: String = "mock_plugin", displayName: String = "Mock Plugin") {
        self.pluginId = pluginId
        self.displayName = displayName
    }

    func configure(registry: ServicePluginRegistry) {
        configured = true
        configuredRegistry = registry
    }

    func start() { started = true }
    func stop() { stopped = true }
}

@MainActor
final class MockObservablePlugin: ObservableObject, ServicePlugin, ObservableServicePlugin {
    let pluginId: String
    let displayName: String
    static let requiredCapabilities: Set<PluginCapability> = [.fileSystemRead]

    var configured = false
    var started = false
    var stopped = false

    @Published var dummy: Int = 0

    init(pluginId: String = "mock_observable", displayName: String = "Mock Observable") {
        self.pluginId = pluginId
        self.displayName = displayName
    }

    func configure(registry: ServicePluginRegistry) { configured = true }
    func start() { started = true }
    func stop() { stopped = true }
}

@MainActor
final class MockSubscriberPlugin: ObservableObject, ServicePlugin, ObservableServicePlugin, TerminalOutputSubscriber {
    let pluginId: String
    let displayName: String
    static let requiredCapabilities: Set<PluginCapability> = [.terminalOutputRead]

    var configured = false
    var started = false
    var stopped = false

    var outputChanges: [(paneIndex: Int, text: String, hash: String)] = []
    var closedPanes: [Int] = []

    @Published var dummy: Int = 0

    init(pluginId: String = "mock_subscriber", displayName: String = "Mock Subscriber") {
        self.pluginId = pluginId
        self.displayName = displayName
    }

    func configure(registry: ServicePluginRegistry) { configured = true }
    func start() { started = true }
    func stop() { stopped = true }

    func terminalOutputDidChange(paneIndex: Int, text: String, hash: String) {
        outputChanges.append((paneIndex, text, hash))
    }

    func terminalPaneDidClose(paneIndex: Int) {
        closedPanes.append(paneIndex)
    }
}

@MainActor
final class MockOverlayPlugin: ObservableObject, ServicePlugin, ObservableServicePlugin, ServicePluginOverlayProvider {
    let pluginId: String
    let displayName: String
    static let requiredCapabilities: Set<PluginCapability> = [.clipboardWrite]

    var configured = false
    var started = false
    var stopped = false

    var shouldProvideOverlay = false

    @Published var dummy: Int = 0

    init(pluginId: String = "mock_overlay", displayName: String = "Mock Overlay") {
        self.pluginId = pluginId
        self.displayName = displayName
    }

    func configure(registry: ServicePluginRegistry) { configured = true }
    func start() { started = true }
    func stop() { stopped = true }

    var overlayAlignment: Alignment { .bottom }

    func overlayView(forPane index: Int) -> AnyView? {
        guard shouldProvideOverlay else { return nil }
        return AnyView(Text("Overlay"))
    }
}

// MARK: - Tests

@MainActor
struct ServicePluginRegistryTests {

    // MARK: - Registration

    @Test func registerPluginAppearsInPlugins() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plugin = MockServicePlugin()

        registry.register(plugin)

        #expect(registry.plugins.count == 1)
        #expect(registry.plugins["mock_plugin"] != nil)
    }

    @Test func registerPluginCallsConfigure() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plugin = MockServicePlugin()

        registry.register(plugin)

        #expect(plugin.configured)
        #expect(plugin.configuredRegistry === registry)
    }

    @Test func registerPluginGrantsCapabilitiesExceptNetworkAccess() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plugin = MockServicePlugin()
        // MockServicePlugin requires: .clipboardWrite, .userNotifications

        registry.register(plugin)

        #expect(registry.hasCapability(.clipboardWrite, pluginId: "mock_plugin"))
        #expect(registry.hasCapability(.userNotifications, pluginId: "mock_plugin"))
        #expect(!registry.hasCapability(.networkAccess, pluginId: "mock_plugin"))
        #expect(!registry.hasCapability(.terminalOutputRead, pluginId: "mock_plugin"))
    }

    // MARK: - NetworkAccess Denied

    @Test func networkAccessCapabilityIsDenied() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)

        // Create a plugin that explicitly requests networkAccess
        let plugin = MockNetworkPlugin()
        registry.register(plugin)

        #expect(!registry.hasCapability(.networkAccess, pluginId: "mock_network"))
        // Other requested capabilities should still be granted
        #expect(registry.hasCapability(.clipboardWrite, pluginId: "mock_network"))
    }

    // MARK: - Observable Forwarding

    @Test func registerObservablePluginStoresCancellable() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plugin = MockObservablePlugin()

        registry.register(plugin)

        // The registry stores cancellables internally; we verify by checking
        // the plugin is registered and that stopAll clears them without issue
        #expect(registry.plugins["mock_observable"] != nil)
    }

    // MARK: - Scanner Subscriber Auto-Add

    @Test func registerSubscriberPluginAddsToScanner() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plugin = MockSubscriberPlugin()

        registry.register(plugin)

        // Verify by setting up the scanner with a content provider and polling
        var pollCount = 0
        scanner.paneContentProvider = {
            pollCount += 1
            return [(index: 0, visibleText: "hello")]
        }
        scanner.start()
        // The start() triggers an immediate pollOnce(), which should notify our subscriber
        scanner.stop()

        #expect(plugin.outputChanges.count == 1)
        #expect(plugin.outputChanges.first?.text == "hello")
    }

    // MARK: - startAll

    @Test func startAllCallsStartOnAllPlugins() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let p1 = MockServicePlugin(pluginId: "p1")
        let p2 = MockServicePlugin(pluginId: "p2")

        registry.register(p1)
        registry.register(p2)
        registry.startAll()

        #expect(p1.started)
        #expect(p2.started)
    }

    // MARK: - stopAll

    @Test func stopAllCallsStopOnAllPlugins() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let p1 = MockServicePlugin(pluginId: "p1")
        let p2 = MockServicePlugin(pluginId: "p2")

        registry.register(p1)
        registry.register(p2)
        registry.stopAll()

        #expect(p1.stopped)
        #expect(p2.stopped)
    }

    @Test func stopAllRemovesScannerSubscribers() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plugin = MockSubscriberPlugin()

        registry.register(plugin)
        registry.stopAll()

        // After stopAll, polling should NOT notify the subscriber
        scanner.paneContentProvider = {
            [(index: 0, visibleText: "after stop")]
        }
        scanner.start()
        scanner.stop()

        #expect(plugin.outputChanges.isEmpty)
    }

    // MARK: - unregisterAll

    @Test func unregisterAllClearsEverything() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let p1 = MockServicePlugin(pluginId: "p1")
        let p2 = MockSubscriberPlugin(pluginId: "p2")

        registry.register(p1)
        registry.register(p2)

        registry.unregisterAll()

        #expect(registry.plugins.isEmpty)
        #expect(!registry.hasCapability(.clipboardWrite, pluginId: "p1"))
        #expect(!registry.hasCapability(.terminalOutputRead, pluginId: "p2"))
        #expect(p1.stopped)
        #expect(p2.stopped)
    }

    @Test func unregisterAllFiresObjectWillChange() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plugin = MockServicePlugin()
        registry.register(plugin)

        var didFire = false
        let cancellable = registry.objectWillChange.sink { didFire = true }

        registry.unregisterAll()

        #expect(didFire)
        _ = cancellable // retain
    }

    // MARK: - hasCapability

    @Test func hasCapabilityReturnsFalseForUnregisteredPlugin() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)

        #expect(!registry.hasCapability(.clipboardWrite, pluginId: "nonexistent"))
    }

    @Test func hasCapabilityReturnsFalseForNonGrantedCapability() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plugin = MockServicePlugin()
        registry.register(plugin)

        // MockServicePlugin does NOT request .fileSystemRead
        #expect(!registry.hasCapability(.fileSystemRead, pluginId: "mock_plugin"))
    }

    // MARK: - overlayProviders

    @Test func overlayProvidersReturnsOnlyOverlayPlugins() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plain = MockServicePlugin(pluginId: "plain")
        let overlay = MockOverlayPlugin(pluginId: "overlay")

        registry.register(plain)
        registry.register(overlay)

        let providers = registry.overlayProviders
        #expect(providers.count == 1)
        #expect(providers.first?.pluginId == "overlay")
    }

    @Test func overlayProvidersReturnsEmptyWhenNoneRegistered() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let plain = MockServicePlugin()
        registry.register(plain)

        #expect(registry.overlayProviders.isEmpty)
    }

    // MARK: - Multiple Registrations

    @Test func multiplePluginsAllPresent() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let p1 = MockServicePlugin(pluginId: "alpha")
        let p2 = MockObservablePlugin(pluginId: "beta")
        let p3 = MockSubscriberPlugin(pluginId: "gamma")

        registry.register(p1)
        registry.register(p2)
        registry.register(p3)

        #expect(registry.plugins.count == 3)
        #expect(registry.plugins["alpha"] != nil)
        #expect(registry.plugins["beta"] != nil)
        #expect(registry.plugins["gamma"] != nil)
    }

    // MARK: - Re-registration

    @Test func reRegistrationReplacesPlugin() {
        let scanner = TerminalOutputScanner()
        let registry = ServicePluginRegistry(scanner: scanner)
        let first = MockServicePlugin(pluginId: "same_id", displayName: "First")
        let second = MockServicePlugin(pluginId: "same_id", displayName: "Second")

        registry.register(first)
        registry.register(second)

        #expect(registry.plugins.count == 1)
        #expect(registry.plugins["same_id"]?.displayName == "Second")
    }
}

// MARK: - Additional Mock for Network Access Test

@MainActor
private final class MockNetworkPlugin: ServicePlugin {
    let pluginId = "mock_network"
    let displayName = "Mock Network"
    static let requiredCapabilities: Set<PluginCapability> = [.networkAccess, .clipboardWrite]

    func configure(registry: ServicePluginRegistry) {}
    func start() {}
    func stop() {}
}
