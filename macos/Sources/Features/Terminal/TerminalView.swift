import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// Execute parsed LLM actions against the terminal.
    func executeTrmActions(_ actions: [TrmAction])

    /// Build pane context for the LLM system prompt.
    func buildPaneContext() -> [PaneContext]

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// Whether to use grid layout instead of the binary split tree.
    var useGridLayout: Bool { get }

    /// Number of columns in each row of the grid layout.
    var gridRowCols: [Int] { get }

    /// The selected pane when it has no surface (agent overview, webview,
    /// plugin). Terminals carry selection through keyboard focus instead.
    var selectedNonSurfacePane: ObjectIdentifier? { get }

    /// True while Cmd+Shift is held: dim pane contents and light up
    /// watermarks so a pane can be found by its label.
    var isWatermarkPeeking: Bool { get }

    /// Fractional heights for each row (sums to 1.0).
    var gridRowHeightFractions: [CGFloat] { get }

    /// Fractional column widths per row (each inner array sums to 1.0).
    var gridColWidthFractions: [[CGFloat]] { get }

    /// Gap between panes.
    var gridGap: CGFloat { get }

    /// Outer padding around the pane grid.
    var gridPadding: CGFloat { get }

    /// The surfaces in grid order, derived from the surfaceTree.
    var gridSurfaces: [Ghostty.SurfaceView] { get }

    /// Inline webview panes opened via URL interception.
    var webviewPanes: [WebViewPane] { get }

    /// Temporary Command-hover URL preview, outside the persistent grid.
    var temporaryURLPreview: WebViewPane? { get }
    var isTemporaryURLPreviewPinned: Bool { get }

    /// All panes (terminals + webviews) for the grid, in display order.
    var gridPanes: [GridPane] { get }

    /// Maps a host pane ID to the ordered list of stacked pane IDs.
    var paneStacks: [ObjectIdentifier: [ObjectIdentifier]] { get }

    /// Per-stack sub-pane height fractions, keyed by the stack cell's ObjectIdentifier.
    var stackSubPaneHeightFractions: [ObjectIdentifier: [CGFloat]] { get }

    /// The currently peeked sub-pane (expanded overlay), or nil.
    var peekedPane: ObjectIdentifier? { get }

    /// Directional animation state for changing the peeked pane.
    var peekSlideOffset: CGFloat { get }
    var isPeekNavigationAnimating: Bool { get }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The help panel state.
    var helpPanelIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }

    /// The live summary manager for per-pane LLM summaries.
    var liveSummaryManager: LiveSummaryManager { get }

    /// The context usage manager for Claude Code context window tracking.
    var contextUsageManager: ContextUsageManager { get }

    /// The service plugin registry managing service plugins (including server URL detection).
    var servicePluginRegistry: ServicePluginRegistry { get }

    /// Shared AI state for the command palette (persists across open/close).
    var commandPaletteAIState: CommandPaletteAIState { get }

    /// Agent monitor for tracking AI agent activity in panes.
    var agentMonitorService: AgentMonitorService { get }

    /// Stable pane IDs that need user attention (agent waiting for input).
    var attentionPaneIds: Set<Int> { get }

    /// Remote panes whose SSH link died; the grid overlays a Reconnect button.
    var disconnectedRemotePaneIds: Set<Int> { get }

    /// Panes parked in the sidebar: running, but not laid out in the grid.
    var sidebarTiles: [GridPane] { get }

    /// Whether the sidebar shelf is expanded rather than collapsed to its rail.
    var sidebarIsShowing: Bool { get }

    /// Whether the Command Center panel is open along the window's edge.
    var commandCenterIsShowing: Bool { get }

    /// Width of the Command Center panel in points.
    var commandCenterWidth: CGFloat { get }

    /// Width of the expanded sidebar shelf in points.
    var sidebarWidth: CGFloat { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    /// Drives the sidebar's per-pane messages.
    ///
    /// The monitor already polls every agent in the window and computes the
    /// paragraph an overview would show, so the sidebar reads that rather than
    /// growing a second, differently-wrong copy of the same logic. It is only
    /// subscribed while the shelf is expanded — an index nobody is looking at
    /// is not worth polling for.
    @ObservedObject private var agentMonitor = CommandCenterMonitor.shared

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)? = nil
    
    // The most recently focused surface, equal to focusedSurface when
    // it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView> = .init()

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }


    /// The agent's latest message per pane id.
    /// Poll agents only while the shelf is expanded — an index nobody is
    /// looking at is not worth a scan every 2.5 seconds.
    private func sidebarSubscription<V: View>(_ view: V) -> some View {
        view
            .onAppear { CommandCenterMonitor.shared.subscribe() }
            .onDisappear { CommandCenterMonitor.shared.unsubscribe() }
    }

    private var sidebarMessages: [Int: String] {
        Dictionary(agentMonitor.entries.map { ($0.paneId, $0.message) },
                   uniquingKeysWith: { first, _ in first })
    }

    private var sidebarAgentNames: [Int: String] {
        Dictionary(agentMonitor.entries.map { ($0.paneId, $0.kind?.displayName ?? "Agent") },
                   uniquingKeysWith: { first, _ in first })
    }

    private var sidebarLocations: [Int: String] {
        Dictionary(agentMonitor.entries.compactMap { entry in
            entry.location.map { (entry.paneId, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if (Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE) {
                        DebugBuildWarningView()
                    }

                    HStack(spacing: 0) {
                    TrmGridView(
                        panes: viewModel.gridPanes,
                        rowCols: viewModel.gridRowCols,
                        gap: viewModel.gridGap,
                        padding: viewModel.gridPadding,
                        liveSummaryManager: viewModel.liveSummaryManager,
                        servicePluginRegistry: viewModel.servicePluginRegistry,
                        attentionPaneIds: viewModel.attentionPaneIds,
                        peekedPane: viewModel.peekedPane,
                        peekSlideOffset: viewModel.peekSlideOffset,
                        isPeekNavigationAnimating: viewModel.isPeekNavigationAnimating,
                        temporaryURLPreview: viewModel.temporaryURLPreview,
                        isTemporaryURLPreviewPinned: viewModel.isTemporaryURLPreviewPinned,
                        onDetachPane: { pane in
                            (self.delegate as? BaseTerminalController)?.detachPaneToWindow(pane)
                        },
                        onAttachPane: { pane in
                            (self.delegate as? BaseTerminalController)?.attachPaneToAnotherWindow(pane)
                        },
                        onCloseWebviewPane: { pane in
                            (self.delegate as? BaseTerminalController)?.closeWebviewPane(pane)
                        },
                        onClosePluginPane: { pane in
                            (self.delegate as? BaseTerminalController)?.closePluginPane(pane)
                        },
                        onShowAgentOverview: { pane in
                            (self.delegate as? BaseTerminalController)?.showAgentOverview(for: pane)
                        },
                        onCloseAgentOverview: { pane in
                            (self.delegate as? BaseTerminalController)?.closeAgentOverview(pane)
                        },
                        onSendToAgent: { overviewPane, text in
                            guard let surface = overviewPane.surface else { return }
                            (self.delegate as? BaseTerminalController)?
                                .sendMessageToSurface(surface, text: text)
                        },
                        onSendToPaneAgent: { surface, text in
                            (self.delegate as? BaseTerminalController)?
                                .sendMessageToSurface(surface, text: text)
                        },
                        onShowIssueTracker: { surface, project in
                            IssueTrackerWindowController.show(project: project, from: surface)
                        },
                        hasAgentOverview: { pane in
                            (self.delegate as? BaseTerminalController)?.hasAgentOverview(for: pane) ?? false
                        },
                        onPlaceOverview: { uuid, target, placement in
                            (self.delegate as? BaseTerminalController)?.placeOverview(
                                overviewUUID: uuid, onto: target, placement: placement)
                        },
                        onSetOverviewPlacement: { overviewPane, placement in
                            (self.delegate as? BaseTerminalController)?.setOverviewPlacement(overviewPane, placement)
                        },
                        onRebindAgentOverview: { overviewPane, surface in
                            (self.delegate as? BaseTerminalController)?.rebindAgentOverview(
                                overviewPane, to: surface)
                        },
                        onMovePane: { pane, direction in
                            (self.delegate as? BaseTerminalController)?.movePane(pane, direction: direction)
                        },
                        onStackPane: { source, target, edge in
                            (self.delegate as? BaseTerminalController)?.stackPane(source, onto: target, edge: edge)
                        },
                        onSwapPane: { source, target in
                            (self.delegate as? BaseTerminalController)?.swapPane(source, with: target)
                        },
                        onTransferPane: { uuid, target, stackMode, edge in
                            (self.delegate as? BaseTerminalController)?.receiveDroppedPane(
                                surfaceUUID: uuid, onto: target, stackMode: stackMode, edge: edge)
                        },
                        onUnstackPane: { pane in
                            (self.delegate as? BaseTerminalController)?.unstackPane(pane)
                        },
                        onSendPaneToSidebar: { pane in
                            (self.delegate as? BaseTerminalController)?.sendPaneToSidebar(pane)
                        },
                        onMoveSubPane: { pane, up in
                            (self.delegate as? BaseTerminalController)?.moveSubPane(pane, up: up)
                        },
                        onPeekPane: { pane in
                            (self.delegate as? BaseTerminalController)?.peekPane(pane)
                        },
                        onSwitchPaneRemote: { pane in
                            (self.delegate as? BaseTerminalController)?.switchPaneToRemote(pane)
                        },
                        disconnectedRemotePaneIds: viewModel.disconnectedRemotePaneIds,
                        onReconnectPane: { pane in
                            (self.delegate as? BaseTerminalController)?.reconnectRemotePane(pane)
                        },
                        onReconnectAll: {
                            (delegate as? BaseTerminalController)?
                                .reconnectDisconnectedRemotePanes()
                        },
                        selectedNonSurfacePane: viewModel.selectedNonSurfacePane,
                        onSelectNonSurfacePane: { id in
                            (self.delegate as? BaseTerminalController)?.selectNonSurfacePane(id)
                        },
                        isWatermarkPeeking: viewModel.isWatermarkPeeking,
                        onDismissPeek: {
                            (self.delegate as? BaseTerminalController)?.dismissPeek()
                        },
                        onNavigatePeek: { delta in
                            (self.delegate as? BaseTerminalController)?.navigatePeek(by: delta)
                        },
                        onPinURLPreview: {
                            (self.delegate as? BaseTerminalController)?.pinTemporaryURLPreview()
                        },
                        onDismissURLPreview: {
                            (self.delegate as? BaseTerminalController)?.dismissTemporaryURLPreview()
                        },
                        rowHeightFractions: viewModel.gridRowHeightFractions,
                        colWidthFractions: viewModel.gridColWidthFractions,
                        onResizeRow: { row, fraction in
                            (self.delegate as? BaseTerminalController)?.resizeGridRow(row, toFraction: fraction)
                        },
                        onResizeCol: { row, col, fraction in
                            (self.delegate as? BaseTerminalController)?.resizeGridCol(row, col: col, toFraction: fraction)
                        },
                        stackHeightFractions: viewModel.stackSubPaneHeightFractions,
                        onResizeStack: { stackID, subIdx, fraction in
                            (self.delegate as? BaseTerminalController)?.resizeStack(stackID, subIdx: subIdx, toFraction: fraction)
                        }
                    )
                    .environmentObject(ghostty)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { newValue in
                            // We want to keep track of our last focused surface so even if
                            // we lose focus we keep this set to the last non-nil value.
                            if newValue != nil {
                                lastFocusedSurface = .init(newValue)
                                self.delegate?.focusedSurfaceDidChange(to: newValue)
                            }
                        }
                        .onChange(of: pwdURL) { newValue in
                            self.delegate?.pwdDidChange(to: newValue)
                        }
                        .onChange(of: cellSize) { newValue in
                            guard let size = newValue else { return }
                            self.delegate?.cellSizeDidChange(to: size)
                        }
                        .frame(idealWidth: lastFocusedSurface.value?.initialSize?.width,
                               idealHeight: lastFocusedSurface.value?.initialSize?.height)

                    sidebar
                    commandCenterPanel
                    }
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == "hidden" ? .top : [])

                if let surfaceView = lastFocusedSurface.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel,
                        onAction: { action in
                            self.delegate?.performAction(action, on: surfaceView)
                        },
                        onExecuteActions: { actions in
                            self.delegate?.executeTrmActions(actions)
                        },
                        buildPaneContext: { [weak delegate] in
                            delegate?.buildPaneContext() ?? []
                        },
                        onToggleLiveSummary: {
                            viewModel.liveSummaryManager.toggle()
                        },
                        aiState: viewModel.commandPaletteAIState,
                        agentMonitor: viewModel.agentMonitorService,
                        servicePluginRegistry: viewModel.servicePluginRegistry
                    )
                }

                // Floating status bar (shown when palette is dismissed during active AI work)
                if !viewModel.commandPaletteIsShowing &&
                    (viewModel.commandPaletteAIState.isAgentActive ||
                     !viewModel.commandPaletteAIState.statusMessages.isEmpty) {
                    FloatingStatusBar(
                        aiState: viewModel.commandPaletteAIState,
                        onTap: {
                            viewModel.commandPaletteIsShowing = true
                        }
                    )
                }

                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    UpdateOverlay()
                }

                // Context usage overlay (bottom-right, below update pill)
                if let usage = viewModel.contextUsageManager.currentUsage {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ContextUsageOverlayView(
                                usage: usage,
                                dailyTokensUsed: viewModel.contextUsageManager.dailyTokensUsed,
                                weeklyTokensUsed: viewModel.contextUsageManager.weeklyTokensUsed
                            )
                        }
                    }
                }

                // Help panel overlay
                if viewModel.helpPanelIsShowing {
                    HelpPanelView(isPresented: $viewModel.helpPanelIsShowing)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        }
    }

    /// Mirrors `CommandCenterView`'s own key so the header toggle and the list
    /// stay in step; @AppStorage on both sides is the same defaults value.
    @AppStorage("CommandCenterBriefingMode") private var commandCenterBriefingMode = false

    /// The Command Center panel: every running agent's current message, along
    /// the window's trailing edge.
    ///
    /// Outermost in the row, past the parked-pane shelf: the shelf belongs to
    /// this window's layout, while this is a view across every window, so it
    /// reads as the outer frame rather than part of the grid.
    @ViewBuilder
    private var commandCenterPanel: some View {
        if viewModel.commandCenterIsShowing {
            SidebarResizeHandle { delta in
                guard let controller = delegate as? BaseTerminalController else { return }
                controller.setCommandCenterWidth(controller.commandCenterWidth - delta)
            }

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(.secondary)
                    Text("Command Center")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Briefing mode lives in the header rather than a menu:
                    // it's a way of reading the same board, switched as often
                    // as the work changes shape.
                    Toggle(isOn: $commandCenterBriefingMode) {
                        Image(systemName: "target")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .foregroundStyle(commandCenterBriefingMode ? Color.accentColor : .secondary)
                    .help("Briefing mode — one sentence per agent, sized to act on")
                    Button {
                        (delegate as? BaseTerminalController)?.commandCenterIsShowing = false
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Hide Command Center (⌘⇧A)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                Divider().opacity(0.5)

                CommandCenterView(onSendToPane: { surface, text in
                    (delegate as? BaseTerminalController)?.sendMessageToSurface(surface, text: text)
                })
            }
            .frame(width: viewModel.commandCenterWidth)
            .background(.background.opacity(0.35))
            .transition(.move(edge: .trailing))
        }
    }

    /// The parked-pane shelf, to the right of the grid.
    ///
    /// It collapses to a narrow rail rather than disappearing: a pane that is
    /// still running must never be invisible with no way back to it. Nothing
    /// is drawn at all when nothing is parked.
    @ViewBuilder
    private var sidebar: some View {
        // The rail still appears on its own only when something is parked — a
        // running pane out of sight must never be invisible. But asking for the
        // sidebar now shows every pane in the window, so an explicit open is
        // reason enough to draw it even with nothing parked.
        if !viewModel.sidebarTiles.isEmpty || viewModel.sidebarIsShowing {
            if viewModel.sidebarIsShowing {
                SidebarResizeHandle { delta in
                    guard let controller = delegate as? BaseTerminalController else { return }
                    controller.sidebarWidth = min(max(controller.sidebarWidth - delta, 180), 520)
                }

                sidebarSubscription(SidebarPanesView(
                    panes: viewModel.sidebarTiles,
                    gridPanes: viewModel.gridPanes,
                    messages: sidebarMessages,
                    agentNames: sidebarAgentNames,
                    locations: sidebarLocations,
                    attentionPaneIds: viewModel.attentionPaneIds,
                    onFocus: { pane in
                        guard let surface = pane.firstTerminalSurface else { return }
                        (delegate as? BaseTerminalController)?.focusSurface(surface)
                    },
                    onRestore: { pane in
                        (delegate as? BaseTerminalController)?.restorePaneFromSidebar(pane.id)
                    },
                    onClose: { pane in
                        (delegate as? BaseTerminalController)?.closeSidebarPane(pane)
                    },
                    onRestoreAll: {
                        (delegate as? BaseTerminalController)?.restoreAllPanesFromSidebar()
                    },
                    onCollapse: {
                        (delegate as? BaseTerminalController)?.sidebarIsShowing = false
                    }
                ))
                .frame(width: viewModel.sidebarWidth)
                .transition(.move(edge: .trailing))
            } else {
                SidebarRailView(
                    count: viewModel.sidebarTiles.count,
                    needsAttention: viewModel.sidebarTiles.contains { pane in
                        guard let id = pane.firstTerminalSurface?.paneId else { return false }
                        return viewModel.attentionPaneIds.contains(id)
                    },
                    onExpand: {
                        (delegate as? BaseTerminalController)?.sidebarIsShowing = true
                    }
                )
                .padding(.trailing, 4)
            }
        }
    }
}

/// The draggable seam between the grid and the sidebar shelf. Reports the
/// horizontal drag delta; the controller clamps and applies it.
private struct SidebarResizeHandle: View {
    let onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onDrag(value.translation.width - lastTranslation)
                        lastTranslation = value.translation.width
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
    }
}

fileprivate struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()
                
                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of trm! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of trm are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of trm are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
