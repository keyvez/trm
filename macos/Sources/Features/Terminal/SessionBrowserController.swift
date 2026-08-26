import Cocoa
import SwiftUI
import os

/// Backing model for the session browser: loads live zmx sessions and performs
/// the open / terminate actions on them.
@MainActor
final class SessionBrowserModel: ObservableObject {
    /// A window's worth of sessions, resolved for display.
    struct Group: Identifiable {
        let name: String
        /// Session TOML path, or nil for the ungrouped bucket and for remote
        /// hosts (whose layouts are saved on the machine they run on).
        let path: String?
        let isOrphanGroup: Bool
        /// SSH destination this group's sessions live on, or nil for local.
        let remoteHost: String?
        /// Why a remote host listed nothing, when that is worth saying.
        let error: String?
        let sessions: [ZmxSessionManager.SessionInfo]

        var id: String { remoteHost.map { "remote:\($0)" } ?? path ?? "__orphans__" }

        /// Whether the group's whole layout can be restored in one go. Only a
        /// saved TOML describes an arrangement; a bag of sessions doesn't.
        var canOpenAsWindow: Bool { path != nil }
    }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var isLoading: Bool = false

    /// Flat view over every session, for the header summary.
    private var allSessions: [ZmxSessionManager.SessionInfo] {
        groups.flatMap(\.sessions)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "SessionBrowser"
    )

    /// Set by the controller so actions can open real windows.
    weak var ghostty: Ghostty.App?
    /// Window used to anchor confirmation sheets.
    weak var hostWindow: NSWindow?

    var summary: String {
        let sessions = allSessions
        guard !sessions.isEmpty else { return "" }
        let detached = sessions.filter { !$0.attached }.count
        let windows = groups.filter { !$0.isOrphanGroup }.count
        var parts = ["\(sessions.count) live"]
        if windows > 0 { parts.append("\(windows) window\(windows == 1 ? "" : "s")") }
        if detached > 0 { parts.append("\(detached) detached") }
        return parts.joined(separator: " · ")
    }

