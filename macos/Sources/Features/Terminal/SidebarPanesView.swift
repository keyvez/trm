import SwiftUI

/// The shelf of panes parked out of the grid.
///
/// A parked pane is still running — same PTY, same zmx session, same agent
/// mid-task — it just isn't taking up a cell. The shelf is how you see what is
/// still going and pull one back when you want it.
///
/// Tiles are watermark cards rather than live miniatures, matching the session
/// browser. That isn't only for consistency: an `NSView` has exactly one
/// superview, so rendering a parked surface here would move it out of its grid
/// cell, and rendering it small would reflow the terminal to a few columns
/// wide. A card shows what the pane is without touching it.
struct SidebarPanesView: View {
    /// Parked panes, in shelf order.
    let panes: [GridPane]

    /// Stable pane IDs whose agent is waiting on the user.
    var attentionPaneIds: Set<Int> = []

    /// Bring a pane back into the grid.
    var onRestore: ((GridPane) -> Void)? = nil

    /// Close a parked pane for good.
    var onClose: ((GridPane) -> Void)? = nil

    /// Bring every parked pane back at once.
    var onRestoreAll: (() -> Void)? = nil

    /// Collapse the shelf.
    var onCollapse: (() -> Void)? = nil

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
        "\(panes.count) pane\(panes.count == 1 ? "" : "s")"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if panes.isEmpty {
            emptyState
        } else {
            ScrollView {
                // A plain VStack, not a LazyVStack: the shelf holds a handful
                // of tiles, and a lazy container inside a ScrollView has to
                // estimate the height of tiles it has not built yet — the same
                // measurement loop that pinned a core in the session browser.
                VStack(spacing: 8) {
                    ForEach(panes) { pane in
                        SidebarPaneTile(
                            pane: pane,
                            needsAttention: needsAttention(pane),
                            watermarkVersion: watermarkVersion,
                            onRestore: { onRestore?(pane) },
                            onClose: { onClose?(pane) }
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Nothing parked")
                .font(.system(size: 12, weight: .medium))
            Text("Send a pane here to keep it running out of sight.")
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
    let needsAttention: Bool
    /// Re-reads the watermark when the Zig side changes it; unused directly.
    let watermarkVersion: Int
    let onRestore: () -> Void
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

            // Buttons stay mounted so the tile height doesn't jump on hover.
            HStack(spacing: 6) {
                Button("Restore", action: onRestore)
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
        .onTapGesture(perform: onRestore)
        .contextMenu {
            Button("Restore to Grid", action: onRestore)
            Divider()
            Button("Close Pane", role: .destructive, action: onClose)
        }
        .help("Still running — click to bring it back")
    }

    /// The pane's watermark, which is the label the user already navigates by.
    private var label: String {
        if let paneId = pane.firstTerminalSurface?.paneId,
           let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId)),
           !watermark.isEmpty {
            return watermark
        }
        return fallbackLabel
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
