import Testing
@testable import trm

/// A file name is not a web address, whatever its extension spells.
struct WrittenLinksTests {
    @Test func aFileNameWithACountryCodeExtensionIsNotALink() {
        // .rs is Serbia, .py Paraguay, .md Moldova: the detector happily
        // made each of these into an http:// address.
        #expect(WrittenLinks.matches(in: "Fixed the retry loop in jobs.rs and main.py, see README.md").isEmpty)
        #expect(CommandCenterMonitor.links(inText: "edited src/jobs.rs").isEmpty)
    }

    @Test func linksWrittenAsLinksAreStillFound() {
        let urls = WrittenLinks.matches(in: "docs at https://example.com/a and www.example.org")
            .map(\.url.absoluteString)
        #expect(urls == ["https://example.com/a", "http://www.example.org"])
    }

    @Test func aFileNameBesideARealLinkStaysPlainText() {
        let urls = WrittenLinks.matches(in: "jobs.rs is served at http://localhost:3000/jobs")
            .map(\.url.absoluteString)
        #expect(urls == ["http://localhost:3000/jobs"])
    }
}
