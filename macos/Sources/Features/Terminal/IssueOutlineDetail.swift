import AppKit
import SwiftUI

/// What the selected task line expands into: the agent's own words, what it
/// has been doing, its evidence, and the one place you can answer.
///
/// It is indented under the task rather than living in a panel, because that
/// is what an outline does with detail — and it means only the selected issue
/// ever builds a composer or reads an artifact.
struct IssueDetail: View {
    @ObservedObject var model: IssueTrackerModel
    @ObservedObject var state: IssueOutlineState
    let row: IssueRow
    @FocusState.Binding var focus: IssueOutlineState.FocusTarget?

    private var issue: TrackedIssue { row.issue }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let agent = row.agent { agentDetail(agent) }
            if !issue.artifacts.isEmpty { artifacts }
            record
            composer
        }
        .padding(.trailing, 16)
    }

    // MARK: Agent

    private func agentDetail(_ agent: IssueAgentSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if agent.message != row.latestUpdate, !agent.message.isEmpty {
                Text(agent.message)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = agent.errorText, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !agent.activity.isEmpty {
                ForEach(Array(agent.activity.suffix(3).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Button {
                if let entry = model.entry(for: agent) {
                    CommandCenterMonitor.shared.reveal(entry)
                }
            } label: {
                Text("Go to \(agent.watermark)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Artifacts

    private var artifacts: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(issue.artifacts) { artifact in
                IssueArtifactPreview(model: model, artifact: artifact)
            }
        }
    }

    // MARK: Record

    private var record: some View {
        DisclosureGroup {
            IssueMarkdownView(text: issue.detail)
                .padding(.top, 4)
        } label: {
            Text("issues/\(issue.id).md")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .disclosureGroupStyle(.automatic)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 7) {
                TextField("Respond…", text: state.draftBinding(issue.id), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .lineLimit(1...5)
                    .focused($focus, equals: .composer)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                focus == .composer
                                    ? Color.accentColor : Color.primary.opacity(0.1),
                                lineWidth: focus == .composer ? 1.5 : 1))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save under this issue and send it to the agent (⌘⏎)")
            }
            Text(statusLine)
                .font(.system(size: 10))
                .foregroundStyle(submissionIsError ? Color.red : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canSend: Bool {
        !state.draft(issue.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var submissionIsError: Bool {
        model.submissionStatus[issue.id]?.hasPrefix("Not sent") == true
    }

    private var statusLine: String {
        if let status = model.submissionStatus[issue.id] { return status }
        let destination = row.agent.map { ", then sent to \($0.watermark)" } ?? ""
        return "Saved to issues/artifacts/\(issue.id)/responses.md\(destination)"
    }

    private func send() {
        let text = state.draft(issue.id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.submit(issue: issue, text: text, entries: CommandCenterMonitor.shared.entries)
        state.drafts[issue.id] = ""
    }
}

// MARK: - Context menu

/// The actions an issue has, wherever it is drawn. A menu, not a row of
/// buttons: the line's job is to be read.
struct IssueContextMenu: View {
    @ObservedObject var model: IssueTrackerModel
    let row: IssueRow

    var body: some View {
        Button(row.isNext ? "Don’t work on this next" : "Work on this next") {
            model.markNext(row.id)
        }
        Divider()
        Button("Open issues/\(row.issue.id).md") { open(relative: "issues/\(row.issue.id).md") }
            .disabled(model.project.remoteHost != nil)
        Button("Show in \(model.project.indexFileName)") {
            open(relative: model.project.indexFileName)
        }
        .disabled(model.project.remoteHost != nil)
        Button("Reveal artifacts in Finder") {
            reveal(relative: "issues/artifacts/\(row.issue.id)")
        }
        .disabled(model.project.remoteHost != nil)

        if let agent = row.agent {
            Divider()
            Button("Go to \(agent.watermark)") {
                if let entry = model.entry(for: agent) {
                    CommandCenterMonitor.shared.reveal(entry)
                }
            }
            Button("Open \(agent.watermark)’s Agent Overview") {
                if let entry = model.entry(for: agent) {
                    CommandCenterMonitor.shared.revealOverview(entry)
                }
            }
        }

        Divider()
        Button("Copy issue ID") { copy(row.issue.id) }
        Button("Copy latest update") { copy(row.latestUpdate) }
    }

    private func absolute(_ relative: String) -> URL {
        URL(fileURLWithPath: model.project.rootPath, isDirectory: true)
            .appendingPathComponent(relative)
    }

    private func open(relative: String) { NSWorkspace.shared.open(absolute(relative)) }

    private func reveal(relative: String) {
        let url = absolute(relative)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Artifacts

/// One artifact, read only when its line is on screen inside a selected task.
struct IssueArtifactPreview: View {
    @ObservedObject var model: IssueTrackerModel
    let artifact: IssueArtifact

    @State private var expanded = false

    private var tooLarge: Bool { artifact.size > IssueTrackerStore.artifactSizeLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if artifact.kind == .other || tooLarge { revealInFinder() } else {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(artifact.name)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(IssueTrackerFormat.byteSize(artifact.size))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.quaternary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Reveal in Finder") { revealInFinder() }
                    .disabled(model.project.remoteHost != nil)
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(artifact.relativePath, forType: .string)
                }
            }

            if expanded, !tooLarge { preview }
        }
        .task(id: "\(artifact.loadID)|\(expanded)") {
            guard expanded, !tooLarge else { return }
            model.loadArtifact(artifact)
        }
    }

    private var symbol: String {
        switch artifact.kind {
        case .image: return "photo"
        case .text: return "doc.text"
        case .other: return "doc"
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let error = model.artifactErrors[artifact.id] {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.red)
        } else if let data = model.artifactData[artifact.id] {
            switch artifact.kind {
            case .image:
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 520, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            case .text:
                Text(String((String(data: data, encoding: .utf8) ?? "").prefix(4_000)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.04)))
            case .other:
                EmptyView()
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private func revealInFinder() {
        guard model.project.remoteHost == nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: model.project.rootPath, isDirectory: true)
                .appendingPathComponent(artifact.relativePath)
        ])
    }
}

// MARK: - Markdown

struct IssueMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                .font(.system(size: max(11.5, 15 - CGFloat(level)), weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 0)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(markdown(text))
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items, let ordered):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "-")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.quaternary)
                        Text(markdown(item))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let text):
            Text(markdown(text))
                .font(.system(size: 11).italic())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        case .rule:
            Divider()
        case .table(let headers, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { index in
                            Text(markdown(headers[index]))
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                Text(markdown(rows[row][column]))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}
