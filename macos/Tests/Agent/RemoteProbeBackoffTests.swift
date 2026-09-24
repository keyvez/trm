import Testing
@testable import trm

/// How often trm is allowed to ask a machine that isn't answering, and what
/// counts as the same machine.
///
/// Both rules exist because of one failure: macOS launches sshd through
/// launchd with a hard cap of 42 concurrent instances, so a Mac with a dozen
/// remote panes open sits near the ceiling, and past it connections are closed
/// during key exchange. Probing faster on failure, and probing the same Mac
/// once per spelling of its address, are the two ways trm made that worse.
struct RemoteProbeBackoffTests {

    // MARK: Backoff

    @Test func aHealthyHostIsAskedOnTheOrdinaryCadence() {
        #expect(IssueTrackerDiscoveryCache.retryDelay(afterFailures: 0) == 30)
    }

    @Test func failureBacksOffInsteadOfSpeedingUp() {
        // The bug this replaces recorded a failed probe twenty seconds in the
        // past against a thirty second lifetime, so an unreachable host was
        // retried three times as often as a reachable one.
        let first = IssueTrackerDiscoveryCache.retryDelay(afterFailures: 1)
        let second = IssueTrackerDiscoveryCache.retryDelay(afterFailures: 2)
        let third = IssueTrackerDiscoveryCache.retryDelay(afterFailures: 3)
        #expect(first == 60)
        #expect(second == 120)
        #expect(third == 240)
        #expect(first > IssueTrackerDiscoveryCache.retryDelay(afterFailures: 0))
    }

    @Test func theWaitIsCapped() {
        // A machine that is off for the weekend should still be found within a
        // quarter of an hour of coming back.
        #expect(IssueTrackerDiscoveryCache.retryDelay(afterFailures: 50) == 900)
        #expect(IssueTrackerDiscoveryCache.retryDelay(afterFailures: 5) <= 900)
    }

    // MARK: One machine, one probe

    private let dump = """
        host mini
        user g
        hostname 100.93.182.104
        port 22
        controlmaster auto
        """

    @Test func aDestinationIsTheAccountAndTheAddressItResolvesTo() {
        #expect(IssueTrackerDiscoveryCache.destination(fromSSHConfigDump: dump)
            == "g@100.93.182.104")
    }

    @Test func twoSpellingsOfOneMachineAreOneDestination() {
        // What `ssh -G` says for `g@mini.follow-ionian.ts.net` and for
        // `g@100.93.182.104` once ~/.ssh/config has rewritten the name.
        let byName = IssueTrackerDiscoveryCache.destination(fromSSHConfigDump: dump)
        let byAddress = IssueTrackerDiscoveryCache.destination(fromSSHConfigDump: """
            host 100.93.182.104
            user g
            hostname 100.93.182.104
            port 22
            """)
        #expect(byName == byAddress)
    }

    @Test func adifferentAccountIsADifferentDestination() {
        // `gaurav@` on a machine whose user is `g` cannot succeed, and merging
        // it with the working spelling would hide that rather than fix it.
        let wrongUser = IssueTrackerDiscoveryCache.destination(fromSSHConfigDump: """
            host mini.follow-ionian.ts.net
            user gaurav
            hostname 100.93.182.104
            port 22
            """)
        #expect(wrongUser == "gaurav@100.93.182.104")
        #expect(wrongUser != IssueTrackerDiscoveryCache.destination(fromSSHConfigDump: dump))
    }

    @Test func anUnusualPortIsPartOfTheDestination() {
        #expect(IssueTrackerDiscoveryCache.destination(fromSSHConfigDump: """
            user g
            hostname 100.93.182.104
            port 2222
            """) == "g@100.93.182.104:2222")
    }

    @Test func anUnreadableDumpIsNoAnswer() {
        #expect(IssueTrackerDiscoveryCache.destination(fromSSHConfigDump: "") == nil)
        #expect(IssueTrackerDiscoveryCache.destination(fromSSHConfigDump: "user g") == nil)
    }
}
