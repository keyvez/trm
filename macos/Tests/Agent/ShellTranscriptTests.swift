import Foundation
import Testing
@testable import trm

/// A shell pane's scrollback is the only transcript it has, and nothing in it
/// marks where a command starts. These pin the rules that find the boundaries
/// — and, as importantly, the ones that refuse to.
@MainActor
struct ShellTranscriptTests {

    // MARK: - Splitting

    @Test func scrollbackSplitsIntoCommandsAndTheirOutput() {
        let scrollback = """
        ~/dev/trm ❯ git status
        On branch main
        nothing to commit, working tree clean
        ~/dev/trm ❯ ls
        README.md
        src
        ~/dev/trm ❯
        """
        let commands = ShellTranscriptReader.commands(inScrollback: scrollback)
        #expect(commands.count == 2)
        #expect(commands[0].command == "git status")
        #expect(commands[0].output == ["On branch main", "nothing to commit, working tree clean"])
        #expect(commands[1].command == "ls")
        // A prompt drawn after a command is the shell saying it finished.
        let allFinished = commands.allSatisfy { $0.finished }
        #expect(allFinished)
    }

    @Test func theLastCommandIsStillRunningWhenNoPromptFollows() {
        let scrollback = """
        ~/dev/trm ❯ zig build
        compiling…
        """
        let commands = ShellTranscriptReader.commands(inScrollback: scrollback)
        #expect(commands.count == 1)
        #expect(commands[0].finished == false)

        let transcript = ShellTranscriptReader.transcript(
            commands: commands, updatedAt: Date())
        #expect(transcript.isWorking)
        #expect(transcript.turns.count == 1)
    }

    @Test func outputThatLooksLikeAPromptIsNotACommand() {
        // The `$` and `%` here are output — a price, a percentage, a docs
        // snippet. Only `❯` repeats, so only `❯` is the prompt.
        let scrollback = """
        ~/dev ❯ ./report
        total: $ 42 spent
        cpu: 93% of one core
        run it with $ ./report --all
        ~/dev ❯
        """
        let commands = ShellTranscriptReader.commands(inScrollback: scrollback)
        #expect(commands.count == 1)
        #expect(commands[0].command == "./report")
        #expect(commands[0].output.count == 3)
    }

    @Test func aPaneInsideOneLongRunningProgramIsStillReadable() {
        // No prompt anywhere: a dev server started before the window opened.
        // Reporting nothing here would blank the overview for exactly the
        // pane someone is watching.
        let scrollback = """
        listening on http://localhost:3000
        GET /  200
        GET /app.js  200
        """
        let commands = ShellTranscriptReader.commands(inScrollback: scrollback)
        #expect(commands.count == 1)
        #expect(commands[0].command.isEmpty)
        #expect(commands[0].output.count == 3)
        #expect(commands[0].finished == false)
    }

    @Test func aRightHandPromptIsNotPartOfTheCommand() {
        // RPROMPT (a clock, a timer) is padded to the far edge and ends up on
        // the command's line once the trailing spaces are trimmed.
        let split = ShellTranscriptReader.promptSplit(
            "~/dev/trm ❯ zig build test                    took 2m14s")
        #expect(split?.command == "zig build test")
    }

