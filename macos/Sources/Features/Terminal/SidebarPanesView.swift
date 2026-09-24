import SwiftUI
import AppKit

/// Every pane in the window, parked or not.
///
/// It used to list only parked panes, which made it a shelf for things you had
/// put away. Listing all of them makes it the window's index: one column that
/// says what every pane is and what its agent last said, so "which pane was
/// doing the migration" is answered by reading rather than by clicking through
/// panes until you find it. A parked pane is still running — same PTY, same
/// zmx session, same agent mid-task — it just isn't taking up a cell, and the
/// shelf is still how you pull one back.
///
/// Tiles draw the pane as it looks — its whole viewport, its own characters and
/// colours, very small. Not a live view of the surface, which is impossible: an
/// `NSView` has exactly one superview, so putting a parked pane's surface here
/// would take it out of its grid cell, and drawing it small would reflow the
/// terminal to a few columns wide. Reading the cells and redrawing them costs
/// neither.
struct SidebarPanesView: View {
    /// Parked panes, in shelf order.
    let panes: [GridPane]

    /// Panes currently laid out in the grid, in visual order. Listed above the
    /// parked ones and acted on differently: a grid pane is focused, not
    /// restored, because it is already on screen.
    var gridPanes: [GridPane] = []

    /// The agent's latest message per pane id, so a tile can say what the pane
    /// is *doing* rather than only what it is called.
    var messages: [Int: String] = [:]
    /// The agent running in each pane, when one is.
    var agentNames: [Int: String] = [:]
    /// Where each pane's work is — a worktree or project directory.
    var locations: [Int: String] = [:]

    /// Stable pane IDs whose agent is waiting on the user.
    var attentionPaneIds: Set<Int> = []

    /// Bring a pane already in the grid to the front.
    var onFocus: ((GridPane) -> Void)? = nil

    /// Bring a pane back into the grid.
    var onRestore: ((GridPane) -> Void)? = nil

    /// Close a parked pane for good.
    var onClose: ((GridPane) -> Void)? = nil

    /// Expand a pane to read it, without moving it.
    ///
    /// ⌘-click, the same gesture that peeks a pane in the grid or a sub-pane in
    /// a stack. It is worth more here than anywhere: a parked pane has no cell
    /// to ⌘-click, so the shelf was the one place a pane could be listed,
    /// described, and still unreadable without first giving it a cell back.
    var onPeek: ((GridPane) -> Void)? = nil

    /// Bring every parked pane back at once.
    var onRestoreAll: (() -> Void)? = nil

    /// Collapse the shelf.
    var onCollapse: (() -> Void)? = nil

    /// A pane's viewport, cells and colours.
    ///
    /// `refresh` exists only to make SwiftUI re-read this: the value is a
    /// snapshot of live terminal state, which the view system has no way to
    /// observe on its own.
    private static func screen(for pane: GridPane, refresh: Int) -> Trm.PaneScreen? {
        _ = refresh
        guard let paneId = pane.firstTerminalSurface?.paneId else { return nil }
        return Trm.shared.paneScreen(paneId: UInt32(paneId))
    }

    /// Bumped on a timer so the previews follow the panes they describe.
    @State private var previewVersion: Int = 0

    /// Bumped when a watermark changes so the tiles re-read their labels.
    @State private var watermarkVersion: Int = 0

    /// Filter text for the shelf.
    ///
    /// The sidebar exists so "which pane was doing the migration" is answered
    /// by reading rather than by clicking through panes. Past a dozen panes
    /// reading stops being quick, and the answer is to type the word you
    /// remember — which is why this matches the agent's *message* as well as
    /// the pane's name: the word you remember is usually something it said.
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        .onReceive(NotificationCenter.default.publisher(for: Trm.watermarkDidChange)) { _ in
            watermarkVersion += 1
        }
        // Once a second: reading a viewport is cheap, but redrawing a shelf of
        // full-grid miniatures is not, and a sidebar is glanced at rather than
        // watched.
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            previewVersion &+= 1
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sidebar.squares.right")
                .foregroundStyle(.secondary)

