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
