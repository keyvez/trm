import Foundation
import Testing
@testable import trm

/// Exercised against the real fasmac tracker rather than a three-issue
/// fixture. The behaviour that matters only shows up at its size and with its
/// mess: dozens of records, several with no index row, section headings that
/// have to reduce to something a line can carry, and issues whose reports cite
/// each other. None of that appears in mock data.
struct IssueOutlineTests {
    private static let fasmacRoot = "/Users/g/dev/fasmac"

    private static var fasmac: IssueTrackerProject? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: fasmacRoot + "/ISSUES.md", isDirectory: &isDirectory),
            !isDirectory.boolValue else { return nil }
        return IssueTrackerProject(
            rootPath: fasmacRoot, indexFileName: "ISSUES.md", remoteHost: nil)
    }

    @Test func readsTheRealFasmacTracker() throws {
        guard let project = Self.fasmac else { return }
        let snapshot = try IssueTrackerStore.snapshot(project)

        // Every record on disk is accounted for, indexed or not.
        let recordCount = try FileManager.default
            .contentsOfDirectory(atPath: project.rootPath + "/issues")
            .filter { $0.hasSuffix(".md") }
            .filter { $0.dropLast(3).range(of: #"^[A-Za-z]+-[0-9]+$"#,
                                           options: .regularExpression) != nil }
            .count
        #expect(snapshot.issues.count >= recordCount)
        #expect(snapshot.issues.count >= 65)

        // Ids are unique: the fallback pass must not duplicate an indexed row.
        #expect(Set(snapshot.issues.map(\.id)).count == snapshot.issues.count)

        // Every issue has something to put in a row. A blank title or a blank
        // update line is a hole in the list, and fasmac has rows whose record
        // exists but whose report does not.
        for issue in snapshot.issues {
            #expect(!issue.title.isEmpty, "\(issue.id) has no title")
        }

        // The four statuses the index actually uses are all present.
        let statuses = Set(snapshot.issues.map(\.status))
        #expect(statuses.contains(.open))
        #expect(statuses.contains(.staged))
        #expect(statuses.contains(.deployed))
    }

    @Test func surfacesRecordsWithNoIndexRow() throws {
        guard let project = Self.fasmac else { return }
        let snapshot = try IssueTrackerStore.snapshot(project)
        let orphans = snapshot.issues.filter { $0.section == "Not present in the index" }
        // fasmac has records whose index line says FIXED / IN PROGRESS /
        // DONE — words the index's own status vocabulary does not contain, so
        // the row does not parse and only the record survives. Losing those
        // silently is the failure this group exists to prevent.
        #expect(!orphans.isEmpty)
        for orphan in orphans {
            #expect(!orphan.detail.isEmpty)
            #expect(orphan.title != orphan.id, "\(orphan.id) fell back to its own id for a title")
        }
    }

    @Test func groupsEveryRealIssueIntoExactlyOneSection() throws {
        guard let project = Self.fasmac else { return }
        let snapshot = try IssueTrackerStore.snapshot(project)
        var counts: [String: Int] = [:]
        for issue in snapshot.issues {
            counts[IssueTrackerFormat.sectionLabel(issue.section), default: 0] += 1
        }
        #expect(counts.values.reduce(0, +) == snapshot.issues.count)
        // Section labels are what the navigator shows. A label that is still
        // the raw heading ("SECTION 1 — ENGINE (talking-agent-rs).  DEPLOYED
        // 2026-08-27 22:09 UTC") overflows the sidebar and tells you nothing.
        for label in counts.keys {
            #expect(!label.hasPrefix("SECTION "), "unreduced section label: \(label)")
            #expect(label.count <= 60, "section label too long for the sidebar: \(label)")
        }
    }

    @Test func rowUpdateLineLeadsWithTheRecordWhenNoAgentIsOnIt() throws {
        guard let project = Self.fasmac else { return }
        let snapshot = try IssueTrackerStore.snapshot(project)
        for issue in snapshot.issues {
            let row = IssueRow(issue: issue, agents: [])
            #expect(row.updateKind == .record)
            let update = row.latestUpdate
            #expect(!update.isEmpty, "\(issue.id) has no update line")
            // A row is one line. The summary must already be short enough that
            // truncation is cosmetic rather than the only thing keeping the
            // list from reflowing.
            #expect(update.count <= 300, "\(issue.id) update line is \(update.count) chars")
            #expect(!update.contains("\n"), "\(issue.id) update line wraps")
        }
    }

    // MARK: Agent state

    private static func entry(
        watermark: String,
        kind: AgentKind?,
        message: String,
        activity: [String] = [],
        isWorking: Bool = false,
        needsAttention: Bool = false,
        errorCount: Int = 0,
        errorText: String? = nil
    ) -> CommandCenterMonitor.Entry {
        CommandCenterMonitor.Entry(
            id: ObjectIdentifier(NSObject()),
            paneId: 1,
            watermark: watermark,
            kind: kind,
            location: nil,
            host: nil,
            message: message,
            prompt: nil,
            promptHistory: [],
            activity: activity,
            links: [],
            isWorking: isWorking,
            needsAttention: needsAttention,
            errorCount: errorCount,
            errorText: errorText,
            updatedAt: nil,
            surface: nil)
    }

    @Test func agentStatesAreDistinguishedInTheOrderThatMatters() {
        // A question outranks everything else: it is the only state where the
        // agent has stopped and is waiting on this window.
        let asking = IssueAgentSummary(Self.entry(
            watermark: "trm-4", kind: .claude, message: "CPU or GPU?",
            isWorking: true, needsAttention: true, errorCount: 3,
            errorText: "python st.py --gpu → exit 1"))
        #expect(asking.state == .waiting)
        #expect(asking.headline == "CPU or GPU?")

        // Errors during a turn the agent is still driving are not "failed" —
        // an agent recovering from a bad tool call is still working.
        let recovering = IssueAgentSummary(Self.entry(
            watermark: "trm-5", kind: .codex, message: "Retrying with --force.",
            isWorking: true, errorCount: 2, errorText: "exit 1"))
        #expect(recovering.state == .working)

        // Stopped with errors is a failure, and the error is the headline.
        let failed = IssueAgentSummary(Self.entry(
            watermark: "trm-5", kind: .codex, message: "Working…",
            errorCount: 1, errorText: "git filter-repo exited 1"))
        #expect(failed.state == .failed)
        #expect(failed.headline == "git filter-repo exited 1")

        let done = IssueAgentSummary(Self.entry(
            watermark: "trm-1", kind: .claude, message: "Deployed and verified."))
        #expect(done.state == .finished)

        // An agent whose kind could not be established is labelled honestly
        // rather than guessed at.
        let unknown = IssueAgentSummary(Self.entry(
            watermark: "pane 7", kind: nil, message: "Working…", isWorking: true))
        #expect(unknown.kindLabel == "Agent")
        #expect(!unknown.kindIsKnown)
    }

    @Test func theRowLeadsWithTheDeveloperUpdateNotTheCommandLine() {
        let agent = IssueAgentSummary(Self.entry(
            watermark: "trm-1", kind: .claude,
            message: "Smart-turn v3.2 is wired in and the CPU path passes.\n\nStill checking the GPU session.",
            activity: ["Bash cargo test", "Edit src/turn/smart_turn.rs"],
            isWorking: true))
        // One line, the first paragraph, no tool call.
        #expect(agent.headline == "Smart-turn v3.2 is wired in and the CPU path passes.")
        #expect(!agent.headline.contains("cargo"))
        #expect(!agent.headline.contains("\n"))
        // The tool calls are still available — in the inspector, not the row.
        #expect(agent.activity.count == 2)
    }

    // MARK: The next issue

    @Test func nextMarkerParsesWhatAHumanWouldWriteInIt() {
        #expect(IssueNextMarker.parse("O-17") == "O-17")
        #expect(IssueNextMarker.parse("  o-17  \n") == "O-17")
        // Comments and blank lines are skipped; the first real id wins.
        #expect(IssueNextMarker.parse("# trm\n\n# O-99\nF-01\nO-08") == "F-01")
        #expect(IssueNextMarker.parse("") == nil)
        #expect(IssueNextMarker.parse("# nothing but a comment\n") == nil)
        #expect(IssueNextMarker.parse("not an id\n") == nil)
        // What trm writes is what trm reads back.
        #expect(IssueNextMarker.parse(IssueNextMarker.render("o-17")) == "O-17")
    }

    @Test func nextMarkerRoundTripsThroughARealTrackerFolder() throws {
        // A copy of the real tracker, so the write path is exercised against
        // the layout it actually ships against rather than an empty temp dir.
        guard let source = Self.fasmac else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trm-next-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: source.rootPath + "/ISSUES.md"),
            to: root.appendingPathComponent("ISSUES.md"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: source.rootPath + "/issues"),
            to: root.appendingPathComponent("issues"))
        let project = IssueTrackerProject(
            rootPath: root.path, indexFileName: "ISSUES.md", remoteHost: nil)

        // Nothing marked to begin with.
        #expect(try IssueTrackerStore.snapshot(project).nextIssueID == nil)

        try IssueTrackerStore.writeNext(project, issueID: "O-17")
        let marked = try IssueTrackerStore.snapshot(project)
        #expect(marked.nextIssueID == "O-17")
        #expect(marked.issues.count >= 65)

        // It lands where the tracker's contract says trm may write, and
        // nowhere else — ISSUES.md is untouched.
        let markerPath = root.appendingPathComponent(IssueNextMarker.relativePath)
        #expect(FileManager.default.fileExists(atPath: markerPath.path))
        #expect(IssueNextMarker.relativePath.hasPrefix("issues/artifacts/"))
        #expect(
            try String(contentsOf: root.appendingPathComponent("ISSUES.md"), encoding: .utf8)
                == (try String(
                    contentsOf: URL(fileURLWithPath: source.rootPath + "/ISSUES.md"),
                    encoding: .utf8)))

        // Marking a different issue moves the mark rather than adding to it.
        try IssueTrackerStore.writeNext(project, issueID: "F-01")
        #expect(try IssueTrackerStore.snapshot(project).nextIssueID == "F-01")
        let text = try String(contentsOf: markerPath, encoding: .utf8)
        #expect(!text.contains("O-17"))

        // Clearing removes the file rather than leaving an empty one.
        try IssueTrackerStore.writeNext(project, issueID: nil)
        #expect(!FileManager.default.fileExists(atPath: markerPath.path))
        #expect(try IssueTrackerStore.snapshot(project).nextIssueID == nil)

        // A malformed id never reaches the filesystem.
        #expect(throws: (any Error).self) {
            try IssueTrackerStore.writeNext(project, issueID: "../../etc/passwd")
        }
        #expect(!FileManager.default.fileExists(atPath: markerPath.path))
    }

    @MainActor
    @Test func handOffOnlyTargetsAnAgentThatHasActuallyStopped() {
        // The four states an agent can be in, against the one rule that
        // matters: work is handed only to one that has stopped and is on
        // nothing. Mid-turn interleaves; blocked buries the question.
        for (state, eligible) in [
            (IssueAgentSummary.State.finished, true),
            (.working, false),
            (.waiting, false),
            (.failed, false),
        ] as [(IssueAgentSummary.State, Bool)] {
            let agent: IssueAgentSummary
            switch state {
            case .finished:
                agent = IssueAgentSummary(Self.entry(
                    watermark: "trm-1", kind: .claude, message: "Done."))
            case .working:
                agent = IssueAgentSummary(Self.entry(
                    watermark: "trm-1", kind: .claude, message: "…", isWorking: true))
            case .waiting:
                agent = IssueAgentSummary(Self.entry(
                    watermark: "trm-1", kind: .claude, message: "?", needsAttention: true))
            case .failed:
                agent = IssueAgentSummary(Self.entry(
                    watermark: "trm-1", kind: .codex, message: "…",
                    errorCount: 1, errorText: "exit 1"))
            }
            #expect((agent.state == .finished) == eligible)
        }
    }

    // MARK: The outline

    @MainActor
    @Test func theOutlineIsTheTrackerGroupedByItsOwnHeadings() throws {
        guard let project = Self.fasmac else { return }
        let rows = try IssueTrackerStore.snapshot(project).issues
            .map { IssueRow(issue: $0, agents: []) }
        let state = IssueOutlineState()
        state.recompute(rows: rows)

        // Every issue is under exactly one project line, in tracker order.
        #expect(state.projects.reduce(0) { $0 + $1.rows.count } == rows.count)
        #expect(state.visible.map(\.id) == rows.map(\.id))
        for project in state.projects {
            #expect(!project.label.hasPrefix("SECTION "))
            #expect(project.label.count <= 60)
            for row in project.rows {
                #expect(IssueTrackerFormat.sectionLabel(row.issue.section) == project.label)
            }
        }

        // Collapsing a project takes its rows out of the arrow-key order but
        // leaves the project itself on screen.
        let first = try #require(state.projects.first)
        state.toggle(first.label)
        state.recompute(rows: rows)
        #expect(state.projects.count > 0)
        #expect(state.visible.count == rows.count - first.rows.count)
        #expect(!state.visible.contains { $0.id == first.rows[0].id })
    }

    @Test func everyFactOnALineIsAlsoATagYouCanSearchFor() throws {
        guard let project = Self.fasmac else { return }
        let issues = try IssueTrackerStore.snapshot(project).issues

        // Status is always a tag, and it is the status the row shows.
        for issue in issues {
            let row = IssueRow(issue: issue, agents: [])
            #expect(row.hasTag(issue.status.rawValue.lowercased(), value: nil))
            #expect(row.tags.contains { $0.role == .status })
        }

        // An agent contributes its watermark and its state.
        let waiting = IssueAgentSummary(Self.entry(
            watermark: "trm-4", kind: .claude, message: "CPU or GPU?", needsAttention: true))
        let row = IssueRow(issue: issues[0], agents: [waiting], isNext: true)
        #expect(row.hasTag("waiting", value: nil))
        #expect(row.hasTag("trm-4", value: nil))
        #expect(row.hasTag("next", value: nil))
        #expect(!row.hasTag("working", value: nil))
        // Tags render the way they are typed into the search bar.
        #expect(row.tags.map(\.text).contains("@waiting"))
        #expect(row.tags.map(\.text).contains("@next"))

        // A watermark that is not a bare word still makes a legal tag.
        let awkward = IssueAgentSummary(Self.entry(
            watermark: "fasmac ⑂ genui/a2ui", kind: .codex, message: "…"))
        #expect(!awkward.tagName.contains(" "))
        #expect(!awkward.tagName.contains("⑂"))
        #expect(!awkward.tagName.isEmpty)

        // Artifact counts are a valued tag.
        if let withArtifacts = issues.first(where: { !$0.artifacts.isEmpty }) {
            let row = IssueRow(issue: withArtifacts, agents: [])
            #expect(row.hasTag("artifacts", value: nil))
            #expect(row.hasTag("artifacts", value: "\(withArtifacts.artifacts.count)"))
        }
    }

    @Test func searchIsTaskPaperShaped() throws {
        guard let project = Self.fasmac else { return }
        let issues = try IssueTrackerStore.snapshot(project).issues
        let working = IssueAgentSummary(Self.entry(
            watermark: "trm-1", kind: .claude, message: "Writing the migration.",
            isWorking: true))
        var rows = issues.map { IssueRow(issue: $0, agents: []) }
        rows[0] = IssueRow(issue: issues[0], agents: [working])

        func match(_ query: String) -> [String] {
            let parsed = IssueQuery.parse(query)
            return rows.filter { IssueQuery.matches($0, query: parsed) }.map(\.id)
        }

        // A tag term.
        #expect(match("@working") == [issues[0].id])
        // Negation, both spellings TaskPaper accepts.
        #expect(!match("not @working").contains(issues[0].id))
        #expect(match("-@working") == match("not @working"))
        // Terms are ANDed.
        #expect(match("@working @deployed").isEmpty
                || match("@working @deployed") == [issues[0].id])
        // A valued tag matches on its value.
        if let withArtifacts = rows.first(where: { !$0.issue.artifacts.isEmpty }) {
            let count = withArtifacts.issue.artifacts.count
            #expect(match("@artifacts(\(count))").contains(withArtifacts.id))
        }
        // Free text still matches the things the line shows.
        #expect(match(issues[0].id).contains(issues[0].id))
        // An empty query is not a filter.
        #expect(match("").count == rows.count)
        // TaskPaper writes the space between two terms as `and`; it changes
        // nothing, and refusing it would only be pedantry.
        #expect(match("@open and @working") == match("@open @working"))
        // `or` opens an alternative rather than narrowing.
        let either = Set(match("@working or @deployed"))
        #expect(either == Set(match("@working")).union(match("@deployed")))
        #expect(either.count >= match("@working").count)
        // Negation binds to the term it precedes, not to the whole query.
        #expect(Set(match("@open not @working"))
                == Set(match("@open")).subtracting(match("@working")))
        // Every status is reachable as a tag, and the tag agrees with the row.
        for status in TrackedIssueStatus.allCases {
            let hits = Set(match("@\(status.rawValue.lowercased())"))
            let expected = Set(rows.filter { $0.issue.status == status }.map(\.id))
            #expect(hits == expected)
        }
    }

    @MainActor
    @Test func clickingATagSearchesForItAndClickingAgainClearsIt() {
        let state = IssueOutlineState()
        let tag = IssueRow.Tag(name: "waiting", value: nil, role: .agentState)
        state.search(for: tag)
        #expect(state.search == "@waiting")
        state.search(for: tag)
        #expect(state.search.isEmpty)

        let valued = IssueRow.Tag(name: "artifacts", value: "3", role: .meta)
        state.search(for: valued)
        #expect(state.search == "@artifacts(3)")
    }

    @MainActor
    @Test func focusingHidesEverySectionButOne() throws {
        guard let project = Self.fasmac else { return }
        let rows = try IssueTrackerStore.snapshot(project).issues
            .map { IssueRow(issue: $0, agents: []) }
        let state = IssueOutlineState()
        state.recompute(rows: rows)

        let labels = state.allProjectLabels(rows: rows)
        #expect(labels.count > 1)
        let target = try #require(labels.first { label in
            state.projects.first { $0.label == label }.map { $0.rows.count > 1 } ?? false
        })
        let expected = state.projects.first { $0.label == target }?.rows.count ?? 0

        state.focus(on: target)
        state.recompute(rows: rows)
        #expect(state.projects.map(\.label) == [target])
        #expect(state.visible.count == expected)
        #expect(state.visible.allSatisfy {
            IssueTrackerFormat.sectionLabel($0.issue.section) == target
        })

        // Focus and search compose: the filter still applies inside it.
        state.search = "@deployed"
        state.recompute(rows: rows)
        #expect(state.visible.allSatisfy { $0.issue.status == .deployed })
        #expect(state.visible.allSatisfy {
            IssueTrackerFormat.sectionLabel($0.issue.section) == target
        })

        state.search = ""
        state.focus(on: nil)
        state.recompute(rows: rows)
        #expect(state.projects.map(\.label) == labels)
        #expect(state.visible.count == rows.count)
    }

    @MainActor
    @Test func foldingAndFocusDoNotLeaveEachOtherInABadState() throws {
        guard let project = Self.fasmac else { return }
        let rows = try IssueTrackerStore.snapshot(project).issues
            .map { IssueRow(issue: $0, agents: []) }
        let state = IssueOutlineState()
        state.recompute(rows: rows)
        let labels = state.allProjectLabels(rows: rows)

        // ⌘9 / ⌘0.
        state.collapseAll(rows: rows)
        state.recompute(rows: rows)
        #expect(state.collapsed == Set(labels))
        #expect(state.visible.isEmpty)
        #expect(state.projects.count == labels.count)   // headings stay

        state.expandAll()
        state.recompute(rows: rows)
        #expect(state.visible.count == rows.count)

        // Focusing clears folds, so leaving focus cannot drop you back into a
        // full outline with a section mysteriously shut.
        state.toggle(labels[0])
        state.focus(on: labels[1])
        #expect(state.collapsed.isEmpty)
        state.recompute(rows: rows)
        #expect(!state.visible.isEmpty)

        state.focus(on: nil)
        state.recompute(rows: rows)
        #expect(state.visible.count == rows.count)
    }

    @MainActor
    @Test func escapeLeavesFocusBeforeItClearsTheSelection() {
        let state = IssueOutlineState()
        state.selection = "O-17"
        state.focusedProject = "OPEN"
        state.search = "@waiting"
        state.focusTarget = .composer

        state.popFocus()
        #expect(state.focusTarget == nil)
        state.popFocus()
        #expect(state.search.isEmpty)
        #expect(state.focusedProject == "OPEN")
        state.popFocus()
        #expect(state.focusedProject == nil)
        #expect(state.selection == "O-17")
        state.popFocus()
        #expect(state.selection == nil)
    }

    @MainActor
    @Test func arrowKeysWalkTheOutlineAndEscapePopsOneLevel() throws {
        guard let project = Self.fasmac else { return }
        let rows = try IssueTrackerStore.snapshot(project).issues
            .map { IssueRow(issue: $0, agents: []) }
        let state = IssueOutlineState()
        state.recompute(rows: rows)

        state.moveSelection(by: 1)
        #expect(state.selection == state.visible.first?.id)
        state.moveSelection(by: 1)
        #expect(state.selection == state.visible[1].id)
        // A wall, not a wrap.
        state.moveSelection(by: -1)
        state.moveSelection(by: -1)
        #expect(state.selection == state.visible.first?.id)
        state.select(state.visible.last?.id)
        state.moveSelection(by: 1)
        #expect(state.selection == state.visible.last?.id)

        state.focusTarget = .composer
        state.search = "@open"
        state.popFocus()
        #expect(state.focusTarget == nil)
        #expect(state.search == "@open")
        state.popFocus()
        #expect(state.search.isEmpty)
        #expect(state.selection != nil)
        state.popFocus()
        #expect(state.selection == nil)
    }
}
