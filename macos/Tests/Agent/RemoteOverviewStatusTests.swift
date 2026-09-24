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

/// What the mirror on disk is allowed to lose.
///
/// A mirror is written through an open handle and read back by path, so a
/// deleted file is not an inconvenience — it is an overview that never updates
/// again, silently, for as long as the app runs.
struct RemoteMirrorPruningTests {

    @Test func pruningNeverTakesAMirrorSomethingIsStreamingInto() throws {
        let host = "prune-test@example.invalid"
        let session = "trm-\(UUID().uuidString.prefix(8))"
        let mirror = RemoteAgentTranscriptMirror.acquire(host: host, remoteSession: session)
        let url = mirror.mirrorURL
        defer {
            RemoteAgentTranscriptMirror.release(mirror)
            try? FileManager.default.removeItem(at: url)
        }

        FileManager.default.createFile(atPath: url.path, contents: Data("{}\n".utf8))
        // An idle session stops appending, so its mirror's age says nothing
        // about whether anything is still writing to it. This is the shape of
        // the bug: old file, live stream.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
            ofItemAtPath: url.path)

        RemoteAgentTranscriptMirror.pruneStaleMirrors(olderThan: 24 * 60 * 60)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func pruningStillTakesAMirrorNothingHolds() throws {
        let dir = try #require(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent("trm/remote-overview", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("prune-test@example.invalid-trm-orphan.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data("{}\n".utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
            ofItemAtPath: url.path)

        RemoteAgentTranscriptMirror.pruneStaleMirrors(olderThan: 24 * 60 * 60)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
