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
    // MARK: - Segmenting a reading

    @Test func segmentsGroupSentencesUpToTheLimit() {
        let text = "One. Two. Three."
        let reading = OverviewSpeaker.reading(of: text, direction: nil)
        // Short sentences ride together: a generate() call per "Two." would
        // spend more time starting than speaking.
        #expect(reading.segments.count == 1)
        #expect(reading.segments[0].text == text)
    }

    @Test func segmentRangesPointAtTheOriginalText() {
        let text = String(repeating: "This sentence is a reasonable length. ", count: 8)
        let reading = OverviewSpeaker.reading(of: text, direction: nil)
        #expect(reading.segments.count > 1)
        for segment in reading.segments {
            // The range is what the highlight uses; if it does not match the
            // segment's own text it is pointing somewhere else on screen.
            #expect(String(text[segment.range]) == segment.text)
        }
    }

    @Test func segmentsStayUnderTheLimitAndLoseNothing() {
        let text = String(repeating: "A moderately long sentence about the build. ", count: 10)
        let reading = OverviewSpeaker.reading(of: text, direction: nil)
        for segment in reading.segments {
            #expect(segment.text.count <= OverviewSpeaker.segmentLimit + 60)
        }
        let rejoined = reading.segments.map(\.text).joined()
        #expect(rejoined.replacingOccurrences(of: " ", with: "")
                == text.replacingOccurrences(of: " ", with: ""))
    }

    @Test func aReadingWithOneSentenceIsStillASegment() {
        let reading = OverviewSpeaker.reading(of: "Done.", direction: nil)
        #expect(reading.segments.count == 1)
        #expect(reading.segments[0].text == "Done.")
    }

    @Test func sentenceRangesSubdivideASegmentForTheHighlight() {
        let text = "The build failed. I am looking at the log now. It was a missing import."
        let ranges = OverviewSpeaker.speechSentenceRanges(in: text)
        #expect(ranges.count == 3)
        #expect(String(text[ranges[0]]).trimmingCharacters(in: .whitespaces)
                == "The build failed.")
        #expect(String(text[ranges[2]]).trimmingCharacters(in: .whitespaces)
                == "It was a missing import.")
    }
    // MARK: - Saying numbers

    @Test func aMoneyRangeIsSaidAsARange() {
        // The reported case: a symbol spoken after the number, a dash meaning
        // "to", and a magnitude letter that governs both ends.
        #expect(OverviewSpeaker.spokenNumbers("It costs $15-45k a year.")
                == "It costs 15 to 45 thousand dollars a year.")
    }

    @Test func bothEndsKeepTheirOwnMagnitudeWhenTheyDiffer() {
        #expect(OverviewSpeaker.spokenNumbers("$900k-2M")
                == "900 thousand to 2 million dollars")
    }

    @Test func aSingleAmountMovesItsSymbolAfterTheNumber() {
        #expect(OverviewSpeaker.spokenNumbers("about $1.5M") == "about 1.5 million dollars")
        #expect(OverviewSpeaker.spokenNumbers("£200 each") == "200 pounds each")
    }

    @Test func thousandsSeparatorsGoSoTheNumberIsNotReadInHalves() {
        #expect(OverviewSpeaker.spokenNumbers("$15,000") == "15000 dollars")
    }

    @Test func percentRangesGetTheirDashSpokenToo() {
        #expect(OverviewSpeaker.spokenNumbers("10-20% slower")
                == "10 to 20 percent slower")
    }

    @Test func plainNumbersAndDatesAreLeftAlone() {
        // Only money and percentages are rewritten. A version, a date or a
        // hyphenated range of ordinary numbers has no symbol to move, and
        // guessing at those breaks more than it fixes.
        #expect(OverviewSpeaker.spokenNumbers("on 2026-09-11") == "on 2026-09-11")
        #expect(OverviewSpeaker.spokenNumbers("takes 3-4 minutes") == "takes 3-4 minutes")
        #expect(OverviewSpeaker.spokenNumbers("version 1.7") == "version 1.7")
    }

    @Test func moneyIsNormalisedOnTheWayIntoSpeech() {
        // Not just the helper: the text the speaker actually sends.
        #expect(OverviewSpeaker.plainProse("Budget is **$15-45k**.")
                == "Budget is 15 to 45 thousand dollars.")
    }
    @Test func aFigureInBackticksIsSpokenNotCalledAValue() {
        // The reported bug: `$15-45k` in a reply reached the "is this a word
        // or a machine" test, had a symbol in it, and came out as "a value".
        #expect(OverviewSpeaker.spokenForm(of: "$15-45k")
                == "15 to 45 thousand dollars")
        #expect(OverviewSpeaker.spokenForm(of: "$1.5M") == "1.5 million dollars")
        #expect(OverviewSpeaker.spokenForm(of: "45k") == "45 thousand")
        #expect(OverviewSpeaker.spokenForm(of: "10-20%") == "10 to 20 percent")
    }

    @Test func backtickedMachineryIsStillNamedRatherThanRead() {
        // The figure rule must not swallow the spans the old behaviour was
        // right about.
        #expect(OverviewSpeaker.spokenForm(of: "git rebase -i") == "a git command")
        #expect(OverviewSpeaker.spokenForm(of: "a1b2c3d4e5f6") == "a commit")
        #expect(OverviewSpeaker.spokenForm(of: "{\"a\":1,\"b\":[2,3],\"c\":\"x/y\"}") == "a value")
    }

    @Test func moneyInBacktickedProseSurvivesTheWholePipeline() {
        let spoken = OverviewSpeaker.speakableProse("The budget is `$15-45k` for now.")
        #expect(spoken == "The budget is 15 to 45 thousand dollars for now.")
        #expect(!spoken.contains("value"))
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
