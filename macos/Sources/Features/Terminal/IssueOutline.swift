import AppKit
import SwiftUI

// MARK: - Search

/// A very small TaskPaper-shaped query language.
///
/// A term is `@tag`, `@tag(value)`, `not @tag` / `-@tag`, or a bare word
/// matched against the id, title, note and tracker report. Terms are ANDed;
/// `and` may be written out, and `or` splits the query into alternatives —
/// `@waiting or @failed` is the one people reach for. That is the whole
/// grammar, deliberately: the point of showing every fact as a tag is that
/// clicking one writes the query for you, and a language you have to learn
/// defeats that.
enum IssueQuery {
    struct Term: Equatable {
        let text: String
        let tagName: String?
        let tagValue: String?
        let negated: Bool
    }

    /// Alternatives, each a set of terms that must all hold. An empty query
    /// has no groups and matches everything.
    struct Query: Equatable {
        let groups: [[Term]]
        var isEmpty: Bool { groups.isEmpty }
    }

    static func parse(_ source: String) -> Query {
        var groups: [[Term]] = []
        var terms: [Term] = []
        var negateNext = false

        for raw in tokenize(source) {
            var token = raw
            // `or` closes the current alternative and opens the next.
            if token.caseInsensitiveCompare("or") == .orderedSame {
                if !terms.isEmpty { groups.append(terms) }
                terms = []
                negateNext = false
                continue
            }
            // `and` is how TaskPaper writes the space between two terms; it
            // changes nothing, and refusing it would only be pedantry.
            if token.caseInsensitiveCompare("and") == .orderedSame { continue }
            // `not @done`, the way TaskPaper writes it, and `-@done` for
            // people who would rather not type a word.
            if token.caseInsensitiveCompare("not") == .orderedSame {
                negateNext = true
                continue
            }
            var negated = negateNext
            negateNext = false
            if token.hasPrefix("-"), token.count > 1 {
                negated = true
                token.removeFirst()
            }
            guard token.hasPrefix("@"), token.count > 1 else {
                terms.append(Term(text: token, tagName: nil, tagValue: nil, negated: negated))
                continue
            }
            var name = String(token.dropFirst())
            var value: String?
            if let open = name.firstIndex(of: "("), name.hasSuffix(")") {
                value = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
                name = String(name[..<open])
            }
            terms.append(Term(text: token, tagName: name, tagValue: value, negated: negated))
        }
        if !terms.isEmpty { groups.append(terms) }
        return Query(groups: groups)
    }

