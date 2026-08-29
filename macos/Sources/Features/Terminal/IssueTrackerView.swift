import AppKit
import Combine
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
                    "host=\(host ?? "local")",
                    "session=\(session ?? "-")",
                    "cwd=\(cwd ?? "-")",
                    "project=\(discovered?.locationLabel ?? "none")",
                ].joined(separator: " ")
                if diagnostic != lastDiagnostic {
                    lastDiagnostic = diagnostic
                    TrmDiagnostics.log("[issue-tracker] pane discovery \(diagnostic)")
                }

                // A remote pane's cwd arrives over SSH and can resolve late.
                // Keep looking so the button appears without a relaunch.
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
        // The workspace draws its own toolbar in the titlebar band, the way
        // Xcode and Mail do. The window title would sit on top of it; the
        // project name is in the toolbar's leading slot instead.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 560)
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

// MARK: - Shared formatting

enum IssueTrackerFormat {
    static func statusColor(_ status: TrackedIssueStatus) -> Color {
        switch status {
        case .open: return .orange
        case .staged: return .blue
        case .deployed: return .green
        case .unverified: return .purple
        }
    }

    static func agentColor(_ state: IssueAgentSummary.State) -> Color {
        switch state {
        case .working: return .green
        case .waiting: return .orange
        case .failed: return .red
        case .finished: return .secondary
        }
    }

