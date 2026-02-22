import Cocoa
import SwiftUI
import Combine
import GhosttyKit
import UniformTypeIdentifiers
import os

/// A base class for windows that can contain Ghostty windows. This base class implements
/// the bare minimum functionality that every terminal window in Ghostty should implement.
///
/// Usage: Specify this as the base class of your window controller for the window that contains
/// a terminal. The window controller must also be the window delegate OR the window delegate
/// functions on this base class must be called by your own custom delegate. For the terminal
/// view the TerminalView SwiftUI view must be used and this class is the view model and
/// delegate.
///
/// Special considerations to implement:
///
///   - Fullscreen: you must manually listen for the right notification and implement the
///   callback that calls toggleFullscreen on this base class.
///
/// Notably, things this class does NOT implement (not exhaustive):
///
///   - Tabbing, because there are many ways to get tabbed behavior in macOS and we
///   don't want to be opinionated about it.
///   - Window restoration or save state
///   - Window visual styles (such as titlebar colors)
///
/// The primary idea of all the behaviors we don't implement here are that subclasses may not
/// want these behaviors.
class BaseTerminalController: NSWindowController,
                              NSWindowDelegate,
                              TerminalViewDelegate,
                              TerminalViewModel,
                              ClipboardConfirmationViewDelegate,
                              FullscreenDelegate
{
    private struct PaneRestorePlacement {
        let controller: Weak<BaseTerminalController>
        let row: Int
        let flatIndex: Int
        /// Index in the visual paneDisplayOrder (may differ from flatIndex
        /// if panes have been rearranged via move operations).
        let displayOrderIndex: Int?
    }

    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.App

    /// The currently focused surface.
    var focusedSurface: Ghostty.SurfaceView? = nil {
        didSet { syncFocusToSurfaceTree() }
    }

    /// The tree of splits within this terminal window.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet { surfaceTreeDidChange(from: oldValue, to: surfaceTree) }
    }

    // MARK: trm Grid State

    /// Whether to use grid layout instead of split tree layout.
    /// When true, surfaces from surfaceTree are rendered in a grid.
    @Published var useGridLayout: Bool = true

    /// Number of columns in each row of the grid (length = number of rows).
    /// Updated when panes are added/removed.
    @Published var gridRowCols: [Int] = [1]

    /// Optional per-window grid config loaded from a project-local trm.toml.
    private var gridConfigOverride: Trm.TrmGridConfig?

    /// Path to the project-local trm.toml used for this window (if any).
    private var configFilePath: String?

    /// Dispatch source monitoring the config file for changes.
    private var configFileWatcher: DispatchSourceFileSystemObject?

    /// Debounce work item for config reload after rapid saves.
    private var configReloadDebounce: DispatchWorkItem?

    /// Runtime grid config loaded by in-app commands.
    private var runtimeGridConfig: Trm.TrmGridConfig?

    private var activeGridConfig: Trm.TrmGridConfig {
        runtimeGridConfig ?? gridConfigOverride ?? Trm.shared.gridConfig()
    }

    /// Gap between panes for this window.
    var gridGap: CGFloat {
        activeGridConfig.gap
    }

    /// Outer padding around panes for this window.
    var gridPadding: CGFloat {
        activeGridConfig.padding
    }

    /// The surfaces in grid order, derived from the surfaceTree leaves.
    var gridSurfaces: [Ghostty.SurfaceView] {
        Array(surfaceTree)
    }

    /// Inline webview panes opened via URL interception.
    @Published var webviewPanes: [WebViewPane] = []

    /// Inline utility plugin panes (notes, file browser, etc.).
    @Published var pluginPanes: [PluginPane] = []

    /// Per-pane "move back" targets for panes that were detached into this window.
    private var detachedTerminalOrigins: [ObjectIdentifier: PaneRestorePlacement] = [:]
    private var detachedWebviewOrigins: [UUID: PaneRestorePlacement] = [:]

    /// Set to `true` while a surface is being moved between windows so that
    /// `ghosttyDidCloseSurface` notifications are suppressed during the transition.
    /// Internal so that `TerminalController` can check it to avoid auto-closing
    /// the window while the surface is being transferred.
    var isMovingSurface = false

    /// Set when the controller was initialized with an existing surface tree
    /// (e.g., a popped-out pane). When true, `setupInitialPanes` is skipped
    /// in `windowDidLoad` to avoid replacing the passed-in tree.
    private var hasExternalSurfaceTree = false

    /// Explicit display order of panes. When non-empty, `gridPanes` sorts
    /// by this order instead of the default terminals → webviews → plugins.
    @Published var paneDisplayOrder: [ObjectIdentifier] = []

    /// All panes for the grid, in display order.
    var gridPanes: [GridPane] {
        let all: [GridPane] =
            gridSurfaces.map { .terminal($0) } +
            webviewPanes.map { .webview($0) } +
            pluginPanes.map { .plugin($0) }

        guard !paneDisplayOrder.isEmpty else { return all }

        let indexed = Dictionary(uniqueKeysWithValues: paneDisplayOrder.enumerated().map { ($1, $0) })
        return all.sorted { a, b in
            let ai = indexed[a.id] ?? Int.max
            let bi = indexed[b.id] ?? Int.max
            return ai < bi
        }
    }

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false

    /// This can be set to show/hide the help panel.
    @Published var helpPanelIsShowing: Bool = false

    /// Set if the terminal view should show the update overlay.
    @Published var updateOverlayIsVisible: Bool = false

    /// The live summary manager for per-pane LLM summaries.
    let liveSummaryManager = LiveSummaryManager()

    /// The shared terminal output scanner.
    let terminalOutputScanner = TerminalOutputScanner()

    /// The service plugin registry managing all service plugins.
    let servicePluginRegistry: ServicePluginRegistry

    /// The context usage manager for Claude Code context window tracking.
    let contextUsageManager = ContextUsageManager()

    /// Shared AI state for the command palette (persists across open/close).
    let commandPaletteAIState = CommandPaletteAIState()

    /// Agent monitor for tracking AI agent activity in panes.
    let agentMonitorService = AgentMonitorService()

    /// Whether the terminal surface should focus when the mouse is over it.
    var focusFollowsMouse: Bool {
        self.derivedConfig.focusFollowsMouse
    }

    /// Non-nil when an alert is active so we don't overlap multiple.
    private var alert: NSAlert? = nil

    /// The clipboard confirmation window, if shown.
    private var clipboardConfirmation: ClipboardConfirmationController? = nil

    /// Fullscreen state management.
    private(set) var fullscreenStyle: FullscreenStyle?

    /// Event monitor (see individual events for why)
    private var eventMonitor: Any? = nil

    /// The previous frame information from the window
    private var savedFrame: SavedFrame? = nil

    /// Cache previously applied appearance to avoid unnecessary updates
    private var appliedColorScheme: ghostty_color_scheme_e?

    /// Tracks the last Option key release time for double-tap detection.
    private var lastOptionReleaseTime: TimeInterval = 0
    /// Whether the Option key was pressed alone (no other modifiers or keys).
    private var optionPressedAlone: Bool = false

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig

    /// Track whether background is forced opaque (true) or using config transparency (false)
    var isBackgroundOpaque: Bool = false

    /// The cancellables related to our focused surface.
    private var focusedSurfaceCancellables: Set<AnyCancellable> = []

    /// An override title for the tab/window set by the user via prompt_tab_title.
    /// When set, this takes precedence over the computed title from the terminal.
    var titleOverride: String? = nil {
        didSet { applyTitleToWindow() }
    }

    /// The last computed title from the focused surface (without the override).
    private var lastComputedTitle: String = "trm"

    /// The time that undo/redo operations that contain running ptys are valid for.
    var undoExpiration: Duration {
        ghostty.config.undoTimeout
    }

    /// The undo manager for this controller is the undo manager of the window,
    /// which we set via the delegate method.
    override var undoManager: ExpiringUndoManager? {
        // This should be set via the delegate method windowWillReturnUndoManager
        if let result = window?.undoManager as? ExpiringUndoManager {
            return result
        }

        // If the window one isn't set, we fallback to our global one.
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            return appDelegate.undoManager
        }

        return nil
    }

    struct SavedFrame {
        let window: NSRect
        let screen: NSRect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    init(_ ghostty: Ghostty.App,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         surfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         gridConfig gridConfigOverride: Trm.TrmGridConfig? = nil,
         configPath: String? = nil
    ) {
        self.ghostty = ghostty
        self.derivedConfig = DerivedConfig(ghostty.config)
        self.gridConfigOverride = gridConfigOverride
        self.configFilePath = configPath
        self.runtimeGridConfig = nil
        self.servicePluginRegistry = ServicePluginRegistry(scanner: self.terminalOutputScanner)

        super.init(window: nil)

        // Initialize our initial surface.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        // Merge base config with pane-0 defaults for this window.
        let initialConfig: Ghostty.SurfaceConfiguration? = {
            var cfg = base ?? Ghostty.SurfaceConfiguration()
            let gridCfg = self.activeGridConfig
            if let firstPane = gridCfg.panes.first {
                if cfg.workingDirectory?.isEmpty != false {
                    if let cwd = firstPane.cwd, !cwd.isEmpty {
                        cfg.workingDirectory = NSString(string: cwd).expandingTildeInPath
                    } else {
                        cfg.workingDirectory = NSHomeDirectory()
                    }
                }
                if cfg.command?.isEmpty != false,
                   let cmd = firstPane.command,
                   !cmd.isEmpty {
                    cfg.command = cmd
                }
            } else if cfg.workingDirectory?.isEmpty != false {
                // Default to home to avoid macOS Documents permission prompts.
                cfg.workingDirectory = NSHomeDirectory()
            }
            if cfg.workingDirectory?.isEmpty != false {
                // Final fallback for any empty/invalid configuration.
                cfg.workingDirectory = NSHomeDirectory()
            }
            return cfg
        }()
        if let tree = tree {
            self.hasExternalSurfaceTree = true
            self.surfaceTree = tree
        } else {
            let initialView = Ghostty.SurfaceView(ghostty_app, baseConfig: initialConfig)
            initialView.paneId = Trm.shared.allocPaneId()
            self.surfaceTree = .init(view: initialView)
        }

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onConfirmClipboardRequest),
            name: Ghostty.Notification.confirmClipboard,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(didChangeScreenParametersNotification),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChangeBase(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyCommandPaletteDidToggle(_:)),
            name: .ghosttyCommandPaletteDidToggle,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyMaximizeDidToggle(_:)),
            name: .ghosttyMaximizeDidToggle,
            object: nil)

        // Text Tap send commands
        center.addObserver(
            self,
            selector: #selector(onTextTapSend(_:)),
            name: .trmTextTapSend,
            object: nil)

        // Splits
        center.addObserver(
            self,
            selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidPresentTerminal(_:)),
            name: Ghostty.Notification.ghosttyPresentTerminal,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttySurfaceDragEndedNoTarget(_:)),
            name: .ghosttySurfaceDragEndedNoTarget,
            object: nil)

        // Webview pane
        center.addObserver(
            self,
            selector: #selector(ghosttyOpenURLInPane(_:)),
            name: .ghosttyOpenURLInPane,
            object: nil)

        // Quick actions
        center.addObserver(
            self,
            selector: #selector(handleQuickActionExecute(_:)),
            name: .trmQuickActionExecute,
            object: nil)

        // Shortcut extractor
        center.addObserver(
            self,
            selector: #selector(handleShortcutExecute(_:)),
            name: .trmShortcutExecute,
            object: nil)

        // Listen for local events that we need to know of outside of
        // single surface handlers.
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in self?.localEventHandler(event) }

        // Wire up the live summary manager's pane content provider.
        // Use the stable Zig pane index so summaries match overlay rendering.
        liveSummaryManager.paneContentProvider = { [weak self] in
            guard let self else { return [] }
            return self.gridSurfaces.enumerated().map { index, surface in
                let title = surface.title.isEmpty ? "Shell" : surface.title
                let visibleText = surface.cachedScreenContents.get()
                let effectivePaneId = surface.paneId ?? index
                return (paneId: effectivePaneId, title: title, visibleText: visibleText)
            }
        }

        // Wire up the terminal output scanner's content provider.
        // Use cachedVisibleContents (viewport only) instead of cachedScreenContents
        // (full scrollback) so that URLs from previous command runs that have scrolled
        // off screen are no longer detected.
        terminalOutputScanner.paneContentProvider = { [weak self] in
            guard let self else { return [] }
            return self.gridSurfaces.enumerated().map { index, surface in
                let visibleText = surface.cachedVisibleContents.get()
                // Use the stable pane ID when available so scanner
                // IDs match what Text Tap and other Zig APIs expect.
                let effectivePaneId = surface.paneId ?? index
                return (paneId: effectivePaneId, visibleText: visibleText)
            }
        }

        // Wire agent monitor to scanner and AI state.
        agentMonitorService.aiState = commandPaletteAIState
        terminalOutputScanner.addSubscriber(agentMonitorService)

        // Register and start all service plugins, then start the config file watcher.
        setupServicePlugins()
        terminalOutputScanner.start()
        servicePluginRegistry.startAll()
        startConfigFileWatcher()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    // MARK: Service Plugin Setup & Hot-Reload

    /// Creates and registers all service plugins from the current `activeGridConfig`.
    private func setupServicePlugins() {
        let serverURLPlugin = ServerURLDetectorPlugin()
        let allCustomPatterns = activeGridConfig.panes.flatMap { $0.patterns }
        if !allCustomPatterns.isEmpty {
            serverURLPlugin.setCustomPatterns(allCustomPatterns)
        }
        servicePluginRegistry.register(serverURLPlugin, disabledByDefault: true)

        let claudeAttentionPlugin = ClaudeAttentionPlugin()
        servicePluginRegistry.register(claudeAttentionPlugin)

        let sendTextPlugin = SendTextIndicatorPlugin()
        servicePluginRegistry.register(sendTextPlugin)

        let quickActionsPlugin = QuickActionsPlugin()
        if let configDir = configFilePath.flatMap({
            ($0 as NSString).deletingLastPathComponent
        }) {
            quickActionsPlugin.actionsFilePath = (configDir as NSString)
                .appendingPathComponent(".trm-actions.toml")
        }
        servicePluginRegistry.register(quickActionsPlugin)

        let shortcutExtractorPlugin = ShortcutExtractorPlugin()
        servicePluginRegistry.register(shortcutExtractorPlugin, disabledByDefault: true)

        // Subprocess plugin example (Phase 2/3 integration path):
        //
        // let subprocessPlugin = SubprocessPluginHost(
        //     id: "my_scanner",
        //     name: "My Custom Scanner",
        //     executablePath: "/path/to/plugin-executable",
        //     config: HostConfigPayload(patterns: ["custom_regex"])
        // )
        // servicePluginRegistry.register(subprocessPlugin)
    }

    /// Tear down all plugins, re-read the config file, and re-register fresh plugins.
    func reloadServicePlugins() {
        servicePluginRegistry.unregisterAll()

        // Re-read the config if we have a file path.
        if let path = configFilePath {
            gridConfigOverride = Trm.gridConfig(fromConfigPath: path)
        }

        setupServicePlugins()
        servicePluginRegistry.startAll()
    }

    /// Start watching the config file for changes via a DispatchSource.
    private func startConfigFileWatcher() {
        guard let path = configFilePath else { return }
        openConfigFileWatcher(path: path)
    }

    /// Open (or re-open) a file watcher on the given path.
    private func openConfigFileWatcher(path: String) {
        // Clean up any existing watcher first.
        stopConfigFileWatcher()

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic save (e.g. vim): file was replaced. Tear down and re-open
                // after a short delay to let the editor finish writing the new file.
                self.stopConfigFileWatcher()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    guard let self else { return }
                    self.openConfigFileWatcher(path: path)
                    self.debounceConfigReload()
                }
            } else {
                self.debounceConfigReload()
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        configFileWatcher = source
    }

    /// Cancel the config file watcher and release its file descriptor.
    private func stopConfigFileWatcher() {
        configReloadDebounce?.cancel()
        configReloadDebounce = nil
        if let watcher = configFileWatcher {
            watcher.cancel()
            configFileWatcher = nil
        }
    }

    /// Debounce config reload to coalesce rapid saves (300ms).
    private func debounceConfigReload() {
        configReloadDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reloadServicePlugins()
        }
        configReloadDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: item)
    }

    // MARK: Methods

    /// Add a new pane to the grid layout.
    ///
    /// Horizontal splits (right/left) add a column to the row containing the focused surface.
    /// Vertical splits (down/up) add a new row below/above the focused surface's row.
    @discardableResult
    func newGridPane(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard let ghostty_app = ghostty.app else { return nil }
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        newView.paneId = nextAvailablePaneId()

        // Use the VISUAL order (gridPanes respects paneDisplayOrder) to find
        // which row/col the focused surface occupies on screen.
        let visualPanes = gridPanes
        let visualIndex = visualPanes.firstIndex(where: {
            if case .terminal(let s) = $0 { return s === oldView }
            return false
        }) ?? 0
        let (row, _) = gridPosition(flatIndex: visualIndex)

        // Collect the terminal surfaces in visual order for the current row so
        // we can determine tree insertion points relative to visual neighbours.
        let visualRowStart = flatIndexFor(row: row, col: 0)
        let colsInRow = row < gridRowCols.count ? gridRowCols[row] : 1
        let visualRowEnd = visualRowStart + colsInRow - 1

        // Helper: extract the SurfaceView from a GridPane (terminal only).
        func surface(of pane: GridPane) -> Ghostty.SurfaceView? {
            if case .terminal(let s) = pane { return s }
            return nil
        }

        // The tree's flat order. Insertion into the split tree is always
        // .right (append after), so we need to pick the correct tree-order
        // neighbour as anchor.
        let treeSurfaces = Array(surfaceTree)
        let oldTreeIndex = treeSurfaces.firstIndex(where: { $0 === oldView }) ?? 0

        let insertAfter: Ghostty.SurfaceView
        switch direction {
        case .right:
            insertAfter = oldView
        case .left:
            if oldTreeIndex > 0 {
                insertAfter = treeSurfaces[oldTreeIndex - 1]
            } else {
                insertAfter = oldView
            }
        case .down:
            // Insert after the last surface of the current VISUAL row.
            let lastVisualIdx = min(visualRowEnd, visualPanes.count - 1)
            if let s = surface(of: visualPanes[lastVisualIdx]) {
                insertAfter = s
            } else {
                insertAfter = oldView
            }
        case .up:
            // Insert before the first surface of the current VISUAL row.
            if visualRowStart > 0, let s = surface(of: visualPanes[visualRowStart - 1]) {
                insertAfter = s
            } else {
                insertAfter = oldView
            }
        }

        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(
                view: newView,
                at: insertAfter,
                direction: .right)
        } catch {
            Ghostty.logger.warning("failed to insert grid pane: \(error)")
            return nil
        }

        // Update grid shape based on direction
        switch direction {
        case .right, .left:
            if row < gridRowCols.count {
                gridRowCols[row] += 1
            }
        case .down:
            let insertRow = min(row + 1, gridRowCols.count)
            gridRowCols.insert(1, at: insertRow)
        case .up:
            gridRowCols.insert(1, at: row)
        }

        // Insert the new pane into paneDisplayOrder at the correct visual
        // position so the grid doesn't reorder existing panes.
        let newId = ObjectIdentifier(newView)
        if !paneDisplayOrder.isEmpty {
            let displayInsertPos: Int
            switch direction {
            case .right:
                displayInsertPos = min(visualIndex + 1, paneDisplayOrder.count)
            case .left:
                displayInsertPos = visualIndex
            case .down:
                displayInsertPos = min(visualRowEnd + 1, paneDisplayOrder.count)
            case .up:
                displayInsertPos = visualRowStart
            }
            paneDisplayOrder.insert(newId, at: displayInsertPos)
        }

        replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: "New Pane")

        return newView
    }

    /// Convert a flat surface index to (row, col) in the grid.
    private func gridPosition(flatIndex: Int) -> (row: Int, col: Int) {
        var offset = 0
        for (row, cols) in gridRowCols.enumerated() {
            if flatIndex < offset + cols {
                return (row, flatIndex - offset)
            }
            offset += cols
        }
        // Fallback to last row
        return (max(gridRowCols.count - 1, 0), 0)
    }

    /// Resolve the current terminal pane index for a specific surface.
    func paneIndex(for surface: Ghostty.SurfaceView) -> Int? {
        gridSurfaces.firstIndex(where: { $0 === surface })
    }

    /// Allocate a globally unique pane ID from the Zig backend.
    private func nextAvailablePaneId() -> Int {
        return Trm.shared.allocPaneId()
    }

    // MARK: - Pane Display Order

    /// Ensure `paneDisplayOrder` reflects the current pane set.
    /// Called lazily before the first move or when needed.
    private func ensurePaneDisplayOrder() {
        let allIDs = gridPanes.map(\.id)
        if paneDisplayOrder.count == allIDs.count {
            return
        }
        paneDisplayOrder = allIDs
    }

    /// Append a new pane ID to the display order. If the order array
    /// hasn't been initialized yet, build it from the current panes first.
    private func appendToPaneDisplayOrder(_ id: ObjectIdentifier) {
        if paneDisplayOrder.isEmpty && gridPanes.count > 1 {
            // Rebuild from all panes except the one we're about to add
            // (it's already in the sub-array but gridPanes re-derives).
            paneDisplayOrder = gridPanes.map(\.id)
            if !paneDisplayOrder.contains(id) {
                paneDisplayOrder.append(id)
            }
        } else if !paneDisplayOrder.isEmpty {
            if !paneDisplayOrder.contains(id) {
                paneDisplayOrder.append(id)
            }
        }
    }

    /// Insert a new pane ID into display order at the end of the given row.
    /// If the order array hasn't been initialized yet, build it first.
    private func insertIntoPaneDisplayOrder(_ id: ObjectIdentifier, atEndOfRow row: Int) {
        if paneDisplayOrder.isEmpty && gridPanes.count > 1 {
            paneDisplayOrder = gridPanes.map(\.id)
        }
        guard !paneDisplayOrder.isEmpty else { return }
        guard row >= 0, row < gridRowCols.count else { return }
        let rowEnd = flatIndexFor(row: row, col: gridRowCols[row] - 1)
        let insertPos = min(rowEnd, paneDisplayOrder.count)
        if !paneDisplayOrder.contains(id) {
            paneDisplayOrder.insert(id, at: insertPos)
        }
    }

    /// Determine which row the currently focused surface is in.
    private func focusedRow() -> Int {
        guard let surface = focusedSurface else { return max(gridRowCols.count - 1, 0) }
        let visualPanes = gridPanes
        if let idx = visualPanes.firstIndex(where: {
            if case .terminal(let s) = $0 { return s === surface }
            return false
        }) {
            return gridPosition(flatIndex: idx).row
        }
        return max(gridRowCols.count - 1, 0)
    }

    /// Move pane in the given direction within the grid.
    enum PaneMoveDirection {
        case left, right, up, down
    }

    func movePane(_ pane: GridPane, direction: PaneMoveDirection) {
        ensurePaneDisplayOrder()
        let panes = gridPanes
        guard panes.count > 1 else { return }

        guard let flatIndex = panes.firstIndex(where: { $0.id == pane.id }) else { return }
        let (srcRow, col) = gridPosition(flatIndex: flatIndex)

        switch direction {
        case .left:
            guard col > 0 else { return }
            swapPanesInDisplayOrder(panes, flatIndex, flatIndex - 1)

        case .right:
            let rowCols = srcRow < gridRowCols.count ? gridRowCols[srcRow] : 1
            guard col < rowCols - 1 else { return }
            swapPanesInDisplayOrder(panes, flatIndex, flatIndex + 1)

        case .up:
            guard srcRow > 0 else { return }
            relocatePane(panes, flatIndex: flatIndex, fromRow: srcRow, toRow: srcRow - 1)

        case .down:
            guard srcRow < gridRowCols.count - 1 else { return }
            relocatePane(panes, flatIndex: flatIndex, fromRow: srcRow, toRow: srcRow + 1)
        }

        // Flash the moved pane's watermark so the user can track it.
        // Delay slightly so SwiftUI finishes re-laying out the grid before
        // the highlight triggers — otherwise the view may be recreated at its
        // new position and miss the onChange transition.
        if case .terminal(let surface) = pane, let pid = surface.paneId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NotificationCenter.default.post(
                    name: Trm.highlightPane,
                    object: nil,
                    userInfo: ["paneId": pid]
                )
            }
        }
    }

    /// Swap two panes within the same row in display order and sync Zig state.
    private func swapPanesInDisplayOrder(_ panes: [GridPane], _ i: Int, _ j: Int) {
        let srcID = panes[i].id
        let dstID = panes[j].id
        guard let srcOrderIdx = paneDisplayOrder.firstIndex(of: srcID),
              let dstOrderIdx = paneDisplayOrder.firstIndex(of: dstID) else { return }
        paneDisplayOrder.swapAt(srcOrderIdx, dstOrderIdx)

        // Keep the Zig-side grid_order in sync so watermarks, Text Tap, and
        // other pane-indexed features follow the moved pane.
        if case .terminal(let srcSurface) = panes[i],
           case .terminal(let dstSurface) = panes[j],
           let srcPaneId = srcSurface.paneId,
           let dstPaneId = dstSurface.paneId {
            if let h = Trm.shared.handle {
                termania_swap_pane_order(h, UInt32(srcPaneId), UInt32(dstPaneId))
            }
        }
    }

    /// Relocate a pane from one row to another (used for up/down moves).
    /// Removes the pane from the source row, adjusts `gridRowCols`, and
    /// appends it to the end of the target row.
    private func relocatePane(_ panes: [GridPane], flatIndex: Int, fromRow: Int, toRow: Int) {
        var layout = GridLayout<ObjectIdentifier>(
            rowCols: gridRowCols,
            displayOrder: paneDisplayOrder
        )
        layout.relocate(flatIndex: flatIndex, fromRow: fromRow, toRow: toRow)
        gridRowCols = layout.rowCols
        paneDisplayOrder = layout.displayOrder
    }

    /// Move the currently focused pane in the given direction.
    func moveFocusedPane(_ direction: PaneMoveDirection) {
        guard let surface = focusedSurface else { return }
        let pane = GridPane.terminal(surface)
        movePane(pane, direction: direction)
    }

    private func flatIndexFor(row: Int, col: Int) -> Int {
        var offset = 0
        for r in 0..<row {
            if r < gridRowCols.count {
                offset += gridRowCols[r]
            }
        }
        return offset + col
    }

    private func capturePlacement(forTerminal surface: Ghostty.SurfaceView) -> PaneRestorePlacement? {
        guard let flatIndex = gridSurfaces.firstIndex(where: { $0 === surface }) else { return nil }
        let (row, _) = gridPosition(flatIndex: flatIndex)
        let displayIdx = paneDisplayOrder.firstIndex(of: ObjectIdentifier(surface))
        return .init(controller: .init(self), row: row, flatIndex: flatIndex,
                     displayOrderIndex: displayIdx)
    }

    private func capturePlacement(forWebview pane: WebViewPane) -> PaneRestorePlacement? {
        guard let webIdx = webviewPanes.firstIndex(where: { $0.id == pane.id }) else { return nil }
        let flatIndex = gridSurfaces.count + webIdx
        let (row, _) = gridPosition(flatIndex: flatIndex)
        let displayIdx = paneDisplayOrder.firstIndex(of: ObjectIdentifier(pane))
        return .init(controller: .init(self), row: row, flatIndex: flatIndex,
                     displayOrderIndex: displayIdx)
    }

    private func applyRestoredRowInsert(_ row: Int) {
        if row < gridRowCols.count {
            gridRowCols[row] += 1
            return
        }
        if row <= gridRowCols.count {
            gridRowCols.insert(1, at: row)
            return
        }
        if gridRowCols.isEmpty {
            gridRowCols = [1]
            return
        }
        gridRowCols[gridRowCols.count - 1] += 1
    }

    /// Move a pane into its own window.
    func detachPaneToWindow(_ pane: GridPane) {
        switch pane {
        case .terminal(let surface):
            moveTerminalSurfaceToOwnWindow(surface)
        case .webview(let pane):
            moveWebviewPaneToOwnWindow(pane)
        case .plugin:
            break
        }
    }

    /// Move a pane from this window into another existing terminal window.
    func attachPaneToAnotherWindow(_ pane: GridPane) {
        switch pane {
        case .terminal(let surface):
            moveTerminalSurfaceToAnotherWindow(surface)
        case .webview(let pane):
            moveWebviewPaneToAnotherWindow(pane)
        case .plugin:
            break
        }
    }

    /// Pick a target window for "attach back" operations.
    private func attachTargetController() -> BaseTerminalController? {
        if let preferred = TerminalController.preferredParent, preferred !== self {
            return preferred
        }

        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard controller !== self else { continue }
            guard window.isVisible, !window.isMiniaturized else { continue }
            return controller
        }

        return nil
    }

    private func moveTerminalSurfaceToOwnWindow(_ target: Ghostty.SurfaceView, position: NSPoint? = nil) {
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }
        guard gridPanes.count > 1 else { return }
        let restorePlacement = capturePlacement(forTerminal: target)

        Ghostty.logger.info("detach: moving surface \(String(describing: ObjectIdentifier(target))) from \(self.gridPanes.count)-pane window")

        // Suppress ghosttyDidCloseSurface notifications during the move so that
        // close events fired by libghostty in the transition gap don't kill the
        // surface while it is between windows.
        isMovingSurface = true
        defer { isMovingSurface = false }

        // If we are removing our focused surface then we move it. We need to
        // keep track of our old one so undo sends focus back to the right place.
        let oldFocusedSurface = focusedSurface
        if focusedSurface == target {
            focusedSurface = findNextFocusTargetAfterClosing(node: targetNode)
        }

        // Remove the surface from our tree.
        let removedTree = surfaceTree.removing(targetNode)

        // Create a new tree with the dragged surface and open a new window.
        let newTree = SplitTree<Ghostty.SurfaceView>(view: target)

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Pane")
        defer {
            undoManager?.endUndoGrouping()
        }

        // Keep row/column geometry in sync with the pane removal so that
        // attaching this pane back can restore the previous layout shape.
        if let restorePlacement {
            let row = restorePlacement.row
            if row < gridRowCols.count {
                if gridRowCols[row] > 1 {
                    gridRowCols[row] -= 1
                } else if gridRowCols.count > 1 {
                    gridRowCols.remove(at: row)
                }
                if gridRowCols.isEmpty {
                    gridRowCols = [1]
                }
            }
        }

        // Remove the detached surface from paneDisplayOrder so the grid
        // rendering in the old window doesn't reference a stale entry.
        if !paneDisplayOrder.isEmpty {
            paneDisplayOrder.removeAll { $0 == ObjectIdentifier(target) }
        }

        // Suppress undo registration for the tree replacement in the old window.
        // The default undo registered by replaceSurfaceTree captures the old tree
        // (which still contains the moved surface), creating dual-ownership if the
        // user later undoes. We register a correct undo action below instead.
        undoManager?.disableUndoRegistration {
            replaceSurfaceTree(removedTree, moveFocusFrom: oldFocusedSurface)
        }

        // Open the new window synchronously to minimize the transition gap where
        // the surface exists in neither window's tree.
        let detached = TerminalController.newWindow(
            ghostty,
            tree: newTree,
            position: position,
            confirmUndo: false,
            showImmediately: true
        )
        if let restorePlacement {
            detached.detachedTerminalOrigins[ObjectIdentifier(target)] = restorePlacement
        }

        Ghostty.logger.info("detach: surface moved to new window, old window now has \(self.gridPanes.count) panes")

        // Briefly highlight the popped-out pane in its new window.
        if let pid = target.paneId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(
                    name: Trm.highlightPane,
                    object: nil,
                    userInfo: ["paneId": pid]
                )
            }
        }
    }

    private func moveTerminalSurfaceToAnotherWindow(_ source: Ghostty.SurfaceView) {
        guard let sourceNode = surfaceTree.root?.node(view: source) else { return }
        let sourceKey = ObjectIdentifier(source)
        let restorePlacement = detachedTerminalOrigins[sourceKey]
        let restoredTarget = restorePlacement?.controller.value

        let targetController: BaseTerminalController
        if let restoredTarget, restoredTarget !== self {
            targetController = restoredTarget
        } else if let fallback = attachTargetController() {
            targetController = fallback
        } else {
            return
        }

        let oldSurfaces = targetController.gridSurfaces
        let destination: Ghostty.SurfaceView?
        let insertDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        if let restorePlacement,
           restorePlacement.controller.value === targetController {
            if oldSurfaces.isEmpty {
                destination = nil
                insertDirection = .right
            } else {
                let desiredIndex = min(max(restorePlacement.flatIndex, 0), oldSurfaces.count)
                if desiredIndex >= oldSurfaces.count {
                    destination = oldSurfaces.last
                    insertDirection = .right
                } else {
                    destination = oldSurfaces[desiredIndex]
                    insertDirection = .left
                }
            }
        } else {
            destination = targetController.focusedSurface ?? oldSurfaces.first
            insertDirection = .right
        }

        let targetTree: SplitTree<Ghostty.SurfaceView>

        do {
            if let destination {
                targetTree = try targetController.surfaceTree.inserting(
                    view: source,
                    at: destination,
                    direction: insertDirection
                )
            } else {
                targetTree = .init(view: source)
            }
        } catch {
            Ghostty.logger.warning("failed to attach pane to target window: \(error)")
            return
        }

        // Suppress ghosttyDidCloseSurface notifications on both controllers
        // during the move so that close events fired by libghostty in the
        // transition gap don't kill the surface while it is between windows.
        isMovingSurface = true
        targetController.isMovingSurface = true
        defer {
            isMovingSurface = false
            targetController.isMovingSurface = false
        }

        // Update target grid shape and tree FIRST, so the surface is owned
        // by the target before we remove it from the source. This prevents
        // the surface from being deallocated if the source window closes.
        if let restorePlacement,
           restorePlacement.controller.value === targetController {
            targetController.applyRestoredRowInsert(restorePlacement.row)
        } else if let destination {
            if let idx = oldSurfaces.firstIndex(where: { $0 === destination }) {
                let (row, _) = targetController.gridPosition(flatIndex: idx)
                if row < targetController.gridRowCols.count {
                    targetController.gridRowCols[row] += 1
                } else if let last = targetController.gridRowCols.indices.last {
                    targetController.gridRowCols[last] += 1
                } else {
                    targetController.gridRowCols = [1]
                }
            } else if let last = targetController.gridRowCols.indices.last {
                targetController.gridRowCols[last] += 1
            } else {
                targetController.gridRowCols = [1]
            }
        } else {
            let existingExtraCount = targetController.webviewPanes.count + targetController.pluginPanes.count
            targetController.gridRowCols = [max(1, existingExtraCount + 1)]
        }

        // Post the highlight notification synchronously BEFORE the tree swap
        // so that the suppress flag is set before the focus-change handler fires.
        if let pid = source.paneId {
            NotificationCenter.default.post(
                name: Trm.highlightPane,
                object: nil,
                userInfo: ["paneId": pid]
            )
        }

        targetController.replaceSurfaceTree(
            targetTree,
            moveFocusTo: source,
            moveFocusFrom: targetController.focusedSurface,
            undoAction: "Move Pane"
        )

        // Insert the surface at the correct position in paneDisplayOrder so
        // that the visual grid order matches the restored position.
        let sourceId = ObjectIdentifier(source)
        if !targetController.paneDisplayOrder.isEmpty {
            targetController.paneDisplayOrder.removeAll { $0 == sourceId }
            if let restorePlacement,
               restorePlacement.controller.value === targetController,
               let displayIdx = restorePlacement.displayOrderIndex {
                // Restore to the original display order position.
                let insertPos = min(displayIdx, targetController.paneDisplayOrder.count)
                targetController.paneDisplayOrder.insert(sourceId, at: insertPos)
            } else {
                // No saved position — use the tree flat index as best guess.
                let newSurfaces = Array(targetTree)
                let insertedFlatIndex = newSurfaces.firstIndex(where: { $0 === source }) ?? newSurfaces.count - 1
                let insertPos = min(insertedFlatIndex, targetController.paneDisplayOrder.count)
                targetController.paneDisplayOrder.insert(sourceId, at: insertPos)
            }
        }

        // Now remove from source. The surface is safely owned by the target
        // tree, so even if the source window closes, the surface survives.
        // Use direct tree manipulation instead of removeSurfaceNode() to avoid
        // registering a "Close Terminal" undo and triggering window-close logic
        // that would deallocate the surface.
        let oldFocused = focusedSurface
        if focusedSurface == source {
            focusedSurface = findNextFocusTargetAfterClosing(node: sourceNode)
        }

        if useGridLayout {
            let surfaces = Array(surfaceTree)
            if let flatIdx = surfaces.firstIndex(where: { $0 === source }) {
                let (row, _) = gridPosition(flatIndex: flatIdx)
                if row < gridRowCols.count {
                    if gridRowCols[row] > 1 {
                        gridRowCols[row] -= 1
                    } else if gridRowCols.count > 1 {
                        gridRowCols.remove(at: row)
                    }
                    if gridRowCols.isEmpty {
                        gridRowCols = [1]
                    }
                }
            }
        }

        if !paneDisplayOrder.isEmpty {
            paneDisplayOrder.removeAll { $0 == sourceKey }
        }

        let removedTree = surfaceTree.removing(sourceNode)
        undoManager?.disableUndoRegistration {
            replaceSurfaceTree(removedTree, moveFocusFrom: oldFocused)
        }

        // If the source window is now empty (this was its only pane), close it.
        // The surface is safe because the target already owns it.
        if surfaceTree.isEmpty && webviewPanes.isEmpty && pluginPanes.isEmpty {
            if let terminal = self as? TerminalController {
                terminal.closeTabImmediately(registerRedo: false)
            } else {
                window?.close()
            }
        }

        targetController.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        _ = detachedTerminalOrigins.removeValue(forKey: sourceKey)
    }

    private func insertWebviewPane(_ pane: WebViewPane, at index: Int? = nil, preferredRow: Int? = nil) {
        let insertAt = min(max(index ?? webviewPanes.count, 0), webviewPanes.count)
        webviewPanes.insert(pane, at: insertAt)

        if let preferredRow {
            appendToPaneDisplayOrder(ObjectIdentifier(pane))
            applyRestoredRowInsert(preferredRow)
            return
        }

        if gridRowCols.isEmpty {
            gridRowCols = [1]
        }
        let row = focusedRow()
        gridRowCols[row] += 1
        insertIntoPaneDisplayOrder(ObjectIdentifier(pane), atEndOfRow: row)
    }

    private func insertPluginPane(_ pane: PluginPane, at index: Int? = nil, preferredRow: Int? = nil) {
        let insertAt = min(max(index ?? pluginPanes.count, 0), pluginPanes.count)
        pluginPanes.insert(pane, at: insertAt)

        if let preferredRow {
            appendToPaneDisplayOrder(ObjectIdentifier(pane))
            applyRestoredRowInsert(preferredRow)
            return
        }

        if gridRowCols.isEmpty {
            gridRowCols = [1]
        }
        let row = focusedRow()
        gridRowCols[row] += 1
        insertIntoPaneDisplayOrder(ObjectIdentifier(pane), atEndOfRow: row)
    }

    @discardableResult
    private func removeWebviewPane(_ pane: WebViewPane) -> Bool {
        guard let idx = webviewPanes.firstIndex(where: { $0.id == pane.id }) else { return false }
        let flatIndex = gridSurfaces.count + idx
        let (row, _) = gridPosition(flatIndex: flatIndex)
        webviewPanes.remove(at: idx)
        paneDisplayOrder.removeAll { $0 == ObjectIdentifier(pane) }

        if row < gridRowCols.count {
            if gridRowCols[row] > 1 {
                gridRowCols[row] -= 1
            } else if gridRowCols.count > 1 {
                gridRowCols.remove(at: row)
            }
        }

        closeWindowIfNoPanes()
        return true
    }

    @discardableResult
    private func removePluginPane(_ pane: PluginPane) -> Bool {
        guard let idx = pluginPanes.firstIndex(where: { $0.id == pane.id }) else { return false }
        let flatIndex = gridSurfaces.count + webviewPanes.count + idx
        let (row, _) = gridPosition(flatIndex: flatIndex)
        pluginPanes.remove(at: idx)
        paneDisplayOrder.removeAll { $0 == ObjectIdentifier(pane) }

        if row < gridRowCols.count {
            if gridRowCols[row] > 1 {
                gridRowCols[row] -= 1
            } else if gridRowCols.count > 1 {
                gridRowCols.remove(at: row)
            }
        }

        closeWindowIfNoPanes()
        return true
    }

    /// Resolve the best URL to use when transferring a web pane between windows.
    private func transferableURL(for pane: WebViewPane) -> URL {
        pane.currentURL ?? pane.webView.url ?? pane.initialURL
    }

    private func moveWebviewPaneToOwnWindow(_ pane: WebViewPane) {
        let restorePlacement = capturePlacement(forWebview: pane)
        let url = transferableURL(for: pane)
        guard removeWebviewPane(pane) else { return }

        let detached = TerminalController.newWindow(ghostty)
        DispatchQueue.main.async {
            // Recreate the web pane in the destination window. Reparenting the
            // same WKWebView between windows can result in a blank renderer.
            let detachedPane = WebViewPane(url: url)
            detached.insertWebviewPane(detachedPane)
            if let restorePlacement {
                detached.detachedWebviewOrigins[detachedPane.id] = restorePlacement
            }

            // Make this a webview-only window by removing the auto-created terminal pane.
            if let firstSurface = detached.gridSurfaces.first {
                detached.closeSurface(firstSurface, withConfirmation: false)
            }
        }
    }

    private func moveWebviewPaneToAnotherWindow(_ pane: WebViewPane) {
        let url = transferableURL(for: pane)
        let restorePlacement = detachedWebviewOrigins[pane.id]
        let restoredTarget = restorePlacement?.controller.value

        let targetController: BaseTerminalController
        if let restoredTarget, restoredTarget !== self {
            targetController = restoredTarget
        } else if let fallback = attachTargetController() {
            targetController = fallback
        } else {
            return
        }

        guard removeWebviewPane(pane) else { return }

        let oldSurfaceCount = targetController.gridSurfaces.count
        let webInsertIndex: Int?
        if let restorePlacement,
           restorePlacement.controller.value === targetController {
            webInsertIndex = max(0, min(
                restorePlacement.flatIndex - oldSurfaceCount,
                targetController.webviewPanes.count
            ))
        } else {
            webInsertIndex = nil
        }

        // Recreate instead of moving the same view instance to avoid blank panes.
        targetController.insertWebviewPane(
            WebViewPane(url: url),
            at: webInsertIndex,
            preferredRow: restorePlacement?.controller.value === targetController
                ? restorePlacement?.row
                : nil
        )
        targetController.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        _ = detachedWebviewOrigins.removeValue(forKey: pane.id)
    }

    private func closeWindowIfNoPanes() {
        guard surfaceTree.isEmpty, webviewPanes.isEmpty, pluginPanes.isEmpty else { return }
        if let terminal = self as? TerminalController {
            // If this controller lives inside a tab group, only close this tab.
            // Closing the whole window group here can unexpectedly terminate
            // unrelated tabs/panes.
            terminal.closeTabImmediately()
        } else {
            window?.close()
        }
    }

    /// Move focus to a surface view.
    func focusSurface(_ view: Ghostty.SurfaceView) {
        // Check if target surface is in our tree
        guard surfaceTree.contains(view) else { return }

        // Move focus to the target surface and activate the window/app
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: view)
            view.window?.makeKeyAndOrderFront(nil)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - LLM Integration

    /// Build pane context for the LLM system prompt.
    func buildPaneContext() -> [PaneContext] {
        let surfaces = gridSurfaces
        return surfaces.enumerated().map { index, surface in
            let title = surface.title.isEmpty ? "Shell" : surface.title
            let isFocused = surface === focusedSurface

            // Get visible text from the surface's cached contents.
            let visibleText = surface.cachedScreenContents.get()

            return PaneContext(
                paneId: surface.paneId ?? index,
                title: title,
                isFocused: isFocused,
                visibleText: visibleText
            )
        }
    }

    /// Execute a list of parsed LLM actions against the terminal.
    func executeTrmActions(_ actions: [TrmAction]) {
        let surfaces = gridSurfaces
        for action in actions {
            switch action {
            case .sendCommand(let paneId, let command):
                guard let surface = surfaces.first(where: { ($0.paneId ?? -1) == paneId }) else { continue }
                sendTextToSurface(surface, text: command + "\n")

            case .sendToAll(let command):
                for surface in surfaces {
                    sendTextToSurface(surface, text: command + "\n")
                }

            case .setTitle(let paneId, let title):
                Trm.shared.setWatermark(forPaneId: UInt32(paneId), text: title)

            case .setWatermark(let paneId, let watermark):
                Trm.shared.setWatermark(forPaneId: UInt32(paneId), text: watermark)

            case .clearWatermark(let paneId):
                Trm.shared.setWatermark(forPaneId: UInt32(paneId), text: "")

            case .spawnPane:
                if let current = focusedSurface ?? surfaces.first {
                    newGridPane(at: current, direction: .right)
                } else if let ghosttyApp = ghostty.app {
                    let newView = Ghostty.SurfaceView(ghosttyApp, baseConfig: nil)
                    newView.paneId = nextAvailablePaneId()
                    replaceSurfaceTree(
                        .init(view: newView),
                        moveFocusTo: newView,
                        moveFocusFrom: focusedSurface,
                        undoAction: "New Pane"
                    )
                    if gridRowCols.isEmpty {
                        gridRowCols = [1]
                    } else {
                        gridRowCols[gridRowCols.count - 1] += 1
                    }
                }

            case .closePane(let paneId):
                guard let surface = surfaces.first(where: { ($0.paneId ?? -1) == paneId }) else { continue }
                closeSurface(surface, withConfirmation: false)

            case .focusPane(let paneId):
                guard let surface = surfaces.first(where: { ($0.paneId ?? -1) == paneId }) else { continue }
                focusSurface(surface)

            case .message:
                // Messages are displayed in the command palette response area,
                // no additional action needed here.
                break
            }
        }
    }

    /// Send text to a specific surface via the `text:` binding action.
    private func sendTextToSurface(_ surface: Ghostty.SurfaceView, text: String) {
        guard let s = surface.surface else { return }
        let action = "text:" + text
        let len = action.utf8CString.count
        guard len > 0 else { return }
        action.withCString { cString in
            ghostty_surface_binding_action(s, cString, UInt(len - 1))
        }
    }

    /// Send a list of initial commands once the pane surface is ready.
    ///
    /// Window setup can race surface initialization; retry briefly so commands
    /// are not dropped when a surface handle is still nil.
    private func sendInitialCommandsWhenReady(
        _ commands: [String],
        to surface: Ghostty.SurfaceView,
        attemptsRemaining: Int = 200
    ) {
        guard attemptsRemaining > 0 else { return }

        if surface.surface != nil {
            for cmd in commands {
                sendTextToSurface(surface, text: cmd + "\n")
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendInitialCommandsWhenReady(
                commands,
                to: surface,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    /// Called when the surfaceTree variable changed.
    ///
    /// Subclasses should call super first.
    func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        // If our surface tree becomes empty then we have no focused surface.
        if (to.isEmpty) {
            focusedSurface = nil
        }
    }

    /// Update all surfaces with the focus state. This ensures that libghostty has an accurate view about
    /// what surface is focused. This must be called whenever a surface OR window changes focus.
    func syncFocusToSurfaceTree() {
        for surfaceView in surfaceTree {
            // Our focus state requires that this window is key and our currently
            // focused surface is the surface in this view.
            let focused: Bool = (window?.isKeyWindow ?? false) &&
                !commandPaletteIsShowing &&
                focusedSurface != nil &&
                surfaceView == focusedSurface!
            surfaceView.focusDidChange(focused)
        }
    }

    // Call this whenever the frame changes
    private func windowFrameDidChange() {
        // We need to update our saved frame information in case of monitor
        // changes (see didChangeScreenParameters notification).
        savedFrame = nil
        guard let window, let screen = window.screen else { return }
        savedFrame = .init(window: window.frame, screen: screen.visibleFrame)
    }

    func confirmClose(
        messageText: String,
        informativeText: String,
        completion: @escaping () -> Void
    ) {
        // If we already have an alert, we need to wait for that one.
        guard alert == nil else { return }

        // If there is no window to attach the modal then we assume success
        // since we'll never be able to show the modal.
        guard let window else {
            completion()
            return
        }

        // If we need confirmation by any, show one confirmation for all windows
        // in the tab group.
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { response in
            let alertWindow = alert.window
            self.alert = nil
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alertWindow.orderOut(nil)
                completion()
            }
        }

        // Store our alert so we only ever show one.
        self.alert = alert
    }

    /// Prompt the user to change the tab/window title.
    func promptTabTitle() {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Change Tab Title"
        alert.informativeText = "Leave blank to restore the default."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = titleOverride ?? window.title
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }

            let newTitle = textField.stringValue
            if newTitle.isEmpty {
                self.titleOverride = nil
            } else {
                self.titleOverride = newTitle
            }
        }
    }

    /// Close a surface from a view.
    func closeSurface(
        _ view: Ghostty.SurfaceView,
        withConfirmation: Bool = true
    ) {
        guard let node = surfaceTree.root?.node(view: view) else { return }
        closeSurface(node, withConfirmation: withConfirmation)
    }

    /// Close a surface node (which may contain splits), requesting confirmation if necessary.
    ///
    /// This will also insert the proper undo stack information in.
    func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // This node must be part of our tree
        guard surfaceTree.contains(node) else { return }

        // If the child process is not alive, then we exit immediately
        guard withConfirmation else {
            removeSurfaceNode(node)
            return
        }

        // Confirm close. We use an NSAlert instead of a SwiftUI confirmationDialog
        // due to SwiftUI bugs (see Ghostty #560). To repeat from #560, the bug is that
        // confirmationDialog allows the user to Cmd-W close the alert, but when doing
        // so SwiftUI does not update any of the bindings to note that window is no longer
        // being shown, and provides no callback to detect this.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            if let self {
                self.removeSurfaceNode(node)
            }
        }
    }

    // MARK: Split Tree Management

    /// Find the next surface to focus when a node is being closed.
    /// Goes to previous split unless we're the leftmost leaf, then goes to next.
    private func findNextFocusTargetAfterClosing(node: SplitTree<Ghostty.SurfaceView>.Node) -> Ghostty.SurfaceView? {
        guard let root = surfaceTree.root else { return nil }
        
        // If we're the leftmost, then we move to the next surface after closing.
        // Otherwise, we move to the previous.
        if root.leftmostLeaf() == node.leftmostLeaf() {
            return surfaceTree.focusTarget(for: .next, from: node)
        } else {
            return surfaceTree.focusTarget(for: .previous, from: node)
        }
    }
    
    /// Remove a node from the surface tree and move focus appropriately.
    ///
    /// This also updates the undo manager to support restoring this node.
    ///
    /// This does no confirmation and assumes confirmation is already done.
    private func removeSurfaceNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        // Move focus if the closed surface was focused and we have a next target
        let nextFocus: Ghostty.SurfaceView? = if node.contains(
            where: { $0 == focusedSurface }
        ) {
            findNextFocusTargetAfterClosing(node: node)
        } else {
            nil
        }

        // Update grid shape if in grid mode
        if useGridLayout, case .leaf(let view) = node {
            let surfaces = Array(surfaceTree)
            if let flatIdx = surfaces.firstIndex(where: { $0 === view }) {
                let (row, _) = gridPosition(flatIndex: flatIdx)
                if row < gridRowCols.count {
                    if gridRowCols[row] > 1 {
                        gridRowCols[row] -= 1
                    } else {
                        gridRowCols.remove(at: row)
                    }
                    // Ensure we always have at least [1] for the remaining surface
                    if gridRowCols.isEmpty {
                        gridRowCols = [1]
                    }
                }
            }
        }

        // Clear watermarks for surfaces being permanently closed (not moved).
        for surface in node {
            let id = surface.paneId ?? 0
            Trm.shared.setWatermark(forPaneId: UInt32(id), text: "")
        }

        replaceSurfaceTree(
            surfaceTree.removing(node),
            moveFocusTo: nextFocus,
            moveFocusFrom: focusedSurface,
            undoAction: "Close Terminal"
        )
    }

    func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // Setup our new split tree
        let oldTree = surfaceTree
        let oldSurfaces = Array(oldTree)
        let newSurfaces = Set(newTree.map { ObjectIdentifier($0) })

        // Watermark clearing is handled by removeSurfaceNode (for permanent
        // closes) and setupInitialPanes (for initial layout). We do NOT clear
        // watermarks here because replaceSurfaceTree is also called during pane
        // moves between windows, where the surface is still alive.

        surfaceTree = newTree
        if let newView {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: newView, from: oldView)
            }
        }
        
        // Setup our undo
        guard let undoManager else { return }
        if let undoAction {
            undoManager.setActionName(undoAction)
        }
        
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.surfaceTree = oldTree
            if let oldView {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: oldView, from: target.focusedSurface)
                }
            }
            
            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.replaceSurfaceTree(
                    newTree,
                    moveFocusTo: newView,
                    moveFocusFrom: target.focusedSurface,
                    undoAction: undoAction)
            }
        }
    }

    // MARK: Notifications

    @objc private func onTextTapSend(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let pane = userInfo["pane"] as? Int,
              let text = userInfo["text"] as? String else { return }

        let surfaces = gridSurfaces
        guard !surfaces.isEmpty else { return }

        // Split trailing CR/LF from the body so that programs using raw input
        // mode (e.g. Claude Code) receive the Enter as a separate write.
        let trailing = text.hasSuffix("\r") ? "\r" : text.hasSuffix("\n") ? "\n" : nil
        let body = trailing != nil ? String(text.dropLast()) : text

        let targets: [Ghostty.SurfaceView]
        if pane == -1 {
            targets = surfaces
        } else if pane < surfaces.count {
            targets = [surfaces[pane]]
        } else {
            return
        }

        // Send the body text.
        if !body.isEmpty {
            for surface in targets {
                sendTextToSurface(surface, text: body)
            }
        }

        // Send the trailing Enter after a short delay so the target program
        // can process the text first.
        if let cr = trailing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                for surface in targets {
                    self?.sendTextToSurface(surface, text: cr)
                }
            }
        }
    }

    @objc private func didChangeScreenParametersNotification(_ notification: Notification) {
        // If we have a window that is visible and it is outside the bounds of the
        // screen then we clamp it back to within the screen.
        guard let window else { return }
        guard window.isVisible else { return }

        // We ignore fullscreen windows because macOS automatically resizes
        // those back to the fullscreen bounds.
        guard !window.styleMask.contains(.fullScreen) else { return }

        guard let screen = window.screen else { return }
        let visibleFrame = screen.visibleFrame
        var newFrame = window.frame

        // Clamp width/height
        if newFrame.size.width > visibleFrame.size.width {
            newFrame.size.width = visibleFrame.size.width
        }
        if newFrame.size.height > visibleFrame.size.height {
            newFrame.size.height = visibleFrame.size.height
        }

        // Ensure the window is on-screen. We only do this if the previous frame
        // was also on screen. If a user explicitly wanted their window off screen
        // then we let it stay that way.
        x: if newFrame.origin.x < visibleFrame.origin.x {
            if let savedFrame, savedFrame.window.origin.x < savedFrame.screen.origin.x {
                break x;
            }

            newFrame.origin.x = visibleFrame.origin.x
        }
        y: if newFrame.origin.y < visibleFrame.origin.y {
            if let savedFrame, savedFrame.window.origin.y < savedFrame.screen.origin.y {
                break y;
            }

            newFrame.origin.y = visibleFrame.origin.y
        }

        // Apply the new window frame
        window.setFrame(newFrame, display: true)
    }

    @objc private func ghosttyConfigDidChangeBase(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // Update our derived config
        self.derivedConfig = DerivedConfig(config)
    }

    @objc private func ghosttyCommandPaletteDidToggle(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        toggleCommandPalette(nil)
    }

    @objc private func ghosttyMaximizeDidToggle(_ notification: Notification) {
        guard let window else { return }
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        window.zoom(nil)
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Notification) {
        guard !isMovingSurface else {
            Ghostty.logger.info("ghosttyDidCloseSurface suppressed during surface move")
            return
        }
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let node = surfaceTree.root?.node(view: target) else { return }
        closeSurface(
            node,
            withConfirmation: (notification.userInfo?["process_alive"] as? Bool) ?? false)
    }

    @objc private func ghosttyDidNewSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let oldView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: oldView) != nil else { return }

        // Notification must contain our base config
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        // Determine our desired direction
        guard let directionAny = notification.userInfo?["direction"] else { return }
        guard let direction = directionAny as? ghostty_action_split_direction_e else { return }
        let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch (direction) {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: splitDirection = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: splitDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: splitDirection = .down
        case GHOSTTY_SPLIT_DIRECTION_UP: splitDirection = .up
        default: return
        }

        // Always use grid layout — add pane to the grid
        newGridPane(at: oldView, direction: splitDirection, baseConfig: config)
    }


    @objc private func ghosttyDidPresentTerminal(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }

        // Bring the window to front and focus the surface.
        window?.makeKeyAndOrderFront(nil)
        
        // We use a small delay to ensure this runs after any UI cleanup
        // (e.g., command palette restoring focus to its original surface).
        Ghostty.moveFocus(to: target)
        Ghostty.moveFocus(to: target, delay: 0.1)

        // Show a brief highlight to help the user locate the presented terminal.
        target.highlight()
    }

    @objc private func ghosttyOpenURLInPane(_ notification: Notification) {
        // Only the key window's controller should handle this.
        guard window?.isKeyWindow == true else { return }
        guard let url = notification.userInfo?[Notification.Name.OpenURLInPaneURLKey] as? URL else { return }

        let pane = WebViewPane(url: url)
        insertWebviewPane(pane)
    }

    // MARK: Quick Actions

    /// Accessor for the quick-actions plugin registered in the service plugin registry.
    var quickActionsPlugin: QuickActionsPlugin? {
        servicePluginRegistry.plugins["quick_actions"] as? QuickActionsPlugin
    }

    @objc private func handleQuickActionExecute(_ notification: Notification) {
        guard window?.isKeyWindow == true else { return }
        guard let command = notification.userInfo?["command"] as? String,
              let paneId = notification.userInfo?["paneId"] as? Int else { return }
        let surfaces = gridSurfaces
        guard let surface = surfaces.first(where: { ($0.paneId ?? -1) == paneId }) else { return }
        sendTextToSurface(surface, text: command + "\n")
    }

    // MARK: Shortcut Extractor

    @objc private func handleShortcutExecute(_ notification: Notification) {
        guard window?.isKeyWindow == true else { return }
        guard let key = notification.userInfo?["key"] as? String,
              let paneId = notification.userInfo?["paneId"] as? Int else { return }
        let surfaces = gridSurfaces
        guard let surface = surfaces.first(where: { ($0.paneId ?? -1) == paneId }) else { return }
        // Send raw keystroke without newline — dev tools read stdin char-by-char.
        sendTextToSurface(surface, text: key)
    }

    /// Close and remove a webview pane from the grid.
    func closeWebviewPane(_ pane: WebViewPane) {
        _ = removeWebviewPane(pane)
    }

    /// Close and remove a utility plugin pane from the grid.
    func closePluginPane(_ pane: PluginPane) {
        _ = removePluginPane(pane)
    }

    @objc private func ghosttySurfaceDragEndedNoTarget(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        moveTerminalSurfaceToOwnWindow(
            target,
            position: notification.userInfo?[Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey] as? NSPoint
        )
    }

    // MARK: Local Events

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .flagsChanged:
            localEventFlagsChanged(event)

        default:
            event
        }
    }

    private func localEventFlagsChanged(_ event: NSEvent) -> NSEvent? {
        // Detect double-tap of Option key to toggle command palette.
        // Only process for our own window.
        if window?.isKeyWindow == true {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let optionOnly = flags == .option

            if optionOnly {
                // Option key was just pressed (alone)
                optionPressedAlone = true
            } else if optionPressedAlone && flags.isEmpty {
                // Option key was just released (it was pressed alone with no other keys)
                optionPressedAlone = false
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - lastOptionReleaseTime
                if elapsed < 0.3 {
                    // Double-tap detected
                    lastOptionReleaseTime = 0
                    DispatchQueue.main.async { [weak self] in
                        self?.toggleCommandPalette(nil)
                    }
                    return event
                }
                lastOptionReleaseTime = now
            } else {
                // Another modifier was involved, reset
                optionPressedAlone = false
            }
        }

        var surfaces: [Ghostty.SurfaceView] = surfaceTree.map { $0 }

        // If we're the main window receiving key input, then we want to avoid
        // calling this on our focused surface because that'll trigger a double
        // flagsChanged call.
        if NSApp.mainWindow == window {
            surfaces = surfaces.filter { $0 != focusedSurface }
        }

        for surface in surfaces {
            surface.flagsChanged(with: event)
        }

        return event
    }

    // MARK: TerminalViewDelegate

    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        let lastFocusedSurface = focusedSurface
        focusedSurface = to

        // Important to cancel any prior subscriptions
        focusedSurfaceCancellables = []

        // Setup our title listener. If we have a focused surface we always use that.
        // Otherwise, we try to use our last focused surface. In either case, we only
        // want to care if the surface is in the tree so we don't listen to titles of
        // closed surfaces.
        if let titleSurface = focusedSurface ?? lastFocusedSurface,
           surfaceTree.contains(titleSurface) {
            // If we have a surface, we want to listen for title changes.
            titleSurface.$title
                .combineLatest(titleSurface.$bell)
                .map { [weak self] in self?.computeTitle(title: $0, bell: $1) ?? "" }
                .sink { [weak self] in self?.titleDidChange(to: $0) }
                .store(in: &focusedSurfaceCancellables)
        } else {
            // There is no surface to listen to titles for.
            titleDidChange(to: "trm")
        }
    }
    
    private func computeTitle(title: String, bell: Bool) -> String {
        var result = title
        if (bell && ghostty.config.bellFeatures.contains(.title)) {
            result = "🔔 \(result)"
        }

        return result
    }

    private func titleDidChange(to: String) {
        lastComputedTitle = to
        applyTitleToWindow()
    }

    private func applyTitleToWindow() {
        guard let window else { return }
        
        if let titleOverride {
            window.title = computeTitle(
                title: titleOverride,
                bell: focusedSurface?.bell ?? false)
            return
        }
        
        window.title = lastComputedTitle
    }
    
    func pwdDidChange(to: URL?) {
        guard let window else { return }

        if derivedConfig.macosTitlebarProxyIcon == .visible {
            // Use the 'to' URL directly
            window.representedURL = to
        } else {
            window.representedURL = nil
        }
    }


    func cellSizeDidChange(to: NSSize) {
        guard derivedConfig.windowStepResize else { return }
        // Stage manager can sometimes present windows in such a way that the
        // cell size is temporarily zero due to the window being tiny. We can't
        // set content resize increments to this value, so avoid an assertion failure.
        guard to.width > 0 && to.height > 0 else { return }
        self.window?.contentResizeIncrements = to
    }

    func performSplitAction(_ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            splitDidResize(node: resize.node, to: resize.ratio)
        case .drop(let drop):
            splitDidDrop(source: drop.payload, destination: drop.destination, zone: drop.zone)
        }
    }

    private func splitDidResize(node: SplitTree<Ghostty.SurfaceView>.Node, to newRatio: Double) {
        let resizedNode = node.resizing(to: newRatio)
        do {
            surfaceTree = try surfaceTree.replacing(node: node, with: resizedNode)
        } catch {
            Ghostty.logger.warning("failed to replace node during split resize: \(error)")
        }
    }

    private func splitDidDrop(
        source: Ghostty.SurfaceView,
        destination: Ghostty.SurfaceView,
        zone: TerminalSplitDropZone
    ) {
        // Map drop zone to split direction
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
        
        // Check if source is in our tree
        if let sourceNode = surfaceTree.root?.node(view: source) {
            // Source is in our tree - same window move
            let treeWithoutSource = surfaceTree.removing(sourceNode)
            let newTree: SplitTree<Ghostty.SurfaceView>
            do {
                newTree = try treeWithoutSource.inserting(view: source, at: destination, direction: direction)
            } catch {
                Ghostty.logger.warning("failed to insert surface during drop: \(error)")
                return
            }
            
            replaceSurfaceTree(
                newTree,
                moveFocusTo: source,
                moveFocusFrom: focusedSurface,
                undoAction: "Move Pane")
            return
        }
        
        // Source is not in our tree - search other windows
        var sourceController: BaseTerminalController?
        var sourceNode: SplitTree<Ghostty.SurfaceView>.Node?
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard controller !== self else { continue }
            if let node = controller.surfaceTree.root?.node(view: source) {
                sourceController = controller
                sourceNode = node
                break
            }
        }
        
        guard let sourceController, let sourceNode else {
            Ghostty.logger.warning("source surface not found in any window during drop")
            return
        }
        
        // Remove from source controller's tree and add it to our tree.
        // We do this first because if there is an error then we can
        // abort.
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: source, at: destination, direction: direction)
        } catch {
            Ghostty.logger.warning("failed to insert surface during cross-window drop: \(error)")
            return
        }
        
        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Pane")
        defer {
            undoManager?.endUndoGrouping()
        }
        
        // Remove the node from the source.
        sourceController.removeSurfaceNode(sourceNode)

        if useGridLayout {
            let surfacesBeforeInsert = gridSurfaces
            if let destinationIdx = surfacesBeforeInsert.firstIndex(where: { $0 === destination }) {
                let (row, _) = gridPosition(flatIndex: destinationIdx)
                if row < gridRowCols.count {
                    gridRowCols[row] += 1
                } else if let last = gridRowCols.indices.last {
                    gridRowCols[last] += 1
                } else {
                    gridRowCols = [1]
                }
            } else if let last = gridRowCols.indices.last {
                gridRowCols[last] += 1
            } else {
                gridRowCols = [1]
            }
        }
        
        // Add in the surface to our tree
        replaceSurfaceTree(
            newTree,
            moveFocusTo: source,
            moveFocusFrom: focusedSurface)
    }

    func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        if handleInternalCommand(action, on: surfaceView) {
            return
        }

        guard let surface = surfaceView.surface else { return }
        let len = action.utf8CString.count
        if (len == 0) { return }
        _ = action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(len - 1))
        }
    }

    private enum InternalCommand {
        case loadToml(pathArg: String?)
        case saveToml(pathArg: String?)
        case addPane(type: String)
        case saveSession(name: String?)
        case restoreLastSession
        case restoreSession(name: String?)
        case clearAutoSave
    }

    private func handleInternalCommand(_ action: String, on surfaceView: Ghostty.SurfaceView) -> Bool {
        guard let command = parseInternalCommand(action) else { return false }

        switch command {
        case .loadToml(let pathArg):
            loadTomlConfig(pathArg: pathArg, on: surfaceView)
            return true
        case .saveToml(let pathArg):
            saveTomlConfig(pathArg: pathArg, on: surfaceView)
            return true
        case .addPane(let type):
            addPaneOfType(type, on: surfaceView)
            return true
        case .saveSession(let name):
            handleSaveSession(name: name)
            return true
        case .restoreLastSession:
            handleRestoreLastSession()
            return true
        case .restoreSession(let name):
            handleRestoreSession(name: name)
            return true
        case .clearAutoSave:
            SessionManager.clearAutoSaves()
            return true
        }
    }

    private func parseInternalCommand(_ action: String) -> InternalCommand? {
        var trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }

        let bareLoadNames: Set<String> = ["trm.load", "trm.load_toml", "load_toml"]
        if bareLoadNames.contains(trimmed) {
            return .loadToml(pathArg: nil)
        }

        for prefix in ["trm.load ", "trm.load_toml ", "load_toml "] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let arg = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeQuotedArgument(arg)
            return .loadToml(pathArg: normalized.isEmpty ? nil : normalized)
        }

        let bareSaveNames: Set<String> = ["trm.save", "trm.save_toml", "save_toml"]
        if bareSaveNames.contains(trimmed) {
            return .saveToml(pathArg: nil)
        }

        for prefix in ["trm.save ", "trm.save_toml ", "save_toml "] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let arg = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeQuotedArgument(arg)
            return .saveToml(pathArg: normalized.isEmpty ? nil : normalized)
        }

        // trm.add_pane <type> [arg] / trm.add <type> [arg]
        let bareAddNames: Set<String> = ["trm.add_pane", "trm.add"]
        if bareAddNames.contains(trimmed) {
            return nil  // type argument required
        }

        for prefix in ["trm.add_pane ", "trm.add "] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let arg = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !arg.isEmpty else { continue }
            return .addPane(type: arg)
        }

        // trm.save_session [name]
        let bareSaveSessionNames: Set<String> = ["trm.save_session"]
        if bareSaveSessionNames.contains(trimmed) {
            return .saveSession(name: nil)
        }
        for prefix in ["trm.save_session "] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let arg = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeQuotedArgument(arg)
            return .saveSession(name: normalized.isEmpty ? nil : normalized)
        }

        // trm.restore_last_session / trm.restore_last
        let restoreLastNames: Set<String> = ["trm.restore_last_session", "trm.restore_last"]
        if restoreLastNames.contains(trimmed) {
            return .restoreLastSession
        }

        // trm.restore_session [name]
        let bareRestoreSessionNames: Set<String> = ["trm.restore_session"]
        if bareRestoreSessionNames.contains(trimmed) {
            return .restoreSession(name: nil)
        }
        for prefix in ["trm.restore_session "] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let arg = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeQuotedArgument(arg)
            return .restoreSession(name: normalized.isEmpty ? nil : normalized)
        }

        // trm.clear_autosave
        if trimmed == "trm.clear_autosave" {
            return .clearAutoSave
        }

        return nil
    }

    private func normalizeQuotedArgument(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func loadTomlConfig(pathArg: String?, on surfaceView: Ghostty.SurfaceView) {
        let pathInput = pathArg ?? "trm.toml"
        let resolvedPath = resolveTomlPath(pathInput, on: surfaceView)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            presentInternalCommandError(
                title: "Could Not Load TOML",
                message: "File not found:\n\(resolvedPath)"
            )
            return
        }

        guard let config = Trm.gridConfig(fromConfigPath: resolvedPath) else {
            presentInternalCommandError(
                title: "Could Not Load TOML",
                message: "Failed to parse or read:\n\(resolvedPath)"
            )
            return
        }

        runtimeGridConfig = config
        setupInitialPanes(from: config)
    }

    private func saveTomlConfig(pathArg: String?, on surfaceView: Ghostty.SurfaceView) {
        let toml = buildCurrentConfigToml()

        if let pathArg {
            let resolvedPath = resolveTomlPath(pathArg, on: surfaceView)
            do {
                try toml.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
            } catch {
                presentInternalCommandError(
                    title: "Could Not Save TOML",
                    message: "Failed to write:\n\(resolvedPath)\n\n\(error.localizedDescription)"
                )
            }
            return
        }

        guard let window else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "trm.toml"
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .plainText]
        panel.directoryURL = URL(fileURLWithPath: resolveCommandWorkingDirectory(for: surfaceView), isDirectory: true)

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try toml.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.presentInternalCommandError(
                    title: "Could Not Save TOML",
                    message: "Failed to write:\n\(url.path)\n\n\(error.localizedDescription)"
                )
            }
        }
    }

    private func addPaneOfType(_ typeArg: String, on surfaceView: Ghostty.SurfaceView) {
        // Split into pane type and optional remainder (URL, content, path, etc.)
        let parts = typeArg.split(separator: " ", maxSplits: 1)
        let rawType = String(parts[0]).lowercased()
        let extraArg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil

        switch rawType {
        case "terminal", "terminal_pane":
            newGridPane(at: surfaceView, direction: .right)
            return

        case "webview", "browser":
            let urlString = extraArg ?? "about:blank"
            let url = URL(string: urlString) ?? URL(string: "about:blank")!
            let pane = WebViewPane(url: url)
            insertWebviewPane(pane)
            return

        default:
            break
        }

        // Try plugin pane kinds
        guard let kind = PluginPaneKind.fromPaneType(rawType) else {
            presentInternalCommandError(
                title: "Unknown Pane Type",
                message: "'\(rawType)' is not a recognized pane type.\n\nAvailable types: terminal, webview, notes, git_status, file_browser, log_viewer, process_monitor, markdown_preview, system_info, screen_capture"
            )
            return
        }

        // Map extraArg to the appropriate config field based on kind
        var content: String? = nil
        var repo: String? = nil
        var path: String? = nil
        var file: String? = nil

        if let extraArg {
            switch kind {
            case .notes:
                content = extraArg
            case .gitStatus:
                repo = extraArg
            case .fileBrowser, .logViewer:
                path = extraArg
            case .markdownPreview:
                file = extraArg
            default:
                break
            }
        }

        let config = Trm.TrmPaneConfig(
            paneType: rawType,
            command: nil,
            cwd: nil,
            watermark: nil,
            title: nil,
            url: nil,
            file: file,
            content: content,
            target: nil,
            targetTitle: nil,
            path: path,
            refreshMs: nil,
            repo: repo,
            initialCommands: [],
            patterns: []
        )
        let pane = PluginPane(kind: kind, config: config)
        insertPluginPane(pane)
    }

    // MARK: - Session Commands

    private func handleSaveSession(name: String?) {
        if let name, !name.isEmpty {
            SessionManager.saveNamedSession(name: name, controller: self)
            return
        }

        // Show name input dialog
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Save Session"
        alert.informativeText = "Enter a name for this session:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "my-session"
        alert.accessoryView = input

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let sessionName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionName.isEmpty else { return }
            SessionManager.saveNamedSession(name: sessionName, controller: self)
        }
    }

    private func handleRestoreLastSession() {
        SessionManager.restoreLastSession(ghostty: ghostty)
    }

    private func handleRestoreSession(name: String?) {
        if let name, !name.isEmpty {
            // Restore by name directly
            let sessions = SessionManager.listNamedSessions()
            if let session = sessions.first(where: { $0.name == name }) {
                SessionManager.restoreNamedSession(path: session.path, ghostty: ghostty)
            } else {
                presentInternalCommandError(
                    title: "Session Not Found",
                    message: "No saved session named '\(name)' was found."
                )
            }
            return
        }

        // Show picker dialog listing saved sessions
        let sessions = SessionManager.listNamedSessions()
        guard !sessions.isEmpty else {
            presentInternalCommandError(
                title: "No Saved Sessions",
                message: "There are no saved sessions to restore.\n\nUse \"Save Session As...\" to save one first."
            )
            return
        }

        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Restore Session"
        alert.informativeText = "Choose a saved session to restore:"
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        for session in sessions {
            let dateStr = dateFormatter.string(from: session.modificationDate)
            popup.addItem(withTitle: "\(session.name)  (\(dateStr))")
        }
        alert.accessoryView = popup

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let selectedIndex = popup.indexOfSelectedItem
            guard selectedIndex >= 0, selectedIndex < sessions.count else { return }
            let session = sessions[selectedIndex]
            SessionManager.restoreNamedSession(path: session.path, ghostty: self.ghostty)
        }
    }

    func buildCurrentConfigToml() -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = dateFormatter.string(from: Date())

        var lines: [String] = []
        lines.append("# trm session config — saved \(timestamp)")
        lines.append("")

        // [grid] section
        let rows = gridRowCols.count
        let cols = gridRowCols.max() ?? 1
        lines.append("[grid]")
        lines.append("rows = \(rows)")
        lines.append("cols = \(cols)")
        // Serialize per-row column counts so jagged grids survive round-trip.
        let isJagged = Set(gridRowCols).count > 1
        if isJagged {
            let rowColsStr = gridRowCols.map(String.init).joined(separator: ",")
            lines.append("row_cols = \(tomlQuote(rowColsStr))")
        }
        lines.append("gap = \(Int(gridGap))")
        lines.append("outer_padding = \(Int(gridPadding))")
        lines.append("")

        // Serialize panes in visual (display) order so watermarks,
        // positions, and pane types stay consistent on reload.
        let visualPanes = gridPanes
        for (index, pane) in visualPanes.enumerated() {
            switch pane {
            case .terminal(let surface):
                lines.append("[[panes]]")
                lines.append("pane_type = \"terminal\"")
                if let pwd = surface.pwd, !pwd.isEmpty {
                    lines.append("cwd = \(tomlQuote(pwd))")
                }
                let id = surface.paneId ?? index
                let watermark = Trm.shared.watermark(forPaneId: UInt32(id))
                if let watermark, !watermark.isEmpty {
                    lines.append("watermark = \(tomlQuote(watermark))")
                }
                lines.append("")

            case .webview(let webviewPane):
                lines.append("[[panes]]")
                lines.append("pane_type = \"webview\"")
                let url = webviewPane.currentURL ?? webviewPane.initialURL
                lines.append("url = \(tomlQuote(url.absoluteString))")
                if !webviewPane.title.isEmpty {
                    lines.append("title = \(tomlQuote(webviewPane.title))")
                }
                lines.append("")

            case .plugin(let pluginPane):
                lines.append("[[panes]]")
                lines.append("pane_type = \(tomlQuote(pluginPane.kind.rawValue))")
                if let title = pluginPane.configuredTitle, !title.isEmpty {
                    lines.append("title = \(tomlQuote(title))")
                }
                if let cwd = pluginPane.cwd, !cwd.isEmpty {
                    lines.append("cwd = \(tomlQuote(cwd))")
                }
                if let file = pluginPane.file, !file.isEmpty {
                    lines.append("file = \(tomlQuote(file))")
                }
                // For notes panes, save current text instead of original content
                if pluginPane.kind == .notes {
                    if !pluginPane.notesText.isEmpty {
                        lines.append("content = \(tomlQuote(pluginPane.notesText))")
                    }
                } else if let content = pluginPane.content, !content.isEmpty {
                    lines.append("content = \(tomlQuote(content))")
                }
                if let target = pluginPane.target, !target.isEmpty {
                    lines.append("target = \(tomlQuote(target))")
                }
                if let targetTitle = pluginPane.targetTitle, !targetTitle.isEmpty {
                    lines.append("target_title = \(tomlQuote(targetTitle))")
                }
                if let path = pluginPane.path, !path.isEmpty {
                    lines.append("path = \(tomlQuote(path))")
                }
                if let repo = pluginPane.repo, !repo.isEmpty {
                    lines.append("repo = \(tomlQuote(repo))")
                }
                if let refreshMs = pluginPane.refreshMs {
                    lines.append("refresh_ms = \(refreshMs)")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func tomlQuote(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func resolveTomlPath(_ path: String, on surfaceView: Ghostty.SurfaceView) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        let basePath = resolveCommandWorkingDirectory(for: surfaceView)
        let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: baseURL).standardizedFileURL.path
    }

    private func resolveCommandWorkingDirectory(for surfaceView: Ghostty.SurfaceView) -> String {
        let candidates: [String?] = [
            focusedSurface?.pwd,
            surfaceView.pwd,
            window?.representedURL?.path,
            ProcessInfo.processInfo.environment["TRM_CWD"],
            FileManager.default.currentDirectoryPath
        ]

        for candidate in candidates {
            guard
                let candidate,
                !candidate.isEmpty
            else {
                continue
            }
            let expanded = NSString(string: candidate).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return expanded
            }
        }

        return NSHomeDirectory()
    }

    private func presentInternalCommandError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Appearance

    /// Toggle the background opacity between transparent and opaque states.
    /// Do nothing if the configured background-opacity is >= 1 (already opaque).
    /// Subclasses should override this to add platform-specific checks and sync appearance.
    func toggleBackgroundOpacity() {
        // Do nothing if config is already fully opaque
        guard ghostty.config.backgroundOpacity < 1 else { return }
        
        // Do nothing if in fullscreen (transparency doesn't apply in fullscreen)
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        // Toggle between transparent and opaque
        isBackgroundOpaque.toggle()
        
        // Update our appearance
        syncAppearance()
    }
    
    /// Override this to resync any appearance related properties. This will be called automatically
    /// when certain window properties change that affect appearance. The list below should be updated
    /// as we add new things:
    ///
    ///  - ``toggleBackgroundOpacity``
    func syncAppearance() {
        // Purposely a no-op. This lets subclasses override this and we can call
        // it virtually from here.
    }

    // MARK: Fullscreen

    /// Toggle fullscreen for the given mode.
    func toggleFullscreen(mode: FullscreenMode) {
        // We need a window to fullscreen
        guard let window = self.window else { return }

        // If we have a previous fullscreen style initialized, we want to check if
        // our mode changed. If it changed and we're in fullscreen, we exit so we can
        // toggle it next time. If it changed and we're not in fullscreen we can just
        // switch the handler.
        var newStyle = mode.style(for: window)
        newStyle?.delegate = self
        old: if let oldStyle = self.fullscreenStyle {
            // If we're not fullscreen, we can nil it out so we get the new style
            if !oldStyle.isFullscreen {
                self.fullscreenStyle = newStyle
                break old
            }

            assert(oldStyle.isFullscreen)

            // We consider our mode changed if the types change (obvious) but
            // also if its nil (not obvious) because nil means that the style has
            // likely changed but we don't support it.
            if newStyle == nil || type(of: newStyle!) != type(of: oldStyle) {
                // Our mode changed. Exit fullscreen (since we're toggling anyways)
                // and then set the new style for future use
                oldStyle.exit()
                self.fullscreenStyle = newStyle

                // We're done
                return
            }

            // Style is the same.
        } else {
            // We have no previous style
            self.fullscreenStyle = newStyle
        }
        guard let fullscreenStyle else { return }

        if fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        } else {
            fullscreenStyle.enter()
        }
    }

    func fullscreenDidChange() {
        guard let fullscreenStyle else { return }
        
        // When we enter fullscreen, we want to show the update overlay so that it
        // is easily visible. For native fullscreen this is visible by showing the
        // menubar but we don't want to rely on that.
        if fullscreenStyle.isFullscreen {
            updateOverlayIsVisible = true
        } else {
            updateOverlayIsVisible = defaultUpdateOverlayVisibility()
        }
        
        // Always resync our appearance
        syncAppearance()
    }

    // MARK: Clipboard Confirmation

    @objc private func onConfirmClipboardRequest(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let surface = target.surface else { return }

        // We need a window
        guard let window = self.window else { return }

        // Check whether we use non-native fullscreen
        guard let str = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStrKey] as? String else { return }
        guard let state = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStateKey] as? UnsafeMutableRawPointer? else { return }
        guard let request = notification.userInfo?[Ghostty.Notification.ConfirmClipboardRequestKey] as? Ghostty.ClipboardRequest else { return }

        // If we already have a clipboard confirmation view up, we ignore this request.
        // This shouldn't be possible...
        guard self.clipboardConfirmation == nil else {
            Ghostty.App.completeClipboardRequest(surface, data: "", state: state, confirmed: true)
            return
        }

        // Show our paste confirmation
        self.clipboardConfirmation = ClipboardConfirmationController(
            surface: surface,
            contents: str,
            request: request,
            state: state,
            delegate: self
        )
        if let ccWindow = self.clipboardConfirmation?.window {
            window.beginSheet(ccWindow)
        }
    }

    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ request: Ghostty.ClipboardRequest) {
        // End our clipboard confirmation no matter what
        guard let cc = self.clipboardConfirmation else { return }
        self.clipboardConfirmation = nil

        // Close the sheet
        if let ccWindow = cc.window {
            window?.endSheet(ccWindow)
        }

        switch (request) {
        case let .osc_52_write(pasteboard):
            guard case .confirm = action else { break }
            let pb = pasteboard ?? NSPasteboard.general
            pb.declareTypes([.string], owner: nil)
            pb.setString(cc.contents, forType: .string)
        case .osc_52_read, .paste:
            let str: String
            switch (action) {
            case .cancel:
                str = ""

            case .confirm:
                str = cc.contents
            }

            Ghostty.App.completeClipboardRequest(cc.surface, data: str, state: cc.state, confirmed: true)
        }
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()

        // Setup our undo manager.

        // Everything beyond here is setting up the window
        guard let window else { return }

        // We always initialize our fullscreen style to native if we can because
        // initialization sets up some state (i.e. observers). If its set already
        // somehow we don't do this.
        if fullscreenStyle == nil {
            fullscreenStyle = NativeFullscreen(window)
            fullscreenStyle?.delegate = self
        }

        // Set our update overlay state
        updateOverlayIsVisible = defaultUpdateOverlayVisibility()

        // Start context usage tracking
        contextUsageManager.start()

        // Setup initial panes from termania.toml config — but skip if we
        // were created with an existing surface tree (e.g., a popped-out pane).
        if hasExternalSurfaceTree {
            hasExternalSurfaceTree = false
        } else {
            setupInitialPanes()
        }
    }

    /// Read the termania.toml session config and create the initial multi-pane layout.
    private func setupInitialPanes() {
        setupInitialPanes(from: activeGridConfig)
    }

    /// Apply a concrete grid config and create the pane layout in-place.
    private func setupInitialPanes(from config: Trm.TrmGridConfig) {
        // Clear all existing watermarks before rebuilding so stale entries
        // from the previous layout don't leak into the new one.
        for surface in gridSurfaces {
            let id = surface.paneId ?? 0
            Trm.shared.setWatermark(forPaneId: UInt32(id), text: "")
        }

        paneDisplayOrder = []

        let paneConfigs: [Trm.TrmPaneConfig] = {
            if !config.panes.isEmpty {
                return config.panes
            }

            let total = max(1, config.rows * config.cols)
            return (0..<total).map { _ in
                Trm.TrmPaneConfig(
                    paneType: "terminal",
                    command: nil,
                    cwd: nil,
                    watermark: nil,
                    title: nil,
                    url: nil,
                    file: nil,
                    content: nil,
                    target: nil,
                    targetTitle: nil,
                    path: nil,
                    refreshMs: nil,
                    repo: nil,
                    initialCommands: [],
                    patterns: []
                )
            }
        }()

        let totalPanes = max(1, paneConfigs.count)
        if !config.rowCols.isEmpty, config.rowCols.reduce(0, +) == totalPanes {
            // Jagged grid: use the exact per-row column counts from the config.
            gridRowCols = config.rowCols
        } else {
            gridRowCols = gridShape(totalPanes: totalPanes, rows: max(config.rows, 1), cols: max(config.cols, 1))
        }

        webviewPanes.removeAll()
        pluginPanes.removeAll()

        for paneConfig in paneConfigs {
            let paneType = normalizedPaneType(paneConfig.paneType)
            switch paneType {
            case "webview":
                let pane = WebViewPane(url: urlForWebview(from: paneConfig))
                webviewPanes.append(pane)
            default:
                if paneType == "terminal" { continue }
                if let kind = PluginPaneKind.fromPaneType(paneType) {
                    pluginPanes.append(PluginPane(kind: kind, config: paneConfig))
                }
            }
        }

        // Build (paneId, config) pairs for terminal panes. Use the Zig
        // grid_slot_pane_id mapping so IDs match the backend's pane_map.
        var terminalConfigsWithPaneId: [(paneId: Int, config: Trm.TrmPaneConfig)] = []
        for (i, paneConfig) in paneConfigs.enumerated() {
            if normalizedPaneType(paneConfig.paneType) == "terminal" {
                let zigId = Trm.shared.gridSlotPaneId(gridIndex: i)
                terminalConfigsWithPaneId.append((paneId: zigId, config: paneConfig))
            }
        }
        rebuildTerminalSurfaces(terminalConfigsWithPaneId)

        // Apply per-pane config (watermarks, initial commands) for terminal panes.
        applyPaneConfig(paneConfigs)
    }

    /// Apply watermarks and initial commands from the termania config to terminal surfaces.
    private func applyPaneConfig(_ paneConfigs: [Trm.TrmPaneConfig]) {
        let surfaces = gridSurfaces
        var surfaceIndex = 0
        for paneConfig in paneConfigs {
            guard normalizedPaneType(paneConfig.paneType) == "terminal" else { continue }
            guard surfaceIndex < surfaces.count else { break }

            let surface = surfaces[surfaceIndex]
            let id = surface.paneId ?? surfaceIndex

            // Set watermark
            if let watermark = paneConfig.watermark, !watermark.isEmpty {
                Trm.shared.setWatermark(forPaneId: UInt32(id), text: watermark)
            }

            // Send initial commands after a delay to let the shell start.
            // Stagger each pane by 50ms to avoid overwhelming the system
            // when many panes are created simultaneously.
            if !paneConfig.initialCommands.isEmpty {
                let commands = paneConfig.initialCommands
                let delay = 0.5 + Double(surfaceIndex) * 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendInitialCommandsWhenReady(commands, to: surface)
                }
            }

            surfaceIndex += 1
        }
    }

    private func gridShape(totalPanes: Int, rows: Int, cols: Int) -> [Int] {
        guard totalPanes > 0 else { return [1] }
        if rows * cols == totalPanes {
            return Array(repeating: cols, count: rows)
        }

        var remaining = totalPanes
        var result: [Int] = []
        while remaining > 0 {
            let count = min(cols, remaining)
            result.append(count)
            remaining -= count
        }
        return result.isEmpty ? [1] : result
    }

    private func normalizedPaneType(_ rawType: String?) -> String {
        guard let rawType else { return "terminal" }
        switch rawType.lowercased() {
        case "terminal", "terminal_pane":
            return "terminal"
        case "browser", "webview":
            return "webview"
        case "notes", "screen_capture", "file_browser", "process_monitor",
             "log_viewer", "markdown_preview", "system_info", "git_status":
            return rawType.lowercased()
        default:
            return "terminal"
        }
    }

    private func urlForWebview(from paneConfig: Trm.TrmPaneConfig) -> URL {
        let raw = paneConfig.url ?? paneConfig.target ?? "about:blank"
        if let url = URL(string: raw) {
            return url
        }
        return URL(string: "about:blank")!
    }

    private func rebuildTerminalSurfaces(_ paneConfigs: [(paneId: Int, config: Trm.TrmPaneConfig)]) {
        guard let ghosttyApp = ghostty.app else { return }

        if paneConfigs.isEmpty {
            replaceSurfaceTree(.init(), moveFocusTo: nil, moveFocusFrom: focusedSurface, undoAction: nil)
            return
        }

        var newViews: [Ghostty.SurfaceView] = []
        newViews.reserveCapacity(paneConfigs.count)

        for entry in paneConfigs {
            var surfaceConfig = Ghostty.SurfaceConfiguration()
            if let cwd = entry.config.cwd, !cwd.isEmpty {
                surfaceConfig.workingDirectory = NSString(string: cwd).expandingTildeInPath
            } else {
                // Default to home to avoid macOS Documents permission prompts.
                surfaceConfig.workingDirectory = NSHomeDirectory()
            }
            if let command = entry.config.command, !command.isEmpty {
                surfaceConfig.command = command
            }
            let view = Ghostty.SurfaceView(ghosttyApp, baseConfig: surfaceConfig)
            view.paneId = entry.paneId
            newViews.append(view)
        }

        guard var newTree = newViews.first.map({ SplitTree<Ghostty.SurfaceView>(view: $0) }) else { return }
        var previous = newViews[0]
        for view in newViews.dropFirst() {
            do {
                newTree = try newTree.inserting(view: view, at: previous, direction: .right)
                previous = view
            } catch {
                Ghostty.logger.warning("failed to build initial terminal pane tree: \(error)")
            }
        }

        // Clear watermarks for surfaces being replaced during initial setup.
        let newSurfaceIds = Set(newViews.map { ObjectIdentifier($0) })
        for (index, surface) in gridSurfaces.enumerated() {
            if !newSurfaceIds.contains(ObjectIdentifier(surface)) {
                let id = surface.paneId ?? index
                Trm.shared.setWatermark(forPaneId: UInt32(id), text: "")
            }
        }

        replaceSurfaceTree(
            newTree,
            moveFocusTo: newViews.first,
            moveFocusFrom: focusedSurface,
            undoAction: nil
        )
    }

    func defaultUpdateOverlayVisibility() -> Bool {
        guard let window else { return true }
        
        // No titlebar we always show the update overlay because it can't support
        // updates in the titlebar
        guard window.styleMask.contains(.titled) else {
            return true
        }
        
        // If it's a non terminal window we can't trust it has an update accessory,
        // so we always want to show the overlay.
        guard let window = window as? TerminalWindow else {
            return true
        }
        
        // Show the overlay if the window isn't.
        return !window.supportsUpdateAccessory
    }

    // MARK: NSWindowDelegate

    // This is called when performClose is called on a window (NOT when close()
    // is called directly). performClose is called primarily when UI elements such
    // as the "red X" are pressed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // We must have a window. Is it even possible not to?
        guard let window = self.window else { return true }

        // If we have no surfaces, close.
        if surfaceTree.isEmpty { return true }

        // If we already have an alert, continue with it
        guard alert == nil else { return false }

        // If our surfaces don't require confirmation, close.
        if !surfaceTree.contains(where: { $0.needsConfirmQuit }) { return true }

        // We require confirmation, so show an alert as long as we aren't already.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) {
            window.close()
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }

        SessionManager.autoSaveSingleWindow(self)

        stopConfigFileWatcher()
        liveSummaryManager.stop()
        terminalOutputScanner.stop()
        servicePluginRegistry.stopAll()
        contextUsageManager.stop()

        // I don't know if this is required anymore. We previously had a ref cycle between
        // the view and the window so we had to nil this out to break it but I think this
        // may now be resolved. We should verify that no memory leaks and we can remove this.
        window.contentView = nil

        // Make sure we clean up all our undos
        window.undoManager?.removeAllActions(withTarget: self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // If when we become key our first responder is the window itself, then we
        // want to move focus to our focused terminal surface. This works around
        // various weirdness with moving surfaces around.
        if let window, window.firstResponder == window, let focusedSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusedSurface)
            }
        }

        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = self.window?.occlusionState.contains(.visible) ?? false
        for view in surfaceTree {
            if let surface = view.surface {
                ghostty_surface_set_occlusion(surface, visible)
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowDidMove(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return appDelegate.undoManager
    }

    // MARK: First Responder

    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.requestClose(surface: surface)
    }

    @IBAction func closeWindow(_ sender: Any) {
        guard let window = window else { return }
        window.performClose(sender)
    }

    @IBAction func changeTabTitle(_ sender: Any) {
        promptTabTitle()
    }

    /// No-op — split zoom is not supported in grid layout mode.
    @IBAction func splitZoom(_ sender: Any) {}

    @IBAction func increaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .increase(1))
    }

    @IBAction func decreaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .decrease(1))
    }

    @IBAction func resetFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .reset)
    }

    @IBAction func toggleCommandPalette(_ sender: Any?) {
        commandPaletteIsShowing.toggle()
    }

    @IBAction func toggleHelpPanel(_ sender: Any?) {
        helpPanelIsShowing.toggle()
    }

    @IBAction func toggleLiveSummary(_ sender: Any?) {
        liveSummaryManager.toggle()
    }

    @IBAction func newRow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_DOWN)
    }
    
    @IBAction func find(_ sender: Any) {
        focusedSurface?.find(sender)
    }

    @IBAction func selectionForFind(_ sender: Any) {
        focusedSurface?.selectionForFind(sender)
    }

    @IBAction func scrollToSelection(_ sender: Any) {
        focusedSurface?.scrollToSelection(sender)
    }

    @IBAction func findNext(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }
    
    @IBAction func findPrevious(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }
    
    @IBAction func findHide(_ sender: Any) {
        focusedSurface?.findHide(sender)
    }

    @objc func resetTerminal(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.resetTerminal(surface: surface)
    }

    private struct DerivedConfig {
        let macosTitlebarProxyIcon: Ghostty.MacOSTitlebarProxyIcon
        let windowStepResize: Bool
        let focusFollowsMouse: Bool

        init() {
            self.macosTitlebarProxyIcon = .visible
            self.windowStepResize = false
            self.focusFollowsMouse = false
        }

        init(_ config: Ghostty.Config) {
            self.macosTitlebarProxyIcon = config.macosTitlebarProxyIcon
            self.windowStepResize = config.windowStepResize
            self.focusFollowsMouse = config.focusFollowsMouse
        }
    }
}

