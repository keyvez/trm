import SwiftUI
import GhosttyKit
import UniformTypeIdentifiers

/// Termania-style border colors and metrics.
///
/// These match the defaults from `src/termania/config.zig`:
///   border:          #30363d
///   border_focused:  #58a6ff
///   border_radius:   8
///   gap:             4
enum TrmBorder {
    static let color        = Color(red: 0x30/255, green: 0x36/255, blue: 0x3d/255)
    static let focusedColor = Color(red: 0x58/255, green: 0xa6/255, blue: 0xff/255)
    static let stackDropColor = Color(red: 0x58/255, green: 0xa6/255, blue: 0xff/255).opacity(0.6)
    /// Attention ring color — blue ring like cmux notification rings.
    static let attentionColor = Color(red: 0x58/255, green: 0xa6/255, blue: 0xff/255)
    static let radius: CGFloat  = 8
    static let width: CGFloat   = 1
    /// Width of the attention ring border (thicker than normal border).
    static let attentionWidth: CGFloat = 2.5
}

/// A grid-based layout for terminal surfaces within a single tab.
///
/// Instead of a binary split tree, this arranges panes in a jagged grid
/// where each row can have a different number of columns. All rows share equal height;
/// within a row all cells share equal width.
///
/// Each pane gets a termania-style rounded border that highlights blue when focused.
struct TrmGridView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    /// The panes to display, in row-major order.
    let panes: [GridPane]

    /// Number of columns in each row (length = number of rows).
    /// The sum of all values must equal panes.count.
    let rowCols: [Int]

    /// Gap between panes in points.
    let gap: CGFloat

    /// Outer padding in points.
    let padding: CGFloat

    /// The live summary manager for per-pane LLM summaries.
    @ObservedObject var liveSummaryManager: LiveSummaryManager

    /// The service plugin registry for rendering service plugin overlays.
    @ObservedObject var servicePluginRegistry: ServicePluginRegistry

    /// Set of stable pane IDs that need user attention (e.g. agent waiting for input).
    /// Drives the animated notification ring around the pane border.
    var attentionPaneIds: Set<Int> = []

    /// The currently peeked sub-pane (expanded overlay), or nil.
    var peekedPane: ObjectIdentifier? = nil

    /// Callback to move a pane into its own window.
    var onDetachPane: ((GridPane) -> Void)? = nil

    /// Callback to move a pane from this window into another window.
    var onAttachPane: ((GridPane) -> Void)? = nil

    /// Callback to close a webview pane.
    var onCloseWebviewPane: ((WebViewPane) -> Void)? = nil

    /// Callback to close a utility plugin pane.
    var onClosePluginPane: ((PluginPane) -> Void)? = nil

    /// Callback to move a pane in a direction (left/right/up/down).
    var onMovePane: ((GridPane, BaseTerminalController.PaneMoveDirection) -> Void)? = nil

    /// Callback to stack a source pane onto a target pane.
    var onStackPane: ((GridPane, GridPane) -> Void)? = nil

    /// Callback to swap two panes' positions in the grid.
    var onSwapPane: ((GridPane, GridPane) -> Void)? = nil

    /// Callback to unstack (restore) a pane from its stack.
    var onUnstackPane: ((GridPane) -> Void)? = nil

    /// Callback to peek (expand) a stacked sub-pane.
    var onPeekPane: ((GridPane) -> Void)? = nil

    /// Callback to dismiss the peek overlay.
    var onDismissPeek: (() -> Void)? = nil

    /// Fractional heights for each row (parallel to rowCols, sums to 1.0).
    var rowHeightFractions: [CGFloat] = []

    /// Fractional column widths per row (parallel to rowCols, each inner array sums to 1.0).
    var colWidthFractions: [[CGFloat]] = []

    /// Called when the user drags a horizontal divider between rows.
    /// `row` is the index of the upper row; `fraction` is the new height fraction for that row.
    var onResizeRow: ((Int, CGFloat) -> Void)? = nil

    /// Called when the user drags a vertical divider between columns in a row.
    /// `row`/`col` identify the left column; `fraction` is the new width fraction for that column.
    var onResizeCol: ((Int, Int, CGFloat) -> Void)? = nil

    /// Per-stack sub-pane height fractions, keyed by the stack pane's ObjectIdentifier.
    /// Each value is an array (length == number of children) summing to 1.0.
    var stackHeightFractions: [ObjectIdentifier: [CGFloat]] = [:]

    /// Called when the user drags a divider between sub-panes in a stack.
    /// `stackID` identifies the stack cell; `subIdx` is the upper sub-pane index;
    /// `fraction` is the new height fraction for that sub-pane.
    var onResizeStack: ((ObjectIdentifier, Int, CGFloat) -> Void)? = nil

    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface

    /// Bumped when a watermark changes to force the overlay to re-evaluate.
    @State private var watermarkVersion: Int = 0

    /// The pane currently being hovered during a drag-and-drop operation.
    @State private var dropHighlightPaneId: ObjectIdentifier?

    /// Whether the current drop operation is in "stack" mode (Option key held).
    /// When false, dropping swaps pane positions instead of stacking.
    @State private var dropIsStackMode: Bool = false

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: Trm.watermarkDidChange)) { _ in
                watermarkVersion += 1
            }
            .onChange(of: focusedSurfaceIdentity) { newIdentity in
                guard panes.count > 1, let newIdentity else { return }
                if let pid = findPaneId(matching: newIdentity, in: panes) {
                    NotificationCenter.default.post(
                        name: Trm.highlightPane,
                        object: nil,
                        userInfo: ["paneId": pid]
                    )
                }
            }
    }

    /// An identity value derived from the focused surface pointer so
    /// `.onChange(of:)` can detect focus changes.
    private var focusedSurfaceIdentity: ObjectIdentifier? {
        focusedSurface.map { ObjectIdentifier($0) }
    }

    /// Recursively search panes (including stack children) for a surface
    /// matching the given identity and return its paneId.
    private func findPaneId(matching identity: ObjectIdentifier, in panes: [GridPane]) -> Int? {
        for pane in panes {
            switch pane {
            case .terminal(let surface):
                if ObjectIdentifier(surface) == identity {
                    return surface.paneId
                }
            case .stack(let children):
                if let pid = findPaneId(matching: identity, in: children) {
                    return pid
                }
            default:
                break
            }
        }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if panes.isEmpty {
            EmptyView()
        } else if panes.count == 1 {
            // Single pane — no grid chrome, just the pane
            paneView(panes[0], index: 0)
                .overlay(
                    dropPlaceholder(isVisible: dropHighlightPaneId == panes[0].id, isStackMode: dropIsStackMode, stackCount: 1)
                        .allowsHitTesting(false)
                )
                .onDrop(of: [.ghosttySurfaceId], delegate: PaneStackDropDelegate(
                    targetPane: panes[0],
                    allPanes: panes,
                    onStack: onStackPane,
                    onSwap: onSwapPane,
                    dropHighlightPaneId: $dropHighlightPaneId,
                    dropIsStackMode: $dropIsStackMode
                ))
                .contextMenu {
                    if let pid = paneIdForPane(panes[0]) {
                        pluginsMenu(forPaneId: pid)
                    }
                }
        } else {
            ZStack {
                GeometryReader { geo in
                    let rows = rowLayout
                    let nRows = rows.count
                    // Normalize height fractions (fall back to equal if not set or wrong length)
                    let rawHF = rowHeightFractions
                    let heightFracs: [CGFloat] = (rawHF.count == nRows && rawHF.allSatisfy { $0 > 0 })
                        ? rawHF
                        : Array(repeating: 1.0 / CGFloat(nRows), count: nRows)

                    let availH = geo.size.height - padding * 2 - gap * CGFloat(nRows - 1)
                    let availW = geo.size.width - padding * 2

                    // Pre-compute row Y prefix sums (O(n)) so ForEach closures don't each do O(n) reduce.
                    let rowHeights: [CGFloat] = heightFracs.map { availH * $0 }
                    let rowYOffsets: [CGFloat] = prefixSums(rowHeights, spacing: gap)

                    ZStack(alignment: .topLeading) {
                        // Pane cells
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                            let nCols = row.count
                            let rawCF = colWidthFractions.indices.contains(rowIdx) ? colWidthFractions[rowIdx] : []
                            let colFracs: [CGFloat] = (rawCF.count == nCols && rawCF.allSatisfy { $0 > 0 })
                                ? rawCF
                                : Array(repeating: 1.0 / CGFloat(nCols), count: nCols)
                            let rowH = rowHeights[rowIdx]
                            let rowY = padding + rowYOffsets[rowIdx]
                            let rowAvailW = availW - gap * CGFloat(nCols - 1)

                            // Pre-compute column X prefix sums for this row.
                            let colWidths: [CGFloat] = colFracs.map { rowAvailW * $0 }
                            let colXOffsets: [CGFloat] = prefixSums(colWidths, spacing: gap)

                            ForEach(Array(row.enumerated()), id: \.element.id) { colIdx, pane in
                                let flatIndex = flatIndexFor(row: rowIdx, col: colIdx)
                                let colW = colWidths[colIdx]
                                let colX = padding + colXOffsets[colIdx]

                                paneCellView(pane, flatIndex: flatIndex, row: rowIdx, col: colIdx)
                                    .frame(width: colW, height: rowH)
                                    .position(x: colX + colW / 2, y: rowY + rowH / 2)
                            }
                        }

                        // Horizontal dividers (between rows)
                        if onResizeRow != nil {
                            ForEach(0..<(nRows - 1), id: \.self) { rowIdx in
                                let rowY = padding + rowYOffsets[rowIdx + 1]
                                let divH: CGFloat = max(gap, 12)
                                let hitY = rowY - gap / 2 - (divH - gap) / 2
                                let topH = rowHeights[rowIdx]
                                let botH = rowHeights[rowIdx + 1]
                                let combinedH = topH + gap + botH
                                let curFrac = combinedH > 0 ? topH / combinedH : 0.5

                                PaneDivider(
                                    axis: .horizontal,
                                    currentFraction: curFrac,
                                    combinedLength: combinedH,
                                    onDrag: { fraction in
                                        onResizeRow?(rowIdx, fraction)
                                    }
                                )
                                .frame(width: availW, height: divH)
                                .position(x: padding + availW / 2, y: hitY + divH / 2)
                                .allowsHitTesting(onResizeRow != nil)
                            }
                        }

                        // Vertical dividers (between columns within each row)
                        if onResizeCol != nil {
                            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                                let nCols = row.count
                                let rawCF = colWidthFractions.indices.contains(rowIdx) ? colWidthFractions[rowIdx] : []
                                let colFracs: [CGFloat] = (rawCF.count == nCols && rawCF.allSatisfy { $0 > 0 })
                                    ? rawCF
                                    : Array(repeating: 1.0 / CGFloat(nCols), count: nCols)
                                let rowAvailW = availW - gap * CGFloat(nCols - 1)
                                let rowH = rowHeights[rowIdx]
                                let rowY = padding + rowYOffsets[rowIdx]

                                // Pre-compute column X prefix sums for divider placement.
                                let colWidths: [CGFloat] = colFracs.map { rowAvailW * $0 }
                                let colXOffsets: [CGFloat] = prefixSums(colWidths, spacing: gap)

                                ForEach(0..<(nCols - 1), id: \.self) { colIdx in
                                    let colX = padding + colXOffsets[colIdx + 1]
                                    let divW: CGFloat = max(gap, 12)
                                    let hitX = colX - gap / 2 - (divW - gap) / 2
                                    let leftW = colWidths[colIdx]
                                    let rightW = colWidths[colIdx + 1]
                                    let combinedW = leftW + gap + rightW
                                    let curFrac = combinedW > 0 ? leftW / combinedW : 0.5

                                    PaneDivider(
                                        axis: .vertical,
                                        currentFraction: curFrac,
                                        combinedLength: combinedW,
                                        onDrag: { fraction in
                                            onResizeCol?(rowIdx, colIdx, fraction)
                                        }
                                    )
                                    .frame(width: divW, height: rowH)
                                    .position(x: hitX + divW / 2, y: rowY + rowH / 2)
                                    .allowsHitTesting(onResizeCol != nil)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Peek overlay
                if let peekedID = peekedPane {
                    peekOverlay(for: peekedID)
                }
            }
        }
    }

    /// Wraps a single pane cell with border, context menu, drag source, and drop target.
    @ViewBuilder
    private func paneCellView(_ pane: GridPane, flatIndex: Int, row: Int, col: Int) -> some View {
        let isDropTarget = dropHighlightPaneId == pane.id
        // How many children the cell will have after the drop.
        let existingCount = pane.stackChildren?.count ?? 1
        let needsAttention = paneNeedsAttention(pane)

        paneView(pane, index: flatIndex)
            .cornerRadius(TrmBorder.radius)
            .overlay(
                RoundedRectangle(cornerRadius: TrmBorder.radius, style: .continuous)
                    .strokeBorder(
                        borderColor(for: pane),
                        lineWidth: needsAttention ? TrmBorder.attentionWidth : TrmBorder.width
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                // Notification ring glow — animated blue ring around panes needing attention
                NotificationRingView(isActive: needsAttention)
                    .allowsHitTesting(false)
            )
            .overlay(
                // BonSplit-style drop placeholder — shows where the pane will land
                dropPlaceholder(isVisible: isDropTarget, isStackMode: dropIsStackMode, stackCount: existingCount)
                    .allowsHitTesting(false)
            )
            .contextMenu {
                if let onPeekPane {
                    Button {
                        onPeekPane(pane)
                    } label: {
                        Label("Peek Pane", systemImage: "rectangle.expand.vertical")
                    }
                    Divider()
                }
                paneMoveMenu(pane: pane, row: row, col: col)
                if let pid = paneIdForPane(pane) {
                    Divider()
                    pluginsMenu(forPaneId: pid)
                }
            }
            .onDrop(of: [.ghosttySurfaceId], delegate: PaneStackDropDelegate(
                targetPane: pane,
                allPanes: panes,
                onStack: onStackPane,
                onSwap: onSwapPane,
                dropHighlightPaneId: $dropHighlightPaneId,
                dropIsStackMode: $dropIsStackMode
            ))
    }

    /// Animated drop placeholder.
    /// - Stack mode (Option held): shrinks to the bottom slot where the pane will land after stacking.
    /// - Swap mode (default): full-cell highlight indicating a position swap.
    @ViewBuilder
    private func dropPlaceholder(isVisible: Bool, isStackMode: Bool, stackCount: Int) -> some View {
        GeometryReader { geo in
            let inset: CGFloat = 4
            let fullW = geo.size.width - inset * 2
            let fullH = geo.size.height - inset * 2

            let totalAfterDrop = CGFloat(stackCount + 1)
            let slotH = geo.size.height / totalAfterDrop - inset

            // Stack mode: animate to bottom slot. Swap mode: full cell highlight.
            let targetW = fullW
            let targetH = isVisible
                ? (isStackMode ? slotH : fullH)
                : fullH
            let targetY = isVisible && isStackMode
                ? geo.size.height - (slotH / 2) - inset
                : geo.size.height / 2

            let fillColor = isStackMode
                ? Color.accentColor.opacity(0.15)
                : Color.orange.opacity(0.12)
            let strokeColor = isStackMode
                ? Color.accentColor.opacity(0.6)
                : Color.orange.opacity(0.5)

            RoundedRectangle(cornerRadius: TrmBorder.radius - 2, style: .continuous)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: TrmBorder.radius - 2, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 2)
                )
                .frame(width: targetW, height: targetH)
                .position(x: geo.size.width / 2, y: targetY)
                .opacity(isVisible ? 1 : 0)
                .animation(.spring(duration: 0.35, bounce: 0.12), value: isVisible)
                .animation(.spring(duration: 0.35, bounce: 0.12), value: isStackMode)
        }
    }

    /// Dispatch to the appropriate view for each pane type.
    ///
    /// Returns `AnyView` to break the recursive type expansion from the
    /// `.stack` case that otherwise hangs the Swift type checker in release builds.
    private func paneView(_ pane: GridPane, index: Int) -> AnyView {
        switch pane {
        case .terminal(let surface):
            return AnyView(
                terminalPaneView(surface, index: index, paneId: surface.paneId ?? index)
            )
        case .webview(let webviewPane):
            return AnyView(webviewPaneView(webviewPane))
        case .plugin(let pluginPane):
            return AnyView(pluginPaneView(pluginPane))
        case .stack(let children):
            return AnyView(stackedPaneView(children, stackID: pane.id))
        }
    }

    /// A single terminal pane: surface with optional watermark and live summary overlays.
    /// - `index`: the flat grid index (position in `gridPanes`)
    /// - `paneId`: the stable Zig pane ID (monotonic u32, survives pane close/reorder)
    @ViewBuilder
    private func terminalPaneView(_ surface: Ghostty.SurfaceView, index: Int, paneId: Int) -> some View {
        let isPeeked = peekedPane == ObjectIdentifier(surface)
        VStack(spacing: 0) {
            // No drag bar for non-stacked panes — peek via context menu
            // "Peek Pane", dismiss by clicking the scrim or pressing Escape.

            if isPeeked {
                // Placeholder while this pane is shown in the peek overlay.
                // An NSView can only have one superview, so we must not
                // render InspectableSurface here AND in the peek overlay.
                Color.black.opacity(0.6)
                    .overlay(watermarkOverlay(forPaneId: paneId))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Ghostty.InspectableSurface(
                    surfaceView: surface,
                    isSplit: panes.count > 1
                )
                .overlay(
                    paneControls(for: .terminal(surface)),
                    alignment: .topTrailing
                )
                .overlay(
                    watermarkOverlay(forPaneId: paneId)
                )
                .overlay(
                    servicePluginOverlays(forPaneId: paneId)
                )
                .overlay(
                    liveSummaryOverlay(forPaneId: paneId),
                    alignment: .bottom
                )
            }
        }
        .onHover { hovering in
            NotificationCenter.default.post(
                name: Trm.hoverPane,
                object: nil,
                userInfo: ["paneId": paneId, "hovering": hovering]
            )
        }
    }

    /// A webview pane with navigation controls, URL bar, and action buttons.
    @ViewBuilder
    private func webviewPaneView(_ pane: WebViewPane) -> some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 4) {
                // Back / Forward
                Button(action: { pane.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(pane.canGoBack ? .secondary : .secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(!pane.canGoBack)
                .help("Back")

                Button(action: { pane.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(pane.canGoForward ? .secondary : .secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(!pane.canGoForward)
                .help("Forward")

                // Reload / Stop
                if pane.isLoading {
                    Button(action: { pane.webView.stopLoading() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop loading")
                } else {
                    Button(action: { pane.reload() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reload")
                }

                // URL bar
                WebViewURLBar(pane: pane)

                // Action buttons
                paneButtons(for: .webview(pane))
                Button(action: { pane.openInDefaultBrowser() }) {
                    Image(systemName: "safari")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Open in default browser")
                Button(action: { onCloseWebviewPane?(pane) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))

            WebViewPaneView(pane: pane)
        }
    }

    /// A utility plugin pane rendered with a small control toolbar.
    @ViewBuilder
    private func pluginPaneView(_ pane: PluginPane) -> some View {
        PluginPaneContainerView(pane: pane, onClose: onClosePluginPane)
    }

    // MARK: - Stacked Pane Rendering

    /// Render a vertical stack of sub-panes sharing one grid cell.
    @ViewBuilder
    private func stackedPaneView(_ children: [GridPane], stackID: ObjectIdentifier) -> some View {
        let n = children.count
        let subGap: CGFloat = 1
        let rawFracs = stackHeightFractions[stackID] ?? []
        let fracs: [CGFloat] = (rawFracs.count == n && rawFracs.allSatisfy { $0 > 0 })
            ? rawFracs
            : Array(repeating: 1.0 / CGFloat(n), count: n)

        GeometryReader { geo in
            let availH = geo.size.height - subGap * CGFloat(n - 1)
            let subHeights: [CGFloat] = fracs.map { availH * $0 }
            let subYOffsets: [CGFloat] = prefixSums(subHeights, spacing: subGap)

            ZStack(alignment: .topLeading) {
                // Sub-pane cells
                ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                    let subH = subHeights[idx]
                    let subY = subYOffsets[idx]

                    VStack(spacing: 0) {
                        // Only the first sub-pane gets a drag bar.
                        if idx == 0, case .terminal(let surface) = child {
                            PaneDragBar(surface: surface, onPeek: {
                                if peekedPane == child.id {
                                    onDismissPeek?()
                                } else {
                                    onPeekPane?(child)
                                }
                            })
                            .frame(height: 6)
                        }

                        stackChildContent(child)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .contextMenu {
                        Button {
                            onUnstackPane?(child)
                        } label: {
                            Label("Restore Pane", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        if let pid = paneIdForPane(child) {
                            SwiftUI.Divider()
                            pluginsMenu(forPaneId: pid)
                        }
                    }
                    .frame(width: geo.size.width, height: subH)
                    .position(x: geo.size.width / 2, y: subY + subH / 2)
                }

                // Horizontal dividers between sub-panes
                ForEach(0..<(n - 1), id: \.self) { idx in
                    let divH: CGFloat = max(subGap, 12)
                    let divY = subYOffsets[idx + 1] - subGap / 2 - (divH - subGap) / 2
                    let topH = subHeights[idx]
                    let botH = subHeights[idx + 1]
                    let combinedH = topH + subGap + botH
                    let curFrac = combinedH > 0 ? topH / combinedH : 0.5

                    PaneDivider(
                        axis: .horizontal,
                        currentFraction: curFrac,
                        combinedLength: combinedH,
                        onDrag: { fraction in
                            onResizeStack?(stackID, idx, fraction)
                        }
                    )
                    .frame(width: geo.size.width, height: divH)
                    .position(x: geo.size.width / 2, y: divY + divH / 2)
                    .allowsHitTesting(onResizeStack != nil)
                }
            }
        }
    }

    /// Render the content of a single child within a stack.
    ///
    /// Returns `AnyView` to break the recursive type expansion that otherwise
    /// causes the Swift type checker to hang during release-mode compilation.
    ///
    /// When a pane is being peeked (shown in the overlay), we render a
    /// placeholder here instead of the live surface. An NSView can only have
    /// one superview, so rendering the same `SurfaceView` in both the stack
    /// cell and the peek overlay would cause the peek to steal the view, and
    /// dismissing the peek would leave the stack cell empty.
    private func stackChildContent(_ pane: GridPane) -> AnyView {
        // If this pane is currently being peeked, show a placeholder so the
        // live NSView is only rendered in the peek overlay.
        if peekedPane == pane.id {
            return AnyView(
                Color.black.opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        switch pane {
        case .terminal(let surface):
            let paneId = surface.paneId ?? 0
            return AnyView(Ghostty.InspectableSurface(
                surfaceView: surface,
                isSplit: true
            )
            .overlay(watermarkOverlay(forPaneId: paneId))
            .overlay(servicePluginOverlays(forPaneId: paneId))
            .overlay(liveSummaryOverlay(forPaneId: paneId), alignment: .bottom)
            .onHover { hovering in
                NotificationCenter.default.post(
                    name: Trm.hoverPane,
                    object: nil,
                    userInfo: ["paneId": paneId, "hovering": hovering]
                )
            }
            )
        case .webview(let webviewPane):
            return AnyView(webviewPaneView(webviewPane))
        case .plugin(let pluginPane):
            return AnyView(pluginPaneView(pluginPane))
        case .stack:
            // Nested stacks not supported — flatten would have happened at model level
            return AnyView(EmptyView())
        }
    }

    /// The peek overlay: shows a stacked sub-pane at half window width, full height.
    @ViewBuilder
    private func peekOverlay(for peekedID: ObjectIdentifier) -> some View {
        // Find the peeked surface across all panes (including stack children).
        let peekedSurface: Ghostty.SurfaceView? = findSurface(byID: peekedID)

        // Background scrim — click to dismiss
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture {
                onDismissPeek?()
            }

        // The expanded pane
        GeometryReader { geo in
            HStack {
                Spacer()
                if let surface = peekedSurface {
                    Ghostty.InspectableSurface(
                        surfaceView: surface,
                        isSplit: false
                    )
                    .overlay(watermarkOverlay(forPaneId: surface.paneId ?? 0))
                    .contextMenu {
                        Button {
                            onDismissPeek?()
                        } label: {
                            Label("Put Back", systemImage: "arrow.uturn.backward")
                        }
                    }
                    .frame(width: geo.size.width * 0.5, height: geo.size.height)
                    .cornerRadius(TrmBorder.radius)
                    .overlay(
                        RoundedRectangle(cornerRadius: TrmBorder.radius, style: .continuous)
                            .strokeBorder(TrmBorder.focusedColor, lineWidth: 2)
                            .allowsHitTesting(false)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 20, x: -5, y: 0)
                }
                Spacer()
            }
        }
        .transition(.opacity)
    }

    /// Find a terminal surface by ObjectIdentifier across all panes and stack children.
    private func findSurface(byID id: ObjectIdentifier) -> Ghostty.SurfaceView? {
        for pane in panes {
            switch pane {
            case .terminal(let surface):
                if ObjectIdentifier(surface) == id { return surface }
            case .stack(let children):
                for child in children {
                    if case .terminal(let surface) = child,
                       ObjectIdentifier(surface) == id {
                        return surface
                    }
                }
            default:
                break
            }
        }
        return nil
    }

    @ViewBuilder
    private func paneControls(for pane: GridPane) -> some View {
        if onDetachPane != nil || onAttachPane != nil {
            HStack(spacing: 4) {
                paneButtons(for: pane)
            }
            .padding(6)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(8)
        }
    }

    @ViewBuilder
    private func paneButtons(for pane: GridPane) -> some View {
        if let onDetachPane {
            Button(action: { onDetachPane(pane) }) {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Move pane to a new window")
        }
        if let onAttachPane {
            Button(action: { onAttachPane(pane) }) {
                Image(systemName: "arrow.down.backward.square")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Move pane to another window")
        }
    }

    /// Returns a live summary overlay if the manager is enabled and has content for this pane.
    @ViewBuilder
    private func liveSummaryOverlay(forPaneId paneId: Int) -> some View {
        if liveSummaryManager.isEnabled,
           let summary = liveSummaryManager.summaries[paneId], !summary.isEmpty {
            VStack {
                Spacer()
                LiveSummaryOverlayView(
                    summary: summary,
                    isLoading: liveSummaryManager.isLoading[paneId] ?? false
                )
            }
        } else if liveSummaryManager.isEnabled,
                  liveSummaryManager.isLoading[paneId] == true {
            VStack {
                Spacer()
                LiveSummaryOverlayView(
                    summary: "Summarizing...",
                    isLoading: true
                )
            }
        }
    }

    /// Returns overlay views from all registered service plugin overlay providers,
    /// skipping any that the user has disabled for this pane.
    @ViewBuilder
    private func servicePluginOverlays(forPaneId paneId: Int) -> some View {
        ForEach(Array(servicePluginRegistry.overlayProviders.enumerated()), id: \.offset) { _, provider in
            if servicePluginRegistry.isPluginDisabled(provider.pluginId, forPaneId: paneId) {
                EmptyView()
            } else if let overlay = provider.overlayView(forPaneId: paneId) {
                overlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: provider.overlayAlignment)
            }
        }
    }

    /// Returns a watermark overlay if one is set for this pane index.
    @ViewBuilder
    private func watermarkOverlay(forPaneId paneId: Int) -> some View {
        // Reference watermarkVersion so SwiftUI re-evaluates when it changes.
        let _ = watermarkVersion
        if let text = Trm.shared.watermark(forPaneId: UInt32(paneId)), !text.isEmpty {
            WatermarkView(text: text, cellHeight: 14, paneId: paneId)
        }
    }

    @ViewBuilder
    private func paneMoveMenu(pane: GridPane, row: Int, col: Int) -> some View {
        let rowCount = rowCols.count
        let colCount = row < rowCols.count ? rowCols[row] : 1

        if let onMovePane {
            Button {
                onMovePane(pane, .left)
            } label: {
                Label("Move Left", systemImage: "arrow.left")
            }
            .disabled(col == 0)

            Button {
                onMovePane(pane, .right)
            } label: {
                Label("Move Right", systemImage: "arrow.right")
            }
            .disabled(col >= colCount - 1)

            Button {
                onMovePane(pane, .up)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(row == 0)

            Button {
                onMovePane(pane, .down)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(row >= rowCount - 1)
        }
    }

    /// Extract the stable pane ID from a terminal pane, returning nil for non-terminal panes.
    private func paneIdForPane(_ pane: GridPane) -> Int? {
        switch pane {
        case .terminal(let surface):
            return surface.paneId
        case .stack(let children):
            // Use the first child's pane ID as the stack's pane ID.
            if let first = children.first {
                return paneIdForPane(first)
            }
            return nil
        default:
            return nil
        }
    }

    /// A "Plugins" submenu listing all registered service plugins with a
    /// checkmark indicating whether they're active (not disabled) for the pane.
    @ViewBuilder
    private func pluginsMenu(forPaneId paneId: Int) -> some View {
        let sortedPlugins = servicePluginRegistry.plugins.values
            .sorted(by: { $0.displayName < $1.displayName })
        Menu("Plugins") {
            ForEach(sortedPlugins.map { $0.pluginId }, id: \.self) { pluginId in
                if let plugin = servicePluginRegistry.plugins[pluginId] {
                    let disabled = servicePluginRegistry.isPluginDisabled(pluginId, forPaneId: paneId)
                    Button {
                        servicePluginRegistry.togglePlugin(pluginId, forPaneId: paneId)
                    } label: {
                        Label(plugin.displayName, systemImage: disabled ? "circle" : "checkmark.circle.fill")
                    }
                }
            }
        }
    }

    private func borderColor(for pane: GridPane) -> Color {
        // Attention ring takes priority over focus for border color
        if paneNeedsAttention(pane) {
            return TrmBorder.attentionColor
        }
        switch pane {
        case .terminal(let surface):
            if let focused = focusedSurface, focused === surface {
                return TrmBorder.focusedColor
            }
            return TrmBorder.color
        case .stack(let children):
            // If any child in the stack is focused, highlight the whole cell.
            if let focused = focusedSurface {
                for child in children {
                    if case .terminal(let s) = child, s === focused {
                        return TrmBorder.focusedColor
                    }
                }
            }
            return TrmBorder.color
        case .webview, .plugin:
            return TrmBorder.color
        }
    }

    /// Check if a pane (or any child in a stack) needs user attention.
    private func paneNeedsAttention(_ pane: GridPane) -> Bool {
        switch pane {
        case .terminal(let surface):
            if let pid = surface.paneId {
                return attentionPaneIds.contains(pid)
            }
            return false
        case .stack(let children):
            for child in children {
                if paneNeedsAttention(child) { return true }
            }
            return false
        case .webview, .plugin:
            return false
        }
    }

    /// Convert (row, col) to flat index.
    private func flatIndexFor(row: Int, col: Int) -> Int {
        var offset = 0
        for r in 0..<row {
            if r < rowCols.count {
                offset += rowCols[r]
            }
        }
        return offset + col
    }

    /// Break the flat panes array into rows based on rowCols.
    private var rowLayout: [[GridPane]] {
        var result: [[GridPane]] = []
        var offset = 0
        for colCount in rowCols {
            let end = min(offset + colCount, panes.count)
            if offset < end {
                result.append(Array(panes[offset..<end]))
            }
            offset = end
        }
        return result
    }
}

// MARK: - Notification Ring

/// An animated blue glow ring around panes that need user attention.
/// Mimics cmux's notification ring: a subtle pulsing border glow.
private struct NotificationRingView: View {
    let isActive: Bool

    @State private var glowPhase: Bool = false

    var body: some View {
        if isActive {
            RoundedRectangle(cornerRadius: TrmBorder.radius, style: .continuous)
                .strokeBorder(
                    TrmBorder.attentionColor.opacity(glowPhase ? 0.8 : 0.4),
                    lineWidth: TrmBorder.attentionWidth
                )
                .shadow(color: TrmBorder.attentionColor.opacity(glowPhase ? 0.5 : 0.2), radius: glowPhase ? 8 : 4)
                .animation(
                    .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: glowPhase
                )
                .onAppear { glowPhase = true }
        }
    }
}

// MARK: - Stack Drag Bar

/// A thin drag handle at the top of each sub-pane in a stack.
/// Double-tap triggers peek mode.
private struct StackDragBar: View {
    var onPeek: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            // Grip dots
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.secondary.opacity(isHovering ? 0.6 : 0.3))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Double-click to peek")
    }
}

// MARK: - Pane Drag Bar

/// A thin drag bar at the top of a top-level terminal pane.
/// Uses an AppKit NSView underneath so that drag initiation works reliably
/// next to GPU-rendered terminal surfaces (SwiftUI `.draggable` gets
/// swallowed by the NSView-backed surface).
private struct PaneDragBar: NSViewRepresentable {
    let surface: Ghostty.SurfaceView
    var onPeek: (() -> Void)? = nil

    func makeNSView(context: Context) -> DragBarNSView {
        let view = DragBarNSView()
        view.surface = surface
        view.onPeek = onPeek
        return view
    }

    func updateNSView(_ nsView: DragBarNSView, context: Context) {
        nsView.surface = surface
        nsView.onPeek = onPeek
    }
}

/// AppKit view that renders grip dots and initiates an NSDraggingSession on drag.
private final class DragBarNSView: NSView, NSDraggingSource {
    var surface: Ghostty.SurfaceView?
    var onPeek: (() -> Void)?
    private var isHovering = false
    private var dragStart: NSPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dotAlpha: CGFloat = isHovering ? 0.6 : 0.3
        let dotColor = NSColor.secondaryLabelColor.withAlphaComponent(dotAlpha)
        let dotSize: CGFloat = 3
        let spacing: CGFloat = 3
        let totalWidth = dotSize * 3 + spacing * 2
        var x = (bounds.width - totalWidth) / 2
        let y = (bounds.height - dotSize) / 2

        for _ in 0..<3 {
            let rect = NSRect(x: x, y: y, width: dotSize, height: dotSize)
            dotColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            x += dotSize + spacing
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 6)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.openHand.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            onPeek?()
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface, let start = dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x
        let dy = current.y - start.y
        guard dx * dx + dy * dy > 9 else { return } // 3pt threshold

        dragStart = nil

        guard let item = surface.pasteboardItem() else { return }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(
            NSRect(x: 0, y: 0, width: 120, height: 80),
            contents: NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                NSColor.separatorColor.setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
                path.lineWidth = 1.5
                path.stroke()
                return true
            }
        )

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }
}

// MARK: - Pane Stack Drop Delegate

/// Drop delegate that handles stacking a dragged terminal pane onto a target cell.
/// Shows a visual highlight on the target pane during hover.
struct PaneStackDropDelegate: DropDelegate {
    let targetPane: GridPane
    let allPanes: [GridPane]
    let onStack: ((GridPane, GridPane) -> Void)?
    let onSwap: ((GridPane, GridPane) -> Void)?
    @Binding var dropHighlightPaneId: ObjectIdentifier?
    @Binding var dropIsStackMode: Bool

    func validateDrop(info: DropInfo) -> Bool {
        // Accept if we have either callback.
        guard onStack != nil || onSwap != nil else { return false }
        return info.hasItemsConforming(to: [.ghosttySurfaceId])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            dropHighlightPaneId = targetPane.id
            // Default is stack mode; Option switches to swap.
            dropIsStackMode = !NSEvent.modifierFlags.contains(.option)
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if dropHighlightPaneId == targetPane.id {
                dropHighlightPaneId = nil
            }
            dropIsStackMode = false
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        // Default: stack the pane (create sub-pane). Option+drop = swap positions.
        let swapMode = NSEvent.modifierFlags.contains(.option)

        withAnimation(.easeInOut(duration: 0.15)) {
            dropHighlightPaneId = nil
            dropIsStackMode = false
        }

        let callback: ((GridPane, GridPane) -> Void)?
        if swapMode {
            callback = onSwap
        } else {
            callback = onStack
        }
        guard let callback else { return false }

        // Load the surface ID from the drop payload.
        let providers = info.itemProviders(for: [.ghosttySurfaceId])
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.ghosttySurfaceId.identifier) { data, _ in
            guard let data, data.count == 16 else { return }
            let uuid = data.withUnsafeBytes { buffer -> UUID in
                buffer.load(as: UUID.self)
            }

            DispatchQueue.main.async {
                let sourcePane = self.findPane(byUUID: uuid)
                guard let sourcePane else { return }
                guard sourcePane.id != self.targetPane.id else { return }
                callback(sourcePane, self.targetPane)
            }
        }

        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Stack is default; Option switches to swap. Update live as modifier changes.
        let isStack = !NSEvent.modifierFlags.contains(.option)
        if isStack != dropIsStackMode {
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.15)) {
                    dropIsStackMode = isStack
                }
            }
        }
        return DropProposal(operation: .move)
    }

    /// Find a GridPane matching a surface UUID.
    private func findPane(byUUID uuid: UUID) -> GridPane? {
        for pane in allPanes {
            switch pane {
            case .terminal(let surface):
                if surface.id == uuid { return pane }
            case .stack(let children):
                for child in children {
                    if case .terminal(let surface) = child, surface.id == uuid {
                        return child
                    }
                }
            default:
                break
            }
        }
        return nil
    }
}

private struct PluginPaneContainerView: View {
    @ObservedObject var pane: PluginPane
    var onClose: ((PluginPane) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(pane.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button(action: { pane.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                if let onClose {
                    Button(action: { onClose(pane) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))

            paneBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var paneBody: some View {
        switch pane.kind {
        case .notes:
            TextEditor(text: $pane.notesText)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .onChange(of: pane.notesText) { _ in
                    pane.refresh()
                }
        case .markdownPreview:
            ScrollView {
                if let attributed = try? AttributedString(markdown: pane.bodyText) {
                    Text(attributed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    Text(pane.bodyText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        default:
            ScrollView {
                Text(pane.bodyText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }
}

// MARK: - WebView URL Bar

/// An editable URL bar for webview panes. Displays the current URL and
/// allows the user to type a new address and press Return to navigate.
private struct WebViewURLBar: View {
    @ObservedObject var pane: WebViewPane
    @State private var editingText: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        ZStack {
            if isEditing {
                TextField("Enter URL", text: $editingText, onCommit: {
                    pane.navigate(to: editingText)
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            } else {
                HStack(spacing: 4) {
                    if pane.isLoading {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 10, height: 10)
                    } else if pane.currentURL?.scheme == "https" {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    Text(displayURL)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    editingText = pane.currentURL?.absoluteString ?? ""
                    isEditing = true
                }
            }
        }
    }

    private var displayURL: String {
        pane.currentURL?.absoluteString ?? pane.initialURL.absoluteString
    }
}

// MARK: - Server URL Banner

/// A rounded-rect pill displayed at the top of a terminal pane when
/// local dev-server URLs are detected.
///
/// Single URL:
///   - Tap → opens in webview pane
///   - Shift-tap → copies to clipboard
///
/// Multiple URLs:
///   - Tap → opens a dropdown listing each URL
///   - Each row: tap opens, shift-tap copies
struct ServerURLBannerView: View {
    let urls: [URL]

    @State private var isHovering = false
    @State private var showDropdown = false
    @State private var copiedURL: String?

    private static let pillColor = Color(red: 0x58/255, green: 0xa6/255, blue: 0xff/255)

    var body: some View {
        ZStack(alignment: .top) {
            // Invisible full-area tap catcher to dismiss the dropdown
            if showDropdown {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDropdown = false
                        }
                    }
            }

            VStack(spacing: 0) {
                // The pill
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 10, weight: .medium))
                    if urls.count == 1 {
                        Text(urls[0].absoluteString)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("\(urls.count) servers")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: showDropdown ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Self.pillColor.opacity(isHovering ? 1.0 : 0.85))
                )
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovering = hovering
                    }
                }
                .onTapGesture {
                    if urls.count == 1 {
                        if NSEvent.modifierFlags.contains(.shift) {
                            copyToClipboard(urls[0])
                        } else {
                            openInPane(urls[0])
                        }
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDropdown.toggle()
                        }
                    }
                }
                .help(urls.count == 1
                      ? "Click to open in pane. Shift-click to copy URL."
                      : "Click to show server URLs.")

                // Dropdown for multiple URLs
                if showDropdown && urls.count > 1 {
                    VStack(spacing: 0) {
                        ForEach(urls, id: \.absoluteString) { url in
                            ServerURLDropdownRow(
                                url: url,
                                isCopied: copiedURL == url.absoluteString,
                                onOpen: { openInPane(url) },
                                onCopy: { copyToClipboard(url) }
                            )
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showDropdown)
        .animation(.easeInOut(duration: 0.2), value: copiedURL)
    }

    private func openInPane(_ url: URL) {
        showDropdown = false
        NotificationCenter.default.post(
            name: .ghosttyOpenURLInPane,
            object: nil,
            userInfo: [Notification.Name.OpenURLInPaneURLKey: url]
        )
    }

    private func copyToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)

        copiedURL = url.absoluteString
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedURL == url.absoluteString {
                copiedURL = nil
            }
        }
    }
}

/// A single row in the server URL dropdown.
private struct ServerURLDropdownRow: View {
    let url: URL
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(url.absoluteString)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.primary)
            Spacer()
            if isCopied {
                Text("Copied!")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHovering ? Color.white.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                onCopy()
            } else {
                onOpen()
            }
        }
        .help("Click to open. Shift-click to copy.")
    }
}

// MARK: - Layout Helpers

/// Returns a prefix-sum array of offsets for `sizes` separated by `spacing`.
/// prefixSums([a, b, c], spacing: g) → [0, a+g, a+g+b+g]
private func prefixSums(_ sizes: [CGFloat], spacing: CGFloat) -> [CGFloat] {
    var offsets = [CGFloat](repeating: 0, count: sizes.count)
    for i in 1..<sizes.count {
        offsets[i] = offsets[i - 1] + sizes[i - 1] + spacing
    }
    return offsets
}
