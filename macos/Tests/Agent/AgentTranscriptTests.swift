import Testing
import Foundation
import SwiftUI
@testable import trm

/// Parsing of Claude Code JSONL transcripts into the agent overview model.
struct AgentTranscriptTests {

    // MARK: - Helpers

    /// Build one JSONL line for an assistant message with the given content blocks.
    private func assistantLine(_ blocks: [[String: Any]]) -> String {
        let obj: [String: Any] = ["type": "assistant", "message": ["content": blocks]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    /// Build one JSONL line for a user message with string content.
    private func userLine(_ text: String) -> String {
        let obj: [String: Any] = ["type": "user", "message": ["content": text]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    /// Build one JSONL line carrying a tool_result for the given tool_use id.
    private func toolResultLine(_ id: String) -> String {
        let obj: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "tool_result", "tool_use_id": id]]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Prose / code splitting

    @Test func splitsFencedCodeFromProse() {
        let blocks = AgentTranscriptReader.splitProseAndCode(
            "Here is the fix:\n```swift\nlet x = 1\n```\nThat should do it."
        )
        #expect(blocks.count == 3)
        #expect(blocks[0] == .paragraph("Here is the fix:"))
        #expect(blocks[1] == .code(language: "swift", text: "let x = 1"))
        #expect(blocks[2] == .paragraph("That should do it."))
    }

    @Test func fenceWithoutLanguageHasNilLanguage() {
        let blocks = AgentTranscriptReader.splitProseAndCode("```\nplain\n```")
        #expect(blocks == [.code(language: nil, text: "plain")])
    }

    @Test func unterminatedFenceStillYieldsCode() {
        // A message still streaming in can end mid-fence; dropping it would
        // make the view flicker empty while the agent is writing.
        let blocks = AgentTranscriptReader.splitProseAndCode("Doing it:\n```zig\nconst a = 1;")
        #expect(blocks.count == 2)
        #expect(blocks[1] == .code(language: "zig", text: "const a = 1;"))
    }

    @Test func indentedTextIsNotTreatedAsCode() {
        let blocks = AgentTranscriptReader.splitProseAndCode("Normal line\n    indented prose")
        #expect(blocks.count == 1)
        if case .paragraph = blocks[0] {} else {
            Issue.record("indented prose should not become a code block")
        }
    }

    @Test func codeBlockPreservesInteriorBlankLines() {
        let blocks = AgentTranscriptReader.splitProseAndCode("```\na\n\nb\n```")
        #expect(blocks == [.code(language: nil, text: "a\n\nb")])
    }

    // MARK: - Message extraction

    @Test func usesLatestAssistantMessageWithText() {
        let lines = [
            userLine("do the thing"),
            assistantLine([["type": "text", "text": "First answer."]]),
            assistantLine([["type": "text", "text": "Second answer."]]),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.blocks == [.paragraph("Second answer.")])
    }

    @Test func toolOnlyAssistantMessageKeepsPreviousProse() {
        // An assistant entry that only calls tools must not blank the message
        // pane — the prose written just before it is still the latest thing said.
        let lines = [
            userLine("go"),
            assistantLine([["type": "text", "text": "Let me check."]]),
            assistantLine([["type": "tool_use", "id": "t1", "name": "Read",
                            "input": ["file_path": "/tmp/a.swift"]]]),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.blocks == [.paragraph("Let me check.")])
    }

    @Test func capturesLastUserPrompt() {
        let lines = [userLine("first"), assistantLine([["type": "text", "text": "ok"]]), userLine("second")]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.lastUserPrompt == "second")
    }

    @Test func syntheticPromptsAreIgnored() {
        // System reminders and interrupt markers are not things the human typed.
        let lines = [
            userLine("real question"),
            userLine("<system-reminder>ignore me</system-reminder>"),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.lastUserPrompt == "real question")
    }

    @Test func malformedLinesAreSkipped() {
        let lines = ["not json at all", "", userLine("hello"), "{\"broken\":"]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.lastUserPrompt == "hello")
    }

    // MARK: - Activity

    @Test func tracksToolCallsInOrder() {
        let lines = [
            userLine("build it"),
            assistantLine([
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/x/capi.zig"]],
                ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "zig build"]],
            ]),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.activity.map(\.name) == ["Read", "Bash"])
        #expect(t.activity[0].detail == "capi.zig")
        #expect(t.activity[1].detail == "zig build")
    }

    @Test func toolResultMarksCallFinished() {
        let lines = [
            userLine("go"),
            assistantLine([["type": "tool_use", "id": "t1", "name": "Bash",
                            "input": ["command": "ls"]]]),
            toolResultLine("t1"),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.activity.count == 1)
        #expect(t.activity[0].finished)
        #expect(!t.isWorking)
    }

    @Test func unfinishedToolCallMeansWorking() {
        let lines = [
            userLine("go"),
            assistantLine([["type": "tool_use", "id": "t1", "name": "Bash",
                            "input": ["command": "sleep 30"]]]),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.isWorking)
        #expect(!t.activity[0].finished)
    }

    @Test func toolResultEntryDoesNotResetTheTurn() {
        // tool_result arrives as a "user" entry. Treating it as a new human
        // turn would wipe the activity list mid-turn.
        let lines = [
            userLine("go"),
            assistantLine([["type": "tool_use", "id": "t1", "name": "Bash",
                            "input": ["command": "ls"]]]),
            toolResultLine("t1"),
            assistantLine([["type": "tool_use", "id": "t2", "name": "Read",
                            "input": ["file_path": "/x/b.swift"]]]),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.activity.count == 2)
        #expect(t.lastUserPrompt == "go")
    }

    @Test func newHumanTurnResetsActivity() {
        let lines = [
            userLine("first task"),
            assistantLine([["type": "tool_use", "id": "t1", "name": "Bash",
                            "input": ["command": "ls"]]]),
            toolResultLine("t1"),
            userLine("second task"),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.activity.isEmpty)
        #expect(t.lastUserPrompt == "second task")
    }

    @Test func longToolDetailIsTruncated() {
        let long = String(repeating: "x", count: 200)
        let detail = AgentTranscriptReader.toolDetail(name: "Bash", input: ["command": long])
        #expect((detail?.count ?? 0) <= 72)
        #expect(detail?.hasSuffix("…") == true)
    }

    @Test func multilineCommandDetailIsFlattened() {
        let detail = AgentTranscriptReader.toolDetail(name: "Bash", input: ["command": "echo a\necho b"])
        #expect(detail?.contains("\n") == false)
    }

    @Test func bashDetailDropsLeadingEnvAssignments() {
        // Observed live: rows read "TESTDIR=/private/tmp/…" instead of the
        // actual command. The row should lead with the command word.
        let detail = AgentTranscriptReader.toolDetail(
            name: "Bash",
            input: ["command": "TESTDIR=/tmp/x FOO=bar screencapture -x /tmp/shot.png"]
        )
        #expect(detail?.hasPrefix("screencapture") == true)
    }

    @Test func bashDetailKeepsPathCommands() {
        // A leading absolute path is a command, not an env assignment — even
        // when an argument later contains "=".
        let detail = AgentTranscriptReader.toolDetail(
            name: "Bash",
            input: ["command": "/usr/bin/env ls --color=auto"]
        )
        #expect(detail?.hasPrefix("/usr/bin/env") == true)
    }

    @Test func imageCaptionIsNotAPrompt() {
        // Observed live: an attached image's caption line rendered as the
        // "You asked" text.
        let lines = [
            userLine("real question"),
            userLine("[Image: original 4112x2658, displayed at 2000x1293.]"),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.lastUserPrompt == "real question")
    }

    @Test func emptyTranscriptIsEmpty() {
        let t = AgentTranscriptReader.parse(lines: [])
        #expect(t.isEmpty)
    }

    // MARK: - File reading

    @Test func recoversPromptPushedOutOfTheTailWindow() throws {
        // A tool-heavy turn can push every human message past the tail window
        // the reader normally scans. Observed on a real 1.8 MB transcript: the
        // prompt line came back blank. The reader must widen its search rather
        // than reporting no prompt.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentTranscriptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("session.jsonl")
        var lines = [userLine("the original question")]

        // Pad well past the 512 KB tail with assistant/tool traffic.
        let filler = String(repeating: "y", count: 4096)
        for i in 0..<220 {
            lines.append(assistantLine([["type": "text", "text": "step \(i) \(filler)"]]))
        }
        lines.append(assistantLine([["type": "text", "text": "Final answer."]]))

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 512 * 1024, "fixture must exceed the tail window to be meaningful")

        let t = try #require(AgentTranscriptReader.parse(url: url))
        #expect(t.lastUserPrompt == "the original question")
        #expect(t.blocks == [.paragraph("Final answer.")])
    }

    @Test func parsingAMissingFileReturnsNil() {
        let missing = URL(fileURLWithPath: "/nonexistent/agent-transcript-\(UUID().uuidString).jsonl")
        #expect(AgentTranscriptReader.parse(url: missing) == nil)
    }
}

