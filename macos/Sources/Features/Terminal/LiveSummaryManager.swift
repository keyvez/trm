import Foundation
import CryptoKit

/// Manages periodic LLM-driven summaries of each pane's visible output.
@MainActor
final class LiveSummaryManager: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var summaries: [Int: String] = [:]
    @Published var isLoading: [Int: Bool] = [:]

    /// Closure that returns the current pane contents for summarization.
    var paneContentProvider: (() -> [(index: Int, title: String, visibleText: String)])?

    /// How often to poll for content changes (seconds).
    var pollInterval: TimeInterval = 8.0

    /// Tracks SHA-256 hashes of the last content sent for each pane.
    private var lastContentHashes: [Int: String] = [:]

    /// Active summarization tasks per pane, so we can cancel stale ones.
    private var activeTasks: [Int: Task<Void, Never>] = [:]

    /// The polling timer.
    private var timer: Timer?

    func toggle() {
        if isEnabled {
            stop()
        } else {
            start()
        }
    }

    func start() {
        isEnabled = true
        pollOnce()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollOnce()
            }
        }
    }

    func stop() {
        isEnabled = false
        timer?.invalidate()
        timer = nil
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        summaries.removeAll()
        isLoading.removeAll()
        lastContentHashes.removeAll()
    }

    func pollOnce() {
        guard isEnabled else { return }
        guard let provider = paneContentProvider else { return }
        let panes = provider()

        for pane in panes {
            let hash = sha256(pane.visibleText)

            // Skip if content hasn't changed
            if lastContentHashes[pane.index] == hash {
                continue
            }
            lastContentHashes[pane.index] = hash

            // Skip empty panes
            let trimmed = pane.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                summaries[pane.index] = nil
                isLoading[pane.index] = false
                continue
            }

            // Cancel any existing task for this pane
            activeTasks[pane.index]?.cancel()

            isLoading[pane.index] = true

            let index = pane.index
            let title = pane.title
            let visibleText = pane.visibleText

            activeTasks[index] = Task { [weak self] in
                do {
                    let summary = try await Trm.shared.llmClient.summarize(
                        visibleText: visibleText,
                        paneTitle: title
                    )
                    guard !Task.isCancelled else { return }
                    self?.summaries[index] = summary
                } catch {
                    guard !Task.isCancelled else { return }
                    // Silently fail — don't replace existing summary on error
                }
                self?.isLoading[index] = false
                self?.activeTasks.removeValue(forKey: index)
            }
        }
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
