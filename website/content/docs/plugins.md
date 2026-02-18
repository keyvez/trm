+++
title = "Plugins"
description = "Reference for all 10 trm pane plugin types: terminal, webview, notes, screen capture, file browser, process monitor, log viewer, markdown preview, system info, and git status."
weight = 4
+++

trm supports 10 built-in pane plugin types managed by an extensible plugin registry, plus automatic server URL detection across all terminal panes. Each pane in the grid can be a different type, configured via `[[panes]]` blocks in your session file.

All plugins share these common fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | String | `"terminal"` | The plugin type identifier |
| `title` | String? | Auto-generated | Custom title for the pane's title bar |

## Plugin Registry

trm uses a plugin registry that maps plugin type names to factory functions. All 10 built-in plugins are registered at startup. The registry supports:

- **Plugin discovery** — list all available plugin types
- **Plugin instantiation** — create plugins by name
- **Extensibility** — future support for dynamic plugin loading

---

## terminal

Full VT100/VT220 terminal emulator with a PTY-backed shell. This is the default pane type.

```toml
[[panes]]
type = "terminal"
title = "Dev Shell"
command = "/bin/zsh"
cwd = "~/projects/myapp"
watermark = "DEV"
initial_commands = ["echo 'Hello!'", "ls -la"]
# env = [["NODE_ENV", "development"], ["PORT", "3000"]]
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `command` | String? | `$SHELL` | Shell or command to execute |
| `cwd` | String? | Inherited | Working directory (supports `~` expansion) |
| `watermark` | String? | None | Large faded text displayed behind the terminal content, useful for identifying panes at a glance |
| `initial_commands` | String[]? | None | Commands to run automatically after the shell starts. Each is sent with a carriage return |
| `env` | \[String, String\][]? | None | Extra environment variables as `[key, value]` pairs |

**Features:**
- GPU-rendered text via Ghostty's Metal/OpenGL renderer
- Full ANSI color support (16 colors + 256-color + true color)
- Scrollback history
- Mouse text selection (click-drag, double-click for word selection)
- Copy/paste via system clipboard
- VT100 escape sequence handling
- Broadcasts input when broadcast mode is active

---

## webview

Embedded web browser using macOS WKWebView. Click inside the pane to interact -- keyboard input is handled natively by WKWebView when focused.

```toml
[[panes]]
type = "webview"
title = "Documentation"
url = "https://docs.rs"
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `url` | String? | None | URL to load in the embedded browser |

**Features:**
- Full web rendering via WebKit
- JavaScript support
- Navigation via the Text Tap API (`navigate` action)
- Native macOS scrolling and interaction
- Automatically positioned and resized with the grid layout

> **Note:** WebView panes are macOS-only.

---

## notes

Editable in-pane scratch pad for quick notes.

```toml
# In-memory scratch pad
[[panes]]
type = "notes"
title = "Scratch Pad"
content = "Type anything here..."

```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `content` | String? | None | Initial note content |
| `file` | String? | None | Reserved for future file-backed notes support |

**Features:**
- In-place editing directly in the pane
- Starts with `content` when provided

> **Note:** Notes panes are macOS-only.

---

## screen_capture

Captures the main display and shows a periodically refreshed screenshot inside a pane.

```toml
[[panes]]
type = "screen_capture"
title = "Display Capture"
refresh_ms = 2000
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `refresh_ms` | Integer? | `2000` | Refresh interval in milliseconds |
| `target` | String? | None | Reserved for future targeted-window capture |
| `target_title` | String? | None | Reserved for future targeted-window capture |

> **Note:** Requires macOS Screen Recording permission.

---

## file_browser

Directory listing pane for quick file browsing context.

```toml
[[panes]]
type = "file_browser"
title = "Project Files"
path = "~/projects/myapp"
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `path` | String? | `"."` | Root directory to browse (supports `~` expansion) |

**Features:**
- Lists files and directories for `path` (or `cwd`)
- Directory entries are grouped in a scrollable text view

---

## process_monitor

Shows process snapshots using `ps`.

