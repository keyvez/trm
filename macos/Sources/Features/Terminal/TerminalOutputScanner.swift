import Foundation
import CryptoKit

/// Shared polling scanner that reads terminal pane content on a timer,
/// computes per-pane SHA-256 hashes, and notifies subscribers only when
/// content changes. Replaces duplicated poll-and-hash logic that was
/// previously spread across `ServerURLDetector` and `LiveSummaryManager`.
@MainActor
final class TerminalOutputScanner {

    /// Closure that returns the current visible text for each terminal pane.
    /// Set by `BaseTerminalController` after initialization.
    var paneContentProvider: (() -> [(paneId: Int, visibleText: String)])?

    /// How often to poll (seconds).
    var pollInterval: TimeInterval = 2.0

    /// Optional filter: returns `true` if a plugin (by ID) is disabled for a pane.
    /// Set by `ServicePluginRegistry` so the scanner can skip notifications for
    /// per-pane disabled plugins.
    var disabledPluginFilter: ((_ pluginId: String, _ paneId: Int) -> Bool)?

    /// Called when a pane closes, so the registry can clean up per-pane state.
    var onPaneClose: ((_ paneId: Int) -> Void)?

    // ------------------------------------------------------------------
    // MARK: Private
    // ------------------------------------------------------------------

    private var timer: Timer?
    private var lastContentHashes: [Int: String] = [:]

    /// Weak wrapper so we don't prevent subscriber deallocation.
    private struct WeakSubscriber {
        weak var value: (any TerminalOutputSubscriber)?
    }

    private var subscribers: [WeakSubscriber] = []

    // ------------------------------------------------------------------
    // MARK: Subscriber Management
    // ------------------------------------------------------------------

    func addSubscriber(_ subscriber: any TerminalOutputSubscriber) {
        subscribers.append(WeakSubscriber(value: subscriber))
    }

    func removeSubscriber(_ subscriber: any TerminalOutputSubscriber) {
        subscribers.removeAll { $0.value === subscriber }
    }

    // ------------------------------------------------------------------
    // MARK: Lifecycle
    // ------------------------------------------------------------------

    func start() {
        guard timer == nil else { return }
        pollOnce()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollOnce()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastContentHashes.removeAll()
    }

    // ------------------------------------------------------------------
    // MARK: Command Lifecycle
    // ------------------------------------------------------------------

    /// Forward a command-finished event to all subscribers for the given pane.
    func notifyCommandDidFinish(paneId: Int) {
        subscribers.removeAll { $0.value == nil }
        for sub in subscribers {
            sub.value?.terminalCommandDidFinish(paneId: paneId)
        }
    }

    // ------------------------------------------------------------------
    // MARK: Scanning
    // ------------------------------------------------------------------

    private func pollOnce() {
        // Prune dead subscribers
        subscribers.removeAll { $0.value == nil }

        guard let provider = paneContentProvider else { return }
        let panes = provider()

        // Detect closed panes
        let currentIndices = Set(panes.map(\.paneId))
        for trackedIndex in lastContentHashes.keys where !currentIndices.contains(trackedIndex) {
            lastContentHashes.removeValue(forKey: trackedIndex)
            for sub in subscribers {
                sub.value?.terminalPaneDidClose(paneId: trackedIndex)
            }
            onPaneClose?(trackedIndex)
        }

        for pane in panes {
            let hash = sha256(pane.visibleText)
            if lastContentHashes[pane.paneId] == hash { continue }
            lastContentHashes[pane.paneId] = hash

            for sub in subscribers {
                // Skip notification if this subscriber's plugin is disabled for this pane.
                if let filter = disabledPluginFilter,
                   let plugin = sub.value as? any ServicePlugin,
                   filter(plugin.pluginId, pane.paneId) {
                    continue
                }
                sub.value?.terminalOutputDidChange(
                    paneId: pane.paneId,
                    text: pane.visibleText,
                    hash: hash
                )
            }
        }
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
