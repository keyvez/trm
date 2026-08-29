import Foundation
import Testing
@testable import trm

/// The taxonomy came from the assistant text in every Claude Code transcript
/// on both machines — ~17,000 messages. These pin the behaviour that survey
/// argued for, including the two things it caught the splitter getting wrong.
@MainActor
struct AgentCardTests {

    @Test func aShortReplyIsOneCardRatherThanConfetti() {
        // 70–78% of real messages are a single short block. Shredding those
        // would produce hundreds of cards a day worth reading none of.
        let cards = AgentCardSplitter.cards(markdown: "Done — pushed to main.")
        #expect(cards.count == 1)
        #expect(cards[0].kind == .did)

        #expect(AgentCardSplitter.cards(markdown: "").isEmpty)
        #expect(AgentCardSplitter.cards(markdown: "   \n  ").isEmpty)
    }

    @Test func theAgentsOwnHeadingsBecomeTheCards() {
        // These titles are the most common in the corpus, on both machines.
        let cards = AgentCardSplitter.cards(markdown: """
        ## What was wrong

        The callback secret was a 64-bit FNV-1a hash, not a MAC.

        ## The fix

        Rotated it to HMAC-SHA256 and updated both call sites.

        ## Verification

        All 406 tests pass and the build is clean.

        ## Two things worth knowing

        The engine and backend have to restart together.

        ## Asking you

        Do you want me to deploy this now?
        """)

        #expect(cards.map(\.kind) == [.found, .did, .verified, .caveat, .ask])
        // The card says what the agent called it, not what trm would.
        #expect(cards.map(\.title) == [
            "What was wrong", "The fix", "Verification",
            "Two things worth knowing", "Asking you",
        ])
    }

    @Test func boldLeadInsAreTitlesOnlyWhenTheSentenceStops() {
        // A real lead-in: the title ends and a new sentence begins.
        let real = AgentCardSplitter.sections(in: """
        **What changed** Rotated the secret to HMAC-SHA256.

        **One caveat** The engine has to restart with it.
        """)
        #expect(real.count == 2)
        #expect(real.map(\.heading) == ["What changed", "One caveat"])

        // Not a lead-in: the sentence continues through the bold. The survey
        // found cards whose whole body was ", in order of size" from this.
        let midSentence = AgentCardSplitter.sections(in:
            "**What would make it flawless**, in order of size: more tests.")
        #expect(midSentence.count == 1)
        #expect(midSentence[0].heading == nil)

        // Nor when a parenthetical follows it.
        let paren = AgentCardSplitter.sections(in:
            "**Code fixes** (`BUILD SUCCEEDED`, verified against live repos)")
        #expect(paren.count == 1)
        #expect(paren[0].heading == nil)
    }

    @Test func anAskHasToActuallyAsk() {
        // A question mark is an ask wherever it sits.
        #expect(AgentCardSplitter.classify(
            text: "Should I commit this batch first?", heading: nil,
            index: 0, of: 2) == .ask)
        // So is an outright request at the end of a reply.
        #expect(AgentCardSplitter.classify(
            text: "Say the word and I'll deploy it.", heading: nil,
            index: 1, of: 2) == .ask)
        // A statement that merely contains "which" is not. The survey caught
        // "…which is what you'd been calling it" filed as a question.
        #expect(AgentCardSplitter.classify(
            text: "Note the product name is Models — which is what you'd been calling it.",
            heading: nil, index: 1, of: 2) != .ask)
    }

    @Test func theKindsTheUserAskedForAreTheOnesThatComeOut() {
        func kind(_ text: String, last: Bool = false) -> AgentCardKind {
            AgentCardSplitter.classify(
                text: text, heading: nil, index: last ? 1 : 0, of: 2)
        }
        #expect(kind("Do you want me to deploy?", last: true) == .ask)
        #expect(kind("I couldn't resolve that from the code — it needs a decision.")
                == .blocked)
        #expect(kind("One thing worth knowing: the migration is not applied anywhere.")
                == .caveat)
        #expect(kind("Done — rotated the secret and updated both call sites.") == .did)
        #expect(kind("The bug was that the prune deleted the whole directory.") == .found)
        #expect(kind("All 406 tests pass and the build is clean.") == .verified)
    }

    @Test func cardsKeepTheirIdentityAsMoreOfTheReplyArrives() {
        // A turn's messages are appended, so cards must be stable across the
        // growth: what is on screen should not be rebuilt because the agent
        // kept talking.
        let firstHalf = """
        ## What was wrong

        The secret was a hash, not a MAC.

        ## The fix

        Rotated to HMAC-SHA256.
        """
        let whole = firstHalf + """


        ## Verification

        All tests pass.

        ## Asking you

        Deploy now?
        """
        let before = AgentCardSplitter.cards(markdown: firstHalf)
        let after = AgentCardSplitter.cards(markdown: whole)

        #expect(before.count == 2)
        #expect(after.count == 4)
        // The cards already on screen are unchanged, ids included.
        #expect(Array(after.prefix(2)).map(\.id) == before.map(\.id))
        #expect(Array(after.prefix(2)) == before)
    }

    @Test func anAskSinksToTheBottomBecauseItIsTheThingYouActOn() {
        let order = AgentCardKind.allCases.sorted { $0.rank < $1.rank }
        #expect(order.last == .ask)
        #expect(order.first == .found)
        // Every kind has a distinct place; a tie would make ordering arbitrary.
        #expect(Set(AgentCardKind.allCases.map(\.rank)).count
                == AgentCardKind.allCases.count)
    }
}