```toml
[[panes]]
type = "process_monitor"
title = "Processes"
refresh_ms = 2000
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `refresh_ms` | Integer? | `2000` | Refresh interval in milliseconds |

**Features:**
- PID, parent PID, CPU %, memory %, and command columns
- Auto-refresh at the configured interval

---

## log_viewer

Reads and displays the tail of a log file.

```toml
[[panes]]
type = "log_viewer"
title = "System Log"
file = "/var/log/system.log"
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `file` | String? | None | Path to the log file to read. Also accepts `path` as an alias |

**Features:**
- Shows the last ~300 lines of the target file
- Auto-refresh at the configured interval

---

## markdown_preview

Renders Markdown content with syntax highlighting for headings, code blocks, lists, and emphasis.

```toml
# From a file
[[panes]]
type = "markdown_preview"
title = "README"
file = "~/projects/myapp/README.md"

# Inline content
[[panes]]
type = "markdown_preview"
title = "Preview"
content = "# Hello\n\nThis is **bold** text."
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `file` | String? | None | Markdown file to render. Also accepts `path` as an alias |
| `content` | String? | None | Inline Markdown content (used when no `file` is specified) |

**Features:**
- Heading rendering with color differentiation
- Code block highlighting
- Bold and italic text support
- Scrollable content

---

## system_info

Displays live host/system details.

```toml
[[panes]]
type = "system_info"
title = "System"
refresh_ms = 3000
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `refresh_ms` | Integer? | `3000` | Refresh interval in milliseconds |

**Features:**
- Hostname and OS version
- CPU count
- Total memory
- System uptime

---

## git_status

Displays `git status --short --branch` output for a repository.

```toml
[[panes]]
type = "git_status"
title = "Git"
repo = "~/projects/myapp"
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `repo` | String? | `"."` | Path to the Git repository. Also accepts `path` as an alias |

**Features:**
- Current branch and working-tree summary
- Modified/staged/untracked file listing
- Auto-refresh at the configured interval

---

## Server URL Detection

trm automatically scans terminal output for local dev-server URLs (e.g. `localhost:3000`, `127.0.0.1:8080`) and shows them in a banner at the top of the pane. This works across all terminal panes without any configuration.

When a single URL is detected, a blue pill appears at the top of the pane. Click it to open the URL in an inline webview pane, or shift-click to copy the URL to your clipboard.

When multiple URLs are detected, clicking the pill opens a dropdown listing each URL. Click any row to open it, or shift-click to copy.

### Custom patterns

By default, trm matches `localhost`, `127.0.0.1`, `0.0.0.0`, and `[::1]` URLs with a port number. You can add extra regex patterns via the `patterns` field on any `[[panes]]` block. Custom patterns are checked before the built-in ones.

```toml
[[panes]]
type = "terminal"
title = "Tunnel"
patterns = [
  "https?://\\S+\\.ngrok\\.io",
  "https?://[\\w-]+\\.loca\\.lt",
  "https?://\\S+\\.trycloudflare\\.com",
]
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `patterns` | String[]? | None | Extra regex patterns for server URL detection. Each string is a case-insensitive regular expression. Matches are normalized to include an `http://` scheme if missing |

**Features:**
- Automatic detection of `localhost`, `127.0.0.1`, `0.0.0.0`, `[::1]` URLs with ports
- Custom regex patterns via config for tunnels, ngrok, localtunnel, etc.
- Multiple URLs per pane with dropdown selector
- Click to open in inline webview pane
- Shift-click to copy URL to clipboard
- URLs persist even after server output scrolls off screen
- `0.0.0.0` is automatically normalized to `localhost`

---

## Service Plugin Architecture

Service plugins are overlay plugins that monitor terminal output and optionally render floating UI on top of terminal panes. Unlike pane plugins (which occupy a grid cell), service plugins run alongside terminal panes without taking up any layout space. They are used for ambient features such as detecting server URLs, signaling when Claude Code needs attention, or showing which panes have a watched process running.

### Protocols

The service plugin system is built on four protocols and a capability enum.

**`ServicePlugin`** is the base protocol. Every service plugin must provide a `pluginId`, a `displayName`, and a set of `requiredCapabilities`. It defines a three-step lifecycle:

1. `configure(registry:)` -- called once after registration so the plugin can store a reference to the registry.
2. `start()` -- called after all plugins are registered, so the plugin can begin work.
3. `stop()` -- called to release resources when the plugin is torn down.

