import SwiftUI
import GhosttyKit

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The update view model for showing update commands.
    var updateViewModel: UpdateViewModel?

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    /// Callback to execute parsed LLM actions against the terminal controller.
    var onExecuteActions: (([TrmAction]) -> Void)?

    /// Callback to build pane context for the LLM.
    var buildPaneContext: (() -> [PaneContext])?

    /// Callback to toggle live summary mode.
    var onToggleLiveSummary: (() -> Void)?

    /// Shared AI state that persists across palette open/close.
    @ObservedObject var aiState: CommandPaletteAIState

    /// Agent monitor for tracking AI agent activity.
    @ObservedObject var agentMonitor: AgentMonitorService

    /// The service plugin registry for listing active plugins.
    @ObservedObject var servicePluginRegistry: ServicePluginRegistry

    @State private var showingAPIKeyPrompt = false
    /// Prompt to auto-submit after the user saves their API token.
    @State private var pendingAIPrompt: String?

    /// Cached command options, computed once when the palette opens.
    @State private var cachedOptions: [CommandOption] = []

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: cachedOptions,
                            onAISubmit: { prompt in
                                submitStreamingAI(prompt: prompt)
                            },
                            onCommandSubmit: { command in
                                // Route command mode: send raw text to focused surface
                                onAction(command)
                            },
                            commandAutocompleteOptions: commandAutocompleteOptions,
                            onExecuteActions: { actions in
                                onExecuteActions?(actions)
                            },
                            onNeedsAPIKey: { prompt in
                                pendingAIPrompt = prompt
                                showingAPIKeyPrompt = true
                            },
                            aiState: aiState
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .sheet(isPresented: $showingAPIKeyPrompt) {
            APIKeyPromptView(isPresented: $showingAPIKeyPrompt) { key in
                // Empty key means the user chose "Use Claude Login" (OAuth).
                if !key.isEmpty {
                    Trm.shared.claudeAPIKey = key
                }
                // Auto-submit the pending prompt now that we have a token
                if let prompt = pendingAIPrompt {
                    pendingAIPrompt = nil
                    submitStreamingAI(prompt: prompt)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            if newValue {
                // Snapshot options once when the palette opens so we don't
                // recompute jump/terminal/update options on every keystroke.
                cachedOptions = commandOptions
            } else {
                // When the command palette disappears we need to send focus back to the
                // surface view we were overlaid on top of.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// Submit an AI prompt with streaming, parsing # references first.
    private func submitStreamingAI(prompt: String) {
        let context = buildPaneContext?() ?? []

        // Parse # references from the prompt
        let (cleanedPrompt, references) = PaneAddressing.extractReferences(from: prompt, panes: context)
        let highlightedPanes = Set(references.compactMap(\.resolvedIndex))

        aiState.isThinking = true
        aiState.streamingText = ""
        aiState.responseText = nil
        aiState.pendingActions = []

        aiState.streamTask = Task {
            do {
                let response = try await Trm.shared.llmClient.submitStreaming(
                    prompt: cleanedPrompt,
                    paneContext: context,
                    highlightedPanes: highlightedPanes
                ) { token in
                    Task { @MainActor in
                        aiState.streamingText += token
                        aiState.isThinking = false
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    aiState.isThinking = false
                    aiState.responseText = response.explanation
                    aiState.pendingActions = response.actions
                }
            } catch {
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    aiState.isThinking = false
                    aiState.responseText = "Error: \(error.localizedDescription)"
                    aiState.streamingText = ""
                    aiState.pendingActions = []
                }
            }
        }
    }

    /// All commands available in the command palette, combining update and terminal options.
    private var commandOptions: [CommandOption] {
        var options: [CommandOption] = []
        // Updates always appear first
        options.append(contentsOf: updateOptions)

        // Sort the rest. We replace ":" with a character that sorts before space
        // so that "Foo:" sorts before "Foo Bar:". Use sortKey as a tie-breaker
        // for stable ordering when titles are equal.
        options.append(contentsOf: (jumpOptions + terminalOptions + pluginOptions).sorted { a, b in
            let aNormalized = a.title.replacingOccurrences(of: ":", with: "\t")
            let bNormalized = b.title.replacingOccurrences(of: ":", with: "\t")
            let comparison = aNormalized.localizedCaseInsensitiveCompare(bNormalized)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            // Tie-breaker: use sortKey if both have one
            if let aSortKey = a.sortKey, let bSortKey = b.sortKey {
                return aSortKey < bSortKey
            }
            return false
        })
        return options
    }

    /// Commands for installing or canceling available updates.
    private var updateOptions: [CommandOption] {
        var options: [CommandOption] = []

        guard let updateViewModel, updateViewModel.state.isInstallable else {
            return options
        }

        // We override the update available one only because we want to properly
        // convey it'll go all the way through.
        let title: String
        if case .updateAvailable = updateViewModel.state {
            title = "Update trm and Restart"
        } else {
            title = updateViewModel.text
        }

        options.append(CommandOption(
            title: title,
            description: updateViewModel.description,
            leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
            badge: updateViewModel.badge,
            emphasis: true
        ) {
            (NSApp.delegate as? AppDelegate)?.updateController.installUpdate()
        })

        options.append(CommandOption(
            title: "Cancel or Skip Update",
            description: "Dismiss the current update process"
        ) {
            updateViewModel.state.cancel()
        })

        return options
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        var options = appDelegate.ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { c in
                CommandOption(
                    title: c.title,
                    description: c.description
                ) {
                    onAction(c.action)
                }
            }

        options.append(CommandOption(
            title: "Load Session TOML",
            description: "Load trm.toml from the focused pane's working directory",
            leadingIcon: "doc.badge.gearshape"
        ) {
            onAction("trm.load_toml")
        })

        options.append(CommandOption(
            title: "Save Session TOML",
            description: "Save the current pane layout to a trm.toml file",
            leadingIcon: "square.and.arrow.down"
        ) {
            onAction("trm.save_toml")
        })

        options.append(CommandOption(
            title: "Save Session As...",
            description: "Save the current layout as a named session for later restore",
            leadingIcon: "square.and.arrow.down.on.square"
        ) {
            onAction("trm.save_session")
        })

        options.append(CommandOption(
            title: "Restore Last Session",
            description: "Restore the most recently auto-saved session in a new window",
            leadingIcon: "arrow.counterclockwise"
        ) {
            onAction("trm.restore_last_session")
        })

        options.append(CommandOption(
            title: "Restore Session...",
            description: "Browse and restore a previously saved named session",
            leadingIcon: "folder"
        ) {
            onAction("trm.restore_session")
        })

        options.append(CommandOption(
            title: "Clear Auto-Save",
            description: "Delete all auto-saved session files",
            leadingIcon: "trash"
        ) {
            onAction("trm.clear_autosave")
        })

        options.append(CommandOption(
            title: "Add Notes Pane",
            description: "Add a new notes pane to the grid",
            leadingIcon: "note.text"
        ) {
            onAction("trm.add_pane notes")
        })

        options.append(CommandOption(
            title: "Add Webview Pane",
            description: "Add a new webview pane to the grid",
            leadingIcon: "globe"
        ) {
            onAction("trm.add_pane webview")
        })

        options.append(CommandOption(
            title: "Add Terminal Pane",
            description: "Add a new terminal pane to the grid",
            leadingIcon: "terminal"
        ) {
            onAction("trm.add_pane terminal")
        })

        options.append(CommandOption(
            title: "Add Git Status Pane",
            description: "Add a git status pane to the grid",
            leadingIcon: "arrow.triangle.branch"
        ) {
            onAction("trm.add_pane git_status")
        })

        if let toggleLiveSummary = onToggleLiveSummary {
            options.append(CommandOption(
                title: "Toggle Live Summary",
                description: "Show/hide LLM-powered per-pane summaries",
                leadingIcon: "text.below.photo"
            ) {
                toggleLiveSummary()
            })
        }

        return options
    }

    /// Commands for viewing and interacting with registered service plugins.
    private var pluginOptions: [CommandOption] {
        servicePluginRegistry.plugins.values.map { plugin in
            let caps = type(of: plugin).requiredCapabilities
            let capLabels = caps.map { cap -> String in
                switch cap {
                case .terminalOutputRead: return "output"
                case .networkAccess: return "network"
                case .fileSystemRead: return "filesystem"
                case .clipboardWrite: return "clipboard"
                case .userNotifications: return "notifications"
                }
            }.sorted().joined(separator: ", ")

            let hasOverlay = plugin is any ServicePluginOverlayProvider
            let subtitle = hasOverlay ? "Overlay plugin \u{00B7} \(capLabels)" : capLabels

            return CommandOption(
                title: "Plugin: \(plugin.displayName)",
                subtitle: subtitle,
                leadingIcon: "puzzlepiece.extension",
                badge: "Active"
            ) {
                // No-op: informational row
            }
        }
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil

            return controller.surfaceTree.map { surface in
                let title = surface.title.isEmpty ? window.title : surface.title
                let displayTitle = title.isEmpty ? "Untitled" : title
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) {
                    pwd
                } else {
                    nil
                }

                return CommandOption(
                    title: "Focus: \(displayTitle)",
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: AnySortKey(ObjectIdentifier(surface))
                ) {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }

    /// Internal command completions for command mode (`!`).
    private var commandAutocompleteOptions: [CommandAutocompleteOption] {
        [
            // -- Load --
            CommandAutocompleteOption(
                label: "trm.load_toml",
                insertion: "trm.load_toml",
                subtitle: "Load trm.toml from focused pane cwd",
                description: "Reads a trm.toml session file from the focused pane's working directory and replaces the current grid layout with the one defined in the file."
            ),
            CommandAutocompleteOption(
                label: "trm.load_toml <path>",
                insertion: "trm.load_toml ",
                subtitle: "Load a specific TOML path",
                description: "Load a session layout from an absolute or relative TOML file path. Relative paths resolve from the focused pane's working directory."
            ),
            CommandAutocompleteOption(
                label: "trm.load",
                insertion: "trm.load",
                subtitle: "Alias for trm.load_toml",
                description: "Shorthand for trm.load_toml — loads trm.toml from the focused pane's working directory."
            ),
            CommandAutocompleteOption(
                label: "trm.load <path>",
                insertion: "trm.load ",
                subtitle: "Alias for trm.load_toml <path>",
                description: "Shorthand for trm.load_toml <path> — loads a specific TOML session file."
            ),

            // -- Save --
            CommandAutocompleteOption(
                label: "trm.save_toml",
                insertion: "trm.save_toml",
                subtitle: "Save current layout to trm.toml",
                description: "Snapshots the current pane layout (types, positions, URLs, notes) and opens a save dialog to write it as a trm.toml file."
            ),
            CommandAutocompleteOption(
                label: "trm.save_toml <path>",
                insertion: "trm.save_toml ",
                subtitle: "Save layout to a specific TOML path",
                description: "Save the current pane layout directly to the given file path without showing a save dialog."
            ),
            CommandAutocompleteOption(
                label: "trm.save",
                insertion: "trm.save",
                subtitle: "Alias for trm.save_toml",
                description: "Shorthand for trm.save_toml — opens a save dialog to export the current layout."
            ),
            CommandAutocompleteOption(
                label: "trm.save <path>",
                insertion: "trm.save ",
                subtitle: "Alias for trm.save_toml <path>",
                description: "Shorthand for trm.save_toml <path> — saves layout directly to a file."
            ),

            // -- Add Pane --
            CommandAutocompleteOption(
                label: "trm.add_pane <type>",
                insertion: "trm.add_pane ",
                subtitle: "Add a new pane to the grid",
                description: "Dynamically insert a new pane into the current grid. Types: terminal, webview, notes, git_status, file_browser, log_viewer, process_monitor, markdown_preview, system_info, screen_capture."
            ),
            CommandAutocompleteOption(
                label: "trm.add_pane terminal",
                insertion: "trm.add_pane terminal",
                subtitle: "Add a new terminal pane",
                description: "Split right on the focused pane and open a new terminal shell."
            ),
            CommandAutocompleteOption(
                label: "trm.add_pane notes",
                insertion: "trm.add_pane notes",
                subtitle: "Add a new notes pane",
                description: "Insert a scratchpad notes pane for jotting down text alongside your terminals."
            ),
            CommandAutocompleteOption(
                label: "trm.add_pane webview <url>",
                insertion: "trm.add_pane webview ",
                subtitle: "Add a webview pane (optional URL)",
                description: "Insert an inline browser pane. Provide a URL to open, or omit for a blank page."
            ),
            CommandAutocompleteOption(
                label: "trm.add_pane git_status",
                insertion: "trm.add_pane git_status",
                subtitle: "Add a git status pane",
                description: "Insert a pane that shows the git status of the current repository, auto-refreshing every few seconds."
            ),
            CommandAutocompleteOption(
                label: "trm.add",
                insertion: "trm.add ",
                subtitle: "Alias for trm.add_pane",
                description: "Shorthand for trm.add_pane — add a new pane by type."
            ),

            // -- Session Management --
            CommandAutocompleteOption(
                label: "trm.save_session",
                insertion: "trm.save_session",
                subtitle: "Save current layout as a named session",
                description: "Save the current window layout as a named session. Shows a dialog to enter a session name if none is provided."
            ),
            CommandAutocompleteOption(
                label: "trm.save_session <name>",
                insertion: "trm.save_session ",
                subtitle: "Save session with a specific name",
                description: "Save the current window layout directly with the given name, without showing a dialog."
            ),
            CommandAutocompleteOption(
                label: "trm.restore_last_session",
                insertion: "trm.restore_last_session",
                subtitle: "Restore the last auto-saved session",
                description: "Restore the most recently auto-saved session from when TRM was last closed. Opens in a new window."
            ),
            CommandAutocompleteOption(
                label: "trm.restore_last",
                insertion: "trm.restore_last",
                subtitle: "Alias for trm.restore_last_session",
                description: "Shorthand for trm.restore_last_session — restores the last auto-saved session."
            ),
            CommandAutocompleteOption(
                label: "trm.restore_session",
                insertion: "trm.restore_session",
                subtitle: "Browse and restore a saved session",
                description: "Shows a picker dialog listing all named sessions. Select one to restore it in a new window."
            ),
            CommandAutocompleteOption(
                label: "trm.restore_session <name>",
                insertion: "trm.restore_session ",
                subtitle: "Restore a specific named session",
                description: "Restore the named session directly without showing a picker dialog."
            ),
            CommandAutocompleteOption(
                label: "trm.clear_autosave",
                insertion: "trm.clear_autosave",
                subtitle: "Delete all auto-saved session files",
                description: "Removes all _autosave_* files from the sessions directory. The next launch will start fresh."
            ),
        ]
    }

}

/// This is done to ensure that the given view is in the responder chain.
fileprivate struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