    /// Reload the session list.
    ///
    /// Introspection spawns several processes per session, so only the cheap,
    /// main-actor-bound lookups (socket listing, TOML references, cached shell
    /// pids) happen here; the expensive per-session scan is handed to a
    /// detached task that fans out across cores.
    func reload() {
        guard !isLoading else { return }
        isLoading = true

        // Collected on the main actor (Bonjour state and UserDefaults live
        // here) and handed to the detached probe.
        let remoteHosts = Self.candidateRemoteHosts()

        let layout = ZmxSessionManager.sessionGroups()
        let names = layout.flatMap(\.sessionNames)
        let referenced = ZmxSessionManager.referencedSessions()
        let attached = ZmxSessionManager.attachedSessions()
        // Resolving a shell pid can shell out to `lsof`, but the result is
        // cached for the session's lifetime, so this is usually free.
        var shellPids: [String: pid_t] = [:]
        for name in names {
            if let pid = ZmxSessionManager.cachedServerShellPid(session: name) {
                shellPids[name] = pid
            }
        }

        Task {
            // The scan spawns processes and fans out over a concurrent queue;
            // if it ever fails to come back cleanly the flag must still clear,
            // otherwise `reload`'s guard rejects every future refresh and the
            // browser looks frozen.
            defer { self.isLoading = false }

            let scanned = await Task.detached(priority: .userInitiated) {
                ZmxSessionManager.allSessionInfoConcurrently(
                    names: names,
                    referenced: referenced,
                    attached: attached,
                    shellPids: shellPids
                )
            }.value

            // Re-attach the scanned detail to its window, preserving pane order.
            let byName = Dictionary(
                scanned.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            self.groups = layout.compactMap { group in
                // The watermark is a property of the pane in its window, not
                // of the daemon, so it is attached here rather than in the
                // per-session scan.
                let sessions = group.sessionNames.compactMap { name -> ZmxSessionManager.SessionInfo? in
                    guard var info = byName[name] else { return nil }
                    // The window's TOML first, then what the session itself
                    // was last called. A crash takes the TOML with it and
                    // leaves the session running, and a pane that comes back
                    // nameless is one you have to identify by reading it.
                    info.watermark = group.watermarks[name]
                        ?? ZmxSessionManager.rememberedWatermark(forSession: name)
                    return info
                }
                guard !sessions.isEmpty else { return nil }
                return Group(
                    name: group.name,
                    path: group.path,
                    isOrphanGroup: group.isOrphanGroup,
                    remoteHost: nil,
                    error: nil,
                    sessions: sessions
                )
            }

            // Remote hosts are an SSH round trip each — seconds, not
            // milliseconds — so they land *after* the local list is already on
            // screen rather than holding the whole browser back.
            guard !remoteHosts.isEmpty else { return }
            let remote = await Task.detached(priority: .userInitiated) {
                ZmxSessionManager.remoteSessionsConcurrently(hosts: remoteHosts)
            }.value

            // A pane this Mac has open on a remote session shows up as
            // attached on the far side, so nothing extra is needed to mark it.
            self.groups += remote.map { host in
                Group(
                    name: host.host,
                    path: nil,
                    isOrphanGroup: false,
                    remoteHost: host.host,
                    error: host.error,
                    sessions: host.sessions
                )
            }
        }
    }

    /// Machines worth asking about their sessions.
    ///
    /// Bonjour alone isn't enough: a host reached over Tailscale or a VPN
    /// never appears in a LAN service browse, but it is exactly the machine
    /// whose sessions went missing when the link dropped. So the list is the
    /// union of what's advertising, what saved windows have put panes on, and
    /// the last address typed into the host prompt.
    /// `expected` marks the machines this Mac has actually put panes on: those
    /// are the ones whose absence needs explaining if the probe fails.
    private static func candidateRemoteHosts() -> [(host: String, expected: Bool)] {
        var hosts: [(host: String, expected: Bool)] = []
        var seen: Set<String> = []
        func add(_ host: String?, expected: Bool) {
            guard let host, !host.isEmpty,
                  BaseTerminalController.isValidRemoteHost(host),
                  seen.insert(host.lowercased()).inserted else { return }
            hosts.append((host: host, expected: expected))
        }

        for host in ZmxSessionManager.savedRemoteHosts() { add(host, expected: true) }
        add(UserDefaults.standard.string(
            forKey: BaseTerminalController.lastRemoteHostDefaultsKey), expected: true)
        for host in RemoteHostDiscovery.shared.hosts {
            add(host.sshDestination, expected: false)
        }

        // Every host costs a connect timeout when it's down, and the browser
        // is meant to feel like a list, not a network scan.
        return Array(hosts.prefix(8))
    }

    // MARK: - Actions

    /// The window already showing `session`, if any.
    ///
    /// A zmx session drives one PTY. Attaching a second client to it leaves two
    /// UIs negotiating size and draining output on the same stream, which wedges
    /// both — so an already-attached session must be *revealed*, never reopened.
    private func existingController(for name: String) -> BaseTerminalController? {
        TerminalController.all.first { controller in
            controller.surfaceTree.contains {
                $0.zmxSessionName == name || $0.remoteZmxSession == name
            }
        }
    }

    /// Bring the window owning `name` to the front. Returns false if no live
    /// window has it, in which case the caller should restore it normally.
    @discardableResult
    private func revealExisting(_ name: String) -> Bool {
        guard let controller = existingController(for: name),
              let window = controller.window else { return false }
        Self.logger.info("Session browser: \(name, privacy: .public) is already attached; revealing its window")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // A pane parked in the sidebar is attached but not on screen, so
        // raising its window alone looks like nothing happened. Bring it back
        // to the grid, which is what "open this" means for a pane you cannot
        // see.
        if let surface = controller.surfaceTree.first(where: {
            $0.zmxSessionName == name || $0.remoteZmxSession == name
        }), let parked = controller.sidebarTiles.first(where: {
            $0.containsSurface(ObjectIdentifier(surface))
        }) {
            controller.restorePaneFromSidebar(parked.id)
        }
        return true
    }

    /// Open a session in a new window by writing a one-pane session config that
    /// names it, then restoring that config. Reattaching by name is what makes
    /// the pane resume the *existing* process instead of spawning a new shell.
    func open(_ session: ZmxSessionManager.SessionInfo) {
        Self.logger.info("Session browser: open \(session.name, privacy: .public) requested")

        // Already on screen: focus it rather than attaching a second client.
        //
        // Gated on what the daemon says rather than on finding a surface that
        // carries the name. A surface outlives its connection — an exited
        // pane, or a remote one sitting behind a Reconnect button, still
        // reports the session it used to hold — so a *detached* session was
        // being called "already attached", and Open just brought a window
        // forward while nothing attached at all.
        //
        // `attached` comes from the session's own client count, which is the
        // only thing that actually answers the question.
        if session.attached, revealExisting(session.name) { return }

        guard let ghostty else {
            // Never fail silently: a nil app reference here means the browser
            // was shown without one, and the button would otherwise look dead.
            Self.logger.error("Session browser: no Ghostty.App; cannot open \(session.name, privacy: .public)")
            presentError(
                title: "Could Not Open Session",
                message: "trm is not ready to open a window yet. Try again in a moment."
            )
            return
        }

        guard let path = writeSinglePaneConfig(for: session) else {
            presentError(
                title: "Could Not Open Session",
                message: "Failed to write a session config for \(session.name)."
            )
            return
        }

        guard let config = Trm.gridConfig(fromConfigPath: path) else {
            presentError(
                title: "Could Not Open Session",
                message: "The generated session config for \(session.name) could not be parsed."
            )
            return
        }

        _ = TerminalController.newWindow(
            ghostty,
            withGridConfig: config,
            withConfigPath: path
        )

        // Dismiss rather than reload. Reloading kept the browser on screen and
        // re-laid-out its whole session list at the moment the new terminal
        // window was being built, so two SwiftUI graphs fought for the same
        // layout pass and the app pinned a core. The browser has done its job
        // once the window is open, and closing it also tears down the hosted
        // view (see `windowWillClose`), so a list refresh isn't needed either.
        dismissAfterOpening()
    }

    /// Close the browser once it has opened a window.
    ///
    /// The model reaches its window through `hostWindow` — the controller owns
    /// the actual `window` property.
    private func dismissAfterOpening() {
        hostWindow?.performClose(nil)
    }

    /// Quote and escape a string for use as a TOML basic-string value.
    private static func tomlQuote(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Write a single-pane TOML that reattaches to `session`.
    /// One window holding every session in a group, laid out as a grid.
    ///
    /// Used when the group has no saved arrangement to restore. The shape is
    /// chosen the way the browser's own tiles are — roughly square, never
    /// more columns than panes — because there is nothing better to go on,
    /// and a long single row would push most of the panes off screen.
    private func writeGroupConfig(for group: Group) -> String? {
        let sessions = group.sessions
        guard !sessions.isEmpty else { return nil }

        let cols = max(1, Int(ceil(Double(sessions.count).squareRoot())))
        let rows = max(1, Int(ceil(Double(sessions.count) / Double(cols))))

        // Named for the group so reopening overwrites rather than litters,
        // and `_browser_` keeps it out of the named-session picker.
        let safeName = group.name.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let url = SessionManager.sessionsDirectory
            .appendingPathComponent("_browser_group_\(safeName).toml")

        var toml = "# Opened from the session browser: every session in this group.\n\n"
        toml += "[grid]\n"
        toml += "rows = \(rows)\n"
        toml += "cols = \(cols)\n"
        toml += "gap = 4\n"
        toml += "outer_padding = 4\n\n"
        for session in sessions {
            toml += "[[panes]]\n"
            toml += "pane_type = \"terminal\"\n"
            if let host = session.remoteHost {
                // A remote pane is described by where it runs, not by a local
                // socket — the restore path rebuilds the `ssh … zmx attach`.
                toml += "remote_host = \(Self.tomlQuote(host))\n"
                toml += "remote_session = \(Self.tomlQuote(session.name))\n"
            } else {
                toml += "zmx_session = \(Self.tomlQuote(session.name))\n"
                if let cwd = session.cwd, !cwd.isEmpty, cwd != "/" {
                    toml += "cwd = \(Self.tomlQuote(cwd))\n"
                }
            }
            if let watermark = session.watermark, !watermark.isEmpty {
                toml += "watermark = \(Self.tomlQuote(watermark))\n"
            }
            toml += "\n"
        }

        do {
            try toml.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            Self.logger.error(
                "Session browser: could not write group config: \(error.localizedDescription)")
            return nil
        }
    }
    private func writeSinglePaneConfig(for session: ZmxSessionManager.SessionInfo) -> String? {
        let dir = SessionManager.sessionsDirectory
        // A stable per-session filename keeps repeated opens from littering the
        // directory, and the `_browser_` prefix keeps these out of the named
        // session picker (which lists plain `<name>.toml`).
        let url = dir.appendingPathComponent("_browser_\(session.name).toml")

        // Escaped rather than interpolated raw: a cwd containing a quote or
        // backslash would otherwise emit malformed TOML, and the restore fails
        // with a parse error instead of opening the session.
        var toml = """
        # Opened from the session browser.

        [grid]
        rows = 1
        cols = 1
        gap = 4
        outer_padding = 4

        [[panes]]
        pane_type = "terminal"

        """
        if let host = session.remoteHost {
            // A remote pane is described by where it runs, not by a local
            // socket — the restore path rebuilds the `ssh … zmx attach` for it.
            toml += "remote_host = \(Self.tomlQuote(host))\n"
            toml += "remote_session = \(Self.tomlQuote(session.name))\n"
            // `cwd` is deliberately omitted: it names a directory on the other
            // machine, and setting it here would point the local surface at a
            // path that may not exist.
        } else {
            toml += "zmx_session = \(Self.tomlQuote(session.name))\n"
            if let cwd = session.cwd, !cwd.isEmpty, cwd != "/" {
                toml += "cwd = \(Self.tomlQuote(cwd))\n"
            }
        }

        do {
            try toml.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            Self.logger.error(
                "Failed to write browser session config: \(error.localizedDescription)")
            return nil
        }
    }

    /// Confirm, then terminate a session and every process inside it.
    func confirmTerminate(_ session: ZmxSessionManager.SessionInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Terminate \(session.command ?? "session")?"

        var detail = "This kills \(session.name) and every process running inside it."
        if let cwd = session.shortCwd {
            detail += "\n\nWorking directory: \(cwd)"
        }
        if session.attached {
            detail += "\n\nThis session is currently attached to a window."
        }
        detail += "\n\nThis cannot be undone."
        alert.informativeText = detail

        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        // Make Cancel the safe default for a destructive, irreversible action.
        alert.buttons.first?.hasDestructiveAction = true
        alert.window.defaultButtonCell = alert.buttons.last?.cell as? NSButtonCell

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.terminate(session)
        }

        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// Open a whole saved window, restoring its full layout in one go. This is
    /// the point of grouping: the panes were arranged together, so bringing
    /// them back individually would lose that arrangement.
    func openGroup(_ group: Group) {
        Self.logger.info("Session browser: open window \(group.name, privacy: .public) requested")

        guard let ghostty else {
            Self.logger.error("Session browser: no Ghostty.App; cannot open \(group.name, privacy: .public)")
            presentError(
                title: "Could Not Open Window",
                message: "trm is not ready to open a window yet. Try again in a moment."
            )
            return
        }

        // No saved arrangement — but that is a reason to invent one, not a
        // reason to hand back N one-pane windows. After a crash the group with
        // every pane in it is usually exactly the one with no TOML, and
        // opening eleven sessions one at a time is the worst possible moment to
        // ask someone to do clerical work. A grid is not the layout that was
        // lost; it is enormously closer to it than eleven windows.
        guard let path = group.path else {
            guard let generated = writeGroupConfig(for: group) else {
                presentError(
                    title: "Could Not Open Window",
                    message: "Failed to write a session config for \(group.name)."
                )
                return
            }
            guard let generatedConfig = Trm.gridConfig(fromConfigPath: generated) else {
                presentError(
                    title: "Could Not Open Window",
                    message: "The session file generated for \(group.name) could not be parsed."
                )
                return
            }
            _ = TerminalController.newWindow(
                ghostty,
                withGridConfig: generatedConfig,
                withConfigPath: generated
            )
            dismissAfterOpening()
            return
        }

        // A group whose panes are all still on screen is the common case for
        // the autosave of the *current* window. Restoring it would build a
        // second window onto the same sessions, so reveal the one already
        // showing them instead.
        let live = group.sessions.filter { existingController(for: $0.name) != nil }
        if live.count == group.sessions.count, let first = live.first {
            revealExisting(first.name)
            return
        }
        if !live.isEmpty {
            // Partially attached: restoring the TOML wholesale would still
            // double-attach the live panes.
            presentError(
                title: "Window Is Already Open",
                message: "\(live.count) of \(group.sessions.count) panes in \(group.name) are "
                    + "already attached to an open window. Close that window first, or open the "
                    + "detached sessions individually."
            )
            return
        }

        guard let config = Trm.gridConfig(fromConfigPath: path) else {
            presentError(
                title: "Could Not Open Window",
                message: "The session file for \(group.name) could not be parsed."
            )
            return
        }

        _ = TerminalController.newWindow(
            ghostty,
            withGridConfig: config,
            withConfigPath: path
        )
        // See `open`: dismiss instead of reloading, so the browser's list isn't
        // re-laid-out while the new window is being built.
        dismissAfterOpening()
    }

    /// Confirm, then terminate every session in a window.
    func confirmTerminateGroup(_ group: Group) {
        let count = group.sessions.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Terminate all \(count) session\(count == 1 ? "" : "s") in \(group.name)?"

        var detail = "This kills every process in this window:\n\n"
        detail += group.sessions
            .prefix(8)
            .map { "• \($0.command ?? "shell")\($0.shortCwd.map { c in "  (\(c))" } ?? "")" }
            .joined(separator: "\n")
        if count > 8 { detail += "\n• …and \(count - 8) more" }
        detail += "\n\nThis cannot be undone."
        alert.informativeText = detail

        alert.addButton(withTitle: "Terminate All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.window.defaultButtonCell = alert.buttons.last?.cell as? NSButtonCell

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let remote = group.sessions.compactMap { session in
                session.remoteHost.map { (name: session.name, host: $0) }
            }
            for session in group.sessions where session.remoteHost == nil {
                ZmxSessionManager.killSession(session.name)
            }
            Task.detached(priority: .userInitiated) {
                for entry in remote {
                    ZmxSessionManager.killRemoteSession(entry.name, host: entry.host)
                }
                try? await Task.sleep(for: .milliseconds(300))
                await MainActor.run { self.reload() }
            }
        }

        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func terminate(_ session: ZmxSessionManager.SessionInfo) {
        // Drop the generated config so a killed session can't be resurrected
        // by a stale file.
        let url = SessionManager.sessionsDirectory
            .appendingPathComponent("_browser_\(session.name).toml")
        try? FileManager.default.removeItem(at: url)

        if let host = session.remoteHost {
            // Killing over SSH is a round trip: run it off the main thread and
            // refresh once it has actually happened, not on a guessed delay.
            let name = session.name
            Task.detached(priority: .userInitiated) {
                ZmxSessionManager.killRemoteSession(name, host: host)
                await MainActor.run { self.reload() }
            }
            return
        }

        ZmxSessionManager.killSession(session.name)
        // Killing is asynchronous in the daemon; give it a moment before the
        // list is rescanned so the socket is actually gone.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            self.reload()
        }
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// Window controller hosting the session browser. One shared instance: the
/// browser is a singleton inspector, not a per-window panel.
@MainActor
final class SessionBrowserController: NSWindowController, NSWindowDelegate {
    static let shared = SessionBrowserController()

    private let model = SessionBrowserModel()

    private init() {
        let window = NSWindow(
            // Tall enough that a typical multi-pane window shows all its panes
            // without scrolling; clamped to the screen below.
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Session Browser"
        window.isReleasedWhenClosed = false
        // The browser is summoned over a terminal window; without this it can
        // come up behind the app's own windows and its controls never see a
        // click.
        window.level = .floating
        // Don't exceed the visible screen on smaller displays.
        if let visible = NSScreen.main?.visibleFrame {
            let h = min(window.frame.height, visible.height - 40)
            let w = min(window.frame.width, visible.width - 40)
            window.setContentSize(NSSize(width: w, height: h))
        }
        window.center()
        super.init(window: window)
        window.delegate = self
        model.hostWindow = window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Install the SwiftUI content. Deferred to `show` rather than done once in
    /// `init` so that closing the browser can tear it down again — see
    /// `windowWillClose`.
    private func installContentView() {
        guard let window, !(window.contentView is NSHostingView<SessionBrowserView>) else { return }
        let hosting = NSHostingView(rootView: SessionBrowserView(model: model))
        window.contentView = hosting
        // Give the hosting view first responder so its buttons are live as
        // soon as the window appears, rather than after a stray click.
        window.initialFirstResponder = hosting
    }

    /// Show the browser, refreshing its contents each time it is summoned.
    func show(ghostty: Ghostty.App?) {
        installContentView()
        model.ghostty = ghostty
        model.reload()
        // Activate first, then key the window: ordering it front while the app
        // is still inactive can leave it visible but not accepting clicks.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Drop the hosted SwiftUI content when the browser is dismissed.
    ///
    /// The window is a singleton kept alive across shows
    /// (`isReleasedWhenClosed = false`), so without this its NSHostingView —
    /// and the whole SwiftUI view graph behind it, including the session list's
    /// LazyVStack — stayed resident after the window was closed. It kept
    /// participating in the app's layout passes: every window resize drove
    /// AppKit's `_layoutSubtreeWithOldSize:` into `NSHostingView.layout()` for
    /// this invisible view, which re-ran `LazyStack.measureEstimates` over the
    /// session tiles and pinned a core for as long as the resize continued.
    /// Tearing the content down on close means a dismissed browser costs
    /// nothing; `show` rebuilds it.
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }

    // This is called when "escape" is pressed.
    @objc func cancel(_ sender: Any?) {
        window?.performClose(sender)
    }
}