```swift
@MainActor
protocol ServicePlugin: AnyObject {
    var pluginId: String { get }
    var displayName: String { get }
    static var requiredCapabilities: Set<PluginCapability> { get }
    func configure(registry: ServicePluginRegistry)
    func start()
    func stop()
}
```

**`ObservableServicePlugin`** is adopted by plugins that are also `ObservableObject`. When a plugin's `@Published` state changes, the registry forwards the change via `objectWillChange` so that SwiftUI views observing the registry automatically re-render.

**`TerminalOutputSubscriber`** receives callbacks from the shared `TerminalOutputScanner` whenever the visible text of a terminal pane changes. The scanner polls pane content on a 2-second timer, computes per-pane SHA-256 hashes, and only notifies subscribers when content actually differs from the last poll.

```swift
@MainActor
protocol TerminalOutputSubscriber: AnyObject {
    func terminalOutputDidChange(paneIndex: Int, text: String, hash: String)
    func terminalPaneDidClose(paneIndex: Int)
}
```

**`ServicePluginOverlayProvider`** allows a plugin to render a SwiftUI overlay on top of a terminal pane. The plugin returns an `AnyView?` for each pane index and declares an `overlayAlignment` (e.g. `.top`, `.topLeading`, `.bottomLeading`) that controls where the overlay is anchored within the pane.

```swift
@MainActor
protocol ServicePluginOverlayProvider: ServicePlugin {
    func overlayView(forPane index: Int) -> AnyView?
    var overlayAlignment: Alignment { get }
}
```

### Plugin Capabilities

Each plugin declares the capabilities it needs via `requiredCapabilities`. At registration time, the registry grants all requested capabilities except `networkAccess`, which is denied by default. Plugins can check at runtime whether a specific capability was granted via `registry.hasCapability(_:pluginId:)`.

---

## Service Plugin Registry

The `ServicePluginRegistry` manages all service plugins for a window. It is an `ObservableObject` so SwiftUI views can observe it directly. The registry:

- **Registers plugins** -- stores each plugin by its `pluginId`, computes granted capabilities, calls `configure(registry:)`, and auto-subscribes `TerminalOutputSubscriber` conformers to the shared `TerminalOutputScanner`.
- **Forwards `objectWillChange`** -- when any `ObservableServicePlugin` publishes a change, the registry re-publishes it so a single `@ObservedObject` binding in SwiftUI is sufficient.
- **Discovers overlay providers** -- the `overlayProviders` property returns all registered plugins that conform to `ServicePluginOverlayProvider`, so the view layer can iterate and render overlays.
- **Manages lifecycle** -- `startAll()` starts every registered plugin, `stopAll()` stops them and removes scanner subscriptions, and `unregisterAll()` tears down everything and clears all state.

---

## Built-in Service Plugins

trm ships with three service plugins that are registered automatically when a window opens.

### Server URL Detector (`server_url_detector`)

Scans terminal output for local dev-server URLs and shows a clickable banner at the top of the pane.

| Property | Value |
|----------|-------|
| Plugin ID | `server_url_detector` |
| Required capabilities | `terminalOutputRead` |
| Overlay alignment | `.top` |

**How it works:**

The plugin receives terminal content changes via `TerminalOutputSubscriber`. On each change it runs all regex patterns against the visible text and extracts unique URLs ordered by position.

Built-in regex patterns match:

- Full URLs: `http(s)://localhost:PORT`, `http(s)://127.0.0.1:PORT`, `http(s)://0.0.0.0:PORT`, `http(s)://[::1]:PORT`
- WebSocket URLs: `ws(s)://` variants of the above
- Bare host:port: `localhost:PORT`, `127.0.0.1:PORT`, `0.0.0.0:PORT`

URL normalization rules:

- Trailing punctuation (`.`, `,`, `;`) is stripped.
- A bare host:port without a scheme gets `http://` prepended.
- `0.0.0.0` is rewritten to `localhost`.

Custom patterns can be added via `setCustomPatterns()`, which compiles user-supplied regex strings from the `patterns` field in `trm.toml`. Custom patterns are checked before the built-in ones.

**Overlay:** A blue pill at the top of the pane. Click to open the URL in an inline webview pane. Shift-click to copy the URL to the clipboard. When multiple URLs are detected, clicking the pill opens a dropdown listing each URL.

