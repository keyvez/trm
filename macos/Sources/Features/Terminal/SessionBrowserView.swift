import SwiftUI

/// Browser over live zmx sessions: a scrollable list of sessions, each with a
/// rendered preview of what that session's terminal currently looks like.
///
/// Sessions outlive the UI process, so this is the place to find work that is
/// still running but no longer shown in any window — after a hang, a crash, or
/// an autosave that lost its layout.
struct SessionBrowserView: View {
    @ObservedObject var model: SessionBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .font(.headline)

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 2)
            }

            Text(model.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty && !model.isLoading {
            emptyState
        } else {
            ScrollView {
                // Deliberately a plain VStack, not a LazyVStack.
                //
                // Each group renders a LazyVGrid of tiles, and nesting one lazy
                // container in another makes each one's size estimate depend on
                // the other's: the outer stack asks for a height the grid can
                // only give once it knows its width, which the outer stack is
                // still deciding. SwiftUI churned text metrics through that
                // cycle and pinned a core whenever the browser was open.
                //
                // A window list is a handful of groups, so laying them out
                // eagerly costs nothing and removes the negotiation entirely.
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.groups) { group in
                        GroupSection(
                            group: group,
                            onOpenGroup: { model.openGroup(group) },
                            onTerminateGroup: { model.confirmTerminateGroup(group) },
                            onOpen: { model.open($0) },
                            onTerminate: { model.confirmTerminate($0) }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No live sessions")
                .font(.headline)
            Text("Sessions appear here while their processes are running.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Group Section

/// One saved window: a header naming it, with its panes listed beneath. The
/// grouping mirrors how the panes were actually arranged, so a window can be
/// restored whole rather than pane by pane.
private struct GroupSection: View {
    let group: SessionBrowserModel.Group
    let onOpenGroup: () -> Void
    let onTerminateGroup: () -> Void
    let onOpen: (ZmxSessionManager.SessionInfo) -> Void
    let onTerminate: (ZmxSessionManager.SessionInfo) -> Void

    private var paneCount: String {
        let n = group.sessions.count
        return "\(n) pane\(n == 1 ? "" : "s")"
    }

    /// Up to three columns, but never more columns than panes — a two-pane
    /// window shouldn't leave a third of the row empty.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: group.isOrphanGroup
                      ? "questionmark.square.dashed"
                      : "macwindow")
                    .foregroundStyle(.secondary)

                Text(group.isOrphanGroup ? "Ungrouped" : group.name)
                    .font(.system(size: 13, weight: .semibold))

                Text(paneCount)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                if !group.isOrphanGroup {
                    Button("Open Window", action: onOpenGroup)
                }
                Button("Terminate All", role: .destructive, action: onTerminateGroup)
            }

            if group.isOrphanGroup {
                Text("Running, but no saved window refers to them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Panes lay out as a grid, mirroring how they actually sit in the
            // window. A full-width row per pane wastes horizontal space on
            // short previews and pushes later panes off screen.
            //
            // Built from plain stacks rather than LazyVGrid: inside a
            // ScrollView the lazy grid (a lazy V of lazy H rows) has to
            // estimate the size of tiles it has not built, while
            // `ScrollViewUtilities.contentFrame` feeds those estimates back as
            // the proposal. Opening a window from the browser drove that cycle
            // without converging and pinned a core
            // (LazyVStackLayout/LazyHStackLayout → measureEstimates in a
            // sample). A window's panes are a handful of tiles, so laying them
            // out eagerly is cheap and always terminates.
            let columns = min(3, max(1, group.sessions.count))
            let rows = stride(from: 0, to: group.sessions.count, by: columns).map { start in
                Array(group.sessions[start..<min(start + columns, group.sessions.count)])
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { session in
                            SessionTile(
                                session: session,
                                onOpen: { onOpen(session) },
                                onTerminate: { onTerminate(session) }
                            )
                            .frame(maxWidth: .infinity)
                        }
                        // Keep a short final row's tiles the same width as a
                        // full row's instead of stretching them.
                        if row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Session Tile

/// One pane inside a window group, shaped like the pane it represents:
/// preview on top, identity beneath. Tiles lay out in a grid so a multi-pane
/// window reads at a glance instead of as a tall stack of full-width rows.
private struct SessionTile: View {
    let session: ZmxSessionManager.SessionInfo
    let onOpen: () -> Void
    let onTerminate: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PaneWatermark(
                text: session.watermark ?? session.command ?? "shell",
                height: 132
            )

            HStack(spacing: 5) {
                Text(session.command ?? "shell")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if session.attached {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .help("Attached to a window")
                } else if !session.referenced {
                    // Live, but no saved layout points at it: exactly the
                    // state a lost pane ends up in.
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .help("Detached — no saved window refers to this")
                }

                Spacer(minLength: 0)

                if let cwd = session.shortCwd {
                    Text(cwd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Actions stay mounted so the tile height doesn't jump on hover.
            HStack(spacing: 6) {
                Button("Open", action: onOpen)
                Button("Kill", role: .destructive, action: onTerminate)
                Spacer(minLength: 0)
                Text(session.name)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            .controlSize(.small)
            .opacity(hovering ? 1 : 0.3)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    session.attached ? Color.accentColor.opacity(0.5)
                                     : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Watermark

/// A pane's watermark, rendered the way the pane itself shows it: large, low
/// contrast, centred on the terminal background.
///
/// This replaced a scrollback thumbnail. Raw `zmx history` output is dominated
/// by the agent's prompt box and status bar, so every tile looked alike; the
/// watermark is the label the pane already carries and identifies it instantly.
private struct PaneWatermark: View {
    let text: String
    var height: CGFloat = 132

    /// Point size for the watermark, chosen from the label's length instead of
    /// by `minimumScaleFactor`.
    ///
    /// `minimumScaleFactor` makes the text's size depend on the width it is
    /// offered, while `.frame(maxWidth: .infinity)` makes the width depend on
    /// the layout — so SwiftUI searched for a scale that satisfied both and
    /// re-ran text metrics for every candidate, per tile, inside the grid's
    /// lazy stack. With a browser full of sessions that never converged and
    /// pinned a core (sampled as _FlexFrameLayout → _FixedSizeLayout →
    /// StyledTextLayoutEngine → NSAttributedString.MetricsCache).
    ///
    /// Watermarks are short labels ("trm", "gooshi", "fasmac2"), so picking the
    /// size from the character count gives the same visual result with a single
    /// measurement and no feedback between size and width.
    private var fontSize: CGFloat {
        switch text.count {
        case 0...4: return 34
        case 5...7: return 26
        case 8...11: return 20
        case 12...16: return 15
        default: return 12
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.22))
            .lineLimit(1)
            // Truncation rather than scaling: the size is already chosen above,
            // so an unusually long label clips instead of reopening the
            // width-versus-size negotiation.
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
