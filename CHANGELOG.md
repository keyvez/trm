# Changelog

## Unreleased

### Added

- **Watermark hover shine**: Moving the mouse into or out of a pane triggers a single watermark flash — the same highlight animation used when a pane gains focus. Works for both regular and stacked sub-panes.
- **`surface.list` pid field**: Each surface entry now includes a `"pid"` field with the child process ID of the pane.
- **Startup session dialog**: trm now shows a dialog at launch whenever there is an auto-saved session to restore. The dialog shows the pane count, process list, and save timestamp. When `--config` was also passed, a third button lets you open that file instead. Previously the dialog only appeared when both an autosave and `--config` were present.
- **`start-claude` script**: `scripts/start-claude.sh` launches trm with a multi-pane layout and automatically starts Claude Code in the last pane, then focuses it after a configurable delay (default 3 s). Options: `--panes N`, `--delay S`, `--session PATH`, `--no-focus`.
- **Claude session**: `sessions/claude.toml` — a 2×2 grid session where the bottom-right pane auto-starts `claude`.

### Fixed

- **`surface.focus` RPC**: The `surface.focus` cmux RPC now correctly focuses the target pane. Three bugs fixed: (1) pane ID lookup in `handleFocusPane` fell back to grid index when `paneId` is nil (matching the same logic as `surface.list`), (2) `focusSurface` now always calls `NSApp.activate` so the trm window comes to front even when another app is focused, (3) `TerminalWindowRestoration` skips macOS native window restoration when `TRM_CONFIG` is set, preventing stale surfaces from a prior session from interfering with a freshly-requested config.
- **`surface.list` duplicate responses**: When multiple windows exist and none is the main window (e.g. trm is in the background), only the first (oldest) controller now responds to cmux queries. Previously both controllers responded, producing duplicate surface entries.

## 0.2.4 (2026-03-12)

### Added

- **cmux-compatible API**: Dual-protocol support on the Text Tap socket. Tools built for cmux automatically work with trm. Supports `system.ping`, `system.capabilities`, `system.identify`, `surface.list`, `surface.send_text`, `surface.send_key`, `workspace.list`, `workspace.current`, and `notification.create`. Phase 2 methods (`surface.list`, `system.identify`) use a response queue through Swift for live data.
- **cmux CLI subcommands**: New `trm ping`, `trm list-surfaces`, `trm identify`, `trm capabilities`, `trm send-key`, and `trm send-text` commands using the cmux protocol.
- **cmux env vars**: Child processes receive `CMUX_SOCKET_PATH`, `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `TRM_SOCKET_PATH`, and `TRM_PANE_ID` environment variables for tool integration.

## 0.2.3 (2026-03-08)

### Added

- **Notification rings**: Panes needing attention now glow with an animated blue ring border that pulses until the pane is focused. Replaces the small icon-only indicator.
- **CLI socket API**: Full-featured `trm` CLI with subcommands: `notify`, `list-panes`, `send`, `send-all`, `send-command`, `mark-connected`, `mark-disconnected`, `open-browser`, `status`, and `raw`. Communicates over the Text Tap Unix socket.
- **Split browser pane**: Open a WebView alongside terminal panes with Cmd+Shift+L. Accessible from the View menu and via `trm open-browser --url URL`.
- **Agent browser integration**: Scriptable WebView API for AI agents. New socket actions: `browser_eval` (execute JS), `browser_navigate`, `browser_snapshot` (accessibility tree), `browser_click`, `browser_fill`. CLI subcommands: `browser-eval`, `browser-navigate`, `browser-snapshot`, `browser-click`, `browser-fill`.

### Fixed

- **Notification pane ID**: Notifications now correctly identify the source pane instead of always using the focused pane.

## 0.2.2 (2026-02-22)

### Added

- **Cmd+1–9 pane switching**: Cmd+1–9 now switches between panes in the grid instead of macOS window tabs. Intercepted directly in key event handling for minimal latency. Previous/next (Cmd+[/]) wrap around. Falls back to tab switching when only one pane exists.
- **Session save/restore**: Grid layout and pane state persist across app restarts, including jagged grid configurations and pane move positions.
- **Text Tap send pipeline**: Route commands through the ghostty surface PTY via Text Tap, enabling external tools to send text to specific panes.
- **Service plugin hot-reload**: Service plugins automatically reload when `trm.toml` config changes.

### Fixed

- **Quick action Enter key**: Quick action buttons now send the Enter keypress (`\r`) as a separate PTY write from the command text, fixing commands not executing in tools like Claude Code.
- **Watermark flash on pane move**: Fixed rapid pane-move causing watermark shine to fire repeatedly by observing notifications directly in WatermarkView.

## 0.2.1 (2026-02-18)

### Added

- **Quick Actions**: Save frequently-used commands as persistent pill buttons on terminal panes. Select text in the terminal, right-click "Save as Quick Action...", and name it. Actions appear as green pills at the bottom-right of the matching pane — click to run, hover to reveal an X to delete. Stored in `.trm-actions.toml` alongside your `trm.toml`, with file watcher hot-reload and session persistence. Supports pane watermark matching and optional SF Symbol icons.

## 0.2.0 (2026-02-17)

### Added

- **Server URL detection**: Terminal panes automatically scan output for local dev-server URLs (`localhost`, `127.0.0.1`, `0.0.0.0`, `[::1]` with a port) and display a clickable banner at the top of the pane. Click to open in an inline webview pane, shift-click to copy. When multiple URLs are detected, clicking the banner opens a dropdown listing each one. Supports custom regex patterns via the `patterns` field in `[[panes]]` config for matching tunnels, ngrok, localtunnel, etc.

## 0.1.0 (2026-02-15)

### Added

- **Inline webview panes**: HTTP/HTTPS URLs opened from terminal processes (via OSC 8 hyperlink clicks or `open` command) now open in an inline webview pane within the grid instead of the system browser. Each webview pane includes a minimal toolbar with the page title and a close button. Non-HTTP schemes (file://, mailto://) and `.text` kind URLs (config files) retain their previous behavior.
- **Claude Code context usage tracking**: Real-time visibility into Claude Code's context window consumption. A compact bottom-right pill shows current usage percentage with color-coded gauge (green/yellow/orange/red). Tap to expand for token counts, daily/weekly usage totals, and auto-compact warnings. Data flows from Claude Code hooks via Text Tap socket using the new `context_update` message type. Usage history persists across sessions with 7-day retention. Drop-in hook script at `scripts/claude-context-trm.sh`.
- **Native notifications via Text Tap**: New `notify` action in the Text Tap API. External tools (like Claude Code) can send `{"type":"action","action":"notify","title":"...","body":"..."}` to the Text Tap socket, and trm displays a native macOS notification via `UNUserNotificationCenter`. Includes a ready-to-use hook script at `scripts/claude-notify-trm.sh`.
- **CLI install script**: `scripts/install-cli.sh` installs a `trm` command to `/usr/local/bin`.

### Fixed

- **Documents folder permission prompts**: Pane surfaces now default to the home directory when no `cwd` is configured, avoiding repeated macOS TCC permission dialogs on startup.
- **Alt+Tab shows "trm"**: Set `CFBundleName = trm` across all Xcode build configurations. Updated all XIB window titles from "Ghostty" to "trm".
