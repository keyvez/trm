import Cocoa
import SwiftUI
import Combine
import GhosttyKit

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

    /// The surfaces in grid order, derived from the surfaceTree leaves.
    var gridSurfaces: [Ghostty.SurfaceView] {
        Array(surfaceTree)
    }

    /// Inline webview panes opened via URL interception.
    @Published var webviewPanes: [WebViewPane] = []

    /// All panes (terminals + webviews) for the grid, in display order.
    var gridPanes: [GridPane] {
        gridSurfaces.map { .terminal($0) } + webviewPanes.map { .webview($0) }
    }

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false

    /// This can be set to show/hide the help panel.
    @Published var helpPanelIsShowing: Bool = false

    /// Set if the terminal view should show the update overlay.
    @Published var updateOverlayIsVisible: Bool = false

    /// The live summary manager for per-pane LLM summaries.
    let liveSummaryManager = LiveSummaryManager()

    /// The context usage manager for Claude Code context window tracking.
    let contextUsageManager = ContextUsageManager()

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
         surfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil
    ) {
        self.ghostty = ghostty
        self.derivedConfig = DerivedConfig(ghostty.config)

        super.init(window: nil)

        // Initialize our initial surface.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        // Default the first surface CWD to the home directory (or pane 0 config)
        // to avoid macOS Documents folder permission prompts.
        let initialConfig: Ghostty.SurfaceConfiguration? = {
            if let b = base { return b }
            var cfg = Ghostty.SurfaceConfiguration()
            let gridCfg = Trm.shared.gridConfig()
            if let firstPane = gridCfg.panes.first {
                if let cwd = firstPane.cwd, !cwd.isEmpty {
                    cfg.workingDirectory = NSString(string: cwd).expandingTildeInPath
                } else {
                    cfg.workingDirectory = NSHomeDirectory()
                }
                if let cmd = firstPane.command, !cmd.isEmpty {
                    cfg.command = cmd
                }
            } else {
                cfg.workingDirectory = NSHomeDirectory()
            }
            return cfg
        }()
        self.surfaceTree = tree ?? .init(view: Ghostty.SurfaceView(ghostty_app, baseConfig: initialConfig))

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

        // Listen for local events that we need to know of outside of
        // single surface handlers.
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in self?.localEventHandler(event) }

        // Wire up the live summary manager's pane content provider.
        liveSummaryManager.paneContentProvider = { [weak self] in
            guard let self else { return [] }
            return self.gridSurfaces.enumerated().map { index, surface in
                let title = surface.title.isEmpty ? "Shell" : surface.title
                let visibleText = surface.cachedScreenContents.get()
                return (index: index, title: title, visibleText: visibleText)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
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

        // We still add the surface to the split tree so all existing lifecycle
        // management (close, focus, undo, etc.) continues to work. We always
        // split right to keep leaves() order matching grid order.
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(
                view: newView,
                at: oldView,
                direction: .right)
        } catch {
            Ghostty.logger.warning("failed to insert grid pane: \(error)")
            return nil
        }

        // Find which row the old surface is in
        let surfaces = Array(surfaceTree)
        let oldFlatIndex = surfaces.firstIndex(where: { $0 === oldView }) ?? 0
        let (row, _) = gridPosition(flatIndex: oldFlatIndex)

        // Update grid shape based on direction
        switch direction {
        case .right, .left:
            // Add column to current row
            if row < gridRowCols.count {
                gridRowCols[row] += 1
            }
        case .down:
            // Add new row below
            let insertRow = min(row + 1, gridRowCols.count)
            gridRowCols.insert(1, at: insertRow)
        case .up:
            // Add new row above
            gridRowCols.insert(1, at: row)
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
                index: index,
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
            case .sendCommand(let pane, let command):
                guard pane < surfaces.count else { continue }
                sendTextToSurface(surfaces[pane], text: command + "\n")

            case .sendToAll(let command):
                for surface in surfaces {
                    sendTextToSurface(surface, text: command + "\n")
                }

            case .setTitle(let pane, let title):
                guard pane < surfaces.count else { continue }
                // Set watermark as a visual title indicator
                Trm.shared.setWatermark(forPane: UInt32(pane), text: title)

            case .setWatermark(let pane, let watermark):
                guard pane < surfaces.count else { continue }
                Trm.shared.setWatermark(forPane: UInt32(pane), text: watermark)

            case .clearWatermark(let pane):
                guard pane < surfaces.count else { continue }
                Trm.shared.setWatermark(forPane: UInt32(pane), text: "")

            case .spawnPane:
                guard let current = focusedSurface ?? surfaces.first else { continue }
                newGridPane(at: current, direction: .right)

            case .closePane(let pane):
                guard pane < surfaces.count else { continue }
                closeSurface(surfaces[pane], withConfirmation: false)

            case .focusPane(let pane):
                guard pane < surfaces.count else { continue }
                focusSurface(surfaces[pane])

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
        webviewPanes.append(pane)

        // Expand the last row to accommodate the new webview pane.
        if gridRowCols.isEmpty {
            gridRowCols = [1]
        }
        gridRowCols[gridRowCols.count - 1] += 1
    }

    /// Close and remove a webview pane from the grid.
    func closeWebviewPane(_ pane: WebViewPane) {
        guard let idx = webviewPanes.firstIndex(where: { $0.id == pane.id }) else { return }
        webviewPanes.remove(at: idx)

        // Shrink the last row (webview panes are always appended at the end).
        if let lastRow = gridRowCols.indices.last {
            if gridRowCols[lastRow] > 1 {
                gridRowCols[lastRow] -= 1
            } else if gridRowCols.count > 1 {
                gridRowCols.removeLast()
            }
        }
    }

    @objc private func ghosttySurfaceDragEndedNoTarget(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }
        
        // If our tree isn't split, then we never create a new window, because
        // it is already a single split.
        guard surfaceTree.isSplit else { return }
        
        // If we are removing our focused surface then we move it. We need to
        // keep track of our old one so undo sends focus back to the right place.
        let oldFocusedSurface = focusedSurface
        if focusedSurface == target {
            focusedSurface = findNextFocusTargetAfterClosing(node: targetNode)
        }

        // Remove the surface from our tree
        let removedTree = surfaceTree.removing(targetNode)

        // Create a new tree with the dragged surface and open a new window
        let newTree = SplitTree<Ghostty.SurfaceView>(view: target)
        
        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Pane")
        defer {
            undoManager?.endUndoGrouping()
        }
        
        replaceSurfaceTree(removedTree, moveFocusFrom: oldFocusedSurface)
        _ = TerminalController.newWindow(
            ghostty,
            tree: newTree,
            position: notification.userInfo?[Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey] as? NSPoint,
            confirmUndo: false)
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
        
        // Add in the surface to our tree
        replaceSurfaceTree(
            newTree,
            moveFocusTo: source,
            moveFocusFrom: focusedSurface)
    }

    func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        guard let surface = surfaceView.surface else { return }
        let len = action.utf8CString.count
        if (len == 0) { return }
        _ = action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(len - 1))
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
        window.beginSheet(self.clipboardConfirmation!.window!)
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

        // Setup initial panes from termania.toml config
        setupInitialPanes()
    }

    /// Read the termania.toml session config and create the initial multi-pane layout.
    private func setupInitialPanes() {
        let config = Trm.shared.gridConfig()

        // Only set up extra panes if the config defines more than a 1x1 grid
        let totalPanes = config.rows * config.cols
        guard totalPanes > 1 else {
            // Even for a single pane, apply watermark and initial commands if configured
            applyPaneConfig(config, startIndex: 0)
            return
        }

        // Update grid layout parameters
        gridRowCols = Array(repeating: config.cols, count: config.rows)

        // Create additional surfaces for the grid (we already have 1 from init)
        guard let ghostty_app = ghostty.app else { return }
        guard let firstSurface = gridSurfaces.first else { return }

        for i in 1..<totalPanes {
            var surfaceConfig = Ghostty.SurfaceConfiguration()
            // Use CWD from pane config, or default to home directory to avoid
            // macOS Documents folder permission prompts.
            if i < config.panes.count, let cwd = config.panes[i].cwd, !cwd.isEmpty {
                surfaceConfig.workingDirectory = NSString(string: cwd).expandingTildeInPath
            } else {
                surfaceConfig.workingDirectory = NSHomeDirectory()
            }
            if i < config.panes.count, let cmd = config.panes[i].command, !cmd.isEmpty {
                surfaceConfig.command = cmd
            }
            let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: surfaceConfig)
            do {
                surfaceTree = try surfaceTree.inserting(
                    view: newView,
                    at: firstSurface,
                    direction: .right)
            } catch {
                Ghostty.logger.warning("failed to create initial grid pane: \(error)")
            }
        }

        // Apply per-pane config (watermarks, initial commands)
        applyPaneConfig(config, startIndex: 0)
    }

    /// Apply watermarks and initial commands from the termania config to surfaces.
    private func applyPaneConfig(_ config: Trm.TrmGridConfig, startIndex: Int) {
        let surfaces = gridSurfaces
        for (i, paneConfig) in config.panes.enumerated() {
            let surfaceIndex = startIndex + i
            guard surfaceIndex < surfaces.count else { break }

            // Set watermark
            if let watermark = paneConfig.watermark, !watermark.isEmpty {
                Trm.shared.setWatermark(forPane: UInt32(surfaceIndex), text: watermark)
            }

            // Send initial commands after a short delay to let the shell start
            if !paneConfig.initialCommands.isEmpty {
                let surface = surfaces[surfaceIndex]
                let commands = paneConfig.initialCommands
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    for cmd in commands {
                        self?.sendTextToSurface(surface, text: cmd + "\n")
                    }
                }
            }
        }
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

        liveSummaryManager.stop()
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
