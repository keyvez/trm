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
}
