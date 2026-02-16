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

    /// The surfaces in grid order, derived from the surfaceTree.
    var gridSurfaces: [Ghostty.SurfaceView] { get }

    /// Inline webview panes opened via URL interception.
    var webviewPanes: [WebViewPane] { get }

    /// All panes (terminals + webviews) for the grid, in display order.
    var gridPanes: [GridPane] { get }

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
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

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

                    TrmGridView(
                        panes: viewModel.gridPanes,
                        rowCols: viewModel.gridRowCols,
                        gap: Trm.shared.gridConfig().gap,
                        padding: Trm.shared.gridConfig().padding,
                        liveSummaryManager: viewModel.liveSummaryManager,
                        onCloseWebviewPane: { pane in
                            (self.delegate as? BaseTerminalController)?.closeWebviewPane(pane)
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
