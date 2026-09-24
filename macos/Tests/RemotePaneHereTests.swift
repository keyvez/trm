import Testing
@testable import trm

/// ⌃⌘⇧N: a remote pane in the focused pane's folder, running its agent.
struct RemotePaneHereTests {

    // MARK: Starting the agent again

    @Test func theAgentsOwnFlagsComeAlong() {
        #expect(RemotePaneHere.launchCommand(
            agent: .claude,
            commandLine: "/Users/g/.local/share/claude/versions/2.1.226 --dangerously-skip-permissions --model opus")
            == "claude --dangerously-skip-permissions --model opus")
    }

    @Test func aConversationIsNotResumedTwice() {
        // Two agents on one session id would write one transcript.
        #expect(RemotePaneHere.launchCommand(
            agent: .claude, commandLine: "claude --resume 3f2a-99 --dangerously-skip-permissions")
            == "claude --dangerously-skip-permissions")
        #expect(RemotePaneHere.launchCommand(agent: .claude, commandLine: "claude --resume=3f2a -c")
            == "claude")
        #expect(RemotePaneHere.launchCommand(agent: .claude, commandLine: "claude -r --verbose")
            == "claude --verbose")
        #expect(RemotePaneHere.launchCommand(agent: .codex, commandLine: "codex resume 0199ab --full-auto")
            == "codex --full-auto")
        #expect(RemotePaneHere.launchCommand(agent: .codex, commandLine: "codex resume --last")
            == "codex")
    }

    @Test func noCommandLineIsJustTheAgent() {
        #expect(RemotePaneHere.launchCommand(agent: .codex, commandLine: nil) == "codex")
    }

    // MARK: The folder

    @Test func aHomePathNamesTheSamePlaceUnderAnotherUser() {
        #expect(RemotePaneHere.homeRelative("/Users/gaurav/dev/trm", home: "/Users/gaurav") == "~/dev/trm")
        #expect(RemotePaneHere.homeRelative("/Users/gaurav", home: "/Users/gaurav") == "~")
        #expect(RemotePaneHere.homeRelative("/Users/gauravx/a", home: "/Users/gaurav") == "/Users/gauravx/a")
        #expect(RemotePaneHere.homeRelative("/opt/src", home: "/Users/gaurav") == "/opt/src")
    }

    @Test func theFolderIsQuotedForTheRemoteShell() {
        #expect(RemotePaneHere.remoteCdTarget("/Users/g/dev/trm") == "/Users/g/dev/trm")
        #expect(RemotePaneHere.remoteCdTarget("~/My Project") == "\"$HOME\"/'My Project'")
        #expect(RemotePaneHere.remoteCdTarget("/tmp/it's") == "'/tmp/it'\\''s'")
    }

    @Test func theAttachCommandStartsInTheFolder() {
        let plain = BaseTerminalController.remoteAttachCommand(
            host: "g@mini", session: "s1", zmxPath: "/z")
        let here = BaseTerminalController.remoteAttachCommand(
            host: "g@mini", session: "s1", zmxPath: "/z", directory: "~/dev/it's")
        #expect(!plain.contains("cd "))
        #expect(here.contains("g@mini 'cd \"$HOME\"/'\\''dev/it'\\''\\'\\'''\\''s'\\'' 2>/dev/null; S=s1;"))
    }

    // MARK: Reading the probe

    @Test func theProbesAnswerIsRead() {
        #expect(RemotePaneHere.parse("/Users/g/dev/trm\tclaude\tclaude --dangerously-skip-permissions\n")
            == .init(directory: "/Users/g/dev/trm", agent: .claude,
                     agentCommandLine: "claude --dangerously-skip-permissions"))
        #expect(RemotePaneHere.parse("/Users/g\t\t\n")
            == .init(directory: "/Users/g", agent: nil, agentCommandLine: nil))
        #expect(RemotePaneHere.parse("") == nil)
    }
}