    /// The same colours, reached from a tag name — the tag is the only place
    /// agent state is drawn now.
    static func agentStateColor(_ tagName: String) -> Color {
        switch tagName {
        case "working": return .green
        case "waiting": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }

    static func sectionLabel(_ raw: String) -> String {
        if let divider = raw.range(of: " — ") {
            let tail = String(raw[divider.upperBound...])
            if let stop = tail.range(of: ".  ") { return String(tail[..<stop.lowerBound]) }
            return tail.replacingOccurrences(of: ".", with: "")
        }
        return raw
    }

    /// One formatter, not one per line per render.
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relativeTime(_ timestamp: TimeInterval) -> String {
        relative.localizedString(
            for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }

    static func byteSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - Keyboard routing

/// A window-scoped key monitor.
///
/// One place decides what a key means, and it steps aside entirely while a
/// text field has the caret. `onKeyPress` is macOS 14 and trm ships to 13.
private struct TrackerKeyMonitor: NSViewRepresentable {
    /// Return true to swallow the event.
    let handler: (NSEvent, Bool) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? MonitorView)?.teardown()
    }

    final class MonitorView: NSView {
        var handler: ((NSEvent, Bool) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else {
                    return event
                }
                let editing = window.firstResponder is NSText
                    || window.firstResponder is NSTextView
                return self.handler?(event, editing) == true ? nil : event
            }
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Root

/// The whole window: a search bar and an outline.
///
/// The tracker is a plain-text file organised into headings and one line per
/// issue, and this is that file with the live agent state written into it as
/// tags. There is no navigator, no view switcher and no inspector, because
/// the document is the interface — the earlier three-pane version was an IDE
/// built around a to-do list.
struct IssueTrackerView: View {
    @ObservedObject var model: IssueTrackerModel
    @StateObject private var state = IssueOutlineState()
    @FocusState private var focus: IssueOutlineState.FocusTarget?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !state.availableTags.isEmpty {
                TagFilterBar(state: state)
            }
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(TrackerKeyMonitor(handler: handleKey))
        .onAppear {
            model.start()
            state.recompute(rows: model.rows)
        }
        .onDisappear { model.stop() }
        .onReceive(model.$rows) { state.recompute(rows: $0) }
        .onChange(of: state.search) { _ in state.recompute(rows: model.rows) }
        .onChange(of: state.collapsed) { _ in state.recompute(rows: model.rows) }
        .onChange(of: state.focusedProject) { _ in state.recompute(rows: model.rows) }
        .onChange(of: state.focusTarget) { target in
            if focus != target { focus = target }
        }
        .onChange(of: focus) { value in
            if state.focusTarget != value { state.focusTarget = value }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage, model.rows.isEmpty {
            OutlineErrorState(model: model, message: error)
            Spacer()
        } else if model.isLoading, model.rows.isEmpty {
            OutlineLoadingState(model: model)
        } else if state.projects.isEmpty {
            OutlineEmptyState(state: state)
            Spacer()
        } else {
            outline
        }
    }

    private var outline: some View {
        ScrollViewReader { proxy in
            List(selection: selectionBinding) {
                ForEach(state.projects) { project in
                    // Focused, the heading is in the bar instead: repeating it
                    // over the only section on screen says nothing.
                    if state.focusedProject == nil {
                        ProjectLine(
                            project: project,
                            collapsed: state.collapsed.contains(project.label),
                            toggle: { state.toggle(project.label) },
                            focus: { state.focus(on: project.label) })
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }

                    if state.focusedProject != nil
                        || !state.collapsed.contains(project.label) {
                        ForEach(project.rows) { row in
                            TaskLine(
                                model: model,
                                state: state,
                                row: row,
                                selected: state.selection == row.id,
                                focus: $focus)
                                .equatable()
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .tag(row.id)
                                .contextMenu { IssueContextMenu(model: model, row: row) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: state.selection) { selection in
                guard let selection else { return }
                proxy.scrollTo(selection, anchor: nil)
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { state.selection }, set: { state.select($0) })
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Text(model.project.name)
                .font(.system(size: 12, weight: .semibold))
                .help(model.project.locationLabel)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField("Search — try @waiting, @next, not @deployed", text: $state.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($focus, equals: .search)
                    .onSubmit { focus = nil }
                if !state.search.isEmpty {
                    Button { state.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        focus == .search ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: focus == .search ? 1.5 : 1))

            if let focused = state.focusedProject {
                Button { state.focus(on: nil) } label: {
                    HStack(spacing: 5) {
                        Text(focused)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Focused on \(focused) — click to show every section (⎋)")
                .fixedSize()
            }

            Text(countLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if model.nextIssueID != nil { HandOffButton(model: model) }

            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Refresh (⌘R)")
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 38)
    }

    private var countLabel: String {
        let shown = state.projects.reduce(0) { $0 + $1.rows.count }
        return shown == model.rows.count ? "\(shown)" : "\(shown)/\(model.rows.count)"
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent, editing: Bool) -> Bool {
        let escape: UInt16 = 53, up: UInt16 = 126, down: UInt16 = 125, ret: UInt16 = 36

        if event.keyCode == escape {
            state.popFocus()
            return true
        }
        let modifiers = event.modifierFlags
            .intersection([.command, .option, .control, .shift])

        if modifiers == [.command, .shift] {
            guard event.charactersIgnoringModifiers?.lowercased() == "n",
                  let selection = state.selection else { return false }
            model.markNext(selection)
            return true
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "r": model.refresh(); return true
            case "f": state.focusTarget = .search; return true
            // TaskPaper's fold keys, same way round.
            case "9": state.collapseAll(rows: model.rows); return true
            case "0": state.expandAll(); return true
            default: return false
            }
        }

        guard !editing, modifiers.isEmpty else { return false }
        switch event.keyCode {
        case up: state.moveSelection(by: -1); return true
        case down: state.moveSelection(by: 1); return true
        case ret:
            guard state.selection != nil else { return false }
            state.focusTarget = .composer
            return true
        default: break
        }
        guard event.charactersIgnoringModifiers == "/" else { return false }
        state.focusTarget = .search
        return true
    }
}

/// Appears only when an issue is marked. Hands it to an agent that has
/// stopped; the switch under it does the same the moment one frees up.
private struct HandOffButton: View {
    @ObservedObject var model: IssueTrackerModel
    @ObservedObject private var monitor = CommandCenterMonitor.shared

    var body: some View {
        Menu {
            Button("Hand \(model.nextIssueID ?? "it") to \(target?.watermark ?? "an agent")") {
                model.handOffNext(monitor.entries)
            }
            .disabled(target == nil)
            Toggle("Automatically, when an agent frees up",
                   isOn: $model.handsOffAutomatically)
            if let status = model.handOffStatus {
                Divider()
                Text(status)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.right.2").font(.system(size: 8, weight: .black))
                Text(model.nextIssueID ?? "")
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .foregroundStyle(Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The issue marked to work on next")
    }

    private var target: IssueAgentSummary? { model.handOffTarget(monitor.entries) }
}