### Claude Attention (`claude_attention`)

Shows a pulsing sparkle icon when Claude Code finishes generating and is waiting for user input.

| Property | Value |
|----------|-------|
| Plugin ID | `claude_attention` |
| Required capabilities | `terminalOutputRead` |
| Overlay alignment | `.topLeading` |

**How it works:**

On `start()`, the plugin subscribes to `.trmClaudeNeedsAttention` notifications. When a notification arrives with a `paneIndex` in its `userInfo`, that pane is added to the `attentionPanes` set. The icon auto-dismisses when terminal output changes for that pane (i.e., the user types something), detected via `terminalOutputDidChange`.

**Overlay:** An orange rounded-rectangle badge with a sparkle icon (`SF Symbols: sparkle`), anchored at the top-leading corner of the pane. The icon pulses continuously with a scale and opacity animation.

### Send Text Indicator (`send_text_indicator`)

Shows an indicator pill when a watched process (e.g. `claude`) is running in a pane, signaling that text can be sent to that pane via the Text Tap socket.

| Property | Value |
|----------|-------|
| Plugin ID | `send_text_indicator` |
| Required capabilities | `terminalOutputRead` |
| Overlay alignment | `.bottomLeading` |

**How it works:**

Each time terminal output changes, the plugin runs asynchronous process detection. It looks up the shell PID for the pane, then uses `pgrep -P <pid>` to find child processes and `ps -o comm=` to get their names. The search is recursive -- grandchild processes are checked too. If any process name matches an entry in `watchedProcessNames` (currently hardcoded to `["claude"]`), the pane is marked as active.

**Overlay:** A teal capsule pill at the bottom-leading corner of the pane showing the matched process name (e.g. "claude") with a link icon.

---

## Hot-Reload

When `trm.toml` changes on disk, service plugins are automatically torn down and re-created with the updated configuration. No restart is required.

**File watching:** A `DispatchSource` file system object source monitors the config file for `.write`, `.rename`, and `.delete` events.

**Debouncing:** A 300ms debounce timer coalesces rapid saves so the reload only fires once.

**Atomic save handling:** Editors like vim save files atomically by deleting the original and renaming a temporary file. When a `.delete` or `.rename` event is detected, the watcher tears itself down and re-opens the file after a 500ms delay, giving the editor time to finish writing.

**Reload sequence:**

1. `reloadServicePlugins()` calls `servicePluginRegistry.unregisterAll()`, which stops all plugins, removes scanner subscriptions, and clears all state.
2. The config file is re-read from disk.
3. `setupServicePlugins()` creates fresh plugin instances with the new configuration.
4. `servicePluginRegistry.startAll()` starts the new plugins.

The `TerminalOutputScanner` continues running throughout the reload -- only its subscriber list changes. SwiftUI views update automatically because `unregisterAll()` and the subsequent registrations trigger `objectWillChange` on the registry.

---

## Plugin Capability Reference

| Capability | Description | Default |
|------------|-------------|---------|
| `terminalOutputRead` | Read terminal pane output via the shared scanner | Granted |
| `networkAccess` | Make outbound network requests | **Denied** |
| `fileSystemRead` | Read from the local file system | Granted |
| `clipboardWrite` | Write to the system clipboard | Granted |
| `userNotifications` | Post user-facing notifications | Granted |

All capabilities except `networkAccess` are granted automatically when a plugin is registered. The registry removes `networkAccess` from every plugin's requested set at registration time. Plugins can check at runtime whether a capability was granted via `registry.hasCapability(_:pluginId:)`.

---

## Mixing Plugin Types

You can combine any plugin types in a single session. Here is an example that uses five different types in a 2x3 grid:

```toml
title = "Full Stack Dev"
rows = 2
cols = 3

[[panes]]
type = "terminal"
title = "Shell"
cwd = "~/projects/myapp"
watermark = "DEV"

[[panes]]
type = "terminal"
title = "Server"
initial_commands = ["npm run dev"]

[[panes]]
type = "webview"
title = "Preview"
url = "http://localhost:3000"

[[panes]]
type = "file_browser"
title = "Files"
path = "~/projects/myapp"

[[panes]]
type = "git_status"
title = "Git"
repo = "~/projects/myapp"

[[panes]]
type = "system_info"
title = "System"
```
