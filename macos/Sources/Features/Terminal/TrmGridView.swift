import SwiftUI
import GhosttyKit

/// Termania-style border colors and metrics.
///
/// These match the defaults from `src/termania/config.zig`:
///   border:          #30363d
///   border_focused:  #58a6ff
///   border_radius:   8
///   gap:             4
private enum TrmBorder {
    static let color        = Color(red: 0x30/255, green: 0x36/255, blue: 0x3d/255)
    static let focusedColor = Color(red: 0x58/255, green: 0xa6/255, blue: 0xff/255)
    static let radius: CGFloat  = 8
    static let width: CGFloat   = 1
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

    /// Callback to close a webview pane.
    var onCloseWebviewPane: ((WebViewPane) -> Void)? = nil

    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface

    var body: some View {
        if panes.isEmpty {
            EmptyView()
        } else if panes.count == 1 {
            // Single pane — no grid chrome, just the pane
            paneView(panes[0], index: 0)
        } else {
            VStack(spacing: gap) {
                ForEach(Array(rowLayout.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: gap) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { colIdx, pane in
                            let flatIndex = flatIndexFor(row: rowIdx, col: colIdx)
                            paneView(pane, index: flatIndex)
                                // cornerRadius applies a CALayer mask that clips the
                                // Metal-rendered terminal content to rounded corners.
                                .cornerRadius(TrmBorder.radius)
                                .overlay(
                                    RoundedRectangle(cornerRadius: TrmBorder.radius, style: .continuous)
                                        .strokeBorder(
                                            borderColor(for: pane),
                                            lineWidth: TrmBorder.width
                                        )
                                        .allowsHitTesting(false)
                                )
                        }
                    }
                }
            }
            .padding(padding)
        }
    }

    /// Dispatch to the appropriate view for each pane type.
    @ViewBuilder
    private func paneView(_ pane: GridPane, index: Int) -> some View {
        switch pane {
        case .terminal(let surface):
            terminalPaneView(surface, index: index)
        case .webview(let webviewPane):
            webviewPaneView(webviewPane)
        }
    }

    /// A single terminal pane: surface with optional watermark and live summary overlays.
    @ViewBuilder
    private func terminalPaneView(_ surface: Ghostty.SurfaceView, index: Int) -> some View {
        Ghostty.InspectableSurface(
            surfaceView: surface,
            isSplit: panes.count > 1
        )
        .overlay(
            watermarkOverlay(forPane: index)
        )
        .overlay(
            liveSummaryOverlay(forPane: index),
            alignment: .bottom
        )
    }

    /// A webview pane with a minimal toolbar showing the URL and a close button.
    @ViewBuilder
    private func webviewPaneView(_ pane: WebViewPane) -> some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 6) {
                if pane.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
                Text(pane.title.isEmpty ? (pane.currentURL?.absoluteString ?? "Loading...") : pane.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                Spacer()
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

    /// Returns a live summary overlay if the manager is enabled and has content for this pane.
    @ViewBuilder
    private func liveSummaryOverlay(forPane index: Int) -> some View {
        if liveSummaryManager.isEnabled,
           let summary = liveSummaryManager.summaries[index], !summary.isEmpty {
            VStack {
                Spacer()
                LiveSummaryOverlayView(
                    summary: summary,
                    isLoading: liveSummaryManager.isLoading[index] ?? false
                )
            }
        } else if liveSummaryManager.isEnabled,
                  liveSummaryManager.isLoading[index] == true {
            VStack {
                Spacer()
                LiveSummaryOverlayView(
                    summary: "Summarizing...",
                    isLoading: true
                )
            }
        }
    }

    /// Returns a watermark overlay if one is set for this pane index.
    @ViewBuilder
    private func watermarkOverlay(forPane index: Int) -> some View {
        if let text = Trm.shared.watermark(forPane: UInt32(index)), !text.isEmpty {
            WatermarkView(text: text, cellHeight: 14)
        }
    }

    private func borderColor(for pane: GridPane) -> Color {
        switch pane {
        case .terminal(let surface):
            if let focused = focusedSurface, focused === surface {
                return TrmBorder.focusedColor
            }
            return TrmBorder.color
        case .webview:
            return TrmBorder.color
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
