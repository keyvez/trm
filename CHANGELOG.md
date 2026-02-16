# Changelog

## 0.1.0 (2026-02-15)

### Added

- **Inline webview panes**: HTTP/HTTPS URLs opened from terminal processes (via OSC 8 hyperlink clicks or `open` command) now open in an inline webview pane within the grid instead of the system browser. Each webview pane includes a minimal toolbar with the page title and a close button. Non-HTTP schemes (file://, mailto://) and `.text` kind URLs (config files) retain their previous behavior.
- **Claude Code context usage tracking**: Real-time visibility into Claude Code's context window consumption. A compact bottom-right pill shows current usage percentage with color-coded gauge (green/yellow/orange/red). Tap to expand for token counts, daily/weekly usage totals, and auto-compact warnings. Data flows from Claude Code hooks via Text Tap socket using the new `context_update` message type. Usage history persists across sessions with 7-day retention. Drop-in hook script at `scripts/claude-context-trm.sh`.
- **Native notifications via Text Tap**: New `notify` action in the Text Tap API. External tools (like Claude Code) can send `{"type":"action","action":"notify","title":"...","body":"..."}` to the Text Tap socket, and trm displays a native macOS notification via `UNUserNotificationCenter`. Includes a ready-to-use hook script at `scripts/claude-notify-trm.sh`.
- **CLI install script**: `scripts/install-cli.sh` installs a `trm` command to `/usr/local/bin`.

### Fixed

- **Documents folder permission prompts**: Pane surfaces now default to the home directory when no `cwd` is configured, avoiding repeated macOS TCC permission dialogs on startup.
- **Alt+Tab shows "trm"**: Set `CFBundleName = trm` across all Xcode build configurations. Updated all XIB window titles from "Ghostty" to "trm".