/// The agent overview must stay immediately beside the pane it describes.
/// `pinCompanion` is what restores that invariant after a move or swap.
struct AgentOverviewAdjacencyTests {

    @Test func pinsCompanionDirectlyAfterAnchor() {
        var layout = GridLayout(rowCols: [3], displayOrder: ["term", "other", "view"])
        layout.pinCompanion("view", after: "term")
        #expect(layout.displayOrder == ["term", "view", "other"])
    }

    @Test func alreadyAdjacentIsLeftAlone() {
        var layout = GridLayout(rowCols: [3], displayOrder: ["term", "view", "other"])
        let moved = layout.pinCompanion("view", after: "term")
        #expect(!moved)
        #expect(layout.displayOrder == ["term", "view", "other"])
    }

    @Test func companionBeforeAnchorIsMovedAfterIt() {
        // The removal shifts the anchor left; inserting at a stale index would
        // put the view in the wrong slot.
        var layout = GridLayout(rowCols: [3], displayOrder: ["view", "other", "term"])
        layout.pinCompanion("view", after: "term")
        #expect(layout.displayOrder == ["other", "term", "view"])
    }

    @Test func companionImmediatelyBeforeAnchorEndsUpImmediatelyAfter() {
        // The view landing just left of its terminal is what a swap produces.
        // Removing it shifts the anchor left by one, so inserting at the
        // pre-removal index would leave a pane wedged between the pair.
        var layout = GridLayout(rowCols: [3], displayOrder: ["view", "term", "other"])
        layout.pinCompanion("view", after: "term")
        #expect(layout.displayOrder == ["term", "view", "other"])
    }

