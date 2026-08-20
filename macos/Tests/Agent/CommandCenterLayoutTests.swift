import Testing
@testable import trm

/// Tests for the Command Center panel's pure layout arithmetic: how many equal
/// cards fit across the panel, and how the rows are chunked.
struct CommandCenterLayoutTests {

    // MARK: columnCount

    @Test func narrowPanelStaysAList() {
        // The panel's default width, and anything under two full cards, keeps
        // the one-per-row layout rather than squeezing two in.
        #expect(CommandCenterView.columnCount(for: 320) == 1)
        #expect(CommandCenterView.columnCount(for: 560) == 1)
        #expect(CommandCenterView.columnCount(for: 679) == 1)
    }

    @Test func wideningToTwoCardsSplitsIntoAGrid() {
        #expect(CommandCenterView.columnCount(for: 680) == 2)
        #expect(CommandCenterView.columnCount(for: 1_020) == 3)
        #expect(CommandCenterView.columnCount(for: 1_400) == 4)
    }

    @Test func degenerateWidthsStillYieldAColumn() {
        // A GeometryReader reports zero on its first pass; a zero-column grid
        // would divide by nothing and render an empty panel.
        #expect(CommandCenterView.columnCount(for: 0) == 1)
        #expect(CommandCenterView.columnCount(for: -50) == 1)
    }

    // MARK: rows

    @Test func rowsChunkInPaneOrder() {
        let entries = (1...5).map { entry(id: $0) }
        let rows = CommandCenterView.rows(entries, columns: 2)
        #expect(rows.map { $0.map(\.watermark) } == [["1", "2"], ["3", "4"], ["5"]])
    }

    @Test func oneColumnIsOneEntryPerRow() {
        let entries = (1...3).map { entry(id: $0) }
        let rows = CommandCenterView.rows(entries, columns: 1)
        #expect(rows.map { $0.map(\.watermark) } == [["1"], ["2"], ["3"]])
    }

    @Test func emptyListHasNoRows() {
        #expect(CommandCenterView.rows([], columns: 3).isEmpty)
    }

    // MARK: -

    /// Entries are identified by their surface; tests have no surfaces, so a
    /// throwaway object stands in as a distinct identity per row, held for the
    /// test's lifetime so the identifier stays valid.
    ///
    /// Instance state, deliberately: swift-testing runs tests in parallel and
    /// makes a fresh instance per test, so this cannot be shared — the static
    /// version of it raced and took the suite down with no assertion message.
    private final class Anchors {
        private var objects: [Int: AnyObject] = [:]
        func identity(_ id: Int) -> ObjectIdentifier {
            if let existing = objects[id] { return ObjectIdentifier(existing) }
            let anchor = NSObject()
            objects[id] = anchor
            return ObjectIdentifier(anchor)
        }
    }

    private let anchors = Anchors()

    private func entry(
        id: Int,
        message: String = "",
        working: Bool = false,
        needsAttention: Bool = false,
        errorCount: Int = 0,
        errorText: String? = nil,
        promptHistory: [String] = []
    ) -> CommandCenterMonitor.Entry {
        .init(
            id: anchors.identity(id),
            paneId: id,
            watermark: "\(id)",
            kind: .claude,
            location: nil,
            host: nil,
            message: message,
            prompt: nil,
            promptHistory: promptHistory,
            activity: [],
            links: [],
            isWorking: working,
            needsAttention: needsAttention,
            errorCount: errorCount,
            errorText: errorText,
            updatedAt: nil,
            surface: nil
        )
    }

    // MARK: Briefing status

    @Test func statusRanksAttentionAboveErrorsAboveWork() {
        // A pane can be all three at once; the label has to pick the one that
        // costs the most to ignore.
        let blocked = entry(id: 1, working: true, needsAttention: true, errorCount: 3)
        #expect(CommandCenterView.status(for: blocked).label == "needs you")

        let failing = entry(id: 2, working: true, errorCount: 2)
        #expect(CommandCenterView.status(for: failing).label == "check this")

        #expect(CommandCenterView.status(for: entry(id: 3, working: true)).label == "working")
        #expect(CommandCenterView.status(for: entry(id: 4)).label == "idle")
    }

