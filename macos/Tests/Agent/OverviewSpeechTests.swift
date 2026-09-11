import Testing
import Foundation
@testable import trm

/// Turning a reply's blocks into natural speech text.
@MainActor
struct OverviewSpeechTests {

    @Test func speaksProseAndSkipsCodeAndImages() {
        let text = OverviewSpeaker.spokenText(blocks: [
            .paragraph("First point."),
            .code(language: "swift", text: "let x = 1"),
            .image(Data([0x1])),
            .paragraph("Second point."),
        ])
        #expect(text == "First point.\n\nSecond point.")
    }

    @Test func stripsMarkdownMarkersForSpeech() {
        #expect(OverviewSpeaker.plainProse("This is **bold** and `code`.")
                == "This is bold and code.")
        #expect(OverviewSpeaker.plainProse("See [the docs](https://example.com) now.")
                == "See the docs now.")
        #expect(OverviewSpeaker.plainProse("## Heading\n- item one\n1. item two")
                == "Heading\nitem one\nitem two")
    }

    @Test func briefingKeepsOutcomesAndDropsProcessNarration() {
        var transcript = AgentTranscript()
        transcript.blocks = [
            .paragraph("Let me inspect the build output now."),
            .paragraph("Streaming TTS is implemented. All 12 tests pass. It is not deployed yet."),
        ]

        let text = OverviewSpeaker.developerBriefing(for: transcript)
        #expect(!text.lowercased().contains("let me"))
        #expect(text.contains("Streaming TTS is implemented."))
        #expect(text.contains("All 12 tests pass."))
        #expect(text.contains("not deployed"))
    }

    @Test func briefingIsEmptyForLowSignalChatter() {
        var transcript = AgentTranscript()
        transcript.blocks = [
            .paragraph("I am checking the next file."),
            .paragraph("Now I will inspect the surrounding code."),
        ]
        #expect(OverviewSpeaker.developerBriefing(for: transcript).isEmpty)
    }

    // MARK: - Mood

    private func failure(_ name: String, _ error: String, id: String)
        -> AgentTranscript.ToolActivity {
        .init(id: id, name: name, detail: nil, finished: true,
              isError: true, errorText: error)
    }

    @Test func threeOfTheSameFailureSoundsFrustrated() {
        var transcript = AgentTranscript()
        transcript.blocks = [.paragraph("Trying the restore test again.")]
        transcript.activity = (1...3).map {
            failure("Bash", "session restore test failed", id: "\($0)")
        }
        #expect(OverviewSpeaker.isStuck(transcript))
        #expect(OverviewSpeaker.mood(for: transcript, reading: "Trying again.") == .frustrated)
    }

    @Test func threeDifferentFailuresAreJustABadAfternoon() {
        var transcript = AgentTranscript()
        transcript.activity = [
            failure("Bash", "session restore test failed", id: "1"),
            failure("Edit", "file not found", id: "2"),
            failure("Read", "permission denied", id: "3"),
        ]
        // Concerned, yes; stuck, no. Being stuck is the same wall repeatedly.
        #expect(!OverviewSpeaker.isStuck(transcript))
        #expect(OverviewSpeaker.mood(for: transcript, reading: "Three things broke.") == .concerned)
    }

    @Test func repetitionIsMatchedByShapeNotByExactText() {
        var transcript = AgentTranscript()
        // The same failure never arrives as the same string — durations, line
        // numbers and pids move between attempts.
        transcript.activity = [
            failure("Bash", "3 tests failed in 4.12s", id: "1"),
            failure("Bash", "3 tests failed in 3.80s", id: "2"),
            failure("Bash", "3 tests failed in 4.44s", id: "3"),
        ]
        #expect(OverviewSpeaker.isStuck(transcript))
    }

    @Test func twoFailuresIsARetryNotAPattern() {
        var transcript = AgentTranscript()
        transcript.activity = [
            failure("Bash", "build failed", id: "1"),
            failure("Bash", "build failed", id: "2"),
        ]
        #expect(!OverviewSpeaker.isStuck(transcript))
    }

    @Test func aQuestionOutranksEverythingElse() {
        var transcript = AgentTranscript()
        transcript.activity = (1...5).map {
            failure("Bash", "build failed", id: "\($0)")
        }
        transcript.questions = [
            .init(id: "q", toolCallID: "t", header: nil,
                  text: "Which database should I use?", options: [],
                  allowsMultiple: false, finished: false),
        ]
        // Being asked something is the only state that is about you.
        #expect(OverviewSpeaker.mood(for: transcript, reading: "Which one?") == .asking)
    }

    @Test func goodNewsSoundsPleasedAndPlainProseStaysNeutral() {
        let clean = AgentTranscript()
        #expect(OverviewSpeaker.mood(for: clean, reading: "All tests passed.") == .pleased)
        #expect(OverviewSpeaker.mood(for: clean, reading: "I read the file.") == .neutral)
    }

    @Test func moodChangesDeliveryButNeverTheSpeaker() {
        var transcript = AgentTranscript()
        transcript.activity = (1...3).map {
            failure("Bash", "build failed", id: "\($0)")
        }
        let stuck = OverviewSpeaker.direction(for: transcript, reading: "Again.")
        let calm = OverviewSpeaker.direction(for: AgentTranscript(), reading: "I read the file.")
        // The voice description is the same in both; only what follows it moves.
        #expect(stuck.hasPrefix(OverviewSpeaker.baseVoice))
        #expect(calm == OverviewSpeaker.baseVoice)
        #expect(stuck != calm)
    }
}

/// GFM pipe tables parsed into real table blocks.
@MainActor
struct OverviewMarkdownTableTests {

    @Test func parsesPipeTable() {
        let blocks = OverviewMarkdownBlock.parse("""
        Intro line.

        | Name | Port |
        | --- | :---: |
        | Moltis | 49264 |
        | Tailscale | - |
        """)
        #expect(blocks == [
            .paragraph("Intro line."),
            .table(
                headers: ["Name", "Port"],
                rows: [["Moltis", "49264"], ["Tailscale", "-"]]
            ),
        ])
    }

    @Test func pipeLinesWithoutSeparatorStayProse() {
        let blocks = OverviewMarkdownBlock.parse("| just | one | row |")
        #expect(blocks == [.paragraph("| just | one | row |")])
    }

    @Test func raggedRowsArePaddedToHeaderWidth() {
        let blocks = OverviewMarkdownBlock.parse("""
        | A | B | C |
        |---|---|---|
        | 1 | 2 |
        | 1 | 2 | 3 | 4 |
        """)
        #expect(blocks == [
            .table(headers: ["A", "B", "C"],
                   rows: [["1", "2", ""], ["1", "2", "3"]]),
        ])
    }

    @Test func tablesSpeakAsCommaSeparatedCells() {
        let spoken = OverviewSpeaker.plainProse("""
        | Name | Port |
        | --- | --- |
        | Moltis | 49264 |
        """)
        #expect(spoken == "Name, Port\nMoltis, 49264")
    }
}
