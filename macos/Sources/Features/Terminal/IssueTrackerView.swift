import AppKit
import SwiftUI

/// The pane-chrome affordance. Discovery is deliberately data-driven: any
/// project with an issues.md/ISSUES.md and an issues directory gets it, with
/// no repository names or paths baked into trm.
struct IssueTrackerPaneButton: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let onOpen: (Ghostty.SurfaceView, IssueTrackerProject) -> Void

    @State private var project: IssueTrackerProject?
    @State private var lastDiagnostic: String?

    var body: some View {
        // Keep a concrete view in the hierarchy while discovery is pending.
        // An `if` inside a Group becomes EmptyView when project is nil, and
        // SwiftUI can elide that node before its `.task` ever runs — leaving
        // the very task that would make the button visible with no lifecycle.
        ZStack {
            Color.clear
            if let project {
                Button {
                    onOpen(surface, project)
                } label: {
                    Image(systemName: "checklist")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Open \(project.name) issue tracker")
                .accessibilityLabel("Open project issue tracker")
            }
        }
        .frame(width: project == nil ? 0 : 18, height: 18)
        .task(id: "\(surface.remoteHost ?? "local")|\(surface.remoteZmxSession ?? "")|\(surface.pwd ?? "")") {
            repeat {
                let host = surface.remoteHost
                let session = surface.remoteZmxSession
                let cwd = AgentOverviewPane.workingDirectory(for: surface)
                let discovered = await IssueTrackerDiscoveryCache.shared.project(
                    cwd: cwd, remoteHost: host, remoteSession: session)
                project = discovered

                let diagnostic = [
                    "pane=\(surface.paneId.map(String.init) ?? "?")",
                    "host=\(host ?? "local")",
                    "session=\(session ?? "none")",
                    "pwd=\(cwd ?? "missing")",
                    "project=\(discovered?.rootPath ?? "none")",
                ].joined(separator: " ")
                if diagnostic != lastDiagnostic {
                    TrmDiagnostics.log("[issue-tracker] \(diagnostic)")
                    lastDiagnostic = diagnostic
                }

                // Local shell integration invalidates this task when pwd
                // changes. A restored remote pane has no such event, so retry
                // periodically in case the session changes directory or its
                // host was asleep during the first probe.
                guard host != nil else { break }
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    break
                }
            } while !Task.isCancelled
        }
    }
}