            Text("Sidebar")
                .font(.system(size: 12, weight: .semibold))

            Text(paneCount)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if panes.count > 1 {
                Button("Restore All") { onRestoreAll?() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }

            Button {
                onCollapse?()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Hide the sidebar")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var paneCount: String {
        let total = gridPanes.count + panes.count
        guard isFiltering else { return "\(total) pane\(total == 1 ? "" : "s")" }
        // While filtering, the count that matters is how much was hidden —
        // "2 of 14" says the shelf is not broken, it is answering a question.
        return "\(matchingGrid.count + matchingParked.count) of \(total)"
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField("Filter panes", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if isFiltering {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var matchingGrid: [GridPane] { gridPanes.filter(matches) }
    private var matchingParked: [GridPane] { panes.filter(matches) }

    /// Everything a tile shows is searchable, because everything a tile shows
    /// is something you might remember it by: the name you gave it, the agent
    /// in it, the directory it works in, and the last thing it said.
    private func matches(_ pane: GridPane) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        guard let paneId = pane.firstTerminalSurface?.paneId else { return false }
        var haystack = ["pane \(paneId)"]
        if let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId)) {
            haystack.append(watermark)
        }
        if let agent = agentNames[paneId] { haystack.append(agent) }
        if let location = locations[paneId] { haystack.append(location) }
        if let message = messages[paneId] { haystack.append(message) }
        return haystack.contains { $0.lowercased().contains(needle) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if panes.isEmpty && gridPanes.isEmpty {
            emptyState
        } else if isFiltering && matchingGrid.isEmpty && matchingParked.isEmpty {
            // Said in words rather than left blank: an empty shelf and a shelf
            // with nothing matching look identical, and only one of them means
            // you should clear the box.
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                Text("No pane matches “\(query)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Clear") { query = "" }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else {
            ScrollView {
                // A plain VStack, not a LazyVStack: the shelf holds a handful
                // of tiles, and a lazy container inside a ScrollView has to
                // estimate the height of tiles it has not built yet — the same
                // measurement loop that pinned a core in the session browser.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(matchingGrid) { pane in
                        tile(for: pane, parked: false)
                    }

                    // Parked panes are separated rather than mixed in: "on
                    // screen" and "running out of sight" are different states,
                    // and the actions differ with them.
                    if !matchingParked.isEmpty {
                        if !matchingGrid.isEmpty {
                            Text("PARKED")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                        ForEach(matchingParked) { pane in
                            tile(for: pane, parked: true)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func tile(for pane: GridPane, parked: Bool) -> some View {
        let paneId = pane.firstTerminalSurface?.paneId
        return SidebarPaneTile(
            pane: pane,
            parked: parked,
            needsAttention: needsAttention(pane),
            watermarkVersion: watermarkVersion,
            message: paneId.flatMap { messages[$0] },
            screen: Self.screen(for: pane, refresh: previewVersion),
            agentName: paneId.flatMap { agentNames[$0] },
            location: paneId.flatMap { locations[$0] },
            onPrimary: { parked ? onRestore?(pane) : onFocus?(pane) },
            onPeek: onPeek.map { peek in { peek(pane) } },
            onClose: { onClose?(pane) }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No panes")
                .font(.system(size: 12, weight: .medium))
            Text("Panes in this window appear here, with what their agent last said.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func needsAttention(_ pane: GridPane) -> Bool {
        guard let paneId = pane.firstTerminalSurface?.paneId else { return false }
        return attentionPaneIds.contains(paneId)
    }
}

// MARK: - Tile

/// One parked pane: its watermark, what it is, and the two things you can do
/// with it. Clicking anywhere on the tile brings the pane back, which is the
/// action the shelf exists for.
private struct SidebarPaneTile: View {
    let pane: GridPane
    /// Parked panes are restored; grid panes are focused.
    let parked: Bool
    let needsAttention: Bool
    /// Re-reads the watermark when the Zig side changes it; unused directly.
    let watermarkVersion: Int
    /// The agent's latest message, when this pane has an agent.
    let message: String?
    /// The pane's viewport, cells and colours, to draw small.
    let screen: Trm.PaneScreen?
    let agentName: String?
    let location: String?
    let onPrimary: () -> Void
    /// Nil when the window can't peek right now; the gesture then falls
    /// through to the ordinary click rather than doing nothing.
    let onPeek: (() -> Void)?
    let onClose: () -> Void

    @State private var hovering = false
    /// Renaming state, held per tile: the shelf is a list of independent
    /// cards and only one of them is ever being typed into.
    @State private var renaming = false
    @State private var renameText = ""
    @FocusState private var renameField: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // One line, not a 62pt block of faint monospace. The watermark was
            // drawn large because the tile had nothing else in it; now that the
            // tile shows the pane itself, a name that tall is the biggest thing
            // on a card whose subject is underneath it.
            HStack(spacing: 5) {
                if needsAttention {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .help("Waiting for input")
                }

                if renaming {
                    // Same shape as the label it replaces, so the tile does
                    // not resize under the cursor mid-rename.
                    TextField("Watermark", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .focused($renameField)
                        .frame(maxWidth: 140)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                        // Clicking away is "done", not "discard". The shelf
                        // moves under you — panes come and go — and losing a
                        // name to a stray click elsewhere would be its own
                        // bug report.
                        .onChange(of: renameField) { focused in
                            if !focused { commitRename() }
                        }
                        .help("Return to rename · esc to leave it alone · blank clears it")
                } else {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Both gestures live on the name itself. The tile's
                        // own click restores the pane, and a double-click that
                        // reached it first would put the pane back in the grid
                        // on the way to renaming it.
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginRename() }
                        .onTapGesture { tapped() }
                }

                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }

            // What the agent last said. The point of listing every pane is to
            // answer "which one was doing the migration" by reading rather
            // than by clicking through panes until you find it — and the
            // message is what actually answers that, not the label.
            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The pane itself, drawn small: the whole viewport, its own
            // characters and its own colours. A pane with no agent has nothing
            // else to show, and this is the only thing that tells one shell
            // from another.
            if let screen {
                PaneMiniature(screen: screen)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Buttons stay mounted so the tile height doesn't jump on hover.
            HStack(spacing: 6) {
                Button(parked ? "Restore" : "Focus", action: onPrimary)
                Button("Close", role: .destructive, action: onClose)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .font(.system(size: 10))
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    needsAttention ? Color.orange.opacity(0.55)
                                   : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: tapped)
        .contextMenu {
            Button(parked ? "Restore to Grid" : "Focus Pane", action: onPrimary)
            if let onPeek {
                Button("Peek", action: onPeek)
            }
            if pane.firstTerminalSurface?.paneId != nil {
                Button("Rename…", action: beginRename)
            }
            Divider()
            Button("Close Pane", role: .destructive, action: onClose)
        }
        .help(parked
              ? "Still running — click to bring it back, ⌘-click to read it where it is, double-click the name to rename it"
              : "Click to focus this pane, ⌘-click to expand it, double-click the name to rename it")
    }

    // MARK: - Renaming

    /// Turn the name into a field, seeded with the pane's own watermark.
    ///
    /// The watermark rather than the label on purpose: the label falls back to
    /// the worktree, the agent or the folder, and carries the worktree
    /// insignia when there is one. None of that is text anyone typed, and
    /// handing it back to be edited would make a guess look like a name.
    private func beginRename() {
        guard let paneId = pane.firstTerminalSurface?.paneId else { return }
        renameText = Trm.shared.watermark(forPaneId: UInt32(paneId)) ?? ""
        renaming = true
        // A field that appears without the keyboard is a field you click
        // twice to use; the hop lets it exist before it is asked to focus.
        DispatchQueue.main.async { renameField = true }
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        renameField = false
        guard let paneId = pane.firstTerminalSurface?.paneId else { return }
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (Trm.shared.watermark(forPaneId: UInt32(paneId)) ?? "") else { return }
        Trm.shared.setWatermark(forPaneId: UInt32(paneId), text: text)
    }

    private func cancelRename() {
        renaming = false
        renameField = false
    }

    /// ⌘-click peeks, a plain click does the tile's usual thing.
    ///
    /// The modifiers are read from the current event rather than carried by
    /// the gesture: SwiftUI's `TapGesture` doesn't report them, and this is the
    /// same way the grid decides a ⌘-click on a pane is a peek.
    private func tapped() {
        let modifiers = NSEvent.modifierFlags
        if let onPeek,
           modifiers.contains(.command),
           modifiers.isDisjoint(with: [.shift, .control, .option]) {
            onPeek()
            return
        }
        onPrimary()
    }

    /// What to call this pane.
    ///
    /// The watermark first, because that is the name someone chose and already
    /// navigates by. Then the worktree, which is the most specific true thing
    /// about a pane working in one — `trm-hello-world` says more than `trm`
    /// does when three panes share a repository. Then the agent, then the
    /// folder. A command line is the last resort it always was: it identifies
    /// the pane only to whoever typed it.
    private var label: String {
        if let paneId = pane.firstTerminalSurface?.paneId,
           let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId)),
           !watermark.isEmpty {
            // A watermark stamped at creation already carries the mark; one
            // typed by hand for a pane that happens to sit in a worktree does
            // not, and wants it.
            return worktreeName == nil ? watermark : WorktreeMark.marked(watermark)
        }
        if let worktree = worktreeName { return WorktreeMark.marked(worktree) }
        if let agentName, !agentName.isEmpty, agentName != "shell" { return agentName }
        if let folder = folderName { return folder }
        return fallbackLabel
    }

    /// The worktree directory's own name, when this pane is working in one.
    ///
    /// A worktree is the branch made visible, and its directory is named for
    /// the branch — so this is the label that distinguishes two panes on the
    /// same project that are doing entirely different things.
    private var worktreeName: String? { WorktreeMark.name(forPath: location) }

    /// The project directory's name — the last component of where the work is.
    private var folderName: String? {
        guard let location, !location.isEmpty else { return nil }
        return location.split(separator: "/").last.map(String.init)
    }

    private var fallbackLabel: String {
        switch pane {
        case .terminal(let surface):
            return surface.logicalCommand ?? surface.initialCommand ?? "shell"
        case .webview(let webview):
            return webview.title.isEmpty
                ? (webview.currentURL ?? webview.initialURL).host ?? "web"
                : webview.title
        case .plugin(let plugin):
            return plugin.title
        case .agentOverview:
            return "overview"
        case .stack:
            return "stack"
        }
    }

    private var subtitle: String {
        switch pane {
        case .terminal(let surface):
            if let host = surface.remoteHost, !host.isEmpty {
                return host
            }
            if let pwd = surface.pwd, !pwd.isEmpty {
                return (pwd as NSString).lastPathComponent
            }
            return surface.logicalCommand ?? surface.initialCommand ?? "shell"
        case .webview(let webview):
            return (webview.currentURL ?? webview.initialURL).host ?? "web page"
        case .plugin(let plugin):
            return plugin.kind.title
        case .agentOverview:
            return "Agent overview"
        case .stack(let children):
            return "\(children.count) stacked panes"
        }
    }
}

// MARK: - Watermark


// MARK: - Collapsed rail

/// The one-tab strip shown when panes are parked but the shelf is collapsed,
/// so a running pane is never invisible with no way back to it.
struct SidebarRailView: View {
    let count: Int
    var needsAttention: Bool = false
    var onExpand: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onExpand) {
            VStack(spacing: 4) {
                Image(systemName: "sidebar.squares.right")
                    .font(.system(size: 12))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                if needsAttention {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 26)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.5))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
        .onHover { hovering = $0 }
        .help("\(count) pane\(count == 1 ? "" : "s") running in the sidebar")
    }
}