    @Test func escalationOnlyAppearsWhenSomethingWantsADecision() {
        #expect(CommandCenterView.escalation(for: entry(id: 1)) == nil)
        #expect(CommandCenterView.escalation(for: entry(id: 2, working: true)) == nil)
        #expect(CommandCenterView.escalation(for: entry(id: 3, needsAttention: true))
            == "Waiting on your answer.")
        #expect(CommandCenterView.escalation(
            for: entry(id: 4, errorCount: 2, errorText: "exit status 1"))
            == "2 errors this turn — exit status 1")
    }

    // MARK: Message history

    @MainActor
    @Test func historyIsNewestFirstWithoutRepeats() {
        let monitor = CommandCenterMonitor.shared
        let row = entry(id: 90, promptHistory: ["first", "second", "second", "third"])
        // The transcript is oldest-first; walking back with Up wants the
        // reverse, and a prompt repeated in the transcript is one entry.
        #expect(monitor.messageHistory(for: row) == ["third", "second", "first"])
    }

    @MainActor
    @Test func messagesTrmSentComeBeforeTheTranscriptCatchesUp() {
        let monitor = CommandCenterMonitor.shared
        monitor.recordSentMessage(paneId: 91, text: "just sent this")
        // Already in the transcript: recorded once, from the transcript.
        monitor.recordSentMessage(paneId: 91, text: "older message")
        let row = entry(id: 91, promptHistory: ["older message"])
        #expect(monitor.messageHistory(for: row) == ["just sent this", "older message"])
    }

    @MainActor
    @Test func aPaneWithNoTranscriptStillRemembersWhatWasSent() {
        let monitor = CommandCenterMonitor.shared
        monitor.recordSentMessage(paneId: 92, text: "one")
        monitor.recordSentMessage(paneId: 92, text: "two")
        let row = entry(id: 92)
        #expect(monitor.messageHistory(for: row) == ["two", "one"])
    }

    // MARK: Briefing parsing

    @Test func aBriefingIsASentenceAndItsBullets() {
        let parsed = CommandCenterMonitor.parseBriefing(
            "Fixed the socket leak and the tests pass.\n- Edited daemon.zig\n- Ran zig build test")
        #expect(parsed?.sentence == "Fixed the socket leak and the tests pass.")
        #expect(parsed?.bullets == ["Edited daemon.zig", "Ran zig build test"])
    }

    @Test func bulletsMayComeFirstOrUseOtherMarkers() {
        // A model that leads with its bullets, or uses • instead of -, should
        // still produce something usable.
        let parsed = CommandCenterMonitor.parseBriefing(
            "• Read grid.zig\n* Wrote a test\nAdded a regression test for the wrap bug.")
        #expect(parsed?.sentence == "Added a regression test for the wrap bug.")
        #expect(parsed?.bullets == ["Read grid.zig", "Wrote a test"])
    }

    @Test func bulletsOnlyStillYieldAHeadline() {
        let parsed = CommandCenterMonitor.parseBriefing("- Ran the suite\n- All green")
        #expect(parsed?.sentence == "All green")
        #expect(parsed?.bullets == ["Ran the suite"])
    }

    @Test func nothingUsableIsNoBriefing() {
        #expect(CommandCenterMonitor.parseBriefing("   \n\n  ") == nil)
    }

    // MARK: Links

    @Test func linksAreFoundWholeAndDeduplicated() {
        let text = "Serving on http://localhost:3000/admin — see http://localhost:3000/admin again"
        #expect(CommandCenterMonitor.links(inText: text) == ["http://localhost:3000/admin"])
    }

    @Test func trailingPunctuationIsNotPartOfTheAddress() {
        // Prose and markdown leave these clinging to a URL; pasting one with a
        // bracket on the end sends you nowhere.
        #expect(CommandCenterMonitor.links(inText: "up at https://example.com/x.")
            == ["https://example.com/x"])
        #expect(CommandCenterMonitor.links(inText: "(see https://example.com/y)")
            == ["https://example.com/y"])
    }

    @Test func barePathsAndPlainWordsAreNotLinks() {
        #expect(CommandCenterMonitor.links(inText: "edit src/main.zig then run it").isEmpty)
    }

    @Test func linkListIsCapped() {
        let text = (1...9).map { "http://h\($0).test/" }.joined(separator: " ")
        #expect(CommandCenterMonitor.links(inText: text, limit: 4).count == 4)
    }

    // MARK: Attachments

    @Test func attachmentPathIsAppendedToWhateverIsTyped() {
        #expect(CommandCenterAttachments.draft("", appending: "/tmp/a.png") == "/tmp/a.png ")
        #expect(CommandCenterAttachments.draft("look at ", appending: "/tmp/a.png")
            == "look at /tmp/a.png ")
        #expect(CommandCenterAttachments.draft("  ", appending: "~/x.log") == "~/x.log ")
    }

    @Test func draggedFilesKeepTheirNameAndExtension() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let name = CommandCenterAttachments.uniqueName(for: "Build Output.LOG", now: now)
        #expect(name.hasPrefix("Build-Output-"))
        #expect(name.hasSuffix(".log"))
        // Nothing a shell would need quoted, since the path goes into a
        // message unquoted.
        #expect(!name.contains(" "))
    }

    @Test func twoDragsOfTheSameFileDoNotCollide() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let first = CommandCenterAttachments.uniqueName(for: "shot.png", now: now)
        let second = CommandCenterAttachments.uniqueName(for: "shot.png", now: now)
        #expect(first != second)
    }

    @Test func pastedImageDataGetsAName() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let name = CommandCenterAttachments.generatedName(ext: "png", now: now)
        #expect(name.hasPrefix("trm-"))
        #expect(name.hasSuffix(".png"))
        #expect(CommandCenterAttachments.generatedName(ext: "", now: now).hasSuffix(".bin"))
    }

    // MARK: firstSentence

    @Test func briefingTakesTheOpeningSentence() {
        let text = "Fixed the socket leak in the daemon. Then I ran the tests and they passed."
        #expect(CommandCenterMonitor.firstSentence(of: text)
            == "Fixed the socket leak in the daemon.")
    }

    @Test func briefingIgnoresAnEarlyAbbreviation() {
        // "e.g." must not end the sentence three characters in.
        let text = "Ran e.g. the failing suite and found the cause in the parser."
        #expect(CommandCenterMonitor.firstSentence(of: text)
            == "Ran e.g. the failing suite and found the cause in the parser.")
    }

    @Test func briefingFlattensAndTruncatesLongProse() {
        let text = String(repeating: "word ", count: 80)
        let sentence = CommandCenterMonitor.firstSentence(of: text, limit: 40)
        #expect(sentence.count <= 41)
        #expect(sentence.hasSuffix("…"))
        #expect(!sentence.contains("\n"))
    }

    @Test func briefingOfNothingIsEmpty() {
        #expect(CommandCenterMonitor.firstSentence(of: "   \n  ").isEmpty)
    }
}
