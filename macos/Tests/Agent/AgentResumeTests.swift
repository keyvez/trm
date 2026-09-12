import Testing
import Foundation
@testable import trm

/// Recovering an agent conversation after the machine restarts.
struct AgentResumeTests {

    @Test func claudeTranscriptIsNamedAfterItsSession() {
        let url = URL(fileURLWithPath:
            "/Users/x/.claude/projects/-Users-x-dev-trm/de7207f7-7cad-42cf-88f2-0394881e85e7.jsonl")
        let record = AgentResume.record(forTranscript: url)
        #expect(record?.kind == .claude)
        #expect(record?.id == "de7207f7-7cad-42cf-88f2-0394881e85e7")
    }

    @Test func codexIdIsCountedFromTheEndBecauseTheTimestampHasDashesToo() {
        let url = URL(fileURLWithPath:
            "/Users/x/.codex/sessions/2026/09/11/rollout-2026-09-11T13-01-10-019a55d2-d108-7352-9043-fc2495a48755.jsonl")
        let record = AgentResume.record(forTranscript: url)
        #expect(record?.kind == .codex)
        #expect(record?.id == "019a55d2-d108-7352-9043-fc2495a48755")
    }

    @Test func aTranscriptFromNeitherAgentYieldsNothing() {
        #expect(AgentResume.record(forTranscript:
            URL(fileURLWithPath: "/tmp/notes/de7207f7-7cad-42cf-88f2-0394881e85e7.jsonl")) == nil)
    }

    @Test func aFilenameThatIsNotAnIdIsRefused() {
        // The id goes into a shell command, so anything not shaped like a
        // session id has to stop here rather than be passed along.
        #expect(!AgentResume.isUUID("; rm -rf ~"))
        #expect(!AgentResume.isUUID("de7207f7-7cad-42cf-88f2"))
        #expect(!AgentResume.isUUID("zzzzzzzz-7cad-42cf-88f2-0394881e85e7"))
        #expect(AgentResume.isUUID("de7207f7-7cad-42cf-88f2-0394881e85e7"))
        #expect(AgentResume.record(forTranscript: URL(fileURLWithPath:
            "/Users/x/.claude/projects/p/not-a-session.jsonl")) == nil)
    }

    @Test func theResumeCommandIsWhatEachAgentActuallyTakes() {
        let id = "de7207f7-7cad-42cf-88f2-0394881e85e7"
        #expect(AgentResume.command(for: .init(kind: .claude, id: id))
                == "claude --resume '\(id)'")
        #expect(AgentResume.command(for: .init(kind: .codex, id: id))
                == "codex resume '\(id)'")
    }
}
