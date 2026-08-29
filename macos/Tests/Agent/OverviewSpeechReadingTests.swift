import Foundation
import Testing
@testable import trm

/// The full reading is what the play button does now, so what it refuses to
/// pronounce matters more than what it says.
@MainActor
struct OverviewSpeechReadingTests {

    @Test func inlineCodeIsJudgedSpanBySpanRatherThanStripped() {
        // A word in backticks is still a word.
        #expect(OverviewSpeaker.spokenForm(of: "retry") == "retry")
        #expect(OverviewSpeaker.spokenForm(of: "capture_retention_days")
                == "capture_retention_days")

        // A command is named, not read out flag by flag.
        #expect(OverviewSpeaker.spokenForm(of: "git filter-repo --force") == "a git command")
        #expect(OverviewSpeaker.spokenForm(of: "cargo test turn_detect") == "a command")
        #expect(OverviewSpeaker.spokenForm(of: "xcodebuild -scheme trm test") == "a command")

        // A path becomes the file, which is the part a person says out loud.
        #expect(OverviewSpeaker.spokenForm(of: "src/turn/smart_turn.rs") == "smart_turn.rs")
        #expect(OverviewSpeaker.spokenForm(of: "issues/O-17.md") == "O-17.md")

        #expect(OverviewSpeaker.spokenForm(of: "a1b2c3d4e5f6") == "a commit")
        #expect(OverviewSpeaker.spokenForm(of: "https://example.com/x") == "a link")

        // Symbol soup has no pronunciation worth attempting.
        #expect(OverviewSpeaker.spokenForm(of: "{\"op\":\"snapshot\",\"root\":\"/x\"}")
                == "a value")
    }

    @Test func tablesAreNamedRatherThanReadCellByCell() {
        let text = """
        Before and after on three calls:

        | metric | before | after |
        |---|---|---|
        | speaking_seconds | 0 | 47 |
        | talk_ratio | 0.0 | 0.35 |
        | wpm | null | 106 |

        That is the whole change.
        """
        let spoken = OverviewSpeaker.speakableProse(text)
        // The separator row is not a row; three data rows plus the header are.
        #expect(spoken.contains("a table of 4 rows"))
        // None of the cells survive as speech.
        #expect(!spoken.contains("talk_ratio"))
        #expect(!spoken.contains("0.35"))
        #expect(!spoken.contains("|"))
        // The prose around it does.
        #expect(spoken.contains("Before and after on three calls"))
        #expect(spoken.contains("That is the whole change"))
    }

    @Test func codeBlocksAreNamedByWhatTheyAreAndCollapseWhenAdjacent() {
        func reading(_ blocks: [AgentTranscript.Block]) -> String {
            OverviewSpeaker.fullReading(for: AgentTranscript(blocks: blocks))
        }

        #expect(reading([
            .paragraph("I rotated the secret."),
            .code(language: "bash", text: "git push --force-with-lease"),
        ]) == "I rotated the secret. Then a git command.")

        #expect(reading([
            .paragraph("Here is the fix."),
            .code(language: nil, text: "--- a/main.rs\n+++ b/main.rs"),
        ]).contains("Then a diff."))

        // An unlabelled fence that opens with a shell verb is a command.
        #expect(reading([
            .paragraph("Ran it."),
            .code(language: nil, text: "cargo test --all"),
        ]).contains("Then a shell command."))

        // Three in a row is one interruption, not three.
        let many = reading([
            .paragraph("Three commands."),
            .code(language: "bash", text: "ls"),
            .code(language: "bash", text: "cd x"),
            .code(language: "bash", text: "make"),
        ])
        #expect(many.contains("Then three shell commands."))
        #expect(!many.contains("Then a shell command. Then a shell command."))

        // Nothing from inside a block is ever spoken.
        #expect(!many.contains("make"))
    }

    @Test func theFullReadingKeepsWhatTheBriefingThrewAway() {
        let transcript = AgentTranscript(blocks: [
            .paragraph("Let me look at the turn detector first."),
            .paragraph("Smart-turn v3.2 is wired in and the CPU path passes 14 of 14."),
            .code(language: "bash", text: "python st.py --gpu"),
            .paragraph("The GPU session needs a CUDA provider. Fall back to CPU?"),
        ])
        let full = OverviewSpeaker.fullReading(for: transcript)
        let brief = OverviewSpeaker.developerBriefing(for: transcript)

        // The briefing deliberately drops "let me look at…"; the full reading
        // is the reply, so it keeps every paragraph.
        #expect(full.contains("Let me look at the turn detector"))
        #expect(!brief.contains("Let me look at the turn detector"))
        #expect(full.contains("Smart-turn v3.2 is wired in"))
        #expect(full.contains("Fall back to CPU?"))
        #expect(full.count > brief.count)
        // Even reading everything, the command is named rather than spoken.
        #expect(!full.contains("st.py --gpu"))
    }

    @Test func unpronounceableTokensInProseAreNamedOrDropped() {
        let spoken = OverviewSpeaker.speakableProse(
            "Reverted in 4f9a1c2b8e7d and pushed; see https://ci.example.com/run/821 for the log.")
        #expect(spoken.contains("a commit"))
        #expect(!spoken.contains("4f9a1c2b8e7d"))
        #expect(spoken.contains("a link"))
        #expect(!spoken.contains("ci.example.com"))
        // The sentence around them is left intact.
        #expect(spoken.contains("Reverted in"))
        #expect(spoken.contains("for the log"))
    }

    @Test func markdownScaffoldingNeverReachesTheVoice() {
        let spoken = OverviewSpeaker.speakableProse("""
        ## What changed

        - **Fixed** the retry path
        - Added a test

        > Worth checking before deploy.
        """)
        for scaffold in ["##", "**", "- ", "> "] {
            #expect(!spoken.contains(scaffold), "\(scaffold) survived into speech")
        }
        #expect(spoken.contains("What changed"))
        #expect(spoken.contains("Fixed the retry path"))
        #expect(spoken.contains("Worth checking before deploy"))
    }
}

