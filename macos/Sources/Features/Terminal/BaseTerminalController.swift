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
        didSet {
            syncFocusToSurfaceTree()
            // Keyboard focus moving to a terminal takes selection away from a
            // non-surface pane; otherwise two panes would look selected.
            if focusedSurface != nil { selectedNonSurfacePane = nil }
        }
    }

    /// The selected pane when it isn't a terminal (agent overview, webview,
    /// plugin).
    ///
    /// Focus is modelled as `Ghostty.SurfaceView?` throughout, so a pane with
    /// no surface could never be represented as selected: its border stayed
    /// unfocused however it was clicked, and clicking it left the previously
    /// focused terminal still ringed — which read as "the overview can't be
    /// selected at all". This carries selection for those panes so they can
    /// show it and act on it.
    @Published var selectedNonSurfacePane: ObjectIdentifier? = nil

    /// True while Cmd+Shift is held: pane contents dim and watermarks come up
    /// to full brightness, so a pane can be found by its label alone.
    @Published var isWatermarkPeeking: Bool = false

    /// Select a pane that has no surface, taking selection away from whatever
    /// held it — including the focused terminal's ring.
    func selectNonSurfacePane(_ id: ObjectIdentifier) {
        guard selectedNonSurfacePane != id else { return }
        selectedNonSurfacePane = id
        // Drop terminal keyboard focus so only one pane reads as selected.
        // Assigning nil goes through the observer above, which would clear the
        // selection we just set, so restore it afterwards.
        if focusedSurface != nil {
            focusedSurface = nil
            selectedNonSurfacePane = id
        }
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

    /// Fractional heights for each row (sums to 1.0).
    /// Automatically equalized when rows are added or removed.
    @Published var gridRowHeightFractions: [CGFloat] = [1.0]

    /// Fractional widths per column within each row (each inner array sums to 1.0).
    /// Automatically equalized when columns are added or removed.
    @Published var gridColWidthFractions: [[CGFloat]] = [[1.0]]

    /// Optional per-window grid config loaded from a project-local trm.toml.
    private var gridConfigOverride: Trm.TrmGridConfig?

    /// Path to the project-local trm.toml used for this window (if any).
    private var configFilePath: String?

    /// Dispatch source monitoring the config file for changes.
    private var configFileWatcher: DispatchSourceFileSystemObject?

    /// Timer for periodic scrollback snapshots (every 30 seconds).
    private var scrollbackSnapshotTimer: Timer?

    /// Session base name for scrollback file naming. Set by `saveScrollbackSnapshots`.
    private var scrollbackSessionBaseName: String?

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

    /// Agent overview panes. Each is bound to one terminal surface and is kept
    /// immediately adjacent to it in the grid.
    @Published var agentOverviewPanes: [AgentOverviewPane] = []

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

    // MARK: - Pane Stacking

    /// Maps a "host" pane's ID to the ordered list of pane IDs in the stack
    /// (including the host as the first element). Panes not in this dictionary
    /// are standalone grid cells.
    @Published var paneStacks: [ObjectIdentifier: [ObjectIdentifier]] = [:]

    /// The currently peeked sub-pane (expanded overlay), or `nil` if no peek.
    @Published var peekedPane: ObjectIdentifier? = nil

    /// Per-stack sub-pane height fractions, keyed by the stack cell's ObjectIdentifier.
    /// Each value is an array (length == number of children) that sums to 1.0.
    @Published var stackSubPaneHeightFractions: [ObjectIdentifier: [CGFloat]] = [:]

    /// All panes for the grid, in display order.
    /// Panes that are stacked inside another cell are filtered out, and the
    /// host cell is replaced with a `.stack([...])` containing the children.
    var gridPanes: [GridPane] {
        let all: [GridPane] =
            gridSurfaces.map { .terminal($0) } +
            webviewPanes.map { .webview($0) } +
            pluginPanes.map { .plugin($0) } +
            agentOverviewPanes.map { .agentOverview($0) }

        let sorted: [GridPane]
        if paneDisplayOrder.isEmpty {
            sorted = all
        } else {
            let indexed = Dictionary(uniqueKeysWithValues: paneDisplayOrder.enumerated().map { ($1, $0) })
            sorted = all.sorted { a, b in
                let ai = indexed[a.id] ?? Int.max
                let bi = indexed[b.id] ?? Int.max
                return ai < bi
            }
        }

        // If no stacks exist, return sorted directly.
        guard !paneStacks.isEmpty else { return sorted }

        // Build a lookup from pane ID to GridPane for stack assembly.
        let paneById = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })

        // Collect all pane IDs that are stacked as non-host children.
        var stackedChildIDs = Set<ObjectIdentifier>()
        for (_, childIDs) in paneStacks {
            // Skip the first element (the host) — only non-host children are hidden.
            for childID in childIDs.dropFirst() {
                stackedChildIDs.insert(childID)
            }
        }

        var result: [GridPane] = []
        for pane in sorted {
            // Skip panes that are stacked inside another cell.
            if stackedChildIDs.contains(pane.id) { continue }

            // If this pane is a stack host, replace it with .stack().
            if let childIDs = paneStacks[pane.id] {
                let children = childIDs.compactMap { paneById[$0] }
                if children.count >= 2 {
                    result.append(.stack(children))
                } else {
                    // Degenerate stack — just show the pane normally.
                    result.append(pane)
                }
            } else {
                result.append(pane)
            }
        }

        return result
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

    /// Stable pane IDs that need user attention (agent waiting for input).
    /// Computed from the ClaudeAttentionPlugin's published state.
    var attentionPaneIds: Set<Int> {
        guard let plugin = servicePluginRegistry.plugins["claude_attention"] as? ClaudeAttentionPlugin else {
            return []
        }
        return plugin.attentionPanes
    }

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

    /// Cancellable for gridRowCols structural-change observation (used to equalize fractions).
    private var gridRowColsCancellable: AnyCancellable?

    // MARK: - Live Layout Sync State

    /// Role of this window in the server-backed UI model.
    enum SessionRole {
        /// Owns its layout: checkpoints autosaves and broadcasts layout
        /// updates to subscribed mirrors.
        case primary
        /// A `trm mirror` / `trm attach-remote` window: follows the primary's
        /// layout, never autosaves the shared window, never kills shared zmx
        /// daemons, and has local layout editing disabled.
        case mirror
    }

    /// This window's role. Mirrors are marked by a `layout_mirror = true`
    /// top-level key in the config they were opened from (written by
    /// mirror-session.py).
    private(set) var sessionRole: SessionRole = .primary

    /// True once this process has hosted a mirror window. A mirror process
    /// shares the sessions directory with the primary process, so it must
    /// never wipe the autosave files — even after its own windows close.
    private(set) static var processHostedMirrorWindow = false

    /// Stable identity for this window, persisted as `window_id` in
    /// checkpoint TOMLs so mirrors can subscribe to this window's layout.
    private(set) var windowUUID: String = UUID().uuidString

    /// Monotonic revision stamped on layout broadcasts (primary role).
    private var layoutRevision = 0

    /// Identifies this broadcasting controller instance. A window can be
    /// closed and reopened (same window_id, same process) with its revision
    /// counter starting over — mirrors reset their monotonic revision guard
    /// when the epoch changes.
    private let layoutEpoch = UUID().uuidString

    /// True while a remote layout snapshot is being applied, so broadcast
    /// hooks and edit guards don't react to our own mutations.
    private var isApplyingRemoteLayout = false

    /// Socket client following the primary's layout (mirror role only).
    private var layoutSyncClient: LayoutSyncClient?

    /// Debounced broadcast trigger over the layout vars (primary role only).
    private var layoutBroadcastCancellable: AnyCancellable?

    /// True while setupInitialPanes replays a saved layout. Restore paths
    /// (restoreStackGroups → stackPane, restoreAgentOverviews →
    /// showAgentOverview) apply the owner's layout rather than editing it,
    /// so the mirror edit guard must not block them.
    private var isRestoringLayout = false

    /// True when local layout edits should be rejected (mirror windows: the
    /// primary owns the layout and would overwrite local edits anyway).
    /// False while a snapshot or saved layout is being applied.
    var isLayoutEditingDisabled: Bool {
        sessionRole == .mirror && !isApplyingRemoteLayout && !isRestoringLayout
    }

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

        // Adopt the window identity from the config we were opened from, so
        // it stays stable across checkpoint/restore, and detect the mirror
        // role (windows opened from a mirror-session.py transform).
        if let cfg = gridConfigOverride {
            if let wid = cfg.windowId, !wid.isEmpty {
                self.windowUUID = wid
            }
            if cfg.layoutMirror {
                self.sessionRole = .mirror
                Self.processHostedMirrorWindow = true
            }
        }

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
            var cfg = initialConfig ?? Ghostty.SurfaceConfiguration()
            let paneId = Trm.shared.allocPaneId()
            Self.injectCmuxEnvVars(into: &cfg, paneId: paneId)
            let persist = Self.wrapForPersistence(&cfg, ghostty: ghostty)
            let initialView = Ghostty.SurfaceView(ghostty_app, baseConfig: cfg)
            initialView.paneId = paneId
            if let persist {
                initialView.zmxSessionName = persist.session
                initialView.logicalCommand = persist.logical
            }
            Self.setDefaultWatermark(forPaneId: initialView.paneId!)
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
        center.addObserver(
            self,
            selector: #selector(onPeekPaneRequest(_:)),
            name: Trm.peekPaneRequest,
            object: nil)

        // Webview pane
        center.addObserver(
            self,
            selector: #selector(ghosttyOpenURLInPane(_:)),
            name: .ghosttyOpenURLInPane,
            object: nil)

        // Split browser (from socket API or Cmd+Shift+L)
        center.addObserver(
            self,
            selector: #selector(handleOpenSplitBrowser(_:)),
            name: .trmOpenSplitBrowser,
            object: nil)

        // Quick actions
        center.addObserver(
            self,
            selector: #selector(handleQuickActionExecute(_:)),
            name: .trmQuickActionExecute,
            object: nil)

        // Quick action scripts (LLM-driven)
        center.addObserver(
            self,
            selector: #selector(handleQuickActionScriptExecute(_:)),
            name: .trmQuickActionScriptExecute,
            object: nil)

        // Shortcut extractor
        center.addObserver(
            self,
            selector: #selector(handleShortcutExecute(_:)),
            name: .trmShortcutExecute,
            object: nil)

        // cmux-compatible API queries
        center.addObserver(
            self,
            selector: #selector(handleCmuxQuery(_:)),
            name: .trmCmuxQuery,
            object: nil)

        // surface.focus RPC: focus a pane by ID
        center.addObserver(
            self,
            selector: #selector(handleFocusPane(_:)),
            name: .trmFocusPane,
            object: nil)

        // swap_panes socket action: swap two panes by visual grid index
        center.addObserver(
            self,
            selector: #selector(handleTextTapSwapPanes(_:)),
            name: .trmTextTapSwapPanes,
            object: nil)

        // Command lifecycle — notify scanner subscribers when a command finishes
        center.addObserver(
            self,
            selector: #selector(ghosttyCommandDidFinish(_:)),
            name: .ghosttyCommandDidFinish,
            object: nil)

        // Listen for local events that we need to know of outside of
        // single surface handlers.
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in self?.localEventHandler(event) }

        // Wire up the live summary manager's pane content provider.
        // Use the stable Zig pane index so summaries match overlay rendering.
        // Use cachedVisibleContents (viewport only): summaries only describe the
        // visible output, and cachedScreenContents reads the ENTIRE scrollback of
        // every pane on the main thread each poll tick.
        liveSummaryManager.paneContentProvider = { [weak self] in
            guard let self else { return [] }
            return self.gridSurfaces.enumerated().map { index, surface in
                let title = surface.title.isEmpty ? "Shell" : surface.title
                let visibleText = surface.cachedVisibleContents.get()
                let effectivePaneId = surface.paneId ?? index
                return (index: effectivePaneId, title: title, visibleText: visibleText)
            }
        }

        // Wire up the terminal output scanner's content provider.
        // Use cachedVisibleContents (viewport only) to avoid leaking memory.
        // The Zig allocator leaks when reading full scrollback via
        // GHOSTTY_POINT_SCREEN every 2s poll cycle.
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
        startScrollbackSnapshotTimer()

        // Hot-reload service plugins when the installed/enabled extension
        // set changes (extension dir watcher, builder installs, toggles).
        ExtensionsManager.shared.startWatching()
        center.addObserver(
            self,
            selector: #selector(trmExtensionsDidChange),
            name: .trmExtensionsChanged,
            object: nil)
    }

    @objc private func trmExtensionsDidChange(_ notification: Notification) {
        reloadServicePlugins()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        // windowWillClose normally tears these down, but a controller can be
        // deallocated without its window ever closing; without this the timer
        // fires (as a no-op) every 30s forever and the watcher leaks its fd.
        // The layout sync client's thread strongly holds the client until
        // stop() — without this it would reconnect-loop forever.
        scrollbackSnapshotTimer?.invalidate()
        configReloadDebounce?.cancel()
        configFileWatcher?.cancel()
        layoutSyncClient?.stop()
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

        let claudePromptPlugin = ClaudePromptPlugin()
        claudePromptPlugin.pwdProvider = { [weak self] in
            guard let self else { return [] }
            return self.gridSurfaces.map { surface in
                (paneId: surface.paneId ?? 0, pwd: surface.pwd)
            }
        }
        servicePluginRegistry.register(claudePromptPlugin)

        // User extensions from ~/Library/Application Support/trm/extensions.
        // Rules extensions run natively; program extensions run supervised
        // out-of-process via SubprocessPluginHost.
        for manifest in ExtensionsManager.shared.enabledExtensions() {
            switch manifest.kind {
            case .rules:
                let plugin = RulesEnginePlugin(manifest: manifest)
                plugin.actionExecutor = { [weak self] actions in
                    self?.executeTrmActions(actions)
                }
                plugin.watermarkProvider = { paneId in
                    Trm.shared.watermark(forPaneId: UInt32(paneId))
                }
                plugin.contextUsagePublisher =
                    contextUsageManager.$currentUsage.eraseToAnyPublisher()
                servicePluginRegistry.register(plugin)
            case .program:
                guard let dir = manifest.directory, let exec = manifest.exec else { break }
                let execPath = dir.appendingPathComponent(exec).path
                let caps = Set(manifest.capabilities.compactMap(PluginCapability.parse))
                    .union([.terminalOutputRead])
                let host = SubprocessPluginHost(
                    id: "ext.\(manifest.name)",
                    name: manifest.name,
                    executablePath: execPath,
                    config: HostConfigPayload(
                        patterns: manifest.patterns.isEmpty ? nil : manifest.patterns),
                    capabilities: caps,
                    memoryLimitMB: manifest.memoryLimitMB ?? 256,
                    cpuLimitSeconds: manifest.cpuLimitSeconds ?? 300
                )
                host.actionExecutor = { [weak self] actions in
                    self?.executeTrmActions(actions)
                }
                host.contextUsagePublisher =
                    contextUsageManager.$currentUsage.eraseToAnyPublisher()
                servicePluginRegistry.register(host, capabilities: caps)
            }
        }
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

    /// Start a repeating 30-second timer that saves scrollback snapshots for all
    /// terminal panes. The snapshots are written to `SessionManager.scrollbackDirectory`
    /// and referenced during session auto-save / restore.
    private func startScrollbackSnapshotTimer() {
        scrollbackSnapshotTimer?.invalidate()

        // Derive a stable base name from the window number (fallback to object hash).
        let baseName: String
        if let windowNumber = window?.windowNumber, windowNumber > 0 {
            baseName = "_periodic_\(windowNumber)"
        } else {
            baseName = "_periodic_\(ObjectIdentifier(self).hashValue)"
        }
        scrollbackSessionBaseName = baseName

        scrollbackSnapshotTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.saveScrollbackSnapshots(sessionBaseName: self.scrollbackSessionBaseName ?? baseName)
            }
        }
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
        baseConfig config: Ghostty.SurfaceConfiguration? = nil,
        didReconcile: Bool = false,
        skipPersistenceWrap: Bool = false
    ) -> Ghostty.SurfaceView? {
        guard !isLayoutEditingDisabled else { return nil }
        guard let ghostty_app = ghostty.app else { return nil }

        // Validate that oldView is still in the surface tree. If a pane was
        // just closed and focusedSurface hasn't updated yet, oldView could be
        // stale. Fall back to any live surface.
        let anchorView: Ghostty.SurfaceView
        if surfaceTree.contains(where: { $0 === oldView }) {
            anchorView = oldView
        } else if let fallback = Array(surfaceTree).first {
            Ghostty.logger.warning("newGridPane: oldView not in tree, using fallback")
            anchorView = fallback
        } else {
            return nil
        }

        let newPaneId = nextAvailablePaneId()
        var newConfig = config ?? Ghostty.SurfaceConfiguration()
        Self.injectCmuxEnvVars(into: &newConfig, paneId: newPaneId)
        // A remote pane already attaches a zmx session — on the remote host.
        // Wrapping it in a local session too would nest one daemon inside
        // another and make the pane look locally-backed in checkpoints.
        let persist = skipPersistenceWrap
            ? nil
            : Self.wrapForPersistence(&newConfig, ghostty: ghostty)
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: newConfig)
        newView.paneId = newPaneId
        if let persist {
            newView.zmxSessionName = persist.session
            newView.logicalCommand = persist.logical
        }
        Self.setDefaultWatermark(forPaneId: newView.paneId!)

        // Use the VISUAL order (gridPanes respects paneDisplayOrder) to find
        // which row/col the focused surface occupies on screen.
        let visualPanes = gridPanes
        guard !visualPanes.isEmpty else { return nil }

        let visualIndex = visualPanes.firstIndex(where: { pane in
            switch pane {
            case .terminal(let s):
                return s === anchorView
            case .stack(let children):
                return children.contains(where: {
                    if case .terminal(let s) = $0 { return s === anchorView }
                    return false
                })
            default:
                return false
            }
        }) ?? 0
        let (row, _) = gridPosition(flatIndex: visualIndex)

        // Collect the terminal surfaces in visual order for the current row so
        // we can determine tree insertion points relative to visual neighbours.
        let visualRowStart = flatIndexFor(row: row, col: 0)
        let colsInRow = row < gridRowCols.count ? gridRowCols[row] : 1
        let visualRowEnd = min(visualRowStart + colsInRow - 1, visualPanes.count - 1)

        // If gridRowCols drifted from the actual pane count, reconcile and retry once.
        guard visualRowStart < visualPanes.count else {
            reconcileGridRowCols()
            guard !didReconcile else { return nil }
            return newGridPane(at: anchorView, direction: direction, baseConfig: config, didReconcile: true)
        }

        // Helper: extract a SurfaceView from a GridPane.
        // For stacks, returns the last child's surface (as the tree anchor).
        func surface(of pane: GridPane) -> Ghostty.SurfaceView? {
            switch pane {
            case .terminal(let s): return s
            case .stack(let children):
                // Use the last child so insertion goes after the whole stack.
                for child in children.reversed() {
                    if case .terminal(let s) = child { return s }
                }
                return nil
            default: return nil
            }
        }

        // The tree's flat order. Insertion into the split tree is always
        // .right (append after), so we need to pick the correct tree-order
        // neighbour as anchor.
        let treeSurfaces = Array(surfaceTree)
        let oldTreeIndex = treeSurfaces.firstIndex(where: { $0 === anchorView }) ?? 0

        let insertAfter: Ghostty.SurfaceView
        switch direction {
        case .right:
            insertAfter = anchorView
        case .left:
            if oldTreeIndex > 0 {
                insertAfter = treeSurfaces[oldTreeIndex - 1]
            } else {
                insertAfter = anchorView
            }
        case .down:
            // Insert after the last surface of the current VISUAL row.
            if let s = surface(of: visualPanes[visualRowEnd]) {
                insertAfter = s
            } else {
                insertAfter = anchorView
            }
        case .up:
            // Insert before the first surface of the current VISUAL row.
            if visualRowStart > 0, let s = surface(of: visualPanes[visualRowStart - 1]) {
                insertAfter = s
            } else {
                insertAfter = anchorView
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
            moveFocusFrom: anchorView,
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

    /// Ensure `gridRowCols` matches the actual pane count.
    /// If they've drifted (e.g. a surface failed to create during session
    /// restore), rebuild `gridRowCols` to reflect the real pane count.
    /// - Parameter extraPendingPanes: cells that belong to panes not yet
    ///   created (agent overviews during restore), so their cells aren't
    ///   trimmed as drift before they exist.
    private func reconcileGridRowCols(extraPendingPanes: Int = 0) {
        let actualCount = gridPanes.count + extraPendingPanes
        let totalBefore = gridRowCols.reduce(0, +)
        var layout = GridLayout<ObjectIdentifier>(
            rowCols: gridRowCols,
            displayOrder: paneDisplayOrder
        )
        layout.reconcile(actualCount: actualCount)

        // Log if reconcile made a significant change — helps diagnose ghost-pane bugs.
        let totalAfter = layout.rowCols.reduce(0, +)
        if totalAfter != totalBefore {
            Ghostty.logger.warning(
                "reconcileGridRowCols: \(self.gridRowCols) (\(totalBefore)) → \(layout.rowCols) (\(totalAfter)), gridPanes=\(actualCount), surfaces=\(Array(self.surfaceTree).count), stacks=\(self.paneStacks.count)"
            )
        }

        gridRowCols = layout.rowCols
    }

    /// Resolve the current terminal pane index for a specific surface.
    func paneIndex(for surface: Ghostty.SurfaceView) -> Int? {
        gridSurfaces.firstIndex(where: { $0 === surface })
    }

    /// Allocate a globally unique pane ID from the Zig backend.
    private func nextAvailablePaneId() -> Int {
        return Trm.shared.allocPaneId()
    }

    /// Assign a default letter watermark (A, B, C, …) based on the pane ID.
    /// Only sets if no watermark has been explicitly configured.
    static func setDefaultWatermark(forPaneId paneId: Int) {
        let letter = String(UnicodeScalar(Int(UnicodeScalar("A").value) + (paneId % 26))!)
        Trm.shared.setWatermark(forPaneId: UInt32(paneId), text: letter)
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
        if let idx = visualPanes.firstIndex(where: { pane in
            switch pane {
            case .terminal(let s):
                return s === surface
            case .stack(let children):
                return children.contains(where: {
                    if case .terminal(let s) = $0 { return s === surface }
                    return false
                })
            default:
                return false
            }
        }) {
            return gridPosition(flatIndex: idx).row
        }
        return max(gridRowCols.count - 1, 0)
    }

    /// Move pane in the given direction within the grid.
    enum PaneMoveDirection {
        case left, right, up, down

        /// Where an agent overview lands when moved this way. Overviews are
        /// positioned relative to their terminal, so a direction names a side
        /// rather than a grid displacement.
        var overviewPlacement: AgentOverviewPlacement {
            switch self {
            case .left: return .leading
            case .right: return .trailing
            case .up: return .above
            case .down: return .below
            }
        }
    }

    func movePane(_ pane: GridPane, direction: PaneMoveDirection) {
        guard !isLayoutEditingDisabled else { return }

        TrmDiagnostics.log("[close-trace] movePane enter direction=\(direction) gridPanes=\(self.gridPanes.count)")
        defer { TrmDiagnostics.log("[close-trace] movePane exit gridPanes=\(self.gridPanes.count)") }
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
            // Past the top edge: give the pane a new first row rather than
            // refusing the move.
            guard srcRow > 0 else {
                relocatePaneToNewRow(flatIndex: flatIndex, fromRow: srcRow, newRowIndex: 0)
                break
            }
            relocatePane(panes, flatIndex: flatIndex, fromRow: srcRow, toRow: srcRow - 1)

        case .down:
            // Past the bottom edge: append a new last row for it.
            guard srcRow < gridRowCols.count - 1 else {
                relocatePaneToNewRow(
                    flatIndex: flatIndex,
                    fromRow: srcRow,
                    newRowIndex: gridRowCols.count
                )
                break
            }
            relocatePane(panes, flatIndex: flatIndex, fromRow: srcRow, toRow: srcRow + 1)
        }

        // Overviews move like any other pane now; only drop ones whose
        // terminal has gone away.
        pruneOrphanedAgentOverviews()

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

    /// Move a pane into a new row created at `newRowIndex` (used when a move
    /// pushes it past the top or bottom edge of the grid).
    private func relocatePaneToNewRow(flatIndex: Int, fromRow: Int, newRowIndex: Int) {
        var layout = GridLayout<ObjectIdentifier>(
            rowCols: gridRowCols,
            displayOrder: paneDisplayOrder
        )
        layout.relocateToNewRow(
            flatIndex: flatIndex,
            fromRow: fromRow,
            newRowIndex: newRowIndex
        )
        gridRowCols = layout.rowCols
        paneDisplayOrder = layout.displayOrder

        // Row count changed, so the old height fractions no longer describe
        // the grid; drop them and let it re-normalise to equal rows.
        gridRowHeightFractions = []
        gridColWidthFractions = []
    }

    /// Move the currently focused pane in the given direction.
    func moveFocusedPane(_ direction: PaneMoveDirection) {
        // A selected non-surface pane (an overview picked with Cmd+N or a
        // click) is what the user means by "the current pane" — act on it
        // rather than on whichever terminal still holds keyboard focus.
        if let selectedID = selectedNonSurfacePane,
           let pane = gridPanes.first(where: { $0.id == selectedID }) {
            movePane(pane, direction: direction)
            return
        }
        guard let surface = focusedSurface else { return }
        let pane = GridPane.terminal(surface)
        movePane(pane, direction: direction)
    }

    /// Reposition the focused terminal's agent overview around it.
    ///
    /// An overview holds no keyboard focus of its own (it has no surface), so
    /// the ordinary move shortcuts can never target it — they resolve through
    /// `focusedSurface` and always land on a terminal. This is the overview's
    /// keyboard equivalent: it acts on the overview attached to whichever
    /// terminal is focused, leaving the plain move shortcuts free to move that
    /// terminal as before.
    func moveFocusedPaneOverview(_ direction: PaneMoveDirection) {
        guard !isLayoutEditingDisabled else { return }
        guard let surface = focusedSurface,
              let overview = agentOverviewPanes.first(where: { $0.surface === surface })
        else { return }
        setOverviewPlacement(overview, direction.overviewPlacement)
    }

    // MARK: - Pane Swap (Drag-to-Swap)

    /// Swap two panes' positions in the grid without stacking them.
    func swapPane(_ source: GridPane, with target: GridPane) {
        guard !isLayoutEditingDisabled else { return }
        guard source.id != target.id else { return }
        ensurePaneDisplayOrder()
        let panes = gridPanes
        guard let srcIdx = panes.firstIndex(where: { $0.id == source.id }),
              let dstIdx = panes.firstIndex(where: { $0.id == target.id }) else { return }
        swapPanesInDisplayOrder(panes, srcIdx, dstIdx)
        pruneOrphanedAgentOverviews()

        // Flash the swapped pane so the user can track it.
        if case .terminal(let surface) = source, let pid = surface.paneId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NotificationCenter.default.post(
                    name: Trm.highlightPane,
                    object: nil,
                    userInfo: ["paneId": pid]
                )
            }
        }
    }

    // MARK: - Pane Stacking Operations

    /// Stack `source` pane onto `target` pane. The source's grid cell is removed
    /// and the target's cell becomes a vertical stack containing both panes.
    /// `edge` controls whether the source lands above (`.top`) or below
    /// (`.bottom`) the existing pane(s) in the stack.
    func stackPane(_ source: GridPane, onto target: GridPane, edge: StackDropEdge = .bottom) {
        guard !isLayoutEditingDisabled else { return }
        let sourceID = source.id
        let targetID = target.id
        guard sourceID != targetID else { return }

        // Dropping a pane onto the stack it is already in is a *reorder*, not
        // a no-op: it's how you move a sub-pane to the top or bottom of its
        // own group. This used to return early, so the drop registered (the
        // preview even showed) and then nothing happened.
        if let existing = paneStacks[targetID], existing.contains(sourceID) {
            reorderWithinStack(hostID: targetID, moving: sourceID, edge: edge)
            return
        }

        ensurePaneDisplayOrder()

        // Capture the source's grid position BEFORE modifying paneStacks,
        // because gridPanes filters out stacked children.
        let visualPanesBefore = gridPanes
        let sourceVisualIdx = visualPanesBefore.firstIndex(where: { $0.id == sourceID })

        // If the source is already a non-host child of another stack, remove
        // it from that stack first so it doesn't appear in two stacks at once.
        // Also dissolve the old stack if only one pane remains.
        if let (oldHostID, oldStackIdx) = findStackEntry(for: sourceID), oldHostID != targetID {
            paneStacks[oldHostID]?.remove(at: oldStackIdx)
            if let remaining = paneStacks[oldHostID], remaining.count <= 1 {
                paneStacks.removeValue(forKey: oldHostID)
            }
        }

        // If the source was itself a stack host, its children come along.
        let sourceExtras: [ObjectIdentifier]
        if let sourceStack = paneStacks.removeValue(forKey: sourceID) {
            sourceExtras = sourceStack.filter { $0 != sourceID }
        } else {
            sourceExtras = []
        }

        // Build or extend the stack on the target. The stack array renders
        // top-to-bottom with the host (grid cell identity) as the first
        // element, so a top-edge drop makes the source the new host.
        let existingChildren = paneStacks[targetID] ?? [targetID]
        switch edge {
        case .bottom:
            paneStacks[targetID] = existingChildren + [sourceID] + sourceExtras
        case .top:
            paneStacks.removeValue(forKey: targetID)
            paneStacks[sourceID] = [sourceID] + sourceExtras + existingChildren
            // Height fractions were keyed by the old host; reset them.
            stackSubPaneHeightFractions.removeValue(forKey: targetID)
        }

        // Remove the source's grid cell using the pre-captured position.
        if let flatIdx = sourceVisualIdx {
            var offset = 0
            for (rowIdx, cols) in gridRowCols.enumerated() {
                if flatIdx < offset + cols {
                    if gridRowCols[rowIdx] > 1 {
                        gridRowCols[rowIdx] -= 1
                    } else if gridRowCols.count > 1 {
                        gridRowCols.remove(at: rowIdx)
                    }
                    break
                }
                offset += cols
            }
            if gridRowCols.isEmpty { gridRowCols = [1] }
        }

        // Remove from paneDisplayOrder.
        if !paneDisplayOrder.isEmpty {
            paneDisplayOrder.removeAll { $0 == sourceID }
        }

        // For a top-edge drop the source is the new stack host, so the grid
        // cell identity changes: the old host's display-order slot now belongs
        // to the source. (Must come after the removeAll above so the source's
        // original slot doesn't survive as a duplicate.)
        if edge == .top, let idx = paneDisplayOrder.firstIndex(of: targetID) {
            paneDisplayOrder[idx] = sourceID
        }

        pruneOrphanedAgentOverviews()
    }

    // MARK: - Agent Overview Pane

    /// Whether the given pane already has an agent overview open.
    func hasAgentOverview(for pane: GridPane) -> Bool {
        guard case .terminal(let surface) = pane else { return false }
        return agentOverviewPanes.contains { $0.surface === surface }
    }

    /// Open (or focus) the agent overview for a terminal pane.
    ///
    /// The view is inserted immediately to the right of its terminal pane,
    /// in the same row, which is the only placement the grid guarantees stays
    /// adjacent. If one is already open for this pane, this is a no-op.
    /// - Parameter applyPlacement: when false the overview is created and
    ///   given a cell, but not positioned relative to its terminal. Restore
    ///   passes false: the checkpoint's `row_cols` already describes where
    ///   every pane sits, and re-deriving the position destroys rows.
    func showAgentOverview(for pane: GridPane, applyPlacement: Bool = true) {
        guard !isLayoutEditingDisabled else { return }
        guard case .terminal(let surface) = pane else { return }
        guard !hasAgentOverview(for: pane) else { return }

        ensurePaneDisplayOrder()

        let view = AgentOverviewPane(surface: surface)
        agentOverviewPanes.append(view)

        // Claim a grid cell for the new overview before placing it — but only
        // when the grid is actually short one.
        //
        // Opening an overview interactively needs the claim: appending to
        // `agentOverviewPanes` grows `gridPanes` by one, so the
        // `ensurePaneDisplayOrder()` inside `applyOverviewPlacement` sees a
        // count mismatch and rebuilds the order with the overview already in
        // it — at which point `placeCompanion` treats it as an existing cell,
        // removing it from one row and re-inserting it beside its anchor for a
        // net-zero change to `gridRowCols`, leaving one more pane than cells
        // and displacing a neighbour.
        //
        // Restore must NOT claim: `gridRowCols` was already seeded from the
        // checkpoint's `row_cols`, which counts the overview's cell. Claiming
        // again made it 7 cells for 6 panes, and the reconciliation collapsed
        // a row to compensate — a restored two-row window came back as one.
        // Comparing against the pane count covers both callers without either
        // needing to know which case it is.
        appendToPaneDisplayOrder(ObjectIdentifier(view))
        let cellCount = gridRowCols.reduce(0, +)
        let paneCount = gridPanes.count
        if gridRowCols.isEmpty {
            gridRowCols = [1]
        } else if cellCount < paneCount {
            gridRowCols[gridRowCols.count - 1] += 1
        }

        if applyPlacement {
            applyOverviewPlacement(view)
        }
    }

    /// Map an overview placement to grid-layout terms.
    private static func companionSide(for placement: AgentOverviewPlacement) -> GridLayout<ObjectIdentifier>.CompanionSide {
        switch placement {
        case .trailing: return .after
        case .leading: return .before
        case .above: return .rowAbove
        case .below: return .rowBelow
        }
    }

    /// (Re-)apply one overview's placement: put its cell adjacent to its
    /// terminal pane on the side its `placement` names, wherever it currently
    /// is. Also used by `repinAgentOverviews` after grid reorders.
    private func applyOverviewPlacement(_ view: AgentOverviewPane) {
        guard let surface = view.surface else { return }
        ensurePaneDisplayOrder()

        var layout = GridLayout<ObjectIdentifier>(
            rowCols: gridRowCols,
            displayOrder: paneDisplayOrder
        )
        // `rowAbove`/`rowBelow` insert a row containing only the overview, so
        // an above/below overview spans the entire window — which is why two
        // overviews could never sit side by side. When the anchor's row holds
        // other panes, share that row instead: the overview lands next to its
        // terminal at the row's width, and a second overview can take a slot
        // in the same row. A full-width row is still right when the anchor is
        // alone in its row, since sharing would be a no-op there.
        let anchorID = ObjectIdentifier(surface)
        let placement = view.placement
        let anchorRowIsShared: Bool = {
            guard let flat = paneDisplayOrder.firstIndex(of: anchorID) else { return false }
            var offset = 0
            for cols in gridRowCols {
                if flat < offset + cols { return cols > 1 }
                offset += cols
            }
            return false
        }()

        if (placement == .above || placement == .below), anchorRowIsShared {
            layout.placeCompanionInRow(
                ObjectIdentifier(view),
                near: anchorID,
                after: placement == .below
            )
        } else {
            layout.placeCompanion(
                ObjectIdentifier(view),
                near: anchorID,
                side: Self.companionSide(for: placement)
            )
        }
        gridRowCols = layout.rowCols
        paneDisplayOrder = layout.displayOrder

        // Fractions are shaped per row/column and are now stale; drop them so
        // the grid re-normalises around the new cell arrangement.
        gridColWidthFractions = []
        gridRowHeightFractions = []
    }

    /// Change where an overview sits relative to its terminal pane.
    func setOverviewPlacement(_ view: AgentOverviewPane, _ placement: AgentOverviewPlacement) {
        view.placement = placement
        applyOverviewPlacement(view)
    }

    /// Handle an overview grab-bar drop: `uuid` identifies the dragged
    /// overview (its `id`), `target` is the cell it was dropped on, and
    /// `placement` which side of that cell. Only the overview's own terminal
    /// pane is a valid target — anywhere else the drop is ignored, which is
    /// what keeps the overview adjacent to its agent.
    func placeOverview(overviewUUID uuid: UUID, onto target: GridPane, placement: AgentOverviewPlacement) {
        guard !isLayoutEditingDisabled else { return }
        guard let view = agentOverviewPanes.first(where: { $0.id == uuid }) else { return }
        // Accept the drop when the target cell contains this overview's
        // terminal — including when that terminal is stacked, which the old
        // `case .terminal` match rejected outright.
        // Valid targets are the overview's terminal (including when stacked)
        // and the overview's own cell — dropping onto itself to choose a
        // different side is the natural gesture.
        guard let surface = view.surface,
              target.containsSurface(ObjectIdentifier(surface))
                || target.id == ObjectIdentifier(view) else { return }
        setOverviewPlacement(view, placement)
    }

    /// Re-pin every agent overview next to the terminal pane it describes.
    ///
    /// Moving or stacking panes reorders `paneDisplayOrder` without knowing
    /// about the overview→terminal binding, which would let the pair drift
    /// apart. Calling this after a reorder restores the invariant that an
    /// overview always sits immediately after its agent's pane. Overviews
    /// whose terminal has gone away are closed.
    /// Close overviews whose terminal has gone away.
    ///
    /// This replaces the old `repinAgentOverviews`, which re-derived *every*
    /// overview's position after any layout change to keep it glued beside its
    /// terminal. That invariant was the source of most of the overview's
    /// misbehaviour: it silently reverted drags and shortcut moves (the drop
    /// applied, then the repin put it back), and with two overviews the repins
    /// fought each other — each `placeCompanion` inserting a fresh full-width
    /// row, which is what collapsed restored layouts.
    ///
    /// An overview is now an ordinary grid pane: it stacks, swaps, moves, and
    /// shares rows like any other. The only tie kept to its terminal is
    /// lifetime — it closes when that terminal does.
    func pruneOrphanedAgentOverviews() {
        guard !agentOverviewPanes.isEmpty else { return }
        for view in agentOverviewPanes where view.surface == nil {
            closeAgentOverview(view)
        }
    }

    /// Close an agent overview pane.
    func closeAgentOverview(_ pane: AgentOverviewPane) {
        guard let idx = agentOverviewPanes.firstIndex(where: { $0 === pane }) else { return }
        let paneID = ObjectIdentifier(pane)

        var layout = GridLayout<ObjectIdentifier>(
            rowCols: gridRowCols,
            displayOrder: paneDisplayOrder
        )
        layout.removeCell(of: paneID)
        gridRowCols = layout.rowCols
        paneDisplayOrder = layout.displayOrder

        agentOverviewPanes.remove(at: idx)
        paneStacks.removeValue(forKey: paneID)
        if gridRowCols.isEmpty { gridRowCols = [1] }
        gridColWidthFractions = []
        gridRowHeightFractions = []

        closeWindowIfNoPanes()
    }

    /// Close any agent overview bound to a surface that is going away, so the
    /// view never outlives the agent pane it describes.
    func closeAgentOverviews(forSurface surface: Ghostty.SurfaceView) {
        for view in agentOverviewPanes where view.surface === surface {
            closeAgentOverview(view)
        }
    }

    /// Unstack a pane from its stack, restoring it to its own grid cell.
    func unstackPane(_ pane: GridPane) {
        guard !isLayoutEditingDisabled else { return }
        let paneID = pane.id

        // Find which stack contains this pane.
        guard let (hostID, stackIndex) = findStackEntry(for: paneID) else { return }

        // Remove the pane from the stack.
        paneStacks[hostID]?.remove(at: stackIndex)

        // If the stack is down to 1 pane, dissolve it.
        if let remaining = paneStacks[hostID], remaining.count <= 1 {
            paneStacks.removeValue(forKey: hostID)
            stackSubPaneHeightFractions.removeValue(forKey: hostID)
        } else {
            // Stack shrunk — reset fractions to equal so they re-normalize.
            stackSubPaneHeightFractions.removeValue(forKey: hostID)
        }

        // Add the pane back to the grid as its own cell.
        addPaneBackToGrid(paneID)
    }

    /// Move a sub-pane to the top or bottom of the stack it already belongs
    /// to, in response to a drop onto its own group.
    private func reorderWithinStack(
        hostID: ObjectIdentifier,
        moving paneID: ObjectIdentifier,
        edge: StackDropEdge
    ) {
        guard var children = paneStacks[hostID],
              let from = children.firstIndex(of: paneID) else { return }

        children.remove(at: from)
        // `.top` means "above the existing panes", i.e. become the new host.
        let to = (edge == .top) ? 0 : children.count
        children.insert(paneID, at: to)
        guard children.count >= 2 else { return }

        // Carry the pane's height with it rather than discarding every
        // fraction: dropping them reset the whole group to equal sizes, so a
        // reorder silently undid any resizing the user had done.
        var fractions = stackSubPaneHeightFractions[hostID]
        if var fracs = fractions, fracs.count > from {
            let moved = fracs.remove(at: from)
            fracs.insert(moved, at: min(to, fracs.count))
            fractions = fracs
        }
        stackSubPaneHeightFractions.removeValue(forKey: hostID)

        let newHostID = children[0]
        if newHostID != hostID {
            // The host owns the grid cell and keys the stack, so promoting a
            // pane to the top hands both over.
            paneStacks.removeValue(forKey: hostID)
            paneStacks[newHostID] = children
            if let slot = paneDisplayOrder.firstIndex(of: hostID) {
                paneDisplayOrder[slot] = newHostID
            }
            stackSubPaneHeightFractions[newHostID] = fractions
        } else {
            paneStacks[hostID] = children
            stackSubPaneHeightFractions[hostID] = fractions
        }
    }

    /// Move a stacked sub-pane up or down within its stack.
    ///
    /// A stack's first element is its *host*: it owns the grid cell and the
    /// stack is keyed by its ID. Moving a pane into or out of position 0
    /// therefore transfers that identity, which is why this can't be a plain
    /// element swap — the `paneStacks` key, the display order slot, and the
    /// height fractions all follow the host.
    func moveSubPane(_ pane: GridPane, up: Bool) {
        guard !isLayoutEditingDisabled else { return }
        let paneID = pane.id
        guard let (hostID, index) = findStackEntry(for: paneID),
              var children = paneStacks[hostID] else { return }

        let target = up ? index - 1 : index + 1
        guard target >= 0, target < children.count else { return }

        children.swapAt(index, target)

        // Swap the two heights alongside the panes, so each keeps the size it
        // had. Discarding them reset the whole group to equal heights, which
        // silently undid the user's resizing on every reorder.
        var fractions = stackSubPaneHeightFractions[hostID]
        if var fracs = fractions, fracs.count == children.count {
            fracs.swapAt(index, target)
            fractions = fracs
        }
        stackSubPaneHeightFractions.removeValue(forKey: hostID)

        if index == 0 || target == 0 {
            // The host changed. Re-key the stack and hand the grid cell over.
            let newHostID = children[0]
            paneStacks.removeValue(forKey: hostID)
            paneStacks[newHostID] = children
            if let slot = paneDisplayOrder.firstIndex(of: hostID) {
                paneDisplayOrder[slot] = newHostID
            }
            stackSubPaneHeightFractions[newHostID] = fractions
        } else {
            paneStacks[hostID] = children
            stackSubPaneHeightFractions[hostID] = fractions
        }
    }

    /// Show the peek overlay for a stacked pane.
    func peekPane(_ pane: GridPane) {
        peekedPane = pane.id

        // Move keyboard focus to the peeked pane's surface. Without this, focus
        // stays on whatever pane was focused before the peek, so the expanded
        // (bigger) pane is shown but not focused — the user would have to tap a
        // second time to type into it. Peeking implies "I want to work in this
        // pane now," so focus it immediately.
        let surfaceToFocus: Ghostty.SurfaceView?
        switch pane {
        case .terminal(let surface):
            surfaceToFocus = surface
        case .stack(let children):
            surfaceToFocus = children.lazy.compactMap {
                if case .terminal(let s) = $0 { return s } else { return nil }
            }.first
        default:
            surfaceToFocus = nil
        }
        if let surfaceToFocus {
            focusSurface(surfaceToFocus)
        }
    }

    /// Dismiss the peek overlay.
    func dismissPeek() {
        peekedPane = nil
    }

    /// Handle a tap on a pane's grab handle: toggle the peek/expand overlay
    /// for that surface. Posted by `SurfaceGrabHandle` via `Trm.peekPaneRequest`.
    @objc private func onPeekPaneRequest(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView else { return }
        // The notification is broadcast to every controller; only the one that
        // actually owns this surface should respond.
        guard surfaceTree.contains(surface) else { return }

        let id = ObjectIdentifier(surface)
        if peekedPane == id {
            dismissPeek()
        } else {
            peekPane(.terminal(surface))
        }
    }

    // MARK: - Grid Resize

    /// Resize row `row` so it takes `fraction` of the total available height.
    /// The adjacent row (row+1) absorbs the remainder.
    func resizeGridRow(_ row: Int, toFraction fraction: CGFloat) {
        guard !isLayoutEditingDisabled else { return }
        let nRows = gridRowCols.count
        guard row >= 0, row < nRows - 1 else { return }
        var fracs = normalizedRowFractions()
        let combined = fracs[row] + fracs[row + 1]
        let newThis = min(max(fraction * combined, 0.05 * combined), 0.95 * combined)
        fracs[row] = newThis
        fracs[row + 1] = combined - newThis
        gridRowHeightFractions = fracs
    }

    /// Resize column `col` in row `row` so it takes `fraction` of that row's available width.
    /// The adjacent column (col+1) absorbs the remainder.
    func resizeGridCol(_ row: Int, col: Int, toFraction fraction: CGFloat) {
        guard !isLayoutEditingDisabled else { return }
        guard row >= 0, row < gridRowCols.count else { return }
        let nCols = gridRowCols[row]
        guard col >= 0, col < nCols - 1 else { return }
        var rowFracs = normalizedColFractions(forRow: row, nCols: nCols)
        let combined = rowFracs[col] + rowFracs[col + 1]
        let newThis = min(max(fraction * combined, 0.05 * combined), 0.95 * combined)
        rowFracs[col] = newThis
        rowFracs[col + 1] = combined - newThis
        var all = gridColWidthFractions
        while all.count <= row { all.append([]) }
        all[row] = rowFracs
        gridColWidthFractions = all
    }

    /// Resize sub-pane `subIdx` in stack `stackID` so it takes `fraction` of the
    /// combined height of sub-panes `subIdx` and `subIdx+1`. The adjacent sub-pane absorbs
    /// the remainder.
    func resizeStack(_ stackID: ObjectIdentifier, subIdx: Int, toFraction fraction: CGFloat) {
        guard !isLayoutEditingDisabled else { return }
        guard let children = paneStacks[stackID] else { return }
        let n = children.count
        guard subIdx >= 0, subIdx < n - 1 else { return }
        var fracs: [CGFloat]
        if let existing = stackSubPaneHeightFractions[stackID], existing.count == n {
            fracs = existing
        } else {
            fracs = Array(repeating: 1.0 / CGFloat(n), count: n)
        }
        let combined = fracs[subIdx] + fracs[subIdx + 1]
        let newThis = min(max(fraction * combined, 0.05 * combined), 0.95 * combined)
        fracs[subIdx] = newThis
        fracs[subIdx + 1] = combined - newThis
        stackSubPaneHeightFractions[stackID] = fracs
    }

    /// Returns the current row height fractions, resetting to equal if stale.
    private func normalizedRowFractions() -> [CGFloat] {
        let n = gridRowCols.count
        if gridRowHeightFractions.count == n { return gridRowHeightFractions }
        return Array(repeating: 1.0 / CGFloat(n), count: n)
    }

    /// Returns the current column width fractions for a row, resetting to equal if stale.
    private func normalizedColFractions(forRow row: Int, nCols: Int) -> [CGFloat] {
        if gridColWidthFractions.indices.contains(row),
           gridColWidthFractions[row].count == nCols {
            return gridColWidthFractions[row]
        }
        return Array(repeating: 1.0 / CGFloat(nCols), count: nCols)
    }

    /// Equalize all row and column fractions to match the current gridRowCols layout.
    /// Called whenever gridRowCols changes structurally (pane added/removed).
    func equalizeGridFractions() {
        let nRows = gridRowCols.count
        gridRowHeightFractions = Array(repeating: 1.0 / CGFloat(nRows), count: nRows)
        gridColWidthFractions = gridRowCols.map { nCols in
            Array(repeating: 1.0 / CGFloat(max(nCols, 1)), count: max(nCols, 1))
        }
    }

    /// Whether a pane is currently stacked inside another cell (as a non-host child).
    func isStacked(_ pane: GridPane) -> Bool {
        let id = pane.id
        for (hostID, children) in paneStacks {
            if children.contains(id) && id != hostID {
                return true
            }
        }
        return false
    }

    /// Whether a pane is part of any stack (host or child).
    /// Used to decide whether closing the pane should decrement gridRowCols.
    private func isPartOfStack(_ paneID: ObjectIdentifier) -> Bool {
        // Is it a stack host?
        if paneStacks[paneID] != nil { return true }
        // Is it a non-host child?
        for (_, children) in paneStacks {
            if children.contains(paneID) { return true }
        }
        return false
    }

    /// Find the stack entry containing a given pane ID.
    /// Returns (hostID, indexInStack) or nil if not found.
    private func findStackEntry(for paneID: ObjectIdentifier) -> (ObjectIdentifier, Int)? {
        for (hostID, children) in paneStacks {
            if let idx = children.firstIndex(of: paneID) {
                return (hostID, idx)
            }
        }
        return nil
    }

    /// Remove a pane from the grid layout (used when stacking).
    private func removePaneFromGrid(_ paneID: ObjectIdentifier) {
        // We need to find the flat index of the source in the pre-stack pane list.
        // Build the flat list ignoring stack transformations.
        let allFlat: [GridPane] = gridSurfaces.map { .terminal($0) } +
            webviewPanes.map { .webview($0) } +
            pluginPanes.map { .plugin($0) }

        let flatSorted: [GridPane]
        if paneDisplayOrder.isEmpty {
            flatSorted = allFlat
        } else {
            let indexed = Dictionary(uniqueKeysWithValues: paneDisplayOrder.enumerated().map { ($1, $0) })
            flatSorted = allFlat.sorted { a, b in
                (indexed[a.id] ?? Int.max) < (indexed[b.id] ?? Int.max)
            }
        }

        // Compute the "visual" panes (same as gridPanes but we need the pre-stack
        // flat list to find the grid position). The source occupies a grid cell
        // only if it's not already hidden by a stack. Since we just added it to a
        // stack above, we need to check the state *before* gridPanes filters it.
        // We'll use the gridPanes property which already filters stacked children.
        let visualPanes = gridPanes

        // Find the source's position in the visual pane list.
        if let flatIdx = visualPanes.firstIndex(where: { $0.id == paneID }) {
            // Determine which row the source was in and shrink that row.
            var offset = 0
            for (rowIdx, cols) in gridRowCols.enumerated() {
                if flatIdx < offset + cols {
                    if gridRowCols[rowIdx] > 1 {
                        gridRowCols[rowIdx] -= 1
                    } else if gridRowCols.count > 1 {
                        gridRowCols.remove(at: rowIdx)
                    }
                    break
                }
                offset += cols
            }

            if gridRowCols.isEmpty { gridRowCols = [1] }
        }

        // Remove from paneDisplayOrder.
        if !paneDisplayOrder.isEmpty {
            paneDisplayOrder.removeAll { $0 == paneID }
        }
    }

    /// Add a pane back to the grid (used when unstacking).
    private func addPaneBackToGrid(_ paneID: ObjectIdentifier) {
        // Add to the last row.
        let row = max(gridRowCols.count - 1, 0)
        if row < gridRowCols.count {
            gridRowCols[row] += 1
        } else {
            gridRowCols.append(1)
        }

        // Add back to display order.
        if !paneDisplayOrder.isEmpty {
            if !paneDisplayOrder.contains(paneID) {
                paneDisplayOrder.append(paneID)
            }
        }
    }

    /// Clean up stack entries when a surface is being closed.
    /// If the closed pane was in a stack, remove it. If it was the host,
    /// promote the next pane or dissolve the stack.
    func cleanupStacksForClosedPane(_ paneID: ObjectIdentifier) {
        // Check if this pane is a stack host.
        if var children = paneStacks[paneID] {
            children.removeAll { $0 == paneID }
            paneStacks.removeValue(forKey: paneID)

            if children.count >= 2 {
                // Promote the first remaining child as new host.
                let newHost = children[0]
                paneStacks[newHost] = children
            } else if children.count == 1 {
                // Only one pane left — dissolve, it stays as a normal cell.
                // Nothing to do — it's already in the grid.
            }
            return
        }

        // Check if this pane is a non-host child in a stack.
        for (hostID, var children) in paneStacks {
            if let idx = children.firstIndex(of: paneID) {
                children.remove(at: idx)
                if children.count <= 1 {
                    paneStacks.removeValue(forKey: hostID)
                } else {
                    paneStacks[hostID] = children
                }
                return
            }
        }
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
        // An agent overview is pinned beside the pane it describes, so it has
        // no meaning in a window of its own.
        case .plugin, .stack, .agentOverview:
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
        // Pinned beside its agent pane — moving it alone would break adjacency.
        case .plugin, .stack, .agentOverview:
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

        moveTerminalSurface(
            source,
            to: targetController,
            destination: destination,
            insertDirection: insertDirection,
            restorePlacement: restorePlacement
        )
    }

    /// Move `source` from this window into `targetController`'s grid, inserted
    /// next to `destination` (or replacing an empty tree when nil).
    private func moveTerminalSurface(
        _ source: Ghostty.SurfaceView,
        to targetController: BaseTerminalController,
        destination: Ghostty.SurfaceView?,
        insertDirection: SplitTree<Ghostty.SurfaceView>.NewDirection,
        restorePlacement: PaneRestorePlacement? = nil
    ) {
        guard let sourceNode = surfaceTree.root?.node(view: source) else { return }
        let sourceKey = ObjectIdentifier(source)
        let oldSurfaces = targetController.gridSurfaces
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

    /// Find the surface with the given trm pane ID across all open windows.
    ///
    /// Uses the same `paneId ?? gridIndex` mapping as `handleFocusPane` and
    /// `buildCmuxSurfaceListResponse` so a pane ID means the same thing
    /// everywhere it crosses the Text Tap boundary.
    static func findSurface(paneId: Int) -> Ghostty.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            let surfaces = controller.gridSurfaces
            if let match = surfaces.enumerated().first(where: { idx, s in
                (s.paneId ?? idx) == paneId
            })?.element {
                return match
            }
        }
        return nil
    }

    /// Find the terminal controller and surface owning the given surface UUID
    /// across all open windows.
    static func findSurface(uuid: UUID) -> (BaseTerminalController, Ghostty.SurfaceView)? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if let surface = controller.surfaceTree.first(where: { $0.id == uuid }) {
                return (controller, surface)
            }
        }
        return nil
    }

    /// Handle a pane dropped onto `target` in this window when the dragged
    /// surface lives in another window: transfer it here, then optionally
    /// stack it onto the target pane.
    func receiveDroppedPane(surfaceUUID uuid: UUID, onto target: GridPane, stackMode: Bool, edge: StackDropEdge) {
        guard let (sourceController, surface) = Self.findSurface(uuid: uuid) else { return }
        guard sourceController !== self else { return }

        // Insert next to the target pane's surface; fall back to the focused
        // or first surface when the target has no terminal (webview/plugin).
        let destination = target.firstTerminalSurface ?? focusedSurface ?? gridSurfaces.first
        sourceController.moveTerminalSurface(
            surface,
            to: self,
            destination: destination,
            insertDirection: .right
        )

        // The surface must actually be in our tree before we can stack it —
        // the move above can fail silently (e.g. tree insert error).
        guard surfaceTree.contains(surface) else { return }

        if stackMode {
            stackPane(.terminal(surface), onto: target, edge: edge)
        }
    }

    private func insertWebviewPane(_ pane: WebViewPane, at index: Int? = nil, preferredRow: Int? = nil) {
        guard !isLayoutEditingDisabled else { return }
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
        guard !isLayoutEditingDisabled else { return }
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
        // An agent overview only ever describes a terminal pane, so once the
        // tree is empty there is nothing left for it to show. Drop any
        // survivors rather than keeping a window alive around a dead view.
        if !agentOverviewPanes.isEmpty {
            let ids = agentOverviewPanes.map { ObjectIdentifier($0) }
            agentOverviewPanes.removeAll()
            paneDisplayOrder.removeAll { ids.contains($0) }
        }
        if let terminal = self as? TerminalController {
            // If this controller lives inside a tab group, only close this tab.
            // Closing the whole window group here can unexpectedly terminate
            // unrelated tabs/panes.
            terminal.closeTabImmediately()
        } else {
            window?.close()
        }
    }

    /// Switch focus to a pane by its 1-indexed grid position.
    /// Called directly from performKeyEquivalent for Cmd+1–9 to avoid
    /// the Zig FFI → notification round-trip that adds latency.
    /// Returns true if focus was switched.
    @discardableResult
    func focusPaneByIndex(_ index: Int) -> Bool {
        // Index over the *visual* panes, not just terminals. Indexing
        // `gridSurfaces` skipped every non-terminal cell, so the numbers ran
        // past agent overviews, webviews, and plugin panes — Cmd+N could never
        // land on one, and the counting didn't match what's on screen.
        let panes = gridPanes
        guard panes.count > 1 else { return false }
        let targetIdx = min(index - 1, panes.count - 1)
        guard targetIdx >= 0 else { return false }

        switch panes[targetIdx] {
        case .terminal(let surface):
            guard surface !== focusedSurface else { return true }
            focusedSurface = surface
            window?.makeFirstResponder(surface)
            return true

        case .stack(let children):
            // Focus the stack's visible host.
            guard case .terminal(let surface)? = children.first else { return false }
            guard surface !== focusedSurface else { return true }
            focusedSurface = surface
            window?.makeFirstResponder(surface)
            return true

        case .agentOverview, .webview, .plugin:
            // No surface to focus: these carry selection separately.
            selectNonSurfacePane(panes[targetIdx].id)
            return true
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
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - LLM Integration

    /// Build pane context for the LLM system prompt.
    func buildPaneContext() -> [PaneContext] {
        let surfaces = gridSurfaces
        return surfaces.enumerated().map { index, surface in
            let title = surface.title.isEmpty ? "Shell" : surface.title
            let isFocused = surface === focusedSurface

            // Viewport only: the LLM system prompt truncates each pane to its
            // last 30 lines, so reading the full scrollback here is pure waste.
            let visibleText = surface.cachedVisibleContents.get()

            return PaneContext(
                index: surface.paneId ?? index,
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
                sendTextToSurface(surface, text: command)
                sendTextToSurface(surface, text: "\r")

            case .sendToAll(let command):
                for surface in surfaces {
                    sendTextToSurface(surface, text: command)
                    sendTextToSurface(surface, text: "\r")
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
                    Self.setDefaultWatermark(forPaneId: newView.paneId!)
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

        // Mirror windows never close panes locally: the primary owns the
        // layout, and killing a pane here would take down the shared zmx
        // daemon the primary is attached to.
        guard !isLayoutEditingDisabled else { return }

        // If the child process is not alive, then we exit immediately
        guard withConfirmation else {
            if sessionRole == .primary { Self.killZmxSessions(in: node) }
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
                if self.sessionRole == .primary { Self.killZmxSessions(in: node) }
                self.removeSurfaceNode(node)
            }
        }
    }

    /// Explicitly closing a pane is a kill, not a detach: take its zmx
    /// session down too so closed panes don't accumulate background daemons.
    /// (Window close / app quit never come through here, so those still
    /// detach and the sessions persist.)
    private static func killZmxSessions(in node: SplitTree<Ghostty.SurfaceView>.Node) {
        for view in node {
            if let session = view.zmxSessionName {
                ZmxSessionManager.killSession(session)
                view.zmxSessionName = nil
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
        if case .leaf(let view) = node {
            TrmDiagnostics.log("[close-trace] removeSurfaceNode paneId=\(String(describing: view.paneId)) gridPanes=\(self.gridPanes.count)")
        } else {
            TrmDiagnostics.log("[close-trace] removeSurfaceNode (non-leaf subtree) gridPanes=\(self.gridPanes.count)")
        }
        // Move focus if the closed surface was focused and we have a next target
        let closingFocused = node.contains(where: { $0 == focusedSurface })
        // Capture the current focusedSurface before we update it, so we can
        // pass the correct moveFocusFrom to replaceSurfaceTree.
        let previousFocus = focusedSurface
        let nextFocus: Ghostty.SurfaceView? = if closingFocused {
            findNextFocusTargetAfterClosing(node: node)
        } else {
            nil
        }

        // Synchronously clear focusedSurface so that any code running between
        // now and the async focus move in replaceSurfaceTree won't use a stale
        // reference to a surface that's being removed from the tree.
        if closingFocused {
            focusedSurface = nextFocus
        }

        // Clean up stacks for the closed surface.
        var wasInStack = false
        if case .leaf(let view) = node {
            let paneID = ObjectIdentifier(view)
            wasInStack = isPartOfStack(paneID)

            // Determine if closing this pane will dissolve a 2-pane stack.
            // If so, the cell stays but the host changes — no grid adjustment needed.
            // If the pane was a non-host child, the cell stays — no adjustment.
            // If the pane was a host with ≥3 children, the cell stays — no adjustment.
            let stackDissolves: Bool
            if wasInStack {
                if let children = paneStacks[paneID] {
                    // Host pane — stack dissolves if exactly 2 children
                    stackDissolves = children.count <= 2
                } else if let (hostID, _) = findStackEntry(for: paneID) {
                    // Non-host child — stack dissolves if host had exactly 2 children
                    stackDissolves = (paneStacks[hostID]?.count ?? 0) <= 2
                } else {
                    stackDissolves = false
                }
            } else {
                stackDissolves = false
            }

            cleanupStacksForClosedPane(paneID)

            // An agent overview only describes this surface, so it goes with it.
            closeAgentOverviews(forSurface: view)

            // Dismiss peek if the peeked pane is being closed.
            if peekedPane == paneID { peekedPane = nil }

            // Update grid shape if in grid mode.
            // - Standalone pane (not in stack): decrement gridRowCols (cell disappears)
            // - Stacked pane where stack survives (≥2 remaining): no adjustment (cell stays)
            // - Stacked pane where stack dissolves (1 remaining): no adjustment (cell becomes normal)
            if useGridLayout && !wasInStack {
                // Use gridPanes (visual grid) to find the row, NOT surfaceTree.
                // surfaceTree includes stacked children which don't occupy their
                // own grid cells, so its indices don't map to gridRowCols.
                let visualPanes = gridPanes
                if let visualIdx = visualPanes.firstIndex(where: { pane in
                    switch pane {
                    case .terminal(let s): return s === view
                    default: return false
                    }
                }) {
                    let (row, _) = gridPosition(flatIndex: visualIdx)
                    if row < gridRowCols.count {
                        let before = gridRowCols
                        if gridRowCols[row] > 1 {
                            gridRowCols[row] -= 1
                        } else {
                            gridRowCols.remove(at: row)
                        }
                        if gridRowCols.isEmpty {
                            gridRowCols = [1]
                        }
                        Ghostty.logger.info("removeSurface grid: \(before) → \(self.gridRowCols), closed row=\(row), visualPanes=\(visualPanes.count), surfaces=\(Array(self.surfaceTree).count)")
                    }
                } else {
                    Ghostty.logger.warning("removeSurface: could not find closing pane in gridPanes (\(visualPanes.count) entries), gridRowCols=\(self.gridRowCols)")
                }
            }
        }

        // Remove closed pane from paneDisplayOrder to avoid stale entries
        // that could confuse ensurePaneDisplayOrder or future move operations.
        if case .leaf(let view) = node {
            let closedID = ObjectIdentifier(view)
            if !paneDisplayOrder.isEmpty {
                paneDisplayOrder.removeAll { $0 == closedID }
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
            moveFocusFrom: previousFocus,
            undoAction: "Close Terminal"
        )

        // Safety net: reconcile gridRowCols after the surface tree has been
        // updated, in case they drifted from the actual pane count.
        // Skip when the closed pane was in a stack — the grid accounting
        // was already handled correctly above, and reconcile would
        // over-correct because gridPanes.count dropped but gridRowCols
        // intentionally stayed the same (the cell persists for remaining
        // stack members).
        //
        // Only allow reconcile to SHRINK during close, never grow. Growing
        // (adding new rows) during a close operation means stacked panes are
        // being counted as separate cells, which would cause them to spill
        // into new rows at the bottom.
        if useGridLayout && !wasInStack {
            let savedRowCols = gridRowCols
            reconcileGridRowCols()
            if gridRowCols.reduce(0, +) > savedRowCols.reduce(0, +) {
                Ghostty.logger.warning("removeSurface: reconcile grew grid \(savedRowCols) → \(self.gridRowCols), reverting")
                gridRowCols = savedRowCols
            }
        }
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
            DispatchQueue.main.async { [weak newView, weak oldView] in
                guard let newView else { return }
                Ghostty.moveFocus(to: newView, from: oldView)
            }
        }

        // Setup our undo — only when an explicit action name is provided.
        // During initial setup (rebuildTerminalSurfaces) undoAction is nil,
        // and we must NOT capture the old tree in the undo stack because
        // those surfaces are about to be deallocated.
        guard let undoAction, let undoManager else { return }
        undoManager.setActionName(undoAction)

        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.surfaceTree = oldTree
            if let oldView {
                DispatchQueue.main.async { [weak oldView] in
                    guard let oldView else { return }
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

    @objc private func ghosttyCommandDidFinish(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        // Map the surface to its pane ID, matching the scanner's convention.
        guard let index = gridSurfaces.firstIndex(where: { $0 === surfaceView }) else { return }
        let paneId = surfaceView.paneId ?? index
        terminalOutputScanner.notifyCommandDidFinish(paneId: paneId)
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

    // MARK: - cmux-Compatible API

    @objc private func handleFocusPane(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let paneId = userInfo["paneId"] as? Int else {
            Ghostty.logger.warning("handleFocusPane: missing or wrong-type paneId in userInfo=\(String(describing: notification.userInfo))")
            return
        }
        // Match by paneId if set, otherwise fall back to grid index — same
        // mapping used in buildCmuxSurfaceListResponse (paneId ?? index).
        let surfaces = gridSurfaces
        let knownIds = surfaces.enumerated().map { idx, s in s.paneId ?? idx }
        guard let surface = surfaces.enumerated().first(where: { idx, s in
            (s.paneId ?? idx) == paneId
        })?.element else {
            Ghostty.logger.warning("handleFocusPane: no surface with paneId=\(paneId), known=\(knownIds)")
            return
        }
        Ghostty.logger.debug("handleFocusPane: focusing paneId=\(paneId)")
        focusSurface(surface)
    }

    @objc private func handleCmuxQuery(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let method = userInfo["method"] as? UInt8,
              let rawRequestId = userInfo["requestId"] as? String,
              let clientIdx = userInfo["clientIdx"] as? UInt32 else { return }

        // The id comes from the client unvalidated; escape it once here so
        // every interpolation below yields well-formed JSON even when the id
        // contains quotes or backslashes.
        let requestId = Self.cmuxJSONEscape(rawRequestId)

        // Only one controller should respond to avoid duplicate responses.
        // Prefer the main window; otherwise use the first (oldest) controller.
        guard window != nil else { return }
        let allControllers = TerminalController.all
        if allControllers.count > 1 {
            // If this window is main, respond. If another is main, defer to it.
            // If none is main, only the first controller in the list responds.
            let mainController = allControllers.first { $0.window?.isMainWindow == true }
            if let main = mainController {
                if self !== main { return }
            } else {
                if self !== allControllers.first { return }
            }
        }

        let json: String
        switch method {
        case 2: // system.identify
            json = buildCmuxIdentifyResponse(requestId: requestId)
        case 3: // surface.list
            json = buildCmuxSurfaceListResponse(requestId: requestId)
        case 7: // surface.focus
            // surface.focus is handled as an action — need params from original message.
            // For now, acknowledge; the actual focus happens via existing focus_pane action.
            json = "{\"id\":\"\(requestId)\",\"ok\":true,\"result\":{}}"
        case 8: // workspace.list
            json = buildCmuxWorkspaceListResponse(requestId: requestId)
        case 9: // workspace.current
            json = "{\"id\":\"\(requestId)\",\"ok\":true,\"result\":{\"workspace_id\":\"workspace-0\",\"name\":\"default\"}}"
        case 6: // surface.split — acknowledge; actual split comes through existing mechanism
            json = "{\"id\":\"\(requestId)\",\"ok\":true,\"result\":{}}"
        default:
            json = "{\"id\":\"\(requestId)\",\"ok\":false,\"error\":\"unhandled method\"}"
        }

        Trm.shared.respondCmux(clientIdx: clientIdx, resultJSON: json)
    }

    static func cmuxJSONEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func buildCmuxSurfaceListResponse(requestId: String) -> String {
        let surfaces = gridSurfaces
        var entries: [String] = []
        func jsonEscape(_ s: String) -> String { Self.cmuxJSONEscape(s) }
        for (index, surface) in surfaces.enumerated() {
            let paneId = surface.paneId ?? index
            let title = surface.title.isEmpty ? "Shell" : surface.title
            let isFocused = surface === focusedSurface
            let escapedTitle = jsonEscape(title)
            let childPid = Trm.shared.paneChildPid(paneId: UInt32(paneId))
            // The pty child pid currently comes back 0 (Ghostty owns the PTY,
            // the Zig pane stub doesn't track it), so external tools can't map a
            // pane to its shell process. Ghostty DOES track the surface's working
            // directory via the `pwd` action, so we emit it as the authoritative
            // pane→cwd key — consumers (e.g. flan-tui) route by this instead of
            // guessing from tty/process trees, which is unreliable.
            let pwdField: String
            if let pwd = surface.pwd, !pwd.isEmpty {
                pwdField = "\"\(jsonEscape(pwd))\""
            } else {
                pwdField = "null"
            }
            entries.append(
                "{\"surface_id\":\"surface-\(paneId)\"," +
                "\"pane_id\":\"\(paneId)\"," +
                "\"title\":\"\(escapedTitle)\"," +
                "\"focused\":\(isFocused)," +
                "\"pid\":\(childPid)," +
                "\"pwd\":\(pwdField)," +
                "\"workspace_id\":\"workspace-0\"," +
                "\"window_id\":\"window-0\"}"
            )
        }
        let surfacesJSON = "[" + entries.joined(separator: ",") + "]"
        let layoutJSON = buildCmuxLayoutJSON()
        return "{\"id\":\"\(requestId)\",\"ok\":true,\"result\":{\"surfaces\":\(surfacesJSON),\"layout\":\(layoutJSON)}}"
    }

    /// Layout introspection attached to the surface.list response: the visual
    /// cell order (zmx session names for terminals, pane types otherwise),
    /// grid shape, and window identity/role. Lets external tools — and the
    /// layout-sync E2E test — assert what a window actually shows.
    private func buildCmuxLayoutJSON() -> String {
        func cellKey(_ pane: GridPane) -> String {
            switch pane {
            case .terminal(let s):
                return s.zmxSessionName ?? "terminal-\(s.paneId ?? -1)"
            case .webview:
                return "webview"
            case .plugin(let p):
                return p.kind.rawValue
            case .agentOverview:
                return "agent_overview"
            case .stack(let children):
                return "stack(" + children.map(cellKey).joined(separator: "+") + ")"
            }
        }
        let cells = gridPanes
            .map { "\"\(Self.cmuxJSONEscape(cellKey($0)))\"" }
            .joined(separator: ",")
        let rowCols = gridRowCols.map(String.init).joined(separator: ",")
        let role = sessionRole == .mirror ? "mirror" : "primary"
        return "{\"window_id\":\"\(Self.cmuxJSONEscape(windowUUID))\"," +
            "\"role\":\"\(role)\"," +
            "\"row_cols\":[\(rowCols)]," +
            "\"cells\":[\(cells)]}"
    }

    private func buildCmuxIdentifyResponse(requestId: String) -> String {
        let surfaces = gridSurfaces
        let focusedIndex = surfaces.firstIndex(where: { $0 === focusedSurface }) ?? 0
        let focusedPaneId = focusedSurface?.paneId ?? focusedIndex
        return "{\"id\":\"\(requestId)\",\"ok\":true,\"result\":{" +
            "\"window_id\":\"window-0\"," +
            "\"workspace_id\":\"workspace-0\"," +
            "\"pane_id\":\"pane-\(focusedPaneId)\"," +
            "\"surface_id\":\"surface-\(focusedPaneId)\"}}"
    }

    private func buildCmuxWorkspaceListResponse(requestId: String) -> String {
        return "{\"id\":\"\(requestId)\",\"ok\":true,\"result\":{\"workspaces\":[" +
            "{\"workspace_id\":\"workspace-0\",\"name\":\"default\",\"active\":true}" +
            "]}}"
    }

    /// Wrap a pane's spawn command with `zmx attach` when session persistence
    /// is enabled, so the shell runs under a detachable per-session daemon
    /// that survives GUI quit. Returns the session name and the logical
    /// (unwrapped) command when wrapping happened, nil otherwise.
    ///
    /// Pass an existing `session` name to reattach (restore path); zmx
    /// replays the terminal state itself in that case.
    static func wrapForPersistence(
        _ cfg: inout Ghostty.SurfaceConfiguration,
        ghostty: Ghostty.App,
        session: String? = nil
    ) -> (session: String, logical: String?)? {
        guard ghostty.sessionPersistence else { return nil }
        let name = session ?? ZmxSessionManager.newSessionName()
        let logical = cfg.command
        guard let wrapped = ZmxSessionManager.wrappedCommand(session: name, logical: logical) else {
            // zmx binary missing: run unwrapped rather than failing the pane.
            return nil
        }
        cfg.command = wrapped
        cfg.environmentVariables["ZMX_DIR"] = ZmxSessionManager.zmxDir
        return (session: name, logical: logical)
    }

    /// Inject cmux/trm env vars into a surface configuration for a given pane ID.
    static func injectCmuxEnvVars(into config: inout Ghostty.SurfaceConfiguration, paneId: Int) {
        if let socketPath = Trm.shared.cmuxSocketPath() {
            config.environmentVariables["TRM_SOCKET_PATH"] = socketPath
            config.environmentVariables["CMUX_SOCKET_PATH"] = socketPath
        }
        config.environmentVariables["TRM_PANE_ID"] = "\(paneId)"
        config.environmentVariables["CMUX_SURFACE_ID"] = "surface-\(paneId)"
        config.environmentVariables["CMUX_WORKSPACE_ID"] = "workspace-0"
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
        let target = notification.object as? Ghostty.SurfaceView
        let processAlive = notification.userInfo?["process_alive"] as? Bool
        TrmDiagnostics.log("[close-trace] ghosttyDidCloseSurface fired paneId=\(String(describing: target?.paneId)) processAlive=\(String(describing: processAlive)) isMovingSurface=\(self.isMovingSurface)")
        guard !isMovingSurface else {
            TrmDiagnostics.log("[close-trace] ghosttyDidCloseSurface suppressed during surface move")
            return
        }
        guard let target else {
            TrmDiagnostics.log("[close-trace] ghosttyDidCloseSurface: object is not a SurfaceView")
            return
        }
        guard let node = surfaceTree.root?.node(view: target) else {
            TrmDiagnostics.log("[close-trace] ghosttyDidCloseSurface: target not in surfaceTree (already removed?)")
            return
        }
        TrmDiagnostics.log("[close-trace] ghosttyDidCloseSurface: calling closeSurface")
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

    @objc private func handleOpenSplitBrowser(_ notification: Notification) {
        guard window?.isKeyWindow == true else { return }
        let action = notification.userInfo?["action"] as? String ?? "open_browser"
        let arg1 = notification.userInfo?["arg1"] as? String ?? notification.userInfo?["url"] as? String ?? ""
        let arg2 = notification.userInfo?["arg2"] as? String ?? ""

        switch action {
        case "open_browser":
            openSplitBrowser(urlString: arg1)
        case "browser_navigate":
            if let pane = findFirstWebViewPane() {
                pane.navigate(to: arg1)
            } else {
                openSplitBrowser(urlString: arg1)
            }
        case "browser_eval":
            if let pane = findFirstWebViewPane() {
                Task { @MainActor in
                    _ = try? await pane.evaluateJS(arg1)
                }
            }
        case "browser_snapshot":
            if let pane = findFirstWebViewPane() {
                Task { @MainActor in
                    _ = try? await pane.snapshotAccessibilityTree()
                }
            }
        case "browser_click":
            if let pane = findFirstWebViewPane() {
                Task { @MainActor in
                    _ = try? await pane.clickElement(selector: arg1)
                }
            }
        case "browser_fill":
            if let pane = findFirstWebViewPane() {
                Task { @MainActor in
                    _ = try? await pane.fillField(selector: arg1, text: arg2)
                }
            }
        default:
            break
        }
    }

    /// Find the first webview pane in the current window.
    private func findFirstWebViewPane() -> WebViewPane? {
        webviewPanes.first
    }

    /// Open a browser pane alongside the current terminal.
    /// If urlString is empty, opens about:blank (user can type in the URL bar).
    func openSplitBrowser(urlString: String = "") {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if trimmed.isEmpty {
            url = URL(string: "about:blank")!
        } else if trimmed.contains("://") {
            url = URL(string: trimmed) ?? URL(string: "about:blank")!
        } else {
            url = URL(string: "https://\(trimmed)") ?? URL(string: "about:blank")!
        }

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
        sendTextToSurface(surface, text: command)
        sendTextToSurface(surface, text: "\r")
    }

    @objc private func handleQuickActionScriptExecute(_ notification: Notification) {
        guard window?.isKeyWindow == true else { return }
        guard let script = notification.userInfo?["script"] as? String,
              let actionName = notification.userInfo?["actionName"] as? String,
              let actionId = notification.userInfo?["actionId"] as? UUID else { return }
        executeScript(script, actionName: actionName, actionId: actionId)
    }

    /// Execute an LLM-driven script action.
    ///
    /// Builds pane context, resolves `#` references, sends the script to the LLM,
    /// and executes the returned actions against the terminal panes.
    private func executeScript(_ script: String, actionName: String, actionId: UUID) {
        let context = buildPaneContext()

        // Resolve # references in the script
        let (cleanedScript, references) = PaneAddressing.extractReferences(from: script, panes: context)
        let highlightedPanes = Set(references.compactMap(\.resolvedIndex))

        // Build augmented prompt
        let prompt = "Execute this automated script action called '\(actionName)': \(cleanedScript)"

        commandPaletteAIState.isAgentActive = true
        commandPaletteAIState.appendStatus("Running script: \(actionName)...")

        Task { @MainActor in
            do {
                let response = try await Trm.shared.llmClient.submit(
                    prompt: prompt,
                    paneContext: context
                )

                executeTrmActions(response.actions)
                commandPaletteAIState.appendStatus("Script '\(actionName)' completed.")
            } catch {
                commandPaletteAIState.appendStatus("Script '\(actionName)' failed: \(error.localizedDescription)")
            }

            quickActionsPlugin?.executingActionId = nil
            commandPaletteAIState.isAgentActive = false
        }
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

            // Hold Cmd+Option to dim every pane's contents and light up its
            // watermark: a way to find the pane you want in a busy grid
            // without reading any of them. Held, not toggled, so it can't be
            // left on by accident.
            //
            // Not Cmd+Shift: that prefixes the pane-move shortcuts
            // (Cmd+Shift+Arrow) and New Row (Cmd+Shift+T), so the dim flashed
            // on every one of them. Cmd+Control is taken by the overview move
            // shortcuts, leaving Cmd+Option as the free chord.
            let watermarkPeek = flags == [.command, .option]
            let wasWatermarkPeeking = isWatermarkPeeking
            if watermarkPeek != isWatermarkPeeking {
                isWatermarkPeeking = watermarkPeek
            }

            if optionOnly {
                // Option key was just pressed (alone). Not after a Cmd+Option
                // peek, though: letting go of Cmd first leaves Option held,
                // which would otherwise arm the double-tap and pop the command
                // palette when the user was only peeking.
                optionPressedAlone = !wasWatermarkPeeking
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
        case createExtension
        case agentOverview
        case remotePane(host: String?)
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
        case .createExtension:
            promptCreateExtension()
            return true
        case .agentOverview:
            showAgentOverview(for: .terminal(surfaceView))
            return true
        case .remotePane(let host):
            newRemotePane(host: host, at: surfaceView)
            return true
        }
    }

    // MARK: - Remote Panes

    /// Default path to trm's bundled zmx on a remote machine.
    static let defaultRemoteZmxPath = "/Applications/trm.app/Contents/MacOS/zmx"

    /// Open a new terminal pane whose shell runs on another machine.
    ///
    /// The pane's command is `ssh -t <host> <remote-zmx> attach <session>`, so
    /// the session daemon lives on the *remote* host: the work survives there
    /// independently of this UI, and the pane can be reattached later (from
    /// here or from that machine) exactly like a local server-backed pane.
    /// Rendering stays local — the same arrangement `trm attach-remote` uses
    /// for whole windows, applied to a single new pane.
    ///
    /// New panes only. An existing pane cannot be moved to another host: its
    /// process is already running under a specific machine's daemon, and
    /// nothing in the PTY model can migrate that.
    func newRemotePane(host: String?, at surfaceView: Ghostty.SurfaceView) {
        guard !isLayoutEditingDisabled else { return }

        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            promptForRemoteHost(at: surfaceView)
            return
        }

        // The remote session name is generated here so it can be recorded in
        // the checkpoint and reattached later.
        let session = ZmxSessionManager.newSessionName()
        let remoteZmx = Self.defaultRemoteZmxPath
        let command = Self.remoteAttachCommand(host: host, session: session, zmxPath: remoteZmx)

        var config = Ghostty.SurfaceConfiguration()
        config.command = command

        guard let view = newGridPane(
            at: surfaceView,
            direction: .right,
            baseConfig: config,
            skipPersistenceWrap: true
        ) else {
            presentInternalCommandError(
                title: "Could not Create Remote Pane",
                message: "Failed to create a pane for \(host)."
            )
            return
        }

        // Record the binding so the pane round-trips through a checkpoint as a
        // remote pane rather than as a local shell running an ssh command.
        view.remoteHost = host
        view.remoteZmxSession = session
    }

    /// Build the SSH command that attaches a remote zmx session, creating it
    /// on first connect.
    ///
    /// `-t` forces a PTY (zmx needs one); the remote side runs zmx directly so
    /// the daemon is owned by that machine.
    static func remoteAttachCommand(host: String, session: String, zmxPath: String) -> String {
        // The command runs through the local shell, so quote what may contain
        // spaces. The host is validated before we get here.
        "ssh -t \(host) \"\(zmxPath)\" attach \(session)"
    }

    /// Ask which machine the new pane should run on.
    private func promptForRemoteHost(at surfaceView: Ghostty.SurfaceView) {
        let alert = NSAlert()
        alert.messageText = "New Remote Pane"
        alert.informativeText = """
        Which machine should this pane run on?

        Requires key-based SSH to the host and trm installed there. \
        The pane's session runs on that machine and keeps running if this \
        window closes.
        """
        // Offer machines discovered over Bonjour, while still allowing any
        // destination to be typed — plenty of hosts aren't on this LAN.
        let discovered = RemoteHostDiscovery.shared.hosts
        let input: NSTextField
        if discovered.isEmpty {
            input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        } else {
            let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            combo.addItems(withObjectValues: discovered.map(\.sshDestination))
            combo.completes = true
            combo.numberOfVisibleItems = 8
            input = combo
        }
        input.placeholderString = "user@host"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create Pane")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        // Reject anything that could break out of the command we build.
        guard Self.isValidRemoteHost(host) else {
            presentInternalCommandError(
                title: "Invalid Host",
                message: "'\(host)' isn't a valid SSH destination. Use host or user@host."
            )
            return
        }
        newRemotePane(host: host, at: surfaceView)
    }

    /// Whether a string is a plausible SSH destination (`host` or `user@host`,
    /// optionally with a port suffix handled by ssh config).
    ///
    /// This is a command-injection guard as much as a validation: the host is
    /// interpolated into a shell command, so anything outside this character
    /// set is refused rather than escaped.
    static func isValidRemoteHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 255 else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-@"))
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // At most one @, and neither side empty when present.
        let parts = host.split(separator: "@", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return !parts[0].isEmpty
        case 2: return !parts[0].isEmpty && !parts[1].isEmpty
        default: return false
        }
    }

    /// Prompt for an extension description and hand it to the LLM builder.
    private func promptCreateExtension() {
        let alert = NSAlert()
        alert.messageText = "Create Extension"
        alert.informativeText = """
        Describe what the extension should do. Examples:
        "notify me when any pane prints BUILD FAILED"
        "show Claude's context usage as a pill on each pane"
        """
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 48))
        input.placeholderString = "When … then …"
        alert.accessoryView = input
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let description = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        ExtensionBuilder.shared.createInteractively(description: description)
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

        // trm.remote_pane [user@host] / trm.remote [user@host] — a new pane
        // whose shell runs on another machine. Bare form prompts for the host.
        let bareRemoteNames: Set<String> = ["trm.remote_pane", "trm.remote"]
        if bareRemoteNames.contains(trimmed) {
            return .remotePane(host: nil)
        }

        for prefix in ["trm.remote_pane ", "trm.remote "] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let arg = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeQuotedArgument(arg)
            return .remotePane(host: normalized.isEmpty ? nil : normalized)
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

        // trm.create_extension
        if trimmed == "trm.create_extension" {
            return .createExtension
        }

        // trm.agent_overview
        if trimmed == "trm.agent_overview" {
            return .agentOverview
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
                message: "'\(rawType)' is not a recognized pane type.\n\nAvailable types: terminal, webview, notes, git_status, file_browser, log_viewer, process_monitor, markdown_preview, system_info"
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

    /// Pane IDs that reattached to a live zmx session during the last
    /// restore. `applyPaneConfig` skips scrollback/initial-command replay
    /// for these (zmx already replayed the live session) and clears them.
    private var reattachedPaneIds: Set<Int> = []

    /// Scrollback filenames saved by the most recent `saveScrollbackSnapshots` call,
    /// keyed by `ObjectIdentifier` of the `SurfaceView`.
    private var savedScrollbackFiles: [ObjectIdentifier: String] = [:]

    /// Cheap per-surface fingerprint of the content at the last snapshot, used to
    /// skip the expensive full-scrollback read+serialize when nothing changed.
    ///
    /// The 30s snapshot timer used to read & re-serialize the ENTIRE scrollback of
    /// every pane on every tick, even when idle — the c_allocator buffers from those
    /// full-screen reads accumulated unbounded and were the root of the multi-GB
    /// memory growth. We now gate the full read on a cheap viewport fingerprint that
    /// changes whenever new output arrives.
    private var lastScrollbackFingerprint: [ObjectIdentifier: Int] = [:]

    /// Save the scrollback buffer of every terminal pane to disk.
    /// Call this before `buildCurrentConfigToml()` so the TOML can reference the files.
    ///
    /// `force: true` bypasses the change-detection gate (use on quit / explicit save
    /// where we want a snapshot regardless of whether the viewport changed).
    func saveScrollbackSnapshots(sessionBaseName: String, force: Bool = false) {
        // Carry prior filenames forward: a pane we skip below (unchanged since the
        // last snapshot) still has a valid file on disk, so its TOML reference must
        // survive. We prune below to drop any surface that no longer exists.
        var liveKeys = Set<ObjectIdentifier>()

        // Flatten stacks the same way buildCurrentConfigToml does.
        var terminalIndex = 0
        for pane in gridPanes {
            let terminals: [Ghostty.SurfaceView]
            if case .stack(let children) = pane {
                terminals = children.compactMap {
                    if case .terminal(let s) = $0 { return s } else { return nil }
                }
            } else if case .terminal(let s) = pane {
                terminals = [s]
            } else {
                continue
            }
            for surface in terminals {
                defer { terminalIndex += 1 }
                let key = ObjectIdentifier(surface)
                liveKeys.insert(key)

                // Cheap change-detection: the visible viewport read is small and
                // bounded (~a few KB), unlike the full scrollback. New shell output
                // always mutates the viewport, so its fingerprint is a reliable
                // "did anything change?" signal. Skip the expensive full read when
                // it's unchanged since the last snapshot — the prior file on disk
                // (and its entry in savedScrollbackFiles) stays valid.
                let visible = surface.cachedVisibleContents.get()
                var fingerprint = Hasher()
                fingerprint.combine(visible)
                let fp = fingerprint.finalize()
                if !force, lastScrollbackFingerprint[key] == fp {
                    continue
                }

                let text = surface.cachedScreenContents.get()
                if !text.isEmpty {
                    if let filename = SessionManager.saveScrollback(
                        text,
                        sessionBaseName: sessionBaseName,
                        paneIndex: terminalIndex
                    ) {
                        savedScrollbackFiles[key] = filename
                        lastScrollbackFingerprint[key] = fp
                    }
                }
            }
        }

        // Drop bookkeeping for surfaces that no longer exist in this controller.
        savedScrollbackFiles = savedScrollbackFiles.filter { liveKeys.contains($0.key) }
        lastScrollbackFingerprint = lastScrollbackFingerprint.filter { liveKeys.contains($0.key) }
    }

    func buildCurrentConfigToml() -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = dateFormatter.string(from: Date())

        var lines: [String] = []
        lines.append("# trm session config — saved \(timestamp)")
        lines.append("")

        // Window identity for live layout sync: mirrors subscribe to this
        // window's layout updates over the primary's Text Tap socket.
        lines.append("window_id = \(tomlQuote(windowUUID))")
        if sessionRole == .primary, Trm.shared.textTapRunning,
           let socketPath = Trm.shared.textTapSocketPath {
            lines.append("text_tap_socket = \(tomlQuote(socketPath))")
        }
        lines.append("")

        // Flatten stacks for serialization, tagging stacked panes with a
        // group name so they can be re-stacked on restore. The stack's
        // sub-pane height fractions ride on its first (host) pane.
        let visualPanes = gridPanes
        var flatPanes: [(pane: GridPane, stackGroup: String?, stackFractions: [CGFloat]?)] = []
        var stackCounter = 0
        for pane in visualPanes {
            if case .stack(let children) = pane {
                let groupName = "stack_\(stackCounter)"
                stackCounter += 1
                let hostFractions = children.first.flatMap { host -> [CGFloat]? in
                    guard let fracs = stackSubPaneHeightFractions[host.id],
                          fracs.count == children.count else { return nil }
                    return fracs
                }
                for (childIdx, child) in children.enumerated() {
                    flatPanes.append((
                        pane: child,
                        stackGroup: groupName,
                        stackFractions: childIdx == 0 ? hostFractions : nil
                    ))
                }
            } else {
                flatPanes.append((pane: pane, stackGroup: nil, stackFractions: nil))
            }
        }

        // Save the visual (stacked) gridRowCols. On restore, the flat-to-visual
        // adjustment is handled by stackPane() calls after pane creation.
        // If gridRowCols is stale (sum doesn't match visual pane count),
        // recompute from the visual count using the active grid config dimensions.
        // Use visual pane count (excluding stacked children) rather than the
        // flat count, since gridRowCols represents the visual layout.
        var saveRowCols = gridRowCols
        let visualPaneCount = visualPanes.count
        if saveRowCols.reduce(0, +) != visualPaneCount, visualPaneCount > 0 {
            // Reconcile against the *live* shape, not activeGridConfig: that
            // is the launch-time config and goes stale as soon as panes are
            // added, closed, or rearranged. Using it pivoted layouts on
            // restore (a 3-across window saved from a rows=3/cols=1 launch
            // config came back as a 3-tall column).
            saveRowCols = Self.reconcileRowCols(saveRowCols, toTotal: visualPaneCount)
        }

        // [grid] section
        let rows = saveRowCols.count
        let cols = saveRowCols.max() ?? 1
        lines.append("[grid]")
        lines.append("rows = \(rows)")
        lines.append("cols = \(cols)")
        // Serialize per-row column counts so jagged grids and stacked layouts
        // survive round-trip. Always emit row_cols when stacks exist, since the
        // visual layout may differ from rows*cols.
        let hasStacks = stackCounter > 0
        let isJagged = Set(saveRowCols).count > 1
        if isJagged || hasStacks {
            let rowColsStr = saveRowCols.map(String.init).joined(separator: ",")
            lines.append("row_cols = \(tomlQuote(rowColsStr))")
        }
        lines.append("gap = \(Int(gridGap))")
        lines.append("outer_padding = \(Int(gridPadding))")
        // Pane size fractions, only when they match the serialized shape
        // (missing keys mean equal splits — same convention as the grid view).
        if gridRowHeightFractions.count == saveRowCols.count {
            lines.append("row_fractions = \(tomlQuote(Self.fractionListString(gridRowHeightFractions)))")
        }
        if gridColWidthFractions.count == saveRowCols.count,
           zip(saveRowCols, gridColWidthFractions).allSatisfy({ $0 == $1.count }) {
            let joined = gridColWidthFractions
                .map { Self.fractionListString($0) }
                .joined(separator: ";")
            lines.append("col_fractions = \(tomlQuote(joined))")
        }
        lines.append("")

        // Serialize panes in visual (display) order so watermarks,
        // positions, and pane types stay consistent on reload.
        for (index, entry) in flatPanes.enumerated() {
            switch entry.pane {
            case .terminal(let surface):
                lines.append("[[panes]]")
                lines.append("pane_type = \"terminal\"")
                // Persist the logical command, never the zmx-wrapped one:
                // restore re-wraps as needed, and a stale absolute zmx path
                // inside the TOML would break attach after app updates.
                let persistedCommand = surface.zmxSessionName != nil
                    ? surface.logicalCommand
                    : surface.initialCommand
                if let command = persistedCommand, !command.isEmpty {
                    lines.append("command = \(tomlQuote(command))")
                }
                if let zmxSession = surface.zmxSessionName {
                    lines.append("zmx_session = \(tomlQuote(zmxSession))")
                }
                // Remote panes: the daemon lives on another machine, so record
                // the destination and its session rather than a local one.
                if let remoteHost = surface.remoteHost, !remoteHost.isEmpty {
                    lines.append("remote_host = \(tomlQuote(remoteHost))")
                    if let remoteSession = surface.remoteZmxSession, !remoteSession.isEmpty {
                        lines.append("remote_session = \(tomlQuote(remoteSession))")
                    }
                }
                if let pwd = surface.pwd, !pwd.isEmpty {
                    lines.append("cwd = \(tomlQuote(pwd))")
                }
                let id = surface.paneId ?? index
                let watermark = Trm.shared.watermark(forPaneId: UInt32(id))
                if let watermark, !watermark.isEmpty {
                    lines.append("watermark = \(tomlQuote(watermark))")
                }
                if !surface.initialCommands.isEmpty {
                    let quoted = surface.initialCommands
                        .map { tomlQuote($0) }
                        .joined(separator: ", ")
                    lines.append("initial_commands = [\(quoted)]")
                }
                if let sbFile = savedScrollbackFiles[ObjectIdentifier(surface)] {
                    lines.append("scrollback_file = \(tomlQuote(sbFile))")
                }
                if let sg = entry.stackGroup {
                    lines.append("stack_group = \(tomlQuote(sg))")
                }
                if let sf = entry.stackFractions {
                    lines.append("stack_fractions = \(tomlQuote(Self.fractionListString(sf)))")
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
                if let sg = entry.stackGroup {
                    lines.append("stack_group = \(tomlQuote(sg))")
                }
                if let sf = entry.stackFractions {
                    lines.append("stack_fractions = \(tomlQuote(Self.fractionListString(sf)))")
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
                if let sg = entry.stackGroup {
                    lines.append("stack_group = \(tomlQuote(sg))")
                }
                if let sf = entry.stackFractions {
                    lines.append("stack_fractions = \(tomlQuote(Self.fractionListString(sf)))")
                }
                lines.append("")

            case .agentOverview(let view):
                // Persist the overview by reference: the index of its terminal
                // pane within this same pane list, plus its placement. Restore
                // recreates it after the terminal panes exist.
                lines.append("[[panes]]")
                lines.append("pane_type = \"agent_overview\"")
                if let surface = view.surface,
                   let anchorIdx = flatPanes.firstIndex(where: { entry in
                       if case .terminal(let s) = entry.pane { return s === surface }
                       return false
                   }) {
                    lines.append("overview_of = \(anchorIdx)")
                }
                lines.append("overview_placement = \(tomlQuote(view.placement.rawValue))")
                lines.append("overview_mode = \(tomlQuote(view.sections.tomlValue))")
                if view.fontScale != AgentOverviewPane.defaultFontScale {
                    lines.append("overview_font_scale = \(String(format: "%.2f", Double(view.fontScale)))")
                }
                // Overviews stack like any other pane now, so their stack
                // membership has to round-trip too. Every other pane type
                // wrote this; the overview branch didn't, which was harmless
                // while overviews couldn't be stacked and silently detached
                // them from their group on reload once they could.
                if let sg = entry.stackGroup {
                    lines.append("stack_group = \(tomlQuote(sg))")
                }
                if let sf = entry.stackFractions, !sf.isEmpty {
                    lines.append("stack_fractions = \(tomlQuote(Self.fractionListString(sf)))")
                }
                lines.append("")
            case .stack:
                // Already flattened above — should not appear here.
                break
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

    private static func fractionListString(_ fracs: [CGFloat]) -> String {
        fracs.map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
    }

    // MARK: - Live Layout Sync

    /// Wire up layout sync for this window's role: primaries broadcast their
    /// layout to subscribed mirrors, mirrors connect and follow.
    private func setupLayoutSync() {
        switch sessionRole {
        case .primary:
            setupLayoutBroadcast()
        case .mirror:
            startLayoutSyncClient()
        }
    }

    /// Broadcast a debounced layout snapshot whenever any layout var changes.
    private func setupLayoutBroadcast() {
        let publishers: [AnyPublisher<Void, Never>] = [
            $surfaceTree.map { _ in () }.eraseToAnyPublisher(),
            $gridRowCols.map { _ in () }.eraseToAnyPublisher(),
            $gridRowHeightFractions.map { _ in () }.eraseToAnyPublisher(),
            $gridColWidthFractions.map { _ in () }.eraseToAnyPublisher(),
            $paneDisplayOrder.map { _ in () }.eraseToAnyPublisher(),
            $paneStacks.map { _ in () }.eraseToAnyPublisher(),
            $stackSubPaneHeightFractions.map { _ in () }.eraseToAnyPublisher(),
            $webviewPanes.map { _ in () }.eraseToAnyPublisher(),
            $pluginPanes.map { _ in () }.eraseToAnyPublisher(),
            $agentOverviewPanes.map { _ in () }.eraseToAnyPublisher(),
        ]
        layoutBroadcastCancellable = Publishers.MergeMany(publishers)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.broadcastLayoutSnapshot()
            }

        // A newly attached mirror needs an initial snapshot: re-broadcast
        // whenever the layout subscriber count rises.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onLayoutSubscribersChanged(_:)),
            name: .trmLayoutSubscribersChanged,
            object: nil)
    }

    @objc private func onLayoutSubscribersChanged(_ notification: Notification) {
        guard sessionRole == .primary else { return }
        broadcastLayoutSnapshot()
    }

    /// Serialize the current layout and broadcast it to subscribed mirrors.
    private func broadcastLayoutSnapshot() {
        guard sessionRole == .primary, !isApplyingRemoteLayout else { return }
        guard Trm.shared.textTapRunning, Trm.shared.layoutSubscriberCount() > 0 else { return }

        layoutRevision += 1
        let payload: [String: Any] = [
            "type": "layout_update",
            "window": windowUUID,
            "epoch": layoutEpoch,
            "revision": layoutRevision,
            "toml": buildCurrentConfigToml(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        Trm.shared.broadcastLayout(windowId: windowUUID, line: line)
    }

    /// Connect to the primary UI's Text Tap socket and follow its layout.
    private func startLayoutSyncClient() {
        guard layoutSyncClient == nil,
              let socketPath = gridConfigOverride?.textTapSocket,
              !socketPath.isEmpty
        else { return }
        let client = LayoutSyncClient(socketPath: socketPath, windowId: windowUUID)
        client.onLayoutUpdate = { [weak self] toml, revision in
            self?.applyRemoteLayout(toml: toml, revision: revision)
        }
        client.start()
        layoutSyncClient = client
    }

    /// Apply a layout snapshot broadcast by the primary UI, in place: existing
    /// panes are matched (terminals by zmx session, webviews by URL, plugins
    /// by kind+title, overviews by their terminal) and only genuinely added or
    /// removed panes are created or dropped. Surviving PTY views are reused
    /// as-is — the mirror never tears down live terminals.
    func applyRemoteLayout(toml: String, revision: Int) {
        guard sessionRole == .mirror, !isApplyingRemoteLayout else { return }

        // Parse with the exact machinery the restore path uses; it wants a
        // file path, so stage the snapshot in a temp file. The name includes
        // pid + a nonce: two mirror processes of the same window receive the
        // same (windowUUID, revision) within milliseconds and share $TMPDIR.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "trm-layout-\(windowUUID)-\(revision)-" +
                "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        guard (try? toml.write(to: tmpURL, atomically: true, encoding: .utf8)) != nil,
              let config = Trm.gridConfig(fromConfigPath: tmpURL.path)
        else { return }

        isApplyingRemoteLayout = true
        defer { isApplyingRemoteLayout = false }
        applyLayoutConfig(config)
    }

    /// The in-place reconciler behind `applyRemoteLayout`.
    private func applyLayoutConfig(_ config: Trm.TrmGridConfig) {
        guard let ghosttyApp = ghostty.app else { return }
        let paneConfigs = config.panes
        guard !paneConfigs.isEmpty else { return }

        // Pools of existing panes still available for matching.
        var freeSurfaces = gridSurfaces
        var freeWebviews = webviewPanes
        var freePlugins = pluginPanes
        var freeOverviews = agentOverviewPanes

        enum ResolvedPane {
            case terminal(Ghostty.SurfaceView)
            case webview(WebViewPane)
            case plugin(PluginPane)
            case overview(AgentOverviewPane)
        }
        var resolvedByConfigIndex: [Int: ResolvedPane] = [:]

        // First pass: terminals, webviews, plugins.
        for (i, paneConfig) in paneConfigs.enumerated() {
            let type = normalizedPaneType(paneConfig.paneType)
            switch type {
            case "terminal":
                if let session = paneConfig.zmxSession,
                   let idx = freeSurfaces.firstIndex(where: { $0.zmxSessionName == session }) {
                    let view = freeSurfaces.remove(at: idx)
                    // Watermarks are part of the synced layout: follow the
                    // primary's value (clearing when it cleared).
                    if let paneId = view.paneId {
                        Trm.shared.setWatermark(
                            forPaneId: UInt32(paneId), text: paneConfig.watermark ?? "")
                    }
                    resolvedByConfigIndex[i] = .terminal(view)
                } else if let view = makeMirrorTerminalSurface(paneConfig, ghosttyApp: ghosttyApp) {
                    resolvedByConfigIndex[i] = .terminal(view)
                }
                // A pane whose zmx session isn't reachable yet is skipped;
                // shape reconciliation below absorbs the gap and the next
                // snapshot picks it up.
            case "webview":
                let targetURL = urlForWebview(from: paneConfig)
                if let idx = freeWebviews.firstIndex(where: {
                    ($0.currentURL ?? $0.initialURL).absoluteString == targetURL.absoluteString
                }) {
                    resolvedByConfigIndex[i] = .webview(freeWebviews.remove(at: idx))
                } else if !freeWebviews.isEmpty {
                    // URL drifted (independent navigation) — reuse in order
                    // rather than reloading a fresh webview.
                    resolvedByConfigIndex[i] = .webview(freeWebviews.removeFirst())
                } else {
                    resolvedByConfigIndex[i] = .webview(WebViewPane(url: targetURL))
                }
            case "agent_overview":
                break // Second pass — the anchor terminal must resolve first.
            default:
                guard let kind = PluginPaneKind.fromPaneType(type) else { break }
                if let idx = freePlugins.firstIndex(where: {
                    $0.kind == kind && $0.configuredTitle == paneConfig.title
                }) ?? freePlugins.firstIndex(where: { $0.kind == kind }) {
                    resolvedByConfigIndex[i] = .plugin(freePlugins.remove(at: idx))
                } else {
                    resolvedByConfigIndex[i] = .plugin(PluginPane(kind: kind, config: paneConfig))
                }
            }
        }

        // Second pass: agent overviews, matched by their anchor terminal.
        for (i, paneConfig) in paneConfigs.enumerated()
        where normalizedPaneType(paneConfig.paneType) == "agent_overview" {
            guard let ofIdx = paneConfig.overviewOf,
                  let resolved = resolvedByConfigIndex[ofIdx],
                  case .terminal(let anchor) = resolved else { continue }
            let placement = paneConfig.overviewPlacement
                .flatMap(AgentOverviewPlacement.init(rawValue:)) ?? .trailing
            let view: AgentOverviewPane
            if let idx = freeOverviews.firstIndex(where: { $0.surface === anchor }) {
                view = freeOverviews.remove(at: idx)
            } else {
                view = AgentOverviewPane(surface: anchor)
            }
            view.placement = placement
            resolvedByConfigIndex[i] = .overview(view)
        }

        // Assemble the final ordered pane lists and flat ID order.
        var newSurfaces: [Ghostty.SurfaceView] = []
        var newWebviews: [WebViewPane] = []
        var newPlugins: [PluginPane] = []
        var newOverviews: [AgentOverviewPane] = []
        var flatIDs: [ObjectIdentifier] = []
        var stackTags: [String?] = []
        var stackFractionsByTag: [String: [CGFloat]] = [:]

        for (i, paneConfig) in paneConfigs.enumerated() {
            guard let resolved = resolvedByConfigIndex[i] else { continue }
            let id: ObjectIdentifier
            switch resolved {
            case .terminal(let v):
                newSurfaces.append(v)
                id = ObjectIdentifier(v)
            case .webview(let p):
                newWebviews.append(p)
                id = ObjectIdentifier(p)
            case .plugin(let p):
                newPlugins.append(p)
                id = ObjectIdentifier(p)
            case .overview(let p):
                newOverviews.append(p)
                id = ObjectIdentifier(p)
            }
            flatIDs.append(id)
            stackTags.append(paneConfig.stackGroup)
            if let tag = paneConfig.stackGroup,
               let sf = paneConfig.stackFractions,
               stackFractionsByTag[tag] == nil {
                stackFractionsByTag[tag] = sf.map { CGFloat($0) }
            }
        }
        guard !flatIDs.isEmpty else { return }

        // Stack state, keyed by each group's first member (the host).
        let groups = LayoutSyncModel.stackGroups(forTags: stackTags)
        let newStacks = LayoutSyncModel.paneStacks(flatIDs: flatIDs, stackGroups: groups)
        var newStackFractions: [ObjectIdentifier: [CGFloat]] = [:]
        for group in groups {
            guard let first = group.first, first < flatIDs.count,
                  let tag = stackTags[first],
                  let fracs = stackFractionsByTag[tag],
                  fracs.count == group.count else { continue }
            newStackFractions[flatIDs[first]] = fracs
        }

        // Rebuild the split tree REUSING surviving surface views — their PTYs
        // are untouched. Dropped surfaces deallocate, which only detaches
        // their zmx client; the session daemons live on.
        var newTree = SplitTree<Ghostty.SurfaceView>()
        if let first = newSurfaces.first {
            newTree = .init(view: first)
            var previous = first
            for view in newSurfaces.dropFirst() {
                do {
                    newTree = try newTree.inserting(view: view, at: previous, direction: .right)
                    previous = view
                } catch {
                    Ghostty.logger.warning("layout sync: failed to insert pane into tree: \(error)")
                }
            }
        }

        // Keep focus where it is when the focused surface survives.
        let focusTarget: Ghostty.SurfaceView?
        if let focused = focusedSurface, newSurfaces.contains(where: { $0 === focused }) {
            focusTarget = nil
        } else {
            focusTarget = newSurfaces.first
        }

        // Assign the pane arrays BEFORE the tree: TerminalController's
        // replaceSurfaceTree override closes the tab when the new tree is
        // empty AND webviewPanes/pluginPanes are empty — it must judge the
        // incoming layout's panes, not the stale ones.
        webviewPanes = newWebviews
        pluginPanes = newPlugins
        agentOverviewPanes = newOverviews
        replaceSurfaceTree(
            newTree,
            moveFocusTo: focusTarget,
            moveFocusFrom: focusedSurface,
            undoAction: nil
        )
        paneStacks = newStacks
        paneDisplayOrder = flatIDs

        // Visual shape from the config (stacks collapsed); reconcile when
        // panes were skipped so the shape always matches the cell count.
        let visualCount = LayoutSyncModel.visualCellCount(
            flatCount: flatIDs.count, stackGroups: groups)
        var rowCols = LayoutSyncModel.targetRowCols(
            visualCount: visualCount,
            configRowCols: config.rowCols,
            rows: config.rows,
            cols: config.cols
        )
        if rowCols.reduce(0, +) != visualCount {
            var layout = GridLayout<ObjectIdentifier>(rowCols: rowCols, displayOrder: flatIDs)
            layout.reconcile(actualCount: visualCount)
            rowCols = layout.rowCols
        }
        gridRowCols = rowCols

        // Fractions last: the gridRowCols assignment above may have
        // re-equalized them via the structural-change sink. Empty/mismatched
        // config fractions mean "equal splits" — [] is the grid's reset value.
        if config.rowFractions.count == rowCols.count {
            gridRowHeightFractions = config.rowFractions.map { CGFloat($0) }
        } else {
            gridRowHeightFractions = []
        }
        if config.colFractions.count == rowCols.count,
           zip(rowCols, config.colFractions).allSatisfy({ $0 == $1.count }) {
            gridColWidthFractions = config.colFractions.map { row in row.map { CGFloat($0) } }
        } else {
            gridColWidthFractions = []
        }
        stackSubPaneHeightFractions = newStackFractions

        // Drop stale peek state for panes that no longer exist.
        if let peeked = peekedPane, !flatIDs.contains(peeked) {
            peekedPane = nil
        }
    }

    /// Create a terminal surface for a mirror window by attaching to a pane's
    /// live zmx session. Returns nil when the session daemon isn't reachable
    /// (never spawns a fresh daemon — that would diverge from the primary).
    private func makeMirrorTerminalSurface(
        _ paneConfig: Trm.TrmPaneConfig,
        ghosttyApp: ghostty_app_t
    ) -> Ghostty.SurfaceView? {
        guard ghostty.sessionPersistence,
              let session = paneConfig.zmxSession,
              ZmxSessionManager.sessionExists(session) else { return nil }

        var surfaceConfig = Ghostty.SurfaceConfiguration()
        if let cwd = paneConfig.cwd, !cwd.isEmpty {
            surfaceConfig.workingDirectory = NSString(string: cwd).expandingTildeInPath
        } else {
            surfaceConfig.workingDirectory = NSHomeDirectory()
        }
        if let command = paneConfig.command, !command.isEmpty {
            surfaceConfig.command = command
        }
        let paneId = Trm.shared.allocPaneId()
        Self.injectCmuxEnvVars(into: &surfaceConfig, paneId: paneId)
        guard let persist = Self.wrapForPersistence(
            &surfaceConfig, ghostty: ghostty, session: session) else { return nil }

        let view = Ghostty.SurfaceView(ghosttyApp, baseConfig: surfaceConfig)
        view.paneId = paneId
        view.zmxSessionName = persist.session
        view.logicalCommand = persist.logical
        Self.setDefaultWatermark(forPaneId: paneId)
        if let watermark = paneConfig.watermark, !watermark.isEmpty {
            Trm.shared.setWatermark(forPaneId: UInt32(paneId), text: watermark)
        }
        return view
    }

    /// Handle the swap_panes socket action (visual grid indices). Indices are
    /// window-relative, so exactly one window may react: the key window when
    /// it can act (primary role), otherwise the first primary main window
    /// (which also covers headless automation with no key window). Resolving
    /// a single designated handler keeps a key quick terminal from acting
    /// alongside a main window, and a key mirror from swallowing the action.
    @objc private func handleTextTapSwapPanes(_ notification: Notification) {
        guard sessionRole == .primary,
              let a = notification.userInfo?["a"] as? Int,
              let b = notification.userInfo?["b"] as? Int else { return }
        let keyController = NSApp.keyWindow?.windowController as? BaseTerminalController
        let target: BaseTerminalController? = (keyController?.sessionRole == .primary)
            ? keyController
            : TerminalController.all.first(where: { $0.sessionRole == .primary })
        guard target === self else { return }
        ensurePaneDisplayOrder()
        let panes = gridPanes
        guard a != b, a >= 0, b >= 0, a < panes.count, b < panes.count else { return }
        swapPanesInDisplayOrder(panes, a, b)
        pruneOrphanedAgentOverviews()
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

        // Restore focus to the terminal surface after the sheet closes.
        // Without this, the window itself becomes first responder and
        // the pane stops receiving keyboard input.
        DispatchQueue.main.async { [weak self] in
            if let surface = self?.focusedSurface {
                self?.window?.makeFirstResponder(surface)
            }
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

        // Start context usage tracking. The reading is process-wide, so the
        // manager filters it to this window's panes — otherwise every window
        // shows a pill for an agent running in some other window.
        contextUsageManager.ownedPaneIds = { [weak self] in
            guard let self else { return [] }
            return Set(self.gridSurfaces.compactMap(\.paneId))
        }
        contextUsageManager.start()

        // Equalize pane size fractions whenever the grid structure changes.
        // We compare the new layout against the current fractions — if the
        // counts no longer match we reset to equal splits.
        gridRowColsCancellable = $gridRowCols
            .removeDuplicates()
            .sink { [weak self] newRowCols in
                guard let self else { return }
                let nRows = newRowCols.count
                let colFracsStale = self.gridColWidthFractions.count != nRows
                    || zip(newRowCols, self.gridColWidthFractions).contains { (cols, fracs) in fracs.count != cols }
                let fractionsStale = self.gridRowHeightFractions.count != nRows || colFracsStale
                if fractionsStale {
                    self.equalizeGridFractions()
                }
            }

        // Live layout sync: primary windows broadcast layout snapshots,
        // mirror windows connect to the primary's socket and follow.
        setupLayoutSync()

        // Setup initial panes from termania.toml config — but skip if we
        // were created with an existing surface tree (e.g., a popped-out pane or
        // macOS window restoration). In the external-tree case, assign pane IDs
        // to any surfaces that don't already have one so the focus RPC works.
        if hasExternalSurfaceTree {
            hasExternalSurfaceTree = false
            // Assign pane IDs to surfaces that don't have one (e.g. macOS-restored
            // surfaces created without going through allocPaneId). This lets the
            // focus RPC match surfaces by pane ID.
            for surface in gridSurfaces where surface.paneId == nil {
                surface.paneId = Trm.shared.allocPaneId()
            }
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
        // Restore applies a saved layout; on mirror windows it must bypass
        // the layout-edit guard (stackPane etc. are guarded).
        isRestoringLayout = true
        defer { isRestoringLayout = false }

        // Clear all existing watermarks before rebuilding so stale entries
        // from the previous layout don't leak into the new one.
        for surface in gridSurfaces {
            let id = surface.paneId ?? 0
            Trm.shared.setWatermark(forPaneId: UInt32(id), text: "")
        }

        paneDisplayOrder = []
        paneStacks = [:]

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
        let hasStackGroups = paneConfigs.contains { $0.stackGroup != nil }

        if hasStackGroups, !config.rowCols.isEmpty {
            // The saved row_cols reflects the visual (stacked) layout. Expand
            // it to flat row_cols by walking pane configs: consecutive panes
            // sharing the same non-nil stack_group occupy one visual cell.
            let flatRowCols = expandRowColsForStacks(
                visualRowCols: config.rowCols,
                paneConfigs: paneConfigs
            )
            gridRowCols = flatRowCols
        } else if !config.rowCols.isEmpty, config.rowCols.reduce(0, +) == totalPanes {
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

        // Build (paneId, config) pairs for terminal panes. Try the Zig
        // grid_slot_pane_id mapping first so IDs match the backend's pane_map.
        // When the backend doesn't have a slot (e.g. loading a TOML file with
        // more panes than the default config), fall back to allocPaneId() so
        // each pane gets a globally unique ID that won't collide with future
        // pane allocations.
        var terminalConfigsWithPaneId: [(paneId: Int, config: Trm.TrmPaneConfig)] = []
        for (i, paneConfig) in paneConfigs.enumerated() {
            if normalizedPaneType(paneConfig.paneType) == "terminal" {
                let zigId = Trm.shared.rawGridSlotPaneId(gridIndex: i)
                let paneId = zigId != nil ? Int(zigId!) : Trm.shared.allocPaneId()
                terminalConfigsWithPaneId.append((paneId: paneId, config: paneConfig))
            }
        }
        rebuildTerminalSurfaces(terminalConfigsWithPaneId)
        // Agent overviews are created further down (they need their terminals
        // to exist first), but the seeded `gridRowCols` already counts their
        // cells. Reconciling here against a pane count that excludes them
        // trimmed those cells — a saved [5,1] became [5], collapsing the
        // second row before the overview was ever placed. Hold the pending
        // overviews' cells so reconcile only fixes genuine drift.
        let pendingOverviews = paneConfigs.filter {
            normalizedPaneType($0.paneType) == "agent_overview"
        }.count
        reconcileGridRowCols(extraPendingPanes: pendingOverviews)

        // Restore pane stacking relationships from stack_group tags.
        if hasStackGroups {
            restoreStackGroups(from: paneConfigs)
        }

        // Assign default letter watermarks (A, B, C, …) to every pane.
        for surface in gridSurfaces {
            if let pid = surface.paneId {
                Self.setDefaultWatermark(forPaneId: pid)
            }
        }

        // Apply per-pane config (watermarks, initial commands) for terminal panes.
        // Explicit watermarks from the config will override the defaults above.
        applyPaneConfig(paneConfigs)

        // Recreate agent overview panes once their terminal panes exist.
        restoreAgentOverviews(from: paneConfigs)

        // Stacking ran before the overviews existed, so an overview that was
        // part of a stack could not join it and came back detached. Add just
        // those overviews to their groups now.
        //
        // Deliberately not a second full `restoreStackGroups` pass: by this
        // point the overviews are in `paneDisplayOrder`, and re-running the
        // whole grouping re-stacked panes that were already grouped, sweeping
        // unrelated panes into the wrong stacks.
        if hasStackGroups, !agentOverviewPanes.isEmpty {
            restoreOverviewStackMembership(from: paneConfigs)
        }
    }

    /// Add restored agent overviews to the stacks they were saved in.
    ///
    /// Only overviews are touched: terminal, webview, and plugin stacking was
    /// already applied before the overviews existed, and re-applying it would
    /// disturb groups that are already correct.
    private func restoreOverviewStackMembership(from paneConfigs: [Trm.TrmPaneConfig]) {
        // Map each saved stack group to a pane already in it, which is the
        // target an overview should stack onto.
        var anchorForGroup: [String: GridPane] = [:]
        let surfaces = gridSurfaces
        var termIdx = 0
        for cfg in paneConfigs where normalizedPaneType(cfg.paneType) == "terminal" {
            defer { termIdx += 1 }
            guard let group = cfg.stackGroup, termIdx < surfaces.count else { continue }
            if anchorForGroup[group] == nil {
                anchorForGroup[group] = .terminal(surfaces[termIdx])
            }
        }

        // Position within each group, as written in the config: an overview
        // saved above its terminal has to come back above it. `stackPane`
        // always appends at the bottom, so restoring by that alone silently
        // reordered every group.
        var savedIndexInGroup: [ObjectIdentifier: Int] = [:]
        var seenInGroup: [String: Int] = [:]
        var ovIdx = 0
        let overviews = agentOverviewPanes
        for cfg in paneConfigs {
            let type = normalizedPaneType(cfg.paneType)
            guard let group = cfg.stackGroup else {
                if type == "agent_overview" { ovIdx += 1 }
                continue
            }
            let position = seenInGroup[group, default: 0]
            seenInGroup[group] = position + 1
            if type == "agent_overview" {
                if ovIdx < overviews.count {
                    savedIndexInGroup[ObjectIdentifier(overviews[ovIdx])] = position
                }
                ovIdx += 1
            }
        }

        ovIdx = 0
        for cfg in paneConfigs where normalizedPaneType(cfg.paneType) == "agent_overview" {
            defer { ovIdx += 1 }
            guard ovIdx < overviews.count,
                  let group = cfg.stackGroup,
                  let anchor = anchorForGroup[group] else { continue }
            let view = overviews[ovIdx]
            let overviewPane = GridPane.agentOverview(view)
            // Already in a stack (nothing to do) or the anchor is missing.
            guard findStackEntry(for: overviewPane.id) == nil else { continue }
            stackPane(overviewPane, onto: anchor)

            // Slot it back into its saved position within the group.
            if let wanted = savedIndexInGroup[ObjectIdentifier(view)] {
                moveOverviewToIndex(view, index: wanted)
            }
        }
    }

    /// Move an already-stacked overview to a specific index in its stack.
    private func moveOverviewToIndex(_ view: AgentOverviewPane, index: Int) {
        let paneID = ObjectIdentifier(view)
        guard let (hostID, current) = findStackEntry(for: paneID),
              var children = paneStacks[hostID],
              index >= 0, index < children.count,
              index != current else { return }

        children.remove(at: current)
        children.insert(paneID, at: index)

        let newHostID = children[0]
        if newHostID != hostID {
            // Position 0 owns the grid cell and keys the stack.
            paneStacks.removeValue(forKey: hostID)
            paneStacks[newHostID] = children
            if let slot = paneDisplayOrder.firstIndex(of: hostID) {
                paneDisplayOrder[slot] = newHostID
            }
            if let fractions = stackSubPaneHeightFractions.removeValue(forKey: hostID) {
                stackSubPaneHeightFractions[newHostID] = fractions
            }
        } else {
            paneStacks[hostID] = children
        }
    }

    /// Recreate agent overviews saved in the session config. Each entry names
    /// its terminal pane by config index (`overview_of`) plus a placement.
    private func restoreAgentOverviews(from paneConfigs: [Trm.TrmPaneConfig]) {
        let surfaces = gridSurfaces

        // Map config index -> index among terminal panes, since surfaces were
        // created in config order but only for terminal entries.
        var terminalIndexByConfigIndex: [Int: Int] = [:]
        var terminalCount = 0
        for (i, cfg) in paneConfigs.enumerated()
        where normalizedPaneType(cfg.paneType) == "terminal" {
            terminalIndexByConfigIndex[i] = terminalCount
            terminalCount += 1
        }

        for cfg in paneConfigs
        where normalizedPaneType(cfg.paneType) == "agent_overview" {
            guard let ofIdx = cfg.overviewOf,
                  let termIdx = terminalIndexByConfigIndex[ofIdx],
                  termIdx < surfaces.count else { continue }
            let target = GridPane.terminal(surfaces[termIdx])
            guard !hasAgentOverview(for: target) else { continue }

            // Restore is replaying a layout the checkpoint already describes,
            // so the overview must be created *without* re-deriving where it
            // goes. Each placement pass runs `placeCompanion`, whose
            // `removeCell` deletes a row outright when the overview is the
            // only pane in it — placing then re-placing turned a saved
            // [7, 1] into [8] and the last row vanished. (Seen directly in the
            // [overview-place] log.)
            showAgentOverview(for: target, applyPlacement: false)

            guard let view = agentOverviewPanes.first(where: { $0.surface === surfaces[termIdx] })
            else { continue }
            if let rawMode = cfg.overviewMode {
                view.sections = AgentOverviewSections(tomlValue: rawMode)
            }
            if let scale = cfg.overviewFontScale {
                view.fontScale = CGFloat(scale)
            }
            // Record the saved placement without applying it: the grid shape
            // comes from row_cols, and this only needs to be right for later
            // interactive moves.
            if let raw = cfg.overviewPlacement,
               let placement = AgentOverviewPlacement(rawValue: raw) {
                view.placement = placement
            }
        }
    }

    /// Expand visual (stacked) row_cols to flat row_cols by counting how many
    /// flat panes each visual cell maps to. Consecutive panes sharing the same
    /// non-nil stack_group occupy one visual cell.
    private func expandRowColsForStacks(
        visualRowCols: [Int],
        paneConfigs: [Trm.TrmPaneConfig]
    ) -> [Int] {
        var flatRowCols: [Int] = []
        var paneIdx = 0

        for visualCols in visualRowCols {
            var flatCols = 0
            for _ in 0..<visualCols {
                guard paneIdx < paneConfigs.count else { break }
                // Count this pane as one visual cell.
                flatCols += 1
                let group = paneConfigs[paneIdx].stackGroup
                paneIdx += 1
                // If it has a stack group, consume consecutive panes with
                // the same group — they share this visual cell.
                if let group {
                    while paneIdx < paneConfigs.count,
                          paneConfigs[paneIdx].stackGroup == group {
                        flatCols += 1
                        paneIdx += 1
                    }
                }
            }
            flatRowCols.append(max(flatCols, 1))
        }

        // If there are leftover panes (shouldn't happen with well-formed
        // TOML), append them as an extra row.
        if paneIdx < paneConfigs.count {
            flatRowCols.append(paneConfigs.count - paneIdx)
        }

        return flatRowCols
    }

    /// Restore pane stacking relationships by grouping panes with matching
    /// stack_group values and calling stackPane() for each group.
    private func restoreStackGroups(from paneConfigs: [Trm.TrmPaneConfig]) {
        // Build the list of GridPanes in TOML (config) order. Pane configs
        // are interleaved by type, but gridPanes groups by type when
        // paneDisplayOrder is empty. Walk configs and pick from the
        // per-type arrays by count.
        let surfaces = gridSurfaces
        let webviews = webviewPanes
        let plugins = pluginPanes
        let overviews = agentOverviewPanes
        var termIdx = 0, webIdx = 0, plugIdx = 0, ovIdx = 0
        // Optional per slot: an agent_overview has no pane yet at this point
        // (they're created later), but its slot must still be counted or every
        // later pane's index shifts — which is what swept unrelated panes into
        // the wrong stacks.
        var panesInConfigOrder: [GridPane?] = []

        for config in paneConfigs {
            let paneType = normalizedPaneType(config.paneType)
            switch paneType {
            case "terminal":
                if termIdx < surfaces.count {
                    panesInConfigOrder.append(.terminal(surfaces[termIdx]))
                    termIdx += 1
                }
            case "webview":
                if webIdx < webviews.count {
                    panesInConfigOrder.append(.webview(webviews[webIdx]))
                    webIdx += 1
                }
            case "agent_overview":
                // This pass runs before overviews are created, so there is
                // nothing to map — but the slot must still be consumed, or
                // every later pane's index shifts. (Falling through to
                // `default` counted an overview as a plugin, which is what
                // pulled unrelated panes into the wrong stacks.) Overviews
                // join their groups afterwards, in
                // `restoreOverviewStackMembership`.
                panesInConfigOrder.append(nil)
                ovIdx += 1
            default:
                if plugIdx < plugins.count {
                    panesInConfigOrder.append(.plugin(plugins[plugIdx]))
                    plugIdx += 1
                }
            }
        }

        // Build ordered groups: group name → [GridPane].
        var groupOrder: [String] = []
        var groups: [String: [GridPane]] = [:]
        for (i, config) in paneConfigs.enumerated() {
            guard let group = config.stackGroup, i < panesInConfigOrder.count else { continue }
            if groups[group] == nil {
                groupOrder.append(group)
            }
            // Skip slots with no pane yet (overviews); they join afterwards.
            guard let pane = panesInConfigOrder[i] else { continue }
            groups[group, default: []].append(pane)
        }

        for groupName in groupOrder {
            guard let members = groups[groupName], members.count >= 2 else { continue }
            let target = members[0]
            for source in members.dropFirst() {
                stackPane(source, onto: target)
            }
        }
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

            // Store initial commands on the surface for round-tripping
            // through session save/restore.
            if !paneConfig.initialCommands.isEmpty {
                surface.initialCommands = paneConfig.initialCommands
            }

            // A pane that reattached to a live zmx session already has its
            // shell running with history replayed — replaying scrollback or
            // initial commands would type into the live session.
            if reattachedPaneIds.contains(id) {
                reattachedPaneIds.remove(id)
                surfaceIndex += 1
                continue
            }

            // Build the command list: first replay scrollback (if present),
            // then run the original initial commands.
            var commands: [String] = []

            // Replay saved scrollback as terminal output via cat.
            // The file is also available as $TRM_RESTORE_SCROLLBACK_FILE
            // for custom shell integrations.
            if let sbFile = paneConfig.scrollbackFile {
                let sbPath = SessionManager.scrollbackDirectory
                    .appendingPathComponent(sbFile).path
                if FileManager.default.fileExists(atPath: sbPath) {
                    // Use cat to display the previous scrollback, then clear
                    // the env var and remove the temp file.
                    commands.append("cat \"\(sbPath)\" 2>/dev/null; rm -f \"\(sbPath)\"")
                }
            }

            commands.append(contentsOf: paneConfig.initialCommands)

            // Send commands after a delay to let the shell start.
            // Stagger each pane by 50ms to avoid overwhelming the system
            // when many panes are created simultaneously.
            if !commands.isEmpty {
                let delay = 0.5 + Double(surfaceIndex) * 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendInitialCommandsWhenReady(commands, to: surface)
                }
            }

            surfaceIndex += 1
        }
    }

    /// Adjust a live `row_cols` shape to hold exactly `total` visual panes,
    /// preserving the layout's existing orientation.
    ///
    /// The checkpoint's shape must survive round-trip: a row of 3 has to come
    /// back as a row of 3, never as a column. So when `gridRowCols` is stale
    /// we grow/shrink the shape we actually have — appending to (or trimming
    /// from) the last row — rather than recomputing it from unrelated
    /// dimensions, which is what pivoted layouts before.
    static func reconcileRowCols(_ shape: [Int], toTotal total: Int) -> [Int] {
        guard total > 0 else { return [1] }
        var rowCols = shape.filter { $0 > 0 }
        guard !rowCols.isEmpty else { return [total] }

        var current = rowCols.reduce(0, +)

        // Too few cells: widen the last row (a single row stays a single row).
        if current < total {
            rowCols[rowCols.count - 1] += total - current
            return rowCols
        }

        // Too many cells: trim from the end, dropping rows that empty out.
        while current > total, !rowCols.isEmpty {
            let last = rowCols[rowCols.count - 1]
            let excess = current - total
            if last > excess {
                rowCols[rowCols.count - 1] = last - excess
                current = total
            } else {
                rowCols.removeLast()
                current -= last
            }
        }
        return rowCols.isEmpty ? [total] : rowCols
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
        case "notes", "file_browser", "process_monitor",
             "log_viewer", "markdown_preview", "system_info", "git_status":
            return rawType.lowercased()
        case "agent_overview":
            // Not a plugin: recreated by restoreAgentOverviews after the
            // terminal panes exist. Must not fall through to "terminal" or a
            // spurious empty terminal appears in its place.
            return "agent_overview"
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
            Self.injectCmuxEnvVars(into: &surfaceConfig, paneId: entry.paneId)

            // Session persistence: reattach to the pane's saved zmx session
            // when it is still alive (zmx replays the terminal state itself),
            // otherwise start a fresh session.
            var didReattach = false
            var persist: (session: String, logical: String?)? = nil
            // A remote pane's daemon lives on another machine: rebuild the SSH
            // attach command and skip local wrapping entirely. `zmx attach`
            // recreates the session if the remote daemon has since died, so
            // this reconnects whether or not the work is still running.
            let remoteHost = entry.config.remoteHost
            if let remoteHost, !remoteHost.isEmpty,
               Self.isValidRemoteHost(remoteHost) {
                let session = entry.config.remoteSession ?? ZmxSessionManager.newSessionName()
                surfaceConfig.command = Self.remoteAttachCommand(
                    host: remoteHost,
                    session: session,
                    zmxPath: Self.defaultRemoteZmxPath
                )
            } else if ghostty.sessionPersistence {
                if let saved = entry.config.zmxSession,
                   ZmxSessionManager.sessionExists(saved) {
                    persist = Self.wrapForPersistence(
                        &surfaceConfig, ghostty: ghostty, session: saved)
                    didReattach = persist != nil
                } else {
                    persist = Self.wrapForPersistence(&surfaceConfig, ghostty: ghostty)
                }
            }

            // If a scrollback file exists, pass it as an environment variable.
            // The shell can replay it, or applyPaneConfig will cat it before
            // running initial commands. Skip when reattaching — zmx already
            // replays the live session's screen and history.
            if !didReattach, let sbFile = entry.config.scrollbackFile {
                let sbPath = SessionManager.scrollbackDirectory
                    .appendingPathComponent(sbFile).path
                if FileManager.default.fileExists(atPath: sbPath) {
                    surfaceConfig.environmentVariables["TRM_RESTORE_SCROLLBACK_FILE"] = sbPath
                }
            }
            let view = Ghostty.SurfaceView(ghosttyApp, baseConfig: surfaceConfig)
            view.paneId = entry.paneId
            if let persist {
                view.zmxSessionName = persist.session
                view.logicalCommand = persist.logical
            }
            // Carry the remote binding forward so the next checkpoint still
            // records this as a remote pane.
            if let remoteHost, !remoteHost.isEmpty {
                view.remoteHost = remoteHost
                view.remoteZmxSession = entry.config.remoteSession
                // zmx replays the remote session's screen; don't also cat
                // scrollback or replay initial commands into a live shell.
                reattachedPaneIds.insert(entry.paneId)
            }
            if didReattach { reattachedPaneIds.insert(entry.paneId) }
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

        // If our surfaces don't require confirmation, close. A zmx-backed
        // surface never requires confirmation here: closing the window only
        // detaches the client; the session daemon and its process live on.
        if !surfaceTree.contains(where: { $0.needsConfirmQuit && $0.zmxSessionName == nil }) {
            return true
        }

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

        layoutSyncClient?.stop()
        layoutSyncClient = nil
        layoutBroadcastCancellable = nil

        stopConfigFileWatcher()
        scrollbackSnapshotTimer?.invalidate()
        scrollbackSnapshotTimer = nil
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

    /// Open a browser pane alongside the terminal (Cmd+Shift+L).
    @IBAction func openSplitBrowserAction(_ sender: Any) {
        openSplitBrowser()
    }

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
