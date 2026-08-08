import Testing
import Foundation
@testable import trm

/// A test subscriber that records all callbacks it receives.
@MainActor
final class TestScannerSubscriber: TerminalOutputSubscriber {
    var outputChanges: [(paneId: Int, text: String, hash: String)] = []
    var closedPanes: [Int] = []

    func terminalOutputDidChange(paneId: Int, text: String, hash: String) {
        outputChanges.append((paneId, text, hash))
    }

    func terminalPaneDidClose(paneId: Int) {
        closedPanes.append(paneId)
    }
}

/// The scanner hashes pane content off the main actor and delivers
/// notifications asynchronously, so tests must await delivery rather than
/// asserting immediately after `start()`. (The old synchronous-style tests
/// subscripted an empty array and aborted the whole test host.)
@MainActor
struct TerminalOutputScannerTests {

    /// Wait until `condition` is true, or fail after `timeout`.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// Fixed wait for negative assertions ("nothing should arrive").
    private func settle() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Subscriber Management

    @Test func addSubscriberIncreasesSubscriberCount() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()

        scanner.addSubscriber(sub)
        scanner.paneContentProvider = { [(paneId: 0, visibleText: "hello")] }
        scanner.start()

        #expect(await waitUntil { sub.outputChanges.count == 1 })
        scanner.stop()
    }

    @Test func removeSubscriberPreventsNotifications() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()

        scanner.addSubscriber(sub)
        scanner.removeSubscriber(sub)

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "hello")] }
        scanner.start()
        await settle()
        scanner.stop()

        #expect(sub.outputChanges.isEmpty)
    }

    @Test func addMultipleSubscribers() async {
        let scanner = TerminalOutputScanner()
        let sub1 = TestScannerSubscriber()
        let sub2 = TestScannerSubscriber()

        scanner.addSubscriber(sub1)
        scanner.addSubscriber(sub2)

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "hello")] }
        scanner.start()

        #expect(await waitUntil { sub1.outputChanges.count == 1 && sub2.outputChanges.count == 1 })
        scanner.stop()
    }

    @Test func removeOneSubscriberLeavesOthers() async {
        let scanner = TerminalOutputScanner()
        let sub1 = TestScannerSubscriber()
        let sub2 = TestScannerSubscriber()

        scanner.addSubscriber(sub1)
        scanner.addSubscriber(sub2)
        scanner.removeSubscriber(sub1)

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "hello")] }
        scanner.start()

        #expect(await waitUntil { sub2.outputChanges.count == 1 })
        #expect(sub1.outputChanges.isEmpty)
        scanner.stop()
    }

    // MARK: - start() and Timer

    @Test func startBeginsPolling() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "content")] }
        scanner.start()

        #expect(await waitUntil { sub.outputChanges.count == 1 })
        #expect(sub.outputChanges.first?.text == "content")

        scanner.stop()
    }

    @Test func startIsIdempotent() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "content")] }

        // Call start twice; the second is a no-op since the timer exists.
        scanner.start()
        scanner.start()

        #expect(await waitUntil { sub.outputChanges.count == 1 })
        await settle()
        #expect(sub.outputChanges.count == 1)

        scanner.stop()
    }

    // MARK: - stop()

    @Test func stopClearsHashesAndInvalidatesTimer() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "content")] }
        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 1 })
        scanner.stop()

        // After stop and restart, the same content should be re-notified
        // because hashes were cleared.
        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 2 })
        scanner.stop()
    }

    // MARK: - Content Change Detection

    @Test func notifiesOnContentChange() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        var content = "first"
        scanner.paneContentProvider = { [(paneId: 0, visibleText: content)] }

        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 1 })
        #expect(sub.outputChanges.first?.text == "first")
        scanner.stop()

        // Change content and restart.
        content = "second"
        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 2 })
        #expect(sub.outputChanges.last?.text == "second")
        scanner.stop()
    }

    @Test func duplicateContentDoesNotReNotify() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "same")] }

        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 1 })
        await settle()
        // Unchanged content must not re-notify.
        #expect(sub.outputChanges.count == 1)
        scanner.stop()
    }

    @Test func multiplePanesTrackedIndependently() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        scanner.paneContentProvider = {
            [
                (paneId: 0, visibleText: "pane0"),
                (paneId: 1, visibleText: "pane1"),
            ]
        }

        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 2 })
        scanner.stop()
    }

    // MARK: - Pane Closure Detection

    @Test func removingPaneNotifiesClosedPanes() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        var panes: [(paneId: Int, visibleText: String)] = [
            (paneId: 0, visibleText: "pane0"),
            (paneId: 1, visibleText: "pane1"),
        ]
        scanner.paneContentProvider = { panes }

        // Close detection compares against hashes from prior polls, and
        // stop() clears those — so the pane must disappear while the scanner
        // keeps running. Use a short interval so the next timer poll sees it.
        scanner.pollInterval = 0.05
        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 2 })
        #expect(sub.closedPanes.isEmpty)

        // Remove pane 1 while polling continues.
        panes = [(paneId: 0, visibleText: "pane0")]

        #expect(await waitUntil { sub.closedPanes.contains(1) })
        scanner.stop()
    }

    // MARK: - No Content Provider

    @Test func noPaneContentProviderDoesNotCrash() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        // paneContentProvider is nil.
        scanner.start()
        await settle()
        scanner.stop()

        #expect(sub.outputChanges.isEmpty)
        #expect(sub.closedPanes.isEmpty)
    }

    // MARK: - Dead Subscriber Cleanup

    @Test func deadSubscriberDoesNotCrashOnPoll() async {
        let scanner = TerminalOutputScanner()

        // Create a subscriber that will be deallocated.
        var sub: TestScannerSubscriber? = TestScannerSubscriber()
        scanner.addSubscriber(sub!)
        sub = nil // Deallocate

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "hello")] }

        // Should not crash.
        scanner.start()
        await settle()
        scanner.stop()
    }

    // MARK: - Hash Computation

    @Test func differentContentProducesDifferentHashes() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        var content = "content A"
        scanner.paneContentProvider = { [(paneId: 0, visibleText: content)] }

        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 1 })
        scanner.stop()

        content = "content B"
        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 2 })
        scanner.stop()

        #expect(sub.outputChanges.first?.hash != sub.outputChanges.last?.hash)
    }

    @Test func sameContentProducesSameHash() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        scanner.paneContentProvider = { [(paneId: 0, visibleText: "identical")] }

        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 1 })
        scanner.stop()

        // Stop clears hashes, so restart re-notifies with the same content.
        scanner.start()
        #expect(await waitUntil { sub.outputChanges.count == 2 })
        scanner.stop()

        #expect(sub.outputChanges.first?.hash == sub.outputChanges.last?.hash)
    }

    // MARK: - Poll Interval

    @Test func defaultPollIntervalIsThree() {
        let scanner = TerminalOutputScanner()
        #expect(scanner.pollInterval == 3.0)
    }

    @Test func pollIntervalCanBeChanged() {
        let scanner = TerminalOutputScanner()
        scanner.pollInterval = 5.0
        #expect(scanner.pollInterval == 5.0)
    }

    // MARK: - Empty Panes

    @Test func emptyPaneListDoesNotNotify() async {
        let scanner = TerminalOutputScanner()
        let sub = TestScannerSubscriber()
        scanner.addSubscriber(sub)

        scanner.paneContentProvider = { [] }
        scanner.start()
        await settle()
        scanner.stop()

        #expect(sub.outputChanges.isEmpty)
    }
}
