import Foundation
import Testing
@testable import trm

/// Clearing an agent's context empties the agent, not the record of what it
/// said. These pin what survives a clear, where the seams fall, and the index
/// arithmetic the overview pages by — none of which is visible from the app
/// without a live agent to clear.
struct AgentTurnHistoryTests {

    private func turn(_ prompt: String) -> AgentTranscript.Turn {
        var value = AgentTranscript.Turn()
        value.prompt = prompt
        return value
    }

    // MARK: - Keeping turns across a clear

    @Test func clearingContextKeepsEarlierTurnsPageable() {
        var history = AgentTurnHistory()
        let first = [turn("one"), turn("two")]
        history.beginContext(sourceKey: "/sessions/a.jsonl", liveTurns: [])

        // The fresh session file `/clear` opens, while the old turns are still
        // what the pane holds.
        history.beginContext(sourceKey: "/sessions/b.jsonl", liveTurns: first)

        let afterClear = history.entries(liveTurns: [])
        #expect(afterClear.count == 3)
        #expect(afterClear.map(\.turn.prompt) == ["one", "two", nil])
        // The empty new context still owns the newest slot, so "latest" means
        // the live view rather than the last turn of the context just cleared.
        #expect(afterClear.last?.isPlaceholder == true)
        #expect(history.hasClearedContexts)
    }

    @Test func theSeamFallsBetweenTheOldTurnsAndTheNewOnes() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        history.beginContext(sourceKey: "b", liveTurns: [turn("one"), turn("two")])

        let entries = history.entries(liveTurns: [turn("three")])
        #expect(entries.count == 3)
        #expect(entries[0].contextIndex == entries[1].contextIndex)
        #expect(entries[2].contextIndex != entries[1].contextIndex)
        #expect(history.breakDates[entries[2].contextIndex] != nil)
    }

    @Test func aFirstBindingDividesNothing() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        let entries = history.entries(liveTurns: [turn("one")])
        #expect(entries.count == 1)
        #expect(!history.hasClearedContexts)
        #expect(entries[0].contextIndex == 0)
    }

    @Test func anEmptyContextIsNotWorthADivider() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        // Two files in a row with nothing said in either.
        history.beginContext(sourceKey: "b", liveTurns: [])
        history.beginContext(sourceKey: "c", liveTurns: [])
        #expect(history.entries(liveTurns: [turn("one")]).count == 1)
        #expect(!history.hasClearedContexts)
    }

    // MARK: - A locator that changes its mind

    @Test func returningToAFileAdoptsItsContextInsteadOfCopyingIt() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        let original = [turn("one"), turn("two")]

        // Away to another file, then back — a locator flap, or a resumed
        // session. The turns must not be filed twice.
        history.beginContext(sourceKey: "b", liveTurns: original)
        history.beginContext(sourceKey: "a", liveTurns: [])

        let entries = history.entries(liveTurns: original)
        #expect(entries.count == 2)
        #expect(entries.map(\.turn.prompt) == ["one", "two"])
        #expect(Set(entries.map(\.contextIndex)).count == 1)
    }

    @Test func anAgentGoingAwayKeepsWhatItSaid() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        // The session can no longer be located: nothing is live, but the turns
        // stay readable.
        history.beginContext(sourceKey: nil, liveTurns: [turn("one")])
        let entries = history.entries(liveTurns: [])
        #expect(entries.count == 2)
        #expect(entries[0].turn.prompt == "one")
        #expect(entries[1].isPlaceholder)
    }

    // MARK: - Bounds and resets

    @Test func keptTurnsAreCappedFromTheOldestEnd() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        let many = (0..<(AgentTurnHistory.maxArchivedTurns + 25)).map { turn("t\($0)") }
        history.beginContext(sourceKey: "b", liveTurns: many)

        let entries = history.entries(liveTurns: [])
        // The cap plus the live placeholder.
        #expect(entries.count == AgentTurnHistory.maxArchivedTurns + 1)
        #expect(entries.first?.turn.prompt == "t25")
    }

    @Test func resetForgetsEveryContext() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        history.beginContext(sourceKey: "b", liveTurns: [turn("one")])
        history.reset()
        #expect(history.entries(liveTurns: []).isEmpty)
        #expect(!history.hasClearedContexts)
    }

    @Test func everyContextGetsItsOwnNumber() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        history.beginContext(sourceKey: "b", liveTurns: [turn("one")])
        history.beginContext(sourceKey: "c", liveTurns: [turn("two")])
        history.beginContext(sourceKey: "d", liveTurns: [turn("three")])

        let entries = history.entries(liveTurns: [turn("four")])
        // Turns said either side of a clear must be separable, or a divider
        // goes missing.
        let indices = entries.map(\.contextIndex)
        #expect(entries.count == 4)
        #expect(Set(indices).count == 4)
    }

    @Test func adoptingAnOldContextDoesNotReuseTheNumberItLeft() {
        var history = AgentTurnHistory()
        history.beginContext(sourceKey: "a", liveTurns: [])
        history.beginContext(sourceKey: "b", liveTurns: [turn("one")])
        // Back to "a": its context is adopted, and the live parse of that file
        // supplies its turns again.
        history.beginContext(sourceKey: "a", liveTurns: [])
        // Then on to a third file, which must not land on a number already
        // spoken for.
        history.beginContext(sourceKey: "c", liveTurns: [turn("two")])

        let entries = history.entries(liveTurns: [turn("three")])
        #expect(entries.count == 2)
        #expect(entries[0].contextIndex != entries[1].contextIndex)
    }
}
