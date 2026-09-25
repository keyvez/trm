import Testing
@testable import trm

/// The question a reply ends on reaches the Command Center, however long the
/// reply is.
struct ClosingQuestionTests {
    private let longReply = String(repeating: "Built it and ran the suite, which passed. ", count: 80)
        + "\n\nWant me to deploy?"

    @Test func aLongReplyKeepsItsEnding() {
        let flat = CommandCenterMonitor.summarize([.paragraph(longReply)])
        #expect(flat.count < longReply.count)
        #expect(flat.hasSuffix("Want me to deploy?"))
        #expect(flat.hasPrefix("Built it"))
        #expect(flat.contains("…"))
    }

    @Test func aShortReplyIsLeftAlone() {
        #expect(CommandCenterMonitor.keepingEnds("Done. Ship it?", limit: 2000) == "Done. Ship it?")
    }

    @Test func theClosingQuestionIsReadFromTheWholeReply() {
        #expect(CommandCenterMonitor.closingQuestion(in: [.paragraph(longReply)]) == "Want me to deploy?")
        #expect(CommandCenterMonitor.closingQuestion(in: [
            .paragraph("Fixed the reconnect."),
            .paragraph("This isn't committed yet. Should I commit and push it like the others?"),
        ]) == "Should I commit and push it like the others?")
    }

    @Test func aReplyThatEndsOnAStatementAsksNothing() {
        #expect(CommandCenterMonitor.closingQuestion(in: [
            .paragraph("Is it flaky? It was not: the test reads a live tracker."),
        ]) == nil)
        #expect(CommandCenterMonitor.closingQuestion(in: []) == nil)
    }
}

/// Claude Code's "※ recap" is read from the transcript while it is current.
struct TranscriptRecapTests {
    private let prompt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix it"}]}}"#
    private let reply = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed. Want me to deploy?"}]}}"#
    private let recap = #"{"type":"system","subtype":"away_summary","content":"Fixed the shelf; next, deploy once you confirm."}"#

    @Test func aRecapAfterTheReplyIsKept() {
        let t = AgentTranscriptReader.parse(lines: [prompt, reply, recap])
        #expect(t.recap == "Fixed the shelf; next, deploy once you confirm.")
    }

    @Test func aRecapTheSessionHasMovedPastIsDropped() {
        #expect(AgentTranscriptReader.parse(lines: [prompt, reply, recap, prompt]).recap == nil)
        #expect(AgentTranscriptReader.parse(lines: [prompt, recap, reply]).recap == nil)
    }
}
