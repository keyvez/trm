# Changelog

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