    /// Split on whitespace, but keep `@tag(a value)` in one piece.
    private static func tokenize(_ source: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for character in source {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character.isWhitespace, depth == 0 {
                if !current.isEmpty { tokens.append(current) }
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func matches(_ row: IssueRow, query: Query) -> Bool {
        guard !query.isEmpty else { return true }
        return query.groups.contains { matches(row, terms: $0) }
    }

    static func matches(_ row: IssueRow, terms: [Term]) -> Bool {
        for term in terms {
            let hit: Bool
            if let tagName = term.tagName {
                hit = row.hasTag(tagName, value: term.tagValue)
            } else {
                hit = row.matchesText(term.text)
            }
            if hit == term.negated { return false }
        }
        return true
    }
}

// MARK: - State

/// What the window remembers. Everything the three-pane version tracked —
/// which view, which filter, which scope, which rail was open — is gone: there
/// is one view, and the search bar is the filter.
@MainActor
final class IssueOutlineState: ObservableObject {
    enum FocusTarget: Hashable {
        case search
        case composer
    }

    /// A tracker heading and the issues under it: TaskPaper's project line
    /// and its children.
    struct Project: Identifiable, Equatable {
        let label: String
        let rows: [IssueRow]
        var id: String { label }
    }

    @Published var search = ""
    @Published var selection: String?
    @Published var collapsed: Set<String> = []
    /// Zoomed into one section, everything else hidden.
    ///
    /// TaskPaper's focus, and it earns its place here: seventy-nine issues
    /// across seven headings is more than a screen, and folding the other six
    /// leaves you scrolling past six fold lines to reach the one you want.
    /// Filtering is not the same thing — a filter hides items that do not
    /// match, focus hides everything that is not under one heading, including
    /// the headings themselves.
    @Published var focusedProject: String?
    @Published var focusTarget: FocusTarget?
    @Published var drafts: [String: String] = [:]

    /// The outline, and the same rows flattened in drawing order so the arrow
    /// keys and the list can never disagree about what comes next.
    @Published private(set) var projects: [Project] = []
    @Published private(set) var visible: [IssueRow] = []
    @Published private(set) var total = 0
    /// The tags actually present in this tracker, with how many carry each.
    ///
    /// Derived rather than hardcoded: a tracker that never uses `@unverified`
    /// should not offer a button for it, and one whose agents are all idle
    /// should not offer `@working`. Counted over every row, not the filtered
    /// set, so the bar does not shuffle and rewrite its own numbers as you
    /// click along it.
    @Published private(set) var availableTags: [TagCount] = []

    struct TagCount: Identifiable, Equatable {
        let tag: IssueRow.Tag
        let count: Int
        var id: String { tag.text }
    }

    func recompute(rows: [IssueRow]) {
        let query = IssueQuery.parse(search)
        var order: [String] = []
        var grouped: [String: [IssueRow]] = [:]
        for row in rows where IssueQuery.matches(row, query: query) {
            let label = IssueTrackerFormat.sectionLabel(row.issue.section)
            // Focus is applied here rather than to the drawn list, so the
            // count in the bar and the arrow keys agree with the screen.
            if let focusedProject, label != focusedProject { continue }
            if grouped[label] == nil { order.append(label) }
            grouped[label, default: []].append(row)
        }
        let projects = order.map { Project(label: $0, rows: grouped[$0] ?? []) }
        if projects != self.projects { self.projects = projects }

        // A focused section is never folded: it is the only thing on screen.
        let flat = projects.flatMap {
            focusedProject == nil && collapsed.contains($0.label) ? [] : $0.rows
        }
        if visible != flat { visible = flat }
        if total != rows.count { total = rows.count }
        recomputeTagCounts(rows: rows)
    }

    /// The filter bar's buttons. Agent watermarks are deliberately left out —
    /// they come and go with the panes, and a row of buttons that reshuffles
    /// itself every time an agent starts is not a row of buttons you can aim
    /// at. Those are still one click away on the line itself.
    private func recomputeTagCounts(rows: [IssueRow]) {
        var counts: [String: (IssueRow.Tag, Int)] = [:]
        var order: [String] = []
        for row in rows {
            for tag in row.tags where tag.role != .agent {
                // A valued tag is counted by name: `@artifacts(3)` and
                // `@artifacts(1)` are one button, "has artifacts".
                let key = tag.name
                if counts[key] == nil {
                    order.append(key)
                    counts[key] = (IssueRow.Tag(name: tag.name, value: nil, role: tag.role), 0)
                }
                counts[key]?.1 += 1
            }
        }
        let rank: [IssueRow.Tag.Role: Int] = [
            .status: 0, .agentState: 1, .next: 2, .warning: 3, .meta: 4, .agent: 5,
        ]
        let statusOrder = TrackedIssueStatus.allCases.map { $0.rawValue.lowercased() }
        let next = order.compactMap { counts[$0] }
            .sorted { lhs, rhs in
                let lr = rank[lhs.0.role] ?? 9, rr = rank[rhs.0.role] ?? 9
                if lr != rr { return lr < rr }
                // Statuses keep the tracker's own order rather than falling
                // into whatever order the file happens to list them.
                if lhs.0.role == .status,
                   let li = statusOrder.firstIndex(of: lhs.0.name),
                   let ri = statusOrder.firstIndex(of: rhs.0.name) {
                    return li < ri
                }
                return lhs.1 > rhs.1
            }
            .map { TagCount(tag: $0.0, count: $0.1) }
        if availableTags != next { availableTags = next }
    }

    /// Every heading in the tracker, focused or not — the fold-all keys and
    /// the focus menu both need the full set, not the visible one.
    func allProjectLabels(rows: [IssueRow]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for row in rows {
            let label = IssueTrackerFormat.sectionLabel(row.issue.section)
            if seen.insert(label).inserted { order.append(label) }
        }
        return order
    }

    func focus(on project: String?) {
        guard focusedProject != project else { return }
        focusedProject = project
        // Leaving a fold behind a focus you have left is a trap: you come
        // back to the full outline with a section mysteriously shut.
        if project != nil { collapsed.removeAll() }
    }

    /// ⌘9 and ⌘0, TaskPaper's fold keys. With two levels — heading, issue —
    /// there is nothing for its gradual (⇧⌘9/⇧⌘0) variants to do.
    func collapseAll(rows: [IssueRow]) {
        let all = Set(allProjectLabels(rows: rows))
        if collapsed != all { collapsed = all }
    }

    func expandAll() {
        if !collapsed.isEmpty { collapsed.removeAll() }
    }

    func select(_ id: String?) {
        if selection != id { selection = id }
    }

    func moveSelection(by offset: Int) {
        guard !visible.isEmpty else { return }
        guard let current = selection,
              let index = visible.firstIndex(where: { $0.id == current }) else {
            select(offset >= 0 ? visible.first?.id : visible.last?.id)
            return
        }
        select(visible[min(max(index + offset, 0), visible.count - 1)].id)
    }

    func toggle(_ project: String) {
        if collapsed.contains(project) { collapsed.remove(project) } else {
            collapsed.insert(project)
        }
    }

    /// Clicking a tag — on a line or in the filter bar — adds it to the
    /// search, and clicking it again takes it out.
    ///
    /// Toggling rather than replacing is what lets the buttons compose:
    /// `@open` then `@waiting` narrows to both, which is the thing you
    /// actually want from a row of filters. On an empty query it still reads
    /// as "show me this", which is what clicking a tag on a line means.
    func search(for tag: IssueRow.Tag) {
        let query = tag.value.map { "@\(tag.name)(\($0))" } ?? "@\(tag.name)"
        var tokens = search.split(separator: " ").map(String.init)
        if let index = tokens.firstIndex(where: {
            $0.caseInsensitiveCompare(query) == .orderedSame
        }) {
            tokens.remove(at: index)
        } else {
            tokens.append(query)
        }
        search = tokens.joined(separator: " ")
    }

    /// Whether a filter button is on.
    func isSearching(for tag: IssueRow.Tag) -> Bool {
        let query = "@\(tag.name)"
        return search.split(separator: " ").contains {
            $0.caseInsensitiveCompare(query) == .orderedSame
        }
    }

    func draft(_ id: String) -> String { drafts[id] ?? "" }

    func draftBinding(_ id: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.drafts[id] ?? "" },
                set: { [weak self] in self?.drafts[id] = $0 })
    }

    /// Escape pops one level at a time, innermost first.
    func popFocus() {
        if focusTarget != nil {
            focusTarget = nil
        } else if !search.isEmpty {
            search = ""
        } else if focusedProject != nil {
            focus(on: nil)
        } else if selection != nil {
            selection = nil
        }
    }
}

// MARK: - Lines

/// `SECTION 3 — OPEN:` — a project line, with its disclosure.
///
/// Click folds it; ⌥-click focuses it, which is TaskPaper's own gesture on a
/// project handle. SwiftUI's tap gestures do not carry modifiers, so the flags
/// are read at the moment of the click — the pattern the grid already uses for
/// ⌘-click peek.
struct ProjectLine: View {
    let project: IssueOutlineState.Project
    let collapsed: Bool
    let toggle: () -> Void
    let focus: () -> Void

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) { focus() } else { toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9)
                Text(project.label)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(":")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("\(project.rows.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 0)
            }
            .padding(.top, 9)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to fold · ⌥-click to focus on this section")
        .contextMenu {
            Button("Focus on \(project.label)") { focus() }
            Button(collapsed ? "Expand" : "Collapse") { toggle() }
        }
    }
}

