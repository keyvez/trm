import Foundation

/// The contexts a pane has been through, and the turns kept from each.
///
/// Clearing an agent's context starts its transcript over — Claude Code opens
/// a fresh session file, Codex a fresh rollout — and the overview used to
/// start over with it: the turn being read vanished, and so did the way back
/// to any of it. The agent is the one that forgot. What was said is still what
/// was said, so the turns stay pageable and a divider marks the seam.
///
/// This is a value type, apart from the pane, because the fiddly part is not
/// the reading: it is what survives a clear, where the dividers fall, and what
/// "latest" means in a context that has nothing in it yet.
struct AgentTurnHistory: Equatable {
    /// One turn as the overview pages it: the turn, and which context it was
    /// said in.
    ///
    /// Context numbers are handed out in order and never reused, so two
    /// different contexts can never compare equal and hide the divider between
    /// them. The turn itself is untouched.
    struct Entry: Identifiable, Equatable {
        var turn: AgentTranscript.Turn
        var contextIndex: Int
        /// The stand-in for a context with nothing in it yet — the moment
        /// after a clear, where "latest" still has to point somewhere.
        var isPlaceholder: Bool = false

        var id: String { "\(contextIndex):\(isPlaceholder ? "-live-" : turn.id)" }
    }

    /// A pane left running all day through a dozen clears must not grow
    /// without bound. This is paging back through recent work, not an archive.
    static let maxArchivedTurns = 300

    /// Turns from contexts that have ended, oldest first.
    private(set) var archived: [Entry] = []

    /// The context the live transcript belongs to.
    private(set) var contextIndex: Int = 0

    /// When each context after the first began — which is the moment the one
    /// before it was cleared. Keyed by context index.
    private(set) var breakDates: [Int: Date] = [:]

    private var nextContextIndex: Int = 1

    /// Which transcript file the live context is read from, and which file
    /// each archived context came from. Together they let a pane that returns
    /// to a file it left pick its old context back up rather than filing the
    /// same turns a second time.
    private var sourceKey: String? = nil
    private var archivedKeys: [Int: String] = [:]

    /// True once this pane has been through at least one clear.
    var hasClearedContexts: Bool { contextIndex > 0 }

    /// Everything pageable, oldest first: the kept contexts, then the live one.
    func entries(liveTurns: [AgentTranscript.Turn]) -> [Entry] {
        var all = archived
        guard !liveTurns.isEmpty else {
            // A cleared agent has said nothing yet, but "latest" must still
            // land somewhere — otherwise the newest slot is the last turn of
            // the context that was just cleared, and every offset below it is
            // out by one.
            if !all.isEmpty {
                all.append(Entry(turn: .init(), contextIndex: contextIndex, isPlaceholder: true))
            }
            return all
        }
        all.append(contentsOf: liveTurns.map { Entry(turn: $0, contextIndex: contextIndex) })
        return all
    }

    /// The pane is now reading a different transcript: the agent's context was
    /// cleared, a new session took the pane, the agent exited (`sourceKey` nil),
    /// or the locator settled on another file for the same agent.
    ///
    /// Call this while `liveTurns` still holds the context that is ending.
    mutating func beginContext(
        sourceKey newKey: String?,
        liveTurns: [AgentTranscript.Turn],
        now: Date = Date()
    ) {
        guard sourceKey != newKey else { return }

        // Back to a file already archived — a locator that flapped, or a
        // session resumed. Adopt that context again instead of keeping a
        // second copy of its turns; the live parse puts them back.
        if let newKey, let previous = archivedKeys.first(where: { $0.value == newKey })?.key {
            archived.removeAll { $0.contextIndex == previous }
            archivedKeys[previous] = nil
            breakDates[contextIndex] = nil
            contextIndex = previous
            sourceKey = newKey
            return
        }

        // The first transcript a pane binds to divides nothing.
        guard sourceKey != nil || !archived.isEmpty else {
            sourceKey = newKey
            return
        }

        if !liveTurns.isEmpty, let current = sourceKey {
            archivedKeys[contextIndex] = current
        }
        archive(liveTurns: liveTurns, now: now)
        sourceKey = newKey
    }

    /// Drop everything kept. For when the pane itself changes — a rebind, or a
    /// pane that turns out to be a shell — where the earlier turns belong to
    /// something else altogether.
    mutating func reset() {
        self = .init()
    }

    /// Keep what the agent said, and open a new context after it. A context
    /// with nothing in it is not worth a divider, so an empty one is passed
    /// over rather than numbered.
    private mutating func archive(liveTurns: [AgentTranscript.Turn], now: Date) {
        guard !liveTurns.isEmpty else { return }
        archived.append(contentsOf: liveTurns.map {
            Entry(turn: $0, contextIndex: contextIndex)
        })
        if archived.count > Self.maxArchivedTurns {
            archived.removeFirst(archived.count - Self.maxArchivedTurns)
        }
        contextIndex = nextContextIndex
        nextContextIndex += 1
        breakDates[contextIndex] = now
    }
}
