import SwiftUI

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
/// Tiles show the pane's last few lines as text, not a live miniature. An
/// `NSView` has exactly one superview, so rendering a parked surface here would
/// move it out of its grid cell, and rendering it small would reflow the
/// terminal to a few columns wide — the pane would change shape because
/// something was looking at it. Reading the viewport's text costs neither:
/// the surface already keeps a half-second cache of it for summaries, so the
/// tile shows what the pane actually says without touching the pane.
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

    /// Bring every parked pane back at once.
    var onRestoreAll: (() -> Void)? = nil

    /// Collapse the shelf.
    var onCollapse: (() -> Void)? = nil

    /// The last lines a pane printed.
    ///
    /// Read straight from the surface's cached viewport text, which the
    /// surface already refreshes at most twice a second for its own summaries
    /// — so a shelf of tiles costs one cache hit each rather than a read per
    /// tile per redraw.
    ///
    /// Trailing blank lines go: a terminal's viewport is padded to its full
    /// height, and showing that means showing mostly nothing.
    private static func preview(for pane: GridPane, refresh: Int, lines: Int = 6) -> [String] {
        _ = refresh
        guard let surface = pane.firstTerminalSurface else { return [] }
        let text = surface.cachedVisibleContents.get()
        guard !text.isEmpty else { return [] }
        var rows = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        guard !rows.isEmpty else { return [] }
        return Array(rows.suffix(lines))
    }

    /// Bumped on a timer so the previews follow the panes they describe.
    @State private var previewVersion: Int = 0

    /// Bumped when a watermark changes so the tiles re-read their labels.
    @State private var watermarkVersion: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        .onReceive(NotificationCenter.default.publisher(for: Trm.watermarkDidChange)) { _ in
            watermarkVersion += 1
        }
        // Twice a second matches the surface's own cache, so this reads
        // something new each time rather than redrawing the same string.
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
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
        return "\(total) pane\(total == 1 ? "" : "s")"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if panes.isEmpty && gridPanes.isEmpty {
            emptyState
        } else {
            ScrollView {
                // A plain VStack, not a LazyVStack: the shelf holds a handful
                // of tiles, and a lazy container inside a ScrollView has to
                // estimate the height of tiles it has not built yet — the same
                // measurement loop that pinned a core in the session browser.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(gridPanes) { pane in
                        tile(for: pane, parked: false)
                    }

                    // Parked panes are separated rather than mixed in: "on
                    // screen" and "running out of sight" are different states,
                    // and the actions differ with them.
                    if !panes.isEmpty {
                        if !gridPanes.isEmpty {
                            Text("PARKED")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                        ForEach(panes) { pane in
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
            preview: Self.preview(for: pane, refresh: previewVersion),
            agentName: paneId.flatMap { agentNames[$0] },
            location: paneId.flatMap { locations[$0] },
            onPrimary: { parked ? onRestore?(pane) : onFocus?(pane) },
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
    /// The last lines the terminal actually printed.
    let preview: [String]
    let agentName: String?
    let location: String?
    let onPrimary: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SidebarWatermark(text: label)

            HStack(spacing: 5) {
                if needsAttention {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .help("Waiting for input")
                }

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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

            // The terminal itself, in miniature: its last lines, monospaced
            // and truncated rather than reflowed, so the shape of the output
            // survives at this size. A pane with no agent has nothing else to
            // show, and this is the only thing that tells one shell from
            // another.
            if !preview.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 7, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )
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
        .padding(7)
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
        .onTapGesture(perform: onPrimary)
        .contextMenu {
            Button(parked ? "Restore to Grid" : "Focus Pane", action: onPrimary)
            Divider()
            Button("Close Pane", role: .destructive, action: onClose)
        }
        .help(parked ? "Still running — click to bring it back" : "Click to focus this pane")
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

/// The pane's label, drawn the way the pane itself draws it: large, low
/// contrast, on the terminal background.
///
/// The point size comes from the character count rather than
/// `minimumScaleFactor`, for the reason spelled out in the session browser:
/// scaling makes the text size depend on the offered width while the layout
/// makes the width depend on the text, and SwiftUI re-runs text metrics
/// searching for a fixed point that a stack of tiles never settles on.
private struct SidebarWatermark: View {
    let text: String

    private var fontSize: CGFloat {
        switch text.count {
        case 0...4: return 24
        case 5...7: return 19
        case 8...11: return 15
        case 12...16: return 12
        default: return 10
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.22))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

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