/// One `@tag`. Clicking it searches for it.
struct TagView: View {
    let tag: IssueRow.Tag
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tag.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Search for \(tag.text)")
    }

    private var color: Color { Self.color(for: tag) }

    static func color(for tag: IssueRow.Tag) -> Color {
        switch tag.role {
        case .status:
            return IssueTrackerFormat.statusColor(
                TrackedIssueStatus(rawValue: tag.name.uppercased()) ?? .open)
        case .agent:
            return .secondary
        case .agentState:
            return IssueTrackerFormat.agentStateColor(tag.name)
        case .next:
            return .accentColor
        case .meta:
            return Color.secondary.opacity(0.75)
        case .warning:
            return .orange
        }
    }
}

/// `- O-17  Wait for the candidate to finish their THOUGHT  @open @trm-4`
///
/// The task line, its note, and — only when it is the selected line — the
/// agent detail and the one composer. Equatable on the row, so a streaming
/// message repaints one line rather than the document.
struct TaskLine: View, Equatable {
    @ObservedObject var model: IssueTrackerModel
    @ObservedObject var state: IssueOutlineState
    let row: IssueRow
    let selected: Bool
    @FocusState.Binding var focus: IssueOutlineState.FocusTarget?

    static func == (lhs: TaskLine, rhs: TaskLine) -> Bool {
        lhs.row == rhs.row && lhs.selected == rhs.selected
    }