@MainActor
final class IssueTrackerWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [String: IssueTrackerWindowController] = [:]

    let model: IssueTrackerModel

    static func show(project: IssueTrackerProject, from surface: Ghostty.SurfaceView) {
        TrmDiagnostics.log(
            "[issue-tracker] opening window for \(project.locationLabel) from pane "
                + "\(surface.paneId.map(String.init) ?? "?")")
        let controller: IssueTrackerWindowController
        if let existing = controllers[project.id] {
            controller = existing
            existing.model.updateSource(surface)
        } else {
            controller = IssueTrackerWindowController(project: project, sourceSurface: surface)
            controllers[project.id] = controller
        }
        controller.present(on: surface.window?.screen ?? NSScreen.main)
    }

    private init(project: IssueTrackerProject, sourceSurface: Ghostty.SurfaceView) {
        model = IssueTrackerModel(project: project, sourceSurface: sourceSurface)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "\(project.name) Issues"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 780, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: IssueTrackerView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func present(on screen: NSScreen?) {
        showWindow(nil)
        if let frame = screen?.visibleFrame {
            // "Full screen" here means the whole useful screen immediately,
            // without forcing the user into a separate macOS Space.
            window?.setFrame(frame, display: true, animate: false)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        TrmDiagnostics.log("[issue-tracker] closing window for \(model.project.locationLabel)")
        model.stop()
    }
}

private enum IssueTrackerRoute: Hashable {
    case board
    case issue(String)
}

private enum IssueTrackerFilter: String, CaseIterable, Identifiable {
    case active = "Active"
    case all = "All"
    case open = "Open"
    case staged = "Staged"
    case complete = "Deployed"

    var id: String { rawValue }

    func includes(_ issue: TrackedIssue) -> Bool {
        switch self {
        case .all: return true
        case .active: return issue.status != .deployed
        case .open: return issue.status == .open || issue.status == .unverified
        case .staged: return issue.status == .staged
        case .complete: return issue.status == .deployed
        }
    }
}

struct IssueTrackerView: View {
    @ObservedObject var model: IssueTrackerModel
    @ObservedObject private var monitor = CommandCenterMonitor.shared

    @State private var route: IssueTrackerRoute? = .board
    @State private var filter: IssueTrackerFilter = .active
    @State private var search = ""
    @State private var drafts: [String: String] = [:]

    private var visibleIssues: [TrackedIssue] {
        model.issues.filter { issue in
            guard filter.includes(issue) else { return false }
            let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return true }
            return issue.id.localizedCaseInsensitiveContains(needle)
                || issue.title.localizedCaseInsensitiveContains(needle)
                || issue.report.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            trackerHeader
            Divider().opacity(0.6)
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 380)
            } detail: {
                detail
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var trackerHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.project.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(model.project.locationLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            issueCounts
            Picker("Show", selection: $filter) {
                ForEach(IssueTrackerFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 330)
            TextField("Search issues", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh issue records and artifacts")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var issueCounts: some View {
        HStack(spacing: 7) {
            countPill(model.issues.filter { $0.status == .open }.count, color: .orange)
            countPill(model.issues.filter { $0.status == .staged }.count, color: .blue)
            countPill(model.issues.filter { $0.status == .deployed }.count, color: .green)
        }
        .help("Open · staged · deployed")
    }

    private func countPill(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var sidebar: some View {
        List(selection: $route) {
            NavigationLink(value: IssueTrackerRoute.board) {
                Label("Progress board", systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
            }

            ForEach(groupedIssues, id: \.section) { group in
                Section(group.section) {
                    ForEach(group.issues) { issue in
                        NavigationLink(value: IssueTrackerRoute.issue(issue.id)) {
                            HStack(alignment: .top, spacing: 7) {
                                Circle()
                                    .fill(statusColor(issue.status))
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.id)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(issue.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.isLoading && model.issues.isEmpty {
                ProgressView("Reading issues…")
                    .controlSize(.small)
            }
        }
    }

    private var groupedIssues: [(section: String, issues: [TrackedIssue])] {
        var order: [String] = []
        var grouped: [String: [TrackedIssue]] = [:]
        for issue in visibleIssues {
            let section = sectionLabel(issue.section)
            if grouped[section] == nil { order.append(section) }
            grouped[section, default: []].append(issue)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    @ViewBuilder
    private var detail: some View {
        if let error = model.errorMessage, model.issues.isEmpty {
            unavailable(
                title: "Couldn’t read this tracker",
                systemImage: "exclamationmark.triangle",
                detail: error)
        } else {
            switch route ?? .board {
            case .board:
                issueBoard
            case .issue(let id):
                if let issue = model.issues.first(where: { $0.id == id }) {
                    issueDetail(issue)
                } else {
                    unavailable(title: "Issue not found", systemImage: "questionmark.folder")
                }
            }
        }
    }

    private func unavailable(
        title: String, systemImage: String, detail: String? = nil
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var issueBoard: some View {
        GeometryReader { geometry in
            let columnCount = Self.columnCount(for: geometry.size.width)
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 320), spacing: 12, alignment: .top),
                count: columnCount)
            let assignments = model.agentAssignments(monitor.entries)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Agent progress")
                                .font(.system(size: 22, weight: .bold))
                            Text("Live transcript activity, evidence, and an issue-scoped steering box.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !assignments.unassigned.isEmpty {
                            Label(
                                "\(assignments.unassigned.count) unassigned",
                                systemImage: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(visibleIssues) { issue in
                            issueCard(
                                issue,
                                agents: assignments.byIssue[issue.id] ?? [])
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func issueCard(
        _ issue: TrackedIssue, agents: [CommandCenterMonitor.Entry]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { route = .issue(issue.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    statusBadge(issue.status)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.id)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(issue.title)
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let agent = agents.first {
                agentProgress(agent, compact: true)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                    Text("No agent has named \(issue.id) in this project yet")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !issue.artifacts.isEmpty {
                artifactRow(Array(issue.artifacts.prefix(3)), compact: true)
            }

            Spacer(minLength: 0)
            responseComposer(issue, compact: true)
        }
        .padding(12)
        .frame(minHeight: 280, maxHeight: 320, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(agents.first?.needsAttention == true
                    ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.09),
                    lineWidth: agents.first?.needsAttention == true ? 1.5 : 1))
    }

    private func issueDetail(_ issue: TrackedIssue) -> some View {
        GeometryReader { geometry in
            let horizontal = geometry.size.width >= 920
            Group {
                if horizontal {
                    HStack(spacing: 0) {
                        issueDocument(issue)
                            .frame(maxWidth: .infinity)
                        Divider()
                        issueWorkPanel(issue)
                            .frame(width: min(470, geometry.size.width * 0.4))
                    }
                } else {
                    VStack(spacing: 0) {
                        issueDocument(issue)
                        Divider()
                        issueWorkPanel(issue)
                            .frame(height: min(380, geometry.size.height * 0.45))
                    }
                }
            }
        }
    }

    private func issueDocument(_ issue: TrackedIssue) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    statusBadge(issue.status)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.id)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(issue.title)
                            .font(.system(size: 25, weight: .bold))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if let changed = issue.mostRecentChange {
                        Text(relativeTime(changed))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                if issue.statusIsOutOfSync {
                    Label(
                        "Index says \(issue.status.rawValue); issue record says \(issue.detailStatus?.rawValue ?? "unknown")",
                        systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(9)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                }

                if !issue.report.isEmpty {
                    documentSection("Tracker report", text: issue.report)
                }
                documentSection("Work record", text: issue.detail)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func documentSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            IssueMarkdownView(text: text)
        }
    }

    private func issueWorkPanel(_ issue: TrackedIssue) -> some View {
        let agents = model.agents(for: issue, entries: monitor.entries)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Live work", systemImage: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let first = agents.first {
                    statusDot(first)
                    Text(first.isWorking ? "Streaming" : first.needsAttention ? "Needs you" : "Idle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if agents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("No agent linked to \(issue.id)", systemImage: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Sending below uses the pane that opened this tracker when possible, and prefixes the instruction with the issue ID so subsequent progress stays attached here.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(agents) { agent in
                            agentProgress(agent, compact: false)
                        }
                    }

                    if !issue.artifacts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ARTIFACTS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .tracking(0.7)
                            artifactColumn(issue.artifacts)
                        }
                    }
                }
                .padding(14)
            }

            Divider().opacity(0.5)
            responseComposer(issue, compact: false)
                .padding(14)
        }
        .background(Color.primary.opacity(0.022))
    }

    private func agentProgress(
        _ agent: CommandCenterMonitor.Entry, compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusDot(agent)
                Text(agent.watermark)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(agent.kind?.displayName ?? "Agent")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if agent.isWorking {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(agent.message)
                .font(.system(size: compact ? 10.5 : 11.5))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(compact ? 4 : 12)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !compact, !agent.activity.isEmpty {
                ForEach(agent.activity.suffix(4), id: \.self) { line in
                    Label(line, systemImage: "terminal")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let error = agent.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(compact ? 9 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (agent.needsAttention ? Color.accentColor : Color.primary)
                .opacity(agent.needsAttention ? 0.09 : 0.035),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func responseComposer(_ issue: TrackedIssue, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField(
                    compact ? "Steer this issue…" : "Respond or steer the agent working on this issue…",
                    text: draftBinding(issue.id),
                    axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(compact ? 1...2 : 2...5)
                    .onSubmit { sendDraft(issue) }
                Button { sendDraft(issue) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: compact ? 18 : 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft(issue.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Color.secondary : Color.accentColor)
                .disabled(draft(issue.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Save under this issue and send to its agent")
            }
            if let status = model.submissionStatus[issue.id] {
                Text(status)
                    .font(.system(size: 9.5))
                    .foregroundStyle(status.hasPrefix("Not sent") ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func sendDraft(_ issue: TrackedIssue) {
        let text = draft(issue.id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.submit(issue: issue, text: text, entries: monitor.entries)
        drafts[issue.id] = ""
    }

    private func draft(_ id: String) -> String { drafts[id] ?? "" }
    private func draftBinding(_ id: String) -> Binding<String> {
        Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })
    }

    private func artifactRow(_ artifacts: [IssueArtifact], compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(artifacts) { artifact in
                IssueArtifactPreview(model: model, artifact: artifact, compact: compact)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func artifactColumn(_ artifacts: [IssueArtifact]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(artifacts) { artifact in
                IssueArtifactPreview(model: model, artifact: artifact, compact: false)
            }
        }
    }

    private func statusBadge(_ status: TrackedIssueStatus) -> some View {
        Text(status.rawValue)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(statusColor(status).opacity(0.11), in: Capsule())
    }

    private func statusDot(_ entry: CommandCenterMonitor.Entry) -> some View {
        Circle()
            .fill(entry.needsAttention ? Color.accentColor
                : entry.errorCount > 0 ? Color.red
                : entry.isWorking ? Color.green : Color.secondary.opacity(0.45))
            .frame(width: 7, height: 7)
    }

    private func statusColor(_ status: TrackedIssueStatus) -> Color {
        switch status {
        case .open: return .orange
        case .staged: return .blue
        case .deployed: return .green
        case .unverified: return .purple
        }
    }

    private func sectionLabel(_ raw: String) -> String {
        if let divider = raw.range(of: " — ") {
            let tail = String(raw[divider.upperBound...])
            if let stop = tail.range(of: ".  ") { return String(tail[..<stop.lowerBound]) }
            return tail.replacingOccurrences(of: ".", with: "")
        }
        return raw
    }

    private func relativeTime(_ timestamp: TimeInterval) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }

    static func columnCount(for width: CGFloat) -> Int {
        max(1, Int((max(0, width) + 12) / 360))
    }

    static func rows(_ issues: [TrackedIssue], columns: Int) -> [[TrackedIssue]] {
        guard columns > 0 else { return issues.isEmpty ? [] : [issues] }
        return stride(from: 0, to: issues.count, by: columns).map { start in
            Array(issues[start..<min(start + columns, issues.count)])
        }
    }
}

private struct IssueArtifactPreview: View {
    @ObservedObject var model: IssueTrackerModel
    let artifact: IssueArtifact
    let compact: Bool

    var body: some View {
        Group {
            switch artifact.kind {
            case .image:
                image
            case .text:
                text
            case .other:
                fileLabel
            }
        }
        .task(id: artifact.loadID) {
            model.loadArtifact(artifact)
        }
    }

    @ViewBuilder
    private var image: some View {
        if let data = model.artifactData[artifact.id], let image = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: compact ? 68 : 280)
                    .background(Color.black.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(artifact.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if let error = model.artifactErrors[artifact.id] {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 9))
                .foregroundStyle(.red)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04))
                ProgressView().controlSize(.mini)
            }
            .frame(height: compact ? 58 : 120)
        }
    }

    @ViewBuilder
    private var text: some View {
        if compact {
            fileLabel
        } else if let data = model.artifactData[artifact.id],
                  let value = String(data: data, encoding: .utf8) {
            VStack(alignment: .leading, spacing: 5) {
                Label(artifact.name, systemImage: "doc.text")
                    .font(.system(size: 10, weight: .semibold))
                Text(String(value.prefix(4_000)))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            fileLabel
        }
    }

    private var fileLabel: some View {
        Label(artifact.name, systemImage: artifact.kind == .image ? "photo" : "doc")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct IssueMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(OverviewMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: OverviewMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(markdown(text))
                .font(.system(size: max(13, 21 - CGFloat(level) * 1.8), weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(markdown(text))
                .font(.system(size: 12))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items, let ordered):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(markdown(item))
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                }
            }
        case .quote(let text):
            Text(markdown(text))
                .font(.system(size: 12).italic())
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 2)
                }
                .textSelection(.enabled)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let headers, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            Text(markdown(headers[index]))
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                Text(markdown(rows[row][column]))
                                    .font(.system(size: 10.5))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}
