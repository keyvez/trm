import Testing
import Foundation
@testable import trm

/// Sanitizing and validating typed/pasted SSH destinations for remote panes.
@MainActor
struct RemoteHostInputTests {

    @Test func cleanHostsPassThrough() {
        #expect(BaseTerminalController.sanitizedRemoteHost("laptop.follow-ionian.ts.net")
                == "laptop.follow-ionian.ts.net")
        #expect(BaseTerminalController.sanitizedRemoteHost("gaurav@100.125.56.90")
                == "gaurav@100.125.56.90")
    }

    @Test func edgeWhitespaceIsTrimmed() {
        #expect(BaseTerminalController.sanitizedRemoteHost("  host.example \n")
                == "host.example")
    }

    @Test func interiorNewlineFromAWrappedCopyIsRemoved() {
        // Copying a hostname out of a terminal that hard-wrapped the line
        // yields an interior newline the user can't see. Hostnames never
        // contain whitespace, so stripping it anywhere is always right.
        #expect(BaseTerminalController.sanitizedRemoteHost("laptop.follow-io\nnian.ts.net")
                == "laptop.follow-ionian.ts.net")
    }

    @Test func zeroWidthCharactersAreRemoved() {
        // U+200B zero-width space and U+2060 word joiner arrive from chat
        // apps and rich-text sources; both are invisible in the text field.
        #expect(BaseTerminalController.sanitizedRemoteHost("host\u{200B}.example\u{2060}")
                == "host.example")
    }

    @Test func pastedSSHCommandDropsTheSSHWord() {
        #expect(BaseTerminalController.sanitizedRemoteHost("ssh gaurav@laptop.ts.net")
                == "gaurav@laptop.ts.net")
    }

    @Test func sanitizedWrappedHostValidates() {
        let host = BaseTerminalController.sanitizedRemoteHost("laptop.follow-io\nnian.ts.net")
        #expect(BaseTerminalController.isValidRemoteHost(host))
    }

    @Test func validatorStillRejectsShellMetacharacters() {
        #expect(!BaseTerminalController.isValidRemoteHost("host;rm -rf /"))
        #expect(!BaseTerminalController.isValidRemoteHost("host$(x)"))
        #expect(!BaseTerminalController.isValidRemoteHost("a@b@c"))
        #expect(!BaseTerminalController.isValidRemoteHost(""))
    }
}