    /// Deployed is TaskPaper's `@done`: struck through and stepped back, so
    /// the eye skips it without the row having to be hidden.
    private var isDone: Bool { row.issue.status == .deployed }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("-")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.quaternary)
                Text(row.issue.id)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isDone ? Color.secondary : Color.secondary)
                Text(row.issue.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isDone ? Color.secondary : Color.primary)
                    .strikethrough(isDone, color: .secondary)
                    .lineLimit(selected ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: selected)
                tags
                Spacer(minLength: 0)
                if let stamp = row.issue.mostRecentChange {
                    Text(IssueTrackerFormat.relativeTime(stamp))
                        .font(.system(size: 10))
                        // Tertiary, not quaternary: quaternary is 10% white,
                        // which on this background is not a faint timestamp,
                        // it is an absent one.
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            // The note: TaskPaper's third line type, and where the agent's
            // own sentence goes.
            Text(row.latestUpdate)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(selected ? nil : 1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: selected)
                .padding(.leading, 18)

            if selected {
                IssueDetail(model: model, state: state, row: row, focus: $focus)
                    .padding(.leading, 18)
                    .padding(.top, 4)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var tags: some View {
        HStack(spacing: 6) {
            ForEach(row.tags, id: \.self) { tag in
                TagView(tag: tag) { state.search(for: tag) }
            }
        }
        .fixedSize()
    }
}

/// The filter bar: one button per tag the tracker actually uses.
///
/// It is the same gesture as clicking a tag on a line, gathered into one place
/// so the common narrowings — everything open, everything waiting on you — are
/// one click rather than a remembered query.
struct TagFilterBar: View {
    @ObservedObject var state: IssueOutlineState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(state.availableTags) { entry in
                    let on = state.isSearching(for: entry.tag)
                    Button {
                        state.search(for: entry.tag)
                    } label: {
                        HStack(spacing: 4) {
                            Text(entry.tag.text)
                                .font(.system(size: 10.5, design: .monospaced))
                            Text("\(entry.count)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(on ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.6))
                        }
                        .foregroundStyle(on ? Color.primary : TagView.color(for: entry.tag))
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(on
                                      ? TagView.color(for: entry.tag).opacity(0.28)
                                      : Color.primary.opacity(0.045)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(
                                    on ? TagView.color(for: entry.tag).opacity(0.7) : .clear,
                                    lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Stop filtering by \(entry.tag.text)"
                             : "Filter by \(entry.tag.text)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
        .frame(height: 25)
    }
}

// MARK: - Empty and error lines

/// Nothing matched. Says what was searched, and offers the one gesture back.
struct OutlineEmptyState: View {
    @ObservedObject var state: IssueOutlineState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(state.search.isEmpty
                 ? "This tracker has no issues yet."
                 : "Nothing matches \(state.search)")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            if !state.search.isEmpty {
                Button("Clear the search") { state.search = "" }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 22)
    }
}

/// The tracker could not be read. The real error, verbatim and selectable,
/// and the thing that matters most: nothing was written.
struct OutlineErrorState: View {
    @ObservedObject var model: IssueTrackerModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.project.remoteHost.map { "Can’t reach \($0)." }
                 ?? "Couldn’t read this tracker.")
                .font(.system(size: 12.5, weight: .medium))
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing has been written. trm only ever appends to issues/artifacts/.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack(spacing: 7) {
                Button("Try again") { model.refresh() }
                Button("Copy error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// The first read. Skeleton lines at the real rhythm, because an empty
/// outline and an unread one are different answers.
struct OutlineLoadingState: View {
    @ObservedObject var model: IssueTrackerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(0..<8, id: \.self) { index in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(max(0.02, 0.09 - Double(index) * 0.010)))
                        .frame(width: 40, height: 8)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(max(0.02, 0.07 - Double(index) * 0.008)))
                        .frame(width: 180 + CGFloat((index * 53) % 150), height: 8)
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading \(model.project.indexFileName)…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(16)
    }
}