    @Test func anchorAtEndAppendsCompanion() {
        var layout = GridLayout(rowCols: [3], displayOrder: ["view", "other", "term"])
        layout.pinCompanion("view", after: "term")
        #expect(layout.displayOrder.last == "view")
    }

    @Test func missingAnchorLeavesOrderUnchanged() {
        var layout = GridLayout(rowCols: [2], displayOrder: ["a", "view"])
        let moved = layout.pinCompanion("view", after: "gone")
        #expect(!moved)
        #expect(layout.displayOrder == ["a", "view"])
    }

    @Test func missingCompanionLeavesOrderUnchanged() {
        var layout = GridLayout(rowCols: [2], displayOrder: ["term", "a"])
        let moved = layout.pinCompanion("view", after: "term")
        #expect(!moved)
        #expect(layout.displayOrder == ["term", "a"])
    }

    @Test func pinningNeverLosesOrDuplicatesPanes() {
        var layout = GridLayout(rowCols: [4], displayOrder: ["a", "view", "b", "term"])
        layout.pinCompanion("view", after: "term")
        #expect(layout.displayOrder.count == 4)
        #expect(Set(layout.displayOrder) == Set(["a", "b", "term", "view"]))
    }

    @Test func twoOverviewsBothStayPinned() {
        var layout = GridLayout(
            rowCols: [4],
            displayOrder: ["t1", "t2", "v1", "v2"]
        )
        layout.pinCompanion("v1", after: "t1")
        layout.pinCompanion("v2", after: "t2")
        let order = layout.displayOrder
        #expect(order.firstIndex(of: "v1") == order.firstIndex(of: "t1")! + 1)
        #expect(order.firstIndex(of: "v2") == order.firstIndex(of: "t2")! + 1)
    }
}

/// Bionic reading emphasis.
struct BionicTextTests {

    @Test func boldPrefixScalesWithWordLength() {
        #expect(BionicText.boldPrefixLength(for: 1) == 1)
        #expect(BionicText.boldPrefixLength(for: 3) == 1)
        #expect(BionicText.boldPrefixLength(for: 5) == 2)
        #expect(BionicText.boldPrefixLength(for: 8) == 3)
        // Long words bold a shrinking proportion so the line stays readable.
        #expect(BionicText.boldPrefixLength(for: 20) == 8)
    }

    @Test func emptyWordBoldsNothing() {
        #expect(BionicText.boldPrefixLength(for: 0) == 0)
    }

    @Test func attributedTextPreservesOriginalCharacters() {
        // The transform may only change styling — never the text itself.
        let source = "The quick brown fox\njumps over."
        let attributed = BionicText.attributed(source, font: .body, boldFont: .body.bold())
        #expect(String(attributed.characters) == source)
    }

    @Test func attributedTextPreservesWhitespaceRuns() {
        let source = "a    b\t\tc"
        let attributed = BionicText.attributed(source, font: .body, boldFont: .body.bold())
        #expect(String(attributed.characters) == source)
    }

    @Test func punctuationOnlyTokenSurvives() {
        let attributed = BionicText.attributed("--- ...", font: .body, boldFont: .body.bold())
        #expect(String(attributed.characters) == "--- ...")
    }
}
