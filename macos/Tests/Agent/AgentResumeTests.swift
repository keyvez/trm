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

    // MARK: - Panes on another machine

    @Test func aLiveRemoteSessionIsNeverTypedAt() {
        // Its agent is still running in it. A resume typed here would arrive
        // in the agent as a prompt, not in a shell as a command.
        let answers = AgentResume.parseRemoteProbe("trm-27e30c6d\talive\t")
        #expect(answers["trm-27e30c6d"]?.alive == true)
        #expect(answers["trm-27e30c6d"]?.record == nil)
    }

    @Test func aGoneRemoteSessionYieldsTheConversationItWasHaving() {
        let answers = AgentResume.parseRemoteProbe([
            "trm-498c04ca\tgone\t/Users/g/.claude/projects/-Users-g-dev-fasmac/"
                + "15275240-2060-4ace-9cc0-09d0223c1346.jsonl",
            "trm-29351d5f\tgone\t/Users/g/.codex/sessions/2026/09/07/"
                + "rollout-2026-09-07T12-26-35-01a07d56-307c-7f80-aea1-e9cee4f80b29.jsonl",
            "trm-nope\tgone\t",
        ].joined(separator: "\n"))
        #expect(answers["trm-498c04ca"]?.record
                == .init(kind: .claude, id: "15275240-2060-4ace-9cc0-09d0223c1346"))
        #expect(answers["trm-29351d5f"]?.record
                == .init(kind: .codex, id: "01a07d56-307c-7f80-aea1-e9cee4f80b29"))
        // Gone, but the hook never recorded anything for it: a fresh shell,
        // which is what a pane without an agent should come back as.
        #expect(answers["trm-nope"]?.alive == false)
        #expect(answers["trm-nope"]?.record == nil)
    }

    @Test func probeNoiseIsNotAnAnswer() {
        // The far side's login shell can print a banner before the script
        // runs; a line that isn't alive/gone says nothing about a session.
        #expect(AgentResume.parseRemoteProbe("Welcome to mini\n\nLast login: Fri").isEmpty)
    }

    @Test func theProbeTestsForAListenerNotForAFile() {
        // The sockets live under $HOME and outlive a restart, so the machine
        // this feature exists for is exactly the one where the file is there
        // and nothing is behind it.
        let script = AgentResume.remoteProbeScript(sessions: ["trm-27e30c6d"])
        #expect(script.contains("lsof -t"))
        #expect(script.contains("$HOME/.trm/agent-sessions/$N"))
        #expect(script.contains("\"trm-27e30c6d\""))
    }

    @Test func aSessionNameThatIsNotOneNeverReachesTheRemoteShell() {
        #expect(AgentResume.isSafeSessionName("trm-27e30c6d"))
        #expect(!AgentResume.isSafeSessionName("trm-x; rm -rf ~"))
        #expect(!AgentResume.isSafeSessionName("$(whoami)"))
        #expect(!AgentResume.isSafeSessionName(""))
        #expect(AgentResume.remoteSessions(host: "h", sessions: ["a b"]).isEmpty)
    }

    @Test func theResumeCommandIsWhatEachAgentActuallyTakes() {
        let id = "de7207f7-7cad-42cf-88f2-0394881e85e7"
        #expect(AgentResume.command(for: .init(kind: .claude, id: id))
                == "claude --resume '\(id)'")
        #expect(AgentResume.command(for: .init(kind: .codex, id: id))
                == "codex resume '\(id)'")
    }
}
