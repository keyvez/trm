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

    /// The service plugin registry for rendering service plugin overlays.
    @ObservedObject var servicePluginRegistry: ServicePluginRegistry

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

    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface

    /// Bumped when a watermark changes to force the overlay to re-evaluate.
    @State private var watermarkVersion: Int = 0

    /// The pane index that was most recently focused, used to trigger
    /// a brief watermark highlight flash on activation.
    @State private var highlightedPane: Int? = nil
    /// When true, the focus-change highlight is suppressed because an
    /// explicit highlightPane notification is already handling the flash.
    @State private var suppressFocusHighlight = false

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: Trm.watermarkDidChange)) { _ in
                watermarkVersion += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: Trm.highlightPane)) { notification in
                guard let pid = notification.userInfo?["paneId"] as? Int else { return }
                // Only highlight if this pane is in our grid.
                guard panes.contains(where: {
                    if case .terminal(let s) = $0 { return s.paneId == pid }
                    return false
                }) else { return }
                suppressFocusHighlight = true
                highlightedPane = pid
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if highlightedPane == pid {
                        highlightedPane = nil
                    }
                    suppressFocusHighlight = false
                }
            }
            .onChange(of: focusedSurfaceIdentity) { newIdentity in
                guard !suppressFocusHighlight else { return }
                guard panes.count > 1, let newIdentity else { return }
                // Match the new identity against pane surfaces to find
                // which pane just gained focus.
                for (i, pane) in panes.enumerated() {
                    if case .terminal(let surface) = pane,
                       ObjectIdentifier(surface) == newIdentity {
                        let pid = surface.paneId ?? i
                        highlightedPane = pid
                        // Reset after the animation completes so
                        // re-focusing the same pane still flashes.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            if highlightedPane == pid {
                                highlightedPane = nil
                            }
                        }
                        break
                    }
                }
            }
    }

    /// An identity value derived from the focused surface pointer so
    /// `.onChange(of:)` can detect focus changes.
    private var focusedSurfaceIdentity: ObjectIdentifier? {
        focusedSurface.map { ObjectIdentifier($0) }
    }

    @ViewBuilder
    private var content: some View {
        if panes.isEmpty {
            EmptyView()
        } else if panes.count == 1 {
            // Single pane — no grid chrome, just the pane
            paneView(panes[0], index: 0)
                .contextMenu {
                    if let pid = paneIdForPane(panes[0]) {
                        pluginsMenu(forPaneId: pid)
                    }
                }
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
                                .contextMenu {
                                    paneMoveMenu(pane: pane, row: rowIdx, col: colIdx)
                                    if let pid = paneIdForPane(pane) {
                                        Divider()
                                        pluginsMenu(forPaneId: pid)
                                    }
                                }
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
            terminalPaneView(surface, index: index, paneId: surface.paneId ?? index)
        case .webview(let webviewPane):
            webviewPaneView(webviewPane)
        case .plugin(let pluginPane):
            pluginPaneView(pluginPane)
        }
    }

    /// A single terminal pane: surface with optional watermark and live summary overlays.
    /// - `index`: the flat grid index (position in `gridPanes`)
    /// - `paneId`: the stable Zig pane ID (monotonic u32, survives pane close/reorder)
    @ViewBuilder
    private func terminalPaneView(_ surface: Ghostty.SurfaceView, index: Int, paneId: Int) -> some View {
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
            WatermarkView(text: text, cellHeight: 14, highlighted: highlightedPane == paneId)
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
        if case .terminal(let surface) = pane {
            return surface.paneId
        }
        return nil
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
        switch pane {
        case .terminal(let surface):
            if let focused = focusedSurface, focused === surface {
                return TrmBorder.focusedColor
            }
            return TrmBorder.color
        case .webview, .plugin:
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
        case .screenCapture:
            if let screenshot = pane.screenshot {
                GeometryReader { proxy in
                    VStack {
                        Image(nsImage: screenshot)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: proxy.size.width, maxHeight: proxy.size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
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