extension BaseTerminalController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(findHide):
            return focusedSurface?.searchState != nil

        default:
            return true
        }
    }
	
    // MARK: - Surface Color Scheme

    /// Update the surface tree's color scheme only when it actually changes.
    ///
    /// Calling ``ghostty_surface_set_color_scheme`` triggers
    /// ``syncAppearance(_:)`` via notification,
    /// so we avoid redundant calls.
    func updateColorSchemeForSurfaceTree() {
        /// Derive the target scheme from `window-theme` or system appearance.
        /// We set the scheme on surfaces so they pick the correct theme
        /// and let ``syncAppearance(_:)`` update the window accordingly.
        ///
        /// Using App's effectiveAppearance here to prevent incorrect updates.
        let themeAppearance = NSApplication.shared.effectiveAppearance
        let scheme: ghostty_color_scheme_e
        if themeAppearance.isDark {
            scheme = GHOSTTY_COLOR_SCHEME_DARK
        } else {
            scheme = GHOSTTY_COLOR_SCHEME_LIGHT
        }
        guard scheme != appliedColorScheme else {
            return
        }
        for surfaceView in surfaceTree {
            if let surface = surfaceView.surface {
                ghostty_surface_set_color_scheme(surface, scheme)
            }
        }
        appliedColorScheme = scheme
    }
}