    @Test func promptsAreFoundWhateverTheShellDrawsThem() {
        #expect(ShellTranscriptReader.promptSplit("g@mini ~ % ls")?.command == "ls")
        #expect(ShellTranscriptReader.promptSplit("bash-5.2$ make")?.command == "make")
        #expect(ShellTranscriptReader.promptSplit("root@box:/# apt update")?.command
                == "apt update")
        #expect(ShellTranscriptReader.promptSplit("➜  trm git:(main) ✗ git push") != nil)
        // Not prompts: a variable, a percentage, a sentence.
        #expect(ShellTranscriptReader.promptSplit("echo $HOME") == nil)
        #expect(ShellTranscriptReader.promptSplit("cpu 93% idle") == nil)
    }

    @Test func aThemeThatPrintsAfterTheMarkerDoesNotBecomeTheCommand() {
        // oh-my-zsh's default theme, taken verbatim from a live pane on this
        // machine: the marker opens the line and the directory, branch and
        // dirty flag all sit where the command should be.
        let scrollback = """
        ➜  ios git:(feature/mic-test) ✗ security unlock-keychain
        ---UNLOCK OK ---
        ➜  ios git:(feature/mic-test) ✗ codesign --force --sign FD70 build/app
        codesign: invalid option -- p
        ➜  ios git:(feature/mic-test) ✗
        """
        let commands = ShellTranscriptReader.commands(inScrollback: scrollback)
        #expect(commands.count == 2)
        #expect(commands[0].command == "security unlock-keychain")
        #expect(commands[1].command == "codesign --force --sign FD70 build/app")
        #expect(commands[1].summary.errorCount == 1)
    }

    @Test func aBareDirectoryInThePromptIsFoundByRepetition() {
        // The same theme outside a git repo: nothing but the directory
        // between the marker and the command. It is only safe to drop
        // because it opens nearly every prompt line and names the pane's own
        // directory — a word that merely repeats is left alone.
        let scrollback = """
        ➜  trm ls
        README.md
        ➜  trm zig build
        ➜  trm git status
        On branch main
        ➜  trm
        """
        let commands = ShellTranscriptReader.commands(
            inScrollback: scrollback, cwdName: "trm")
        #expect(commands.map(\.command) == ["ls", "zig build", "git status"])

        // Without knowing the directory, a bare word is not assumed to be one.
        let unknown = ShellTranscriptReader.commands(inScrollback: scrollback)
        #expect(unknown[0].command == "trm ls")
    }

    @Test func aRepeatedFirstWordThatIsNotAPlaceIsKept() {
        // Someone whose every command starts with `git` must not lose it.
        let token = ShellTranscriptReader.repeatedLeadingToken(
            in: ["git status", "git add -A", "git commit -m x"], cwdName: "trm")
        #expect(token == nil)
        #expect(ShellTranscriptReader.repeatedLeadingToken(
            in: ["~ ls", "~ pwd", "~ top"], cwdName: nil) == "~")
    }

    @Test func linesTheTerminalWrappedAreRejoined() {
        // Scrollback is what was drawn, so a command wider than the pane
        // arrives in pieces. On the 79-column pane this was found on, the
        // command read `security unlock-keychain ~/Lib` and the rest of it
        // became two lines of output.
        let width = 40
        let wrapped = [
            String(repeating: "a", count: width),
            "tail",
            String(repeating: "b", count: width),
            "end",
            String(repeating: "c", count: width),
            "stop",
            "short line",
        ]
        let joined = ShellTranscriptReader.unwrapped(wrapped)
        #expect(joined == [
            String(repeating: "a", count: width) + "tail",
            String(repeating: "b", count: width) + "end",
            String(repeating: "c", count: width) + "stop",
            "short line",
        ])

        // Nothing to learn from, nothing joined.
        #expect(ShellTranscriptReader.unwrapped(["one", "two"]) == ["one", "two"])
    }

    @Test func aWrappedCommandIsReadWhole() {
        let long = "security unlock-keychain ~/Library/Keychains/login.keychain-db"
        let width = 40
        let head = String(long.prefix(width))
        let rest = String(long.dropFirst(width))
        let scrollback = [
            "➜  ios ✗ " + String(repeating: "x", count: width - 9),
            "done",
            "➜  ios ✗ " + head.prefix(width - 9),
            rest,
            "➜  ios ✗ " + String(repeating: "y", count: width - 9),
            "done",
        ].joined(separator: "\n")
        let commands = ShellTranscriptReader.commands(inScrollback: scrollback)
        #expect(commands.count == 3)
        #expect(commands[1].command.hasSuffix("login.keychain-db"))
    }

    @Test func theDominantMarkerWins() {
        #expect(ShellTranscriptReader.dominantMarker(in: ["❯", "❯", "$"]) == "❯")
        // `>` opens quoted lines and diffs, so it only wins unopposed.
        #expect(ShellTranscriptReader.dominantMarker(in: [">", ">", ">", "%"]) == "%")
        #expect(ShellTranscriptReader.dominantMarker(in: [">", ">"]) == ">")
        #expect(ShellTranscriptReader.dominantMarker(in: []) == nil)
    }

    // MARK: - Errors

    @Test func failingLinesAreFoundAndSuccessfulOnesAreNot() {
        #expect(ShellOutputSummary.isErrorLine("error: expected ';' before '}'"))
        #expect(ShellOutputSummary.isErrorLine("zsh: command not found: gti"))
        #expect(ShellOutputSummary.isErrorLine("Traceback (most recent call last):"))
        #expect(ShellOutputSummary.isErrorLine("fatal: not a git repository"))
        #expect(ShellOutputSummary.isErrorLine("npm ERR! code ELIFECYCLE"))

        // The lines that make a naive error filter useless.
        #expect(!ShellOutputSummary.isErrorLine("0 errors, 3 warnings"))
        #expect(!ShellOutputSummary.isErrorLine("no errors found"))
        #expect(!ShellOutputSummary.isErrorLine("warning: unused variable 'x'"))
        #expect(!ShellOutputSummary.isErrorLine("Build succeeded"))
        #expect(!ShellOutputSummary.isErrorLine(""))
    }

    @Test func theErrorExcerptCarriesItsContextAndTheCommand() {
        let command = ShellCommand(
            index: 0,
            command: "zig build test",
            output: [
                "compiling termania",
                "src/termania/grid.zig:41:9: error: expected type 'u32'",
                "    const x: u32 = value;",
                "        ^",
            ],
            finished: true)
        let excerpt = command.errorExcerpt(context: 2)
        #expect(excerpt?.hasPrefix("$ zig build test") == true)
        #expect(excerpt?.contains("compiling termania") == true)
        #expect(excerpt?.contains("const x: u32 = value;") == true)
        #expect(command.firstErrorLine?.hasPrefix("src/termania/grid.zig") == true)

        // Nothing failed, nothing to excerpt.
        let clean = ShellCommand(
            index: 0, command: "ls", output: ["a", "b"], finished: true)
        #expect(clean.errorExcerpt() == nil)
    }

    // MARK: - Summary

    @Test func theSummaryLeadsWithTheFailureAndThenWithTheFacts() {
        let failed = ShellCommand(
            index: 0, command: "cargo test",
            output: ["running 12 tests", "error: test failed"], finished: true)
        #expect(failed.summary.headline.hasPrefix("Failed:"))
        #expect(failed.summary.errorCount == 1)

        let passed = ShellCommand(
            index: 0, command: "cargo test",
            output: ["running 12 tests", "12 tests passed", "done in 4s"],
            finished: true)
        #expect(passed.summary.errorCount == 0)
        #expect(passed.summary.headline == "12 tests passed")
        #expect(passed.summary.facts.contains("done in 4s"))

        let running = ShellCommand(
            index: 0, command: "npm run dev", output: ["ready"], finished: false)
        #expect(running.summary.headline.contains("Still running"))

        let silent = ShellCommand(
            index: 0, command: "touch x", output: [], finished: true)
        #expect(silent.summary.headline == "No output.")
    }

    // MARK: - Categories

    @Test func commandsAreCategorisedByTheWorkTheyDo() {
        #expect(ShellCommandKind.classify("git status") == .vcs)
        #expect(ShellCommandKind.classify("zig build test") == .test)
        #expect(ShellCommandKind.classify("zig build") == .build)
        #expect(ShellCommandKind.classify("zig build run") == .run)
        #expect(ShellCommandKind.classify("npm install") == .packages)
        #expect(ShellCommandKind.classify("npm run dev") == .run)
        #expect(ShellCommandKind.classify("rg overview src") == .search)
        #expect(ShellCommandKind.classify("ssh mini uptime") == .remote)
        #expect(ShellCommandKind.classify("docker ps") == .containers)
        #expect(ShellCommandKind.classify("./scripts/deploy.sh") == .run)
        // A leading environment assignment does not name the work.
        #expect(ShellCommandKind.classify("RUST_LOG=debug cargo build") == .build)
    }

    // MARK: - Cards

    @Test func aFailedCommandGetsCommandSummaryFailureAndOutputCards() {
        let command = ShellCommand(
            index: 0, command: "zig build",
            output: ["compiling", "error: no member named 'foo'", "one error"],
            finished: true)
        let cards = ShellCardBuilder.cards(for: command)
        #expect(cards.map(\.kind) == [.command, .summary, .failure, .output])
        // The command card is titled by what kind of work it is.
        #expect(cards[0].title == "Build")
        #expect(cards[0].subtitle == "failed")
        // The failure card copies the excerpt, the output card the full log.
        #expect(cards[2].copyText.contains("error: no member named 'foo'"))
        #expect(cards[3].copyText.hasPrefix("$ zig build"))
    }

    @Test func aQuietCommandDoesNotGetASummaryOfItself() {
        let command = ShellCommand(
            index: 0, command: "pwd", output: ["/Users/g/dev/trm"], finished: true)
        let cards = ShellCardBuilder.cards(for: command)
        #expect(cards.map(\.kind) == [.command, .output])
    }

    // MARK: - Transcript shape

    @Test func turnsAndCommandsStayAligned() {
        let scrollback = """
        ~ ❯ echo one
        one
        ~ ❯ echo two
        two
        ~ ❯
        """
        let commands = ShellTranscriptReader.commands(inScrollback: scrollback)
        let transcript = ShellTranscriptReader.transcript(
            commands: commands, updatedAt: Date())
        #expect(transcript.turns.count == commands.count)
        #expect(transcript.lastUserPrompt == "echo two")
        #expect(transcript.activity.first?.name == "echo")
        #expect(transcript.activity.first?.detail == "two")
        #expect(transcript.isWorking == false)
    }

    @Test func aLongOutputIsPreviewedByItsTailAndCopiedInFull() {
        let lines = (1...200).map { "line \($0)" }
        let command = ShellCommand(
            index: 0, command: "cat big.txt", output: lines, finished: true)
        let preview = command.outputPreview(lines: 60)
        #expect(preview.contains("… 140 earlier lines"))
        #expect(preview.contains("line 200"))
        #expect(!preview.contains("line 100"))
        #expect(command.fullLog.contains("line 100"))
        #expect(command.tail(lines: 3) == "line 198\nline 199\nline 200")
    }
}
