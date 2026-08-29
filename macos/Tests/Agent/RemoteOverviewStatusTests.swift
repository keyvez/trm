import Foundation
import Testing
@testable import trm

/// The message a remote overview shows when it has no transcript to show.
@MainActor
struct RemoteOverviewStatusTests {

    @Test func aDeliveredButEmptySessionIsNotCalledStreaming() {
        // The case found on the laptop: the mirror had arrived — 15 lines,
        // 32 KB, zero assistant messages — and the pane claimed it was still
        // streaming, indefinitely. Bytes on disk mean the transfer worked.
        #expect(AgentOverviewPane.remoteEmptyStatus(
            host: "g@100.93.182.104", mirrorHasData: true)
            == "No messages in this session yet.")

        // Nothing has arrived yet: "streaming" is then the truth.
        #expect(AgentOverviewPane.remoteEmptyStatus(
            host: "g@100.93.182.104", mirrorHasData: false)
            == "Streaming the session from g@100.93.182.104…")
    }

    @Test func theStreamingMessageNamesTheHostItIsWaitingOn() {
        // Which host is the useful half of that sentence when several remote
        // panes are open at once.
        let status = AgentOverviewPane.remoteEmptyStatus(
            host: "gaurav@mini.follow-ionian.ts.net", mirrorHasData: false)
        #expect(status.contains("gaurav@mini.follow-ionian.ts.net"))
    }

    @Test func theEmptyMessageMatchesTheWordsTheLocalPathAlreadyUses() {
        // Local and remote panes should not describe the same state in two
        // different ways; the local path has said this since before mirrors
        // existed.
        #expect(AgentOverviewPane.remoteEmptyStatus(host: "h", mirrorHasData: true)
                == "No messages in this session yet.")
    }
}
