import Testing
@testable import trm

/// Reading an agent's on-screen question off the pane.
///
/// The fixtures are the shapes Claude Code draws: a boxed permission prompt, a
/// boxed prompt with a diff above the question, and a bare numbered menu. The
/// rejections matter as much as the matches — a numbered list in a reply must
/// never come back as a question somebody is waiting on.
struct PanePromptDetectorTests {

    // MARK: Fixtures

    private let permission = """
        ⏺ I'll update the retry loop.

        ╭─────────────────────────────────────────────────────────╮
        │ Do you want to make this edit to Session.zig?           │
        │ ❯ 1. Yes                                                │
        │   2. Yes, and don't ask again this session              │
        │   3. No, and tell Claude what to do differently         │
        ╰─────────────────────────────────────────────────────────╯

          esc to interrupt
        """

    private let withDiff = """
        ╭─────────────────────────────────────────────────────────╮
        │ Edit file                                               │
        │ ╭─────────────────────────────────────────────────────╮ │
        │ │ Session.zig                                         │ │
        │ │   41  -     if (self.socket) |s| s.close();         │ │
        │ │   41  +     if (self.socket) |s| { s.close();       │ │
        │ │   42  +         self.poller.deinit(); }             │ │
        │ ╰─────────────────────────────────────────────────────╯ │
        │ Do you want to make this edit to Session.zig?           │
        │ ❯ 1. Yes                                                │
        │   2. No, and tell Claude what to do differently         │
        ╰─────────────────────────────────────────────────────────╯
        """

    private let bare = """
        Which approach should I take?

        ❯ 1. Rewrite the retry loop
          2. Leave it and add a test
        """

    // MARK: Matches

    @Test func readsABoxedPermissionPrompt() {
        let prompt = PanePromptDetector.detect(inViewport: permission)
        #expect(prompt?.question == "Do you want to make this edit to Session.zig?")
        #expect(prompt?.options.map(\.number) == [1, 2, 3])
        #expect(prompt?.options.first?.label == "Yes")
        #expect(prompt?.selected?.number == 1)
        #expect(prompt?.previewRows == nil)
    }

    @Test func theFrameIsThePromptsExtent() {
        // Rows 2…7 of the fixture: the box, not the line of prose above it.
        let prompt = PanePromptDetector.detect(inViewport: permission)
        #expect(prompt?.rows.lowerBound == 2)
        #expect(prompt?.rows.upperBound == 7)
    }

    @Test func aDiffAboveTheQuestionIsThePreview() {
        let prompt = PanePromptDetector.detect(inViewport: withDiff)
        #expect(prompt?.question == "Do you want to make this edit to Session.zig?")
        #expect(prompt?.options.count == 2)
        // Everything inside the frame above the question: the header, the
        // nested box and the diff lines.
        #expect(prompt?.previewRows == 1...7)
    }

    @Test func aPromptWithNoBoxIsStillAPrompt() {
        let prompt = PanePromptDetector.detect(inViewport: bare)
        #expect(prompt?.question == "Which approach should I take?")
        #expect(prompt?.options.map(\.label) == [
            "Rewrite the retry loop", "Leave it and add a test",
        ])
        #expect(prompt?.selected?.number == 1)
    }

    @Test func aWrappedOptionLabelDoesNotBreakTheRun() {
        let prompt = PanePromptDetector.detect(inViewport: """
            Do you want to proceed?
            ❯ 1. Yes, and run the whole suite afterwards so the
                 regression is covered before I move on
              2. No
            """)
        #expect(prompt?.options.count == 2)
        #expect(prompt?.options.last?.label == "No")
    }

    // MARK: Rejections

    @Test func aNumberedListInAReplyIsNotAQuestion() {
        // Same shape as a menu — a sentence ending in a colon over three
        // consecutive numbered lines — and not a menu. What tells them apart
        // is the cursor: an agent waiting for a choice draws one, an agent
        // listing what it did does not.
        let prompt = PanePromptDetector.detect(inViewport: """
            I found three problems and fixed all of them:

            1. The poller was never freed
            2. The retry loop spun on a closed socket
            3. The test asserted the wrong count

            Everything passes now.
            """)
        #expect(prompt == nil)
    }

    @Test func aMenuWithNoCursorIsNotWaitingOnAnyone() {
        // The echo left behind after a prompt is answered: the choices are
        // still on screen, but nothing is resting on one of them.
        #expect(PanePromptDetector.detect(inViewport: """
            Do you want to make this edit to Session.zig?
              1. Yes
              2. No
            """) == nil)
    }

    @Test func oneChoiceIsNotAMenu() {
        #expect(PanePromptDetector.detect(inViewport: """
            Do you want to proceed?
            ❯ 1. Yes
            """) == nil)
    }

    @Test func anAnsweredPromptScrolledOutOfReachIsIgnored() {
        // The same box, with a screenful of output under it: the agent moved
        // on, and re-offering the question is how a board starts lying.
        let after = (1...20).map { "  running step \($0)…" }.joined(separator: "\n")
        #expect(PanePromptDetector.detect(inViewport: permission + "\n" + after) == nil)
    }

    @Test func emptyIsNothing() {
        #expect(PanePromptDetector.detect(inViewport: "") == nil)
        #expect(PanePromptDetector.detect(inViewport: "\n\n   \n") == nil)
    }

    // MARK: Pieces

    @Test func optionLinesAreRecognisedWithTheirCursor() {
        #expect(PanePromptDetector.optionParts("❯ 1. Yes")?.selected == true)
        #expect(PanePromptDetector.optionParts("  2. No")?.selected == false)
        #expect(PanePromptDetector.optionParts("3) Maybe")?.number == 3)
    }

    @Test func aDecimalIsNotAnOption() {
        #expect(PanePromptDetector.optionParts("1.5 seconds elapsed") == nil)
        #expect(PanePromptDetector.optionParts("41. ") == nil)
        #expect(PanePromptDetector.optionParts("v1. something") == nil)
    }

    @Test func aFramedRowReadsAsItsContents() {
        #expect(PanePromptDetector.unframed("│ Do you want to proceed?   │") == "Do you want to proceed?")
        #expect(PanePromptDetector.unframed("│   2. No") == "  2. No")
        #expect(PanePromptDetector.unframed("plain text") == "plain text")
    }
}
