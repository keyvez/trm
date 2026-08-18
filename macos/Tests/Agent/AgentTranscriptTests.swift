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

    @Test func injectedSkillDocumentIsNotAPrompt() {
        // Observed live: Claude records a selected skill's entire document as
        // a user message. One bundled skill was 923 KB, and rendering it as
        // "You asked" sent restored overview panes into a CoreText layout spin.
        let lines = [
            userLine("build the image editor"),
            userLine("Base directory for this skill: /tmp/bundled-skills/imagegen\n# Skill\nInjected instructions"),
        ]
        let t = AgentTranscriptReader.parse(lines: lines)
        #expect(t.lastUserPrompt == "build the image editor")
    }

    @Test func hugeHumanPromptIsCollapsedForOverviewRendering() throws {
        let prompt = String(repeating: "x", count: 50_000)
        let t = AgentTranscriptReader.parse(lines: [userLine(prompt)])
        let rendered = try #require(t.lastUserPrompt)

        #expect(rendered.hasPrefix(String(repeating: "x", count: AgentTranscriptReader.pasteCollapseKeptChars)))
        #expect(rendered.hasSuffix("[Pasted text +49000 chars]"))
        #expect(rendered.count < prompt.count)
    }

    // MARK: - Paste and image collapsing (CLI-matched)

    @Test func multiLinePasteCollapsesToHeadPlusBadge() throws {
        // 40 lines: keep the head, badge the rest — the CLI's
        // "[Pasted text #1 +N lines]" presentation, re-derived.
        let paste = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let t = AgentTranscriptReader.parse(lines: [userLine(paste)])
        let rendered = try #require(t.lastUserPrompt)

        let kept = AgentTranscriptReader.pasteCollapseKeptLines
        #expect(rendered.hasPrefix((1...kept).map { "line \($0)" }.joined(separator: "\n")))
        #expect(rendered.hasSuffix("[Pasted text +\(40 - kept) lines]"))
        #expect(!rendered.contains("line \(kept + 1)\n"))
    }

    @Test func shortPromptsAreNotCollapsed() {
        let prompt = "just a normal question\nwith a second line"
        let t = AgentTranscriptReader.parse(lines: [userLine(prompt)])
        #expect(t.lastUserPrompt == prompt)
    }

    @Test func attachedImagesBecomePlaceholderChips() {
        // A prompt with two pasted images: the base64 payload is useless as
        // prose; the CLI shows [Image #N] chips and so does the overview.
        let obj: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "text", "text": "compare these screenshots"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "BBBB"]],
        ]]]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let t = AgentTranscriptReader.parse(lines: [line])
        #expect(t.lastUserPrompt == "compare these screenshots\n[Image #1]\n[Image #2]")
    }

    @Test func imageOnlyPromptStillShowsAsAPrompt() {
        let obj: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]],
        ]]]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let t = AgentTranscriptReader.parse(lines: [line])
        #expect(t.lastUserPrompt == "[Image #1]")
    }

    @Test func promptFencedCodeBecomesACodeBlock() throws {
        let prompt = "fix this function\n```swift\nfunc broken() {}\n```"
        let t = AgentTranscriptReader.parse(lines: [userLine(prompt)])
        #expect(t.promptBlocks.count == 2)
        guard case .code(let lang, let code) = try #require(t.promptBlocks.last) else {
            Issue.record("expected code block, got \(String(describing: t.promptBlocks.last))")
            return
        }
        #expect(lang == "swift")
        #expect(code == "func broken() {}")
    }

    @Test func collapseClosesACutFenceSoTheBadgeStaysProse() throws {
        // A paste collapsed mid-code-block must not leave the fence open —
        // the badge would render as code.
        let code = (1...40).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        let prompt = "review:\n```swift\n\(code)\n```"
        let t = AgentTranscriptReader.parse(lines: [userLine(prompt)])
        guard case .paragraph(let tail) = try #require(t.promptBlocks.last) else {
            Issue.record("badge should be prose, got \(String(describing: t.promptBlocks.last))")
            return
        }
        #expect(tail.contains("[Pasted text +"))
    }

    @Test func pastedHTMLWithoutFencesIsDetectedAsCode() throws {
        let prompt = """
        why does this render wrong?
        <div class="card">
          <span>hello</span>
        </div>
        """
        let t = AgentTranscriptReader.parse(lines: [userLine(prompt)])
        #expect(t.promptBlocks.count == 2)
        guard case .code(let lang, let code) = try #require(t.promptBlocks.last) else {
            Issue.record("expected detected code block, got \(String(describing: t.promptBlocks.last))")
            return
        }
        #expect(lang == "html")
        #expect(code.contains("<span>hello</span>"))
        if case .paragraph(let intro) = try #require(t.promptBlocks.first) {
            #expect(intro == "why does this render wrong?")
        }
    }

    @Test func pastedJSWithoutFencesIsDetectedAsCode() throws {
        let prompt = "review this\nconst x = load();\nreturn x.map(f);"
        let t = AgentTranscriptReader.parse(lines: [userLine(prompt)])
        guard case .code(let lang, _) = try #require(t.promptBlocks.last) else {
            Issue.record("expected detected code block")
            return
        }
        #expect(lang == nil)
    }

    @Test func aSingleCodeLookingLineStaysProse() {
        // One odd line is not enough evidence — prose must not be miscast.
        let prompt = "the fix was adding a semicolon;\nthanks for the help"
        let t = AgentTranscriptReader.parse(lines: [userLine(prompt)])
        #expect(t.promptBlocks.count == 1)
        if case .code = t.promptBlocks[0] {
            Issue.record("single line must not convert to code")
        }
    }

    @Test func collapsedHTMLPasteKeepsBadgeAsProse() throws {
        let html = (1...40).map { "<li>item \($0)</li>" }.joined(separator: "\n")
        let t = AgentTranscriptReader.parse(lines: [userLine("check this list\n" + html)])
        guard case .paragraph(let tail) = try #require(t.promptBlocks.last) else {
            Issue.record("badge should be prose, got \(String(describing: t.promptBlocks.last))")
            return
        }
        #expect(tail.contains("[Pasted text +"))
        #expect(t.promptBlocks.contains { if case .code(let l, _) = $0 { return l == "html" } else { return false } })
    }

    /// 1×1 transparent PNG.
    private static let tinyPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    @Test func attachedImagesProduceInlineThumbnailBlocks() throws {
        let obj: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "text", "text": "what is this"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": Self.tinyPNG]],
        ]]]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let t = AgentTranscriptReader.parse(lines: [line])

        #expect(t.lastUserPrompt == "what is this\n[Image #1]")
        guard case .image(let data) = try #require(t.promptBlocks.last) else {
            Issue.record("expected image block, got \(String(describing: t.promptBlocks.last))")
            return
        }
        #expect(!data.isEmpty)
    }

    @Test func imagesInsideToolResultsAreNotPromptChips() {
        // A screenshot coming back in a tool_result is a result, not
        // something the human attached.
        let obj: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]],
            ]],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "BBBB"]],
        ]]]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let t = AgentTranscriptReader.parse(lines: [userLine("real question"), line])
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

    // MARK: - Turn history

    @Test func collectsEveryTurnInTheWindow() {
        let t = AgentTranscriptReader.parse(lines: [
            userLine("first question"),
            assistantLine([["type": "text", "text": "first answer"]]),
            userLine("second question"),
            assistantLine([["type": "text", "text": "second answer"]]),
        ])
        #expect(t.turns.count == 2)
        #expect(t.turns[0].prompt == "first question")
        #expect(t.turns[0].blocks == [.paragraph("first answer")])
        #expect(t.turns[1].prompt == "second question")
        // The top-level fields still mirror the latest turn.
        #expect(t.lastUserPrompt == "second question")
        #expect(t.blocks == [.paragraph("second answer")])
    }

    @Test func archivedTurnKeepsItsActivity() {
        let t = AgentTranscriptReader.parse(lines: [
            userLine("build it"),
            assistantLine([["type": "tool_use", "id": "t1", "name": "Bash",
                            "input": ["command": "make"]]]),
            toolResultLine("t1"),
            userLine("now test it"),
        ])
        #expect(t.turns.count == 2)
        #expect(t.turns[0].activity.count == 1)
        #expect(t.turns[0].activity[0].name == "Bash")
        #expect(t.turns[0].activity[0].finished)
        // The live turn starts clean, as before.
        #expect(t.activity.isEmpty)
    }

    @Test func leadingFragmentWithoutPromptIsStillATurn() {
        // The tail window can open mid-turn: assistant output whose prompt
        // was cut off upstream still deserves a page in history.
        let t = AgentTranscriptReader.parse(lines: [
            assistantLine([["type": "text", "text": "tail of an old answer"]]),
            userLine("new question"),
        ])
        #expect(t.turns.count == 2)
        #expect(t.turns[0].prompt == nil)
        #expect(t.turns[0].blocks == [.paragraph("tail of an old answer")])
        #expect(t.turns[1].prompt == "new question")
    }

    @Test func turnIDsAreStableAsNewTurnsAppend(){
        let base = [
            userLine("first"),
            assistantLine([["type": "text", "text": "answer one"]]),
        ]
        let before = AgentTranscriptReader.parse(lines: base)
        let after = AgentTranscriptReader.parse(lines: base + [
            userLine("second"),
            assistantLine([["type": "text", "text": "answer two"]]),
        ])
        #expect(before.turns.count == 1)
        #expect(after.turns.count == 2)
        #expect(before.turns[0].id == after.turns[0].id)
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

    // MARK: - Context usage

    @Test func contextPercentUsesStandardWindow() {
        #expect(AgentTranscriptReader.contextPercent(usedTokens: 100_000) == 50)
    }

    @Test func contextPercentInfersLargeWindowWhenOverStandard() {
        // A 1M-context session's transcript still reports the plain model id,
        // so usage past 200k is the only signal the window is bigger.
        #expect(AgentTranscriptReader.contextPercent(usedTokens: 600_000) == 60)
        #expect(AgentTranscriptReader.contextPercent(usedTokens: 1_200_000) == 100)
    }

    @Test func claudeUsageFlowsIntoTranscript() {
        let obj: [String: Any] = ["type": "assistant", "message": [
            "content": [["type": "text", "text": "hi"]],
            "usage": ["input_tokens": 2, "cache_creation_input_tokens": 818,
                      "cache_read_input_tokens": 99_180],
        ]]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let t = AgentTranscriptReader.parse(lines: [userLine("go"), line])
        #expect(t.contextUsedPercent == 50)
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

/// The agent overview must stay adjacent to the pane it describes — beside
/// it in the same row, or in its own row directly above/below.
/// `placeCompanion` applies and restores that invariant.
struct AgentOverviewAdjacencyTests {

    @Test func placesAfterAnchorInSameRow() {
        var layout = GridLayout(rowCols: [2], displayOrder: ["term", "other"])
        layout.placeCompanion("view", near: "term", side: .after)
        #expect(layout.displayOrder == ["term", "view", "other"])
        #expect(layout.rowCols == [3])
    }

    @Test func placesBeforeAnchorInSameRow() {
        var layout = GridLayout(rowCols: [2], displayOrder: ["term", "other"])
        layout.placeCompanion("view", near: "term", side: .before)
        #expect(layout.displayOrder == ["view", "term", "other"])
        #expect(layout.rowCols == [3])
    }

    @Test func placesInOwnRowAbove() {
        var layout = GridLayout(rowCols: [2, 1], displayOrder: ["a", "b", "term"])
        layout.placeCompanion("view", near: "term", side: .rowAbove)
        #expect(layout.displayOrder == ["a", "b", "view", "term"])
        #expect(layout.rowCols == [2, 1, 1])
    }

    @Test func placesInOwnRowBelow() {
        var layout = GridLayout(rowCols: [1, 2], displayOrder: ["term", "a", "b"])
        layout.placeCompanion("view", near: "term", side: .rowBelow)
        #expect(layout.displayOrder == ["term", "view", "a", "b"])
        #expect(layout.rowCols == [1, 1, 2])
    }

    @Test func movingBetweenSidesRemovesOldCell() {
        var layout = GridLayout(rowCols: [2], displayOrder: ["term", "other"])
        layout.placeCompanion("view", near: "term", side: .after)
        layout.placeCompanion("view", near: "term", side: .rowBelow)
        // Row-below means a new row after ALL cells of the anchor's row.
        #expect(layout.displayOrder == ["term", "other", "view"])
        #expect(layout.rowCols == [2, 1])
        #expect(layout.displayOrder.filter { $0 == "view" }.count == 1)
    }

    @Test func movingFromOwnRowBackBesideCollapsesTheRow() {
        var layout = GridLayout(rowCols: [2], displayOrder: ["term", "other"])
        layout.placeCompanion("view", near: "term", side: .rowAbove)
        #expect(layout.rowCols == [1, 2])
        layout.placeCompanion("view", near: "term", side: .after)
        #expect(layout.rowCols == [3])
        #expect(layout.displayOrder == ["term", "view", "other"])
    }

    @Test func companionImmediatelyBeforeAnchorEndsUpImmediatelyAfter() {
        // The view sitting just left of its terminal is what a swap produces.
        // Removal shifts the anchor left; a stale insert index would wedge a
        // pane between the pair.
        var layout = GridLayout(rowCols: [3], displayOrder: ["view", "term", "other"])
        layout.placeCompanion("view", near: "term", side: .after)
        #expect(layout.displayOrder == ["term", "view", "other"])
    }

    @Test func missingAnchorLeavesLayoutUnchanged() {
        var layout = GridLayout(rowCols: [2], displayOrder: ["a", "view"])
        layout.placeCompanion("view", near: "gone", side: .after)
        #expect(layout.displayOrder == ["a", "view"])
        #expect(layout.rowCols == [2])
    }

    @Test func placementNeverLosesOrDuplicatesPanes() {
        var layout = GridLayout(rowCols: [4], displayOrder: ["a", "view", "b", "term"])
        for side in [GridLayout<String>.CompanionSide.after, .before, .rowAbove, .rowBelow, .after] {
            layout.placeCompanion("view", near: "term", side: side)
            #expect(layout.displayOrder.count == 4)
            #expect(Set(layout.displayOrder) == Set(["a", "b", "term", "view"]))
            #expect(layout.rowCols.reduce(0, +) == 4)
        }
    }

    @Test func removeCellDropsSingleCellRow() {
        var layout = GridLayout(rowCols: [1, 2], displayOrder: ["view", "term", "b"])
        layout.removeCell(of: "view")
        #expect(layout.displayOrder == ["term", "b"])
        #expect(layout.rowCols == [2])
    }

    @Test func removeCellAbsentIdIsNoOp() {
        var layout = GridLayout(rowCols: [2], displayOrder: ["a", "b"])
        layout.removeCell(of: "ghost")
        #expect(layout.displayOrder == ["a", "b"])
        #expect(layout.rowCols == [2])
    }

    @Test func twoOverviewsBothStayPinned() {
        var layout = GridLayout(rowCols: [4], displayOrder: ["t1", "t2", "v1", "v2"])
        layout.placeCompanion("v1", near: "t1", side: .after)
        layout.placeCompanion("v2", near: "t2", side: .after)
        let order = layout.displayOrder
        #expect(order.firstIndex(of: "v1") == order.firstIndex(of: "t1")! + 1)
        #expect(order.firstIndex(of: "v2") == order.firstIndex(of: "t2")! + 1)
    }
}

/// Parsing of Codex CLI rollout transcripts. Fixture shapes mirror a real
/// rollout file (rollout-2026-08-08T01-08-57-*.jsonl).
struct CodexTranscriptTests {

    private func line(_ payload: [String: Any]) -> String {
        let obj: [String: Any] = ["timestamp": "2026-08-08T08:10:24.207Z", "type": "response_item", "payload": payload]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    private func userLine(_ text: String) -> String {
        line(["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]])
    }

    private func assistantLine(_ text: String) -> String {
        line(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])
    }

    @Test func parsesAssistantMessageAndPrompt() {
        let t = CodexTranscriptReader.parse(lines: [
            userLine("fix the build"),
            assistantLine("Looking at the failure now."),
        ])
        #expect(t.lastUserPrompt == "fix the build")
        #expect(t.blocks == [.paragraph("Looking at the failure now.")])
    }

    @Test func environmentContextIsNotAPrompt() {
        // Codex injects synthetic user messages wrapped in tags.
        let t = CodexTranscriptReader.parse(lines: [
            userLine("real ask"),
            userLine("<environment_context>\n  <cwd>/x</cwd>\n</environment_context>"),
        ])
        #expect(t.lastUserPrompt == "real ask")
    }

    @Test func developerMessagesAreIgnored() {
        let t = CodexTranscriptReader.parse(lines: [
            userLine("go"),
            line(["type": "message", "role": "developer",
                  "content": [["type": "input_text", "text": "<skills_instructions>…"]]]),
            assistantLine("Done."),
        ])
        #expect(t.lastUserPrompt == "go")
        #expect(t.blocks == [.paragraph("Done.")])
    }

    @Test func customToolCallsTrackAsActivity() {
        let t = CodexTranscriptReader.parse(lines: [
            userLine("build it"),
            line(["type": "custom_tool_call", "call_id": "c1", "name": "exec",
                  "input": "const r = await tools.exec_command({cmd:\"zig build\"})"]),
        ])
        #expect(t.activity.count == 1)
        #expect(t.activity[0].name == "exec")
        #expect(t.isWorking)
    }

    @Test func toolOutputMarksCallFinished() {
        let t = CodexTranscriptReader.parse(lines: [
            userLine("go"),
            line(["type": "custom_tool_call", "call_id": "c1", "name": "exec", "input": "ls"]),
            line(["type": "custom_tool_call_output", "call_id": "c1",
                  "output": [["type": "input_text", "text": "ok"]]]),
        ])
        #expect(t.activity[0].finished)
        #expect(!t.isWorking)
    }

    @Test func functionCallsParseArgumentsAsDetail() {
        let t = CodexTranscriptReader.parse(lines: [
            userLine("go"),
            line(["type": "function_call", "call_id": "f1", "name": "wait",
                  "arguments": "{\"cell_id\":\"20\"}"]),
        ])
        #expect(t.activity[0].name == "wait")
        #expect(t.activity[0].detail?.contains("cell_id") == true)
    }

    @Test func newPromptResetsTurn() {
        let t = CodexTranscriptReader.parse(lines: [
            userLine("first"),
            line(["type": "custom_tool_call", "call_id": "c1", "name": "exec", "input": "ls"]),
            userLine("second"),
        ])
        #expect(t.lastUserPrompt == "second")
        #expect(t.activity.isEmpty)
    }

    @Test func toolOnlyTurnKeepsPreviousProse() {
        let t = CodexTranscriptReader.parse(lines: [
            userLine("go"),
            assistantLine("Starting."),
            line(["type": "custom_tool_call", "call_id": "c1", "name": "exec", "input": "ls"]),
        ])
        #expect(t.blocks == [.paragraph("Starting.")])
    }

    @Test func tokenCountEventYieldsContextPercent() {
        // Shape from a real rollout: token_count carries the window size.
        let obj: [String: Any] = ["timestamp": "t", "type": "event_msg", "payload": [
            "type": "token_count",
            "info": ["model_context_window": 258_400,
                     "last_token_usage": ["total_tokens": 129_200]],
        ]]
        let tc = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let t = CodexTranscriptReader.parse(lines: [userLine("go"), tc, assistantLine("ok")])
        #expect(t.contextUsedPercent == 50)
    }
}

/// Pure parts of the per-pane agent-session resolution.
struct AgentSessionLocatorTests {

    @Test func recognizesAgentProcessNames() {
        #expect(AgentSessionLocator.kind(forProcessName: "claude") == .claude)
        #expect(AgentSessionLocator.kind(forProcessName: "codex") == .codex)
        #expect(AgentSessionLocator.kind(forProcessName: "zsh") == nil)
        #expect(AgentSessionLocator.kind(forProcessName: "claude-helper") == nil)
    }

    @Test func birthTimeCorrelationPicksThisProcessSession() {
        // Mirrors the observed disambiguation case: two Claude sessions share
        // one cwd. The pane's process started at T; its transcript was born
        // T+2m; the other session's file was born a month earlier. Agents
        // don't hold transcripts open, so this correlation is the binding.
        let started = Date(timeIntervalSince1970: 1_000_000)
        let old = (URL(fileURLWithPath: "/t/old.jsonl"), started.addingTimeInterval(-3_000_000))
        let mine = (URL(fileURLWithPath: "/t/mine.jsonl"), started.addingTimeInterval(140))
        let later = (URL(fileURLWithPath: "/t/later.jsonl"), started.addingTimeInterval(90_000))
        let pick = AgentSessionLocator.selectTranscript(
            startedAt: started, slack: 30, candidates: [later, old, mine])
        #expect(pick?.0.lastPathComponent == "mine.jsonl")
    }

    @Test func noCandidateBornAfterStartMeansNoMatch() {
        // A resumed session reuses an old file — correlation must miss and let
        // the caller fall back rather than guessing.
        let started = Date(timeIntervalSince1970: 1_000_000)
        let old = (URL(fileURLWithPath: "/t/old.jsonl"), started.addingTimeInterval(-86_400))
        let pick = AgentSessionLocator.selectTranscript(
            startedAt: started, slack: 30, candidates: [old])
        #expect(pick == nil)
    }

    @Test func slackToleratesFileBornJustBeforeProcessClock() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let justBefore = (URL(fileURLWithPath: "/t/j.jsonl"), started.addingTimeInterval(-10))
        let pick = AgentSessionLocator.selectTranscript(
            startedAt: started, slack: 30, candidates: [justBefore])
        #expect(pick?.0.lastPathComponent == "j.jsonl")
    }

    @Test func transcriptPathsMatchPerAgent() {
        #expect(AgentSessionLocator.isTranscriptPath(
            "/Users/x/.claude/projects/-Users-x-dev/abc.jsonl", kind: .claude))
        #expect(!AgentSessionLocator.isTranscriptPath(
            "/Users/x/.claude/projects/-Users-x-dev/abc.jsonl", kind: .codex))
        #expect(AgentSessionLocator.isTranscriptPath(
            "/Users/x/.codex/sessions/2026/08/08/rollout-abc.jsonl", kind: .codex))
        #expect(!AgentSessionLocator.isTranscriptPath(
            "/Users/x/.codex/sessions/2026/08/08/rollout-abc.txt", kind: .codex))
        #expect(!AgentSessionLocator.isTranscriptPath(
            "/Users/x/somewhere/else.jsonl", kind: .claude))
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