/// Playback: the labels and the clock, which are the parts that are pure
/// enough to pin. Seeking itself needs a running audio graph.
@MainActor
struct OverviewPlaybackTests {

    @Test func rateLabelsReadAsSpeeds() {
        #expect(OverviewPlaybackControls.label(1) == "1×")
        #expect(OverviewPlaybackControls.label(2) == "2×")
        #expect(OverviewPlaybackControls.label(1.5) == "1.5×")
        #expect(OverviewPlaybackControls.label(0.75) == "0.75×")
    }

    @Test func thePositionSaysWhenTheEndIsNotYetTheEnd() {
        // Still generating: the total is only what has been rendered, and the
        // marker says so rather than implying the reply is 40 seconds long.
        #expect(OverviewPlaybackControls.position(9, of: 40, complete: false) == "0:09/0:40+")
        // Finished generating: the total is the total.
        #expect(OverviewPlaybackControls.position(9, of: 40, complete: true) == "0:09/0:40")
        #expect(OverviewPlaybackControls.position(0, of: 0, complete: true) == "0:00/0:00")
        #expect(OverviewPlaybackControls.position(125, of: 605, complete: true)
                == "2:05/10:05")
    }

    @Test func theRateIsClampedToWhatIsStillLanguage() {
        let speaker = OverviewSpeaker()
        speaker.rate = 5
        #expect(speaker.rate == 2)
        speaker.rate = 0.1
        #expect(speaker.rate == 0.5)
        speaker.rate = 1.5
        #expect(speaker.rate == 1.5)
        speaker.rate = 1
    }

    @Test func seekingIsInertWithNothingRendered() {
        let speaker = OverviewSpeaker()
        #expect(!speaker.canSeek)
        // Must not crash or move a clock that has no audio behind it.
        speaker.seek(by: -10)
        speaker.restart()
        #expect(speaker.elapsed == 0)
        #expect(!speaker.isSpeaking)
    }
}
