# Changelog

Versioning: the trm version lives in the `VERSION` file at the repo root
(shown as CFBundleShortVersionString). The **build number** is the git
commit count (`git rev-list --count HEAD`) — monotonically increasing and
unique per commit — stamped into the app together with the commit hash at
build time. Check yours with `trm version` or the About window. Build
numbers below mark the build at which each release's features shipped;
`≈` marks numbers reconstructed from commit dates for releases tagged
retroactively.

## 0.3.0 (Unreleased, builds 14407+)

### Added

- **Versioning & build numbers**: The app now reports a real version (from the `VERSION` file), a monotonically increasing build number derived from the git commit count, and the commit hash — visible in the About window and via the new `trm version` CLI command. Every feature can now be traced to the build that shipped it.
- **Drag-to-resize pane dividers**: Grab any divider between grid panes (or stack sub-panes) and drag to resize. Divider hit areas and visuals were reworked so dividers stay visible and easy to target.
- **Claude prompt pill**: Panes running Claude Code show the last human prompt as a small pill at the top of the pane (reads the conversation JSONL for the pane's project directory), so you can tell at a glance what each agent was asked to do.
- **Pane drag-to-stack by default**: Dropping a dragged pane onto another now stacks them (layers); hold Option while dropping to swap positions instead.
- **Drag panes between windows**: Dragging a pane onto a pane in another trm window now transfers it there — stacking onto the hovered pane by default, or (with Option held) landing as its own grid cell.
- **Agent Overview pane**: Right-click a terminal pane running a coding agent → **Show Agent Overview** (also in the command palette) to open a native (non-webview) reading pane pinned beside it. It shows what you last asked, a live activity strip of the agent's tool calls with a spinner while a call is in flight, and the agent's last message rendered for reading: prose with inline markdown and comfortable line spacing, fenced code in its own monospaced block that scrolls horizontally. A **B** button toggles bionic reading (prose only); the setting persists. Supports **Claude Code and Codex** — the overview binds to the agent process running in *that* pane (process-tree walk + open-file/birth-time correlation), so two agents sharing a working directory each get their own overview rather than whichever session wrote last. The overview is constrained to sit adjacent to its agent's pane: drag its grab bar onto the terminal pane (or use its context menu) to place it right/left/above/below, where above/below give it its own full-width row. It cannot be detached to another window, closes with its terminal, and is saved in session TOML (`pane_type = "agent_overview"`, `overview_of`, `overview_placement`) so restore brings it back.
- **Click-to-focus agent notifications**: Notifications sent through the Text Tap `notify` action (e.g. the Claude Code hook in `scripts/claude-notify-trm.sh`) are now first-class trm notifications attached to the pane they came from — clicking the banner raises that window and focuses the pane, instead of just bringing the app forward. The `notify` action accepts an optional `"pane"` field; hook scripts pass `$TRM_PANE_ID` so the right pane is credited even with several agents running at once (previously the pane was guessed from the first connected Text Tap client, which picked the wrong pane). Notifications are suppressed while the originating pane is already focused. `scripts/claude-notify-trm.sh` now also reports the real hook message, handles the `Stop` hook ("Claude finished working"), and falls back to an AppleScript banner when trm isn't running.
- **Top/bottom stack drop placement**: The drop preview now follows the cursor — hover the top half of a pane to stack the dragged pane above it, the bottom half to stack below. Previously only the bottom slot was offered.

- **LLM-built extensions**: Describe an extension in plain language — from the command palette ("Create Extension...") or `trm ext create "<description>"` — and trm's configured LLM (Anthropic/OpenAI/Ollama/LM Studio) generates, validates, dry-runs, and (after you confirm its capability list) installs it. Two tiers:
  - **Rules** (preferred): declarative if-this-then-that TOML — triggers (output regex per pane/watermark, command finished, pane closed, agent attention, context-usage threshold, interval) → actions (send command, notify, set watermark/title, focus/spawn/close pane, run shell, open URL). Evaluated natively with per-rule cooldowns and regex input caps: no code runs, nothing can leak.
  - **Programs**: any-language executables (Python, Zig, Rust, …) speaking newline-delimited JSON over stdio, supervised with crash-restart backoff, a memory watchdog (SIGKILL over the manifest cap), a CPU-seconds ulimit, and **enforced** per-extension capabilities (`send_input`, `pane_control`, `pane_decorate`, `notifications`) — an extension can only do what its manifest declares, and repeated violations kill it. New `metric_pill` overlay template for quota-style displays.
  Extensions live in `~/Library/Application Support/trm/extensions/<name>/extension.toml`, hot-reload on edit, and can be toggled per-pane like built-in plugins. Ships with an example: **agent-quota** (`examples/extensions/agent-quota/`), which shows Claude Code's context-window usage as a colored pill fed by the existing context-usage hook pipeline.
- **Live layout sync for mirror UIs**: Layout edits in a window now propagate live (~1 s) to every `trm mirror` UI attached to it. Each window carries a stable `window_id` in its checkpoint TOML plus the primary's `text_tap_socket`; a mirror connects to that socket as a client, subscribes with `{"type": "layout_subscribe", "window": ...}`, and receives debounced full-snapshot `layout_update` messages (the serialized session TOML, with a monotonic revision) whenever pane order, grid shape, stacks, agent overviews, or pane sizes change. The mirror applies snapshots **in place** — panes are matched by identity (terminals by `zmx_session`) and reordered/restacked/resized without rebuilding PTY views; only genuinely added or removed panes are created or dropped. The primary owns the layout: mirrors have local layout editing disabled, never kill shared zmx daemons, and no longer run the checkpoint autosave (previously a mirror process's 30 s timer clobbered the primary's `_autosave_*` files). If the primary dies, mirrors keep the last layout with PTYs live via zmx, then resync automatically when a primary returns. Pane size fractions (`row_fractions`, `col_fractions`, `stack_fractions`) are now serialized in checkpoint TOMLs, and the Text Tap socket gained a `swap_panes` action (`{"type": "action", "action": "swap_panes", "pane_a": N, "pane_b": M}`) to swap panes by visual index. Details: `docs/server-backed-ui.md`.
- **Server-backed UI by default (disposable trm)**: `session_persistence` now defaults to **on** — every pane runs under a zmx session daemon, window layouts checkpoint automatically every 30 s (not just at quit), and at launch trm **re-attaches instantly with no dialog** when the saved layout is fully backed by live daemons. Kill the app — even `kill -9` — relaunch, and everything is back with processes untouched, tmux-style. Set `session_persistence = false` in trm.toml for the old in-process behavior. New CLI: **`trm mirror`** opens a second UI attached to the same live window (zmx multi-client — verified: both UIs stream the same PTYs, either can be killed freely), and **`trm attach-remote <ssh-host>`** opens a local, GPU-rendered trm showing a remote machine's window with panes attached over SSH. Explicit `TRM_CONFIG` launches that only attach to live daemons also skip the startup dialog. Architecture + remaining work: `docs/server-backed-ui.md`.
- **Detachable sessions (tmux-style persistence)**: With `session_persistence = true` in trm.toml, every terminal pane runs under a per-session daemon (powered by a bundled, vendored [zmx](https://github.com/neurosnap/zmx) built against trm's own ghostty-vt). Quitting or closing trm only *detaches* — shells and running processes keep going in the background, and relaunching reattaches with the terminal state replayed. Explicitly closing a pane kills its session; "Terminate All & Quit" kills everything. Sessions can also be attached from any terminal (`trm attach <name>`), shared by multiple clients simultaneously, or attached remotely over SSH (`ssh -t host /Applications/trm.app/Contents/MacOS/zmx attach <name>`). At startup, trm offers to attach any running sessions that no saved window references. New CLI: `trm sessions`, `trm attach <name>`, `trm kill-session <name>`. Detach from an attached terminal with `ctrl+\`. (The previous half-built `trm-server` daemon scaffold — which pointed at a binary that was never built — has been removed.)

- **Quick Terminal Here**: New menu item `File → Quick Terminal Here` (Cmd+D) toggles the Quick Terminal; when opening a fresh shell, it starts in the focused trm pane's current working directory instead of `$HOME`.
- **Watermark hover shine**: Moving the mouse into or out of a pane triggers a single watermark flash — the same highlight animation used when a pane gains focus. Works for both regular and stacked sub-panes.
- **Tap a pane's bar to expand it**: Single-clicking the grab handle at the top of a pane (the bar revealed when you hover the pane's top edge), or a stacked sub-pane's grip bar, now peeks (expands) that pane to half the window width at full height so you can see more of its contents. Click it again — or the dimmed background — to put it back. Dragging the same handle still moves/stacks the pane.
- **Cmd+click to peek a pane**: Holding Cmd and clicking anywhere in a pane now peeks (expands) that pane to half the window width at full height, the same overlay as tapping its grab bar. Cmd+click the pane again, or click the dimmed background, to put it back. The click is consumed, so the terminal never sees a stray mouse event.
- **`surface.list` pid field**: Each surface entry now includes a `"pid"` field with the child process ID of the pane.
- **Startup session dialog**: trm now shows a dialog at launch whenever there is an auto-saved session to restore. The dialog shows the pane count, process list, and save timestamp. When `--config` was also passed, a third button lets you open that file instead. Previously the dialog only appeared when both an autosave and `--config` were present.
- **`start-claude` script**: `scripts/start-claude.sh` launches trm with a multi-pane layout and automatically starts Claude Code in the last pane, then focuses it after a configurable delay (default 3 s). Options: `--panes N`, `--delay S`, `--session PATH`, `--no-focus`.
- **Claude session**: `sessions/claude.toml` — a 2×2 grid session where the bottom-right pane auto-starts `claude`.

### Performance

- **Live Summary no longer reads full scrollback**: The Live Summary poll (every 8 s when enabled) read the *entire* scrollback of every pane on the main thread, hashed it, and sent it untruncated to the LLM. It now reads only the visible viewport — the same pattern the output scanner already used — eliminating a main-thread stall and the risk of re-introducing the full-scrollback leak.
- **LLM pane context reads viewport only**: `buildPaneContext()` (command palette AI) read each pane's full scrollback even though the system prompt only keeps the last 30 lines. It now reads the visible viewport.
- **Context usage tracking is O(1) per update**: The 1 Hz context-usage poll re-scanned the entire snapshot history on every change and re-encoded the full history JSON on the main thread every ~10 s. Aggregates are now bumped incrementally (full recompute at most every 5 min), history saves are time-throttled (≥60 s apart) and encoded off the main thread, and in-memory snapshots are capped at 50k entries.
- **Claude prompt pill: one process scan per tick, app-wide**: Each window's `ClaudePromptPlugin` enumerated every PID on the system (hundreds of syscalls) every 3 s. The scan result is now cached app-wide with a 2.5 s TTL, so N windows cost one scan instead of N.
- **Text Tap accessor polls throttled**: The C-API status accessors (`termania_text_tap_is_active`, `..._app_name*`, `..._client_count`, `..._active_panes`) each ran a full socket poll (accept + per-client read syscalls) and are called per pane per SwiftUI render pass. Accessor-driven polls are now throttled to at most one per 100 ms; the main event-loop poll is unchanged.
- **Keybinding trace logs downgraded**: Leftover `[newtab-trace]` `log.info` calls on every keybinding action (per-keystroke formatting + log I/O) are now `log.debug`.

### Fixed

- **Context usage pill appeared in every window**: The Claude Code context reading is stored process-wide, but each window polled it and rendered the pill unconditionally — so a fresh window with no agent in it showed the context usage of an agent running in a *different* window, and the pill never disappeared once set. Context readings are now attributed to a pane: `context_update` accepts a `"pane"` field (`scripts/claude-context-trm.sh` passes `$TRM_PANE_ID`, falling back to the sender's `mark_connected` pane), exposed via the new `termania_context_pane_id` export, and a window only shows the pill for panes it owns. Readings also expire after 30 minutes, so an agent that goes idle stops leaving a stale number on screen. Readings with no pane attribution (older hook scripts) still show everywhere, as before.
- **Invisible stack sub-pane dividers and typing lag**: Stack sub-pane dividers rendered invisibly, and per-keystroke work in hot paths caused typing lag; both fixed.
- **Phantom selection on pane focus**: Focusing a pane no longer creates a phantom text selection.
- **Pane drag bar**: Dragging by the grab bar now uses an AppKit `NSDraggingSource` (the SwiftUI `.draggable` implementation dropped drags); grip-bar drags are reliable.
- **`GridPane.runShellCommand` uses `/bin/sh`**: was `/bin/zsh -lc`, which sourced user login config and broke on some setups.
- **macOS build on Xcode 26.x + Zig 0.15.2**: replaced `libtool` with a custom `MergeStaticLibsStep` and fixed the xcframework output path resolution.
- **Removed the screen_capture plugin pane** (unused; its registry entries and tests are gone).
- **FFI header drift for `termania_pane_info_s` / `termania_cell_s`**: The C header declarations were out of sync with the Zig structs (`termania_pane_info_s` was missing the leading `pane_id` field; `termania_cell_s` had the color-type byte before the r/g/b triple instead of after). Both APIs are currently unused from Swift, so this was latent — but it's the same class of ABI mismatch that previously caused a release-only crash and a multi-GB leak. The header now matches the Zig layout field-for-field.
- **Text Tap send payloads no longer vanish on truncation**: A send payload longer than 1024 bytes could be cut mid-UTF-8-codepoint, making the whole string undecodable — Swift then silently sent `""` while the client had already received `{"status":"queued"}`. Truncation now lands on a codepoint boundary (also applied to notification title/body), and Swift decodes lossily instead of dropping to empty.
- **Text Tap oversized-message resync**: A JSON line larger than the 4 KB client buffer was silently discarded and its tail bytes were then parsed as a fresh (corrupt) message. The server now replies `{"error": "message too large"}` and discards up to the line's terminating newline so the next message re-aligns cleanly.
- **cmux `id` echoed unescaped**: A request `id` containing quotes/backslashes produced malformed JSON in every cmux response. The id is now JSON-escaped once at extraction.
- **Duplicate URLs in the server-URL banner**: The bare `host:port` pattern re-matched the authority inside already-matched full URLs, so `https://localhost:8443`, `ws://` URLs, or URLs with a path (e.g. `http://127.0.0.1:8080/api`) surfaced a bogus second `http://host:port` entry in the banner. Matches contained inside an already-accepted match are now skipped. (Found by re-enabling the Swift test suite, which had been silently broken — see below.)
- **Stale plugin-registry tests**: Removing the `screen_capture` pane left the registry with 9 builtins, but its tests still asserted 10 (and force-unwrapped index 9, aborting the test binary with signal 6). Tests now match the registry.
- **`zig build test` ran xcodebuild against the old scheme**: The build's `xcodebuild test` step still targeted `-scheme Ghostty`, which no longer exists after the project rename to `trm.xcodeproj` — every full test run failed that step. It now uses the `trm` scheme.
- **`zig build test` hung forever**: The "server broadcast to subscribed clients" test set its check socket non-blocking with `fcntl(F_SETFL, ... | SOCK.NONBLOCK)` — but `SOCK.NONBLOCK` is a socket-type flag, not the `O_NONBLOCK` file-status flag, so the fd stayed blocking and the final `read()` (on a socket that never receives data) hung the entire test run. Now sets the real `O_NONBLOCK` (0x0004), matching what `start()` already does.
- **Text Tap queued-command leak on shutdown**: `TextTapServer.deinit` freed the command list but not the heap-allocated strings of commands still queued between the last drain and teardown.
- **`termania_swap_overlay` double-free window**: The overlay swap re-inserted both panes via `put()`; if the second insert failed, two keys pointed at one pane (double-freed on deinit) while the other leaked. The swap now exchanges the stored values in place.
- **Timer/fd leak when a window controller dies without closing**: `BaseTerminalController.deinit` now invalidates the scrollback-snapshot timer and cancels the config-file watcher; previously these were only torn down in `windowWillClose`.
- **Unbounded memory growth (multi-GB leak) — `ghostty_surface_free_text` ABI mismatch**: The Zig export `ghostty_surface_free_text` took a single `*Text` argument, but the C header and all Swift call sites pass two arguments (`surface, &text`). On arm64 the surface pointer was bound to the text parameter, so the deinit ran against the wrong struct and the actual text buffer was **never freed**. Every `ghostty_surface_read_text` call leaked its buffer — and because the `TerminalOutputScanner` reads each pane's viewport on a repeating poll, this leaked ~1.3 MB/min (~6.7 GB over 4 days). The Zig signature now matches the header (`surface: *Surface, ptr: *Text`), so the buffer is freed correctly. Root-caused with `malloc_history` on a live process (1 ALLOC / 0 FREE on the scanner's allocations).
- **Unbounded memory growth (multi-GB leak)**: The periodic scrollback-snapshot timer (every 30 s, per window) read and re-serialized the *entire* scrollback of every pane on every tick — even when nothing had changed and even while the window sat idle. Each full-scrollback read allocated a large heap buffer (hundreds of KB per pane) that accumulated without bound, growing trm's memory footprint to ~10 GB over multi-day uptime. The snapshot now skips a pane whose visible viewport is unchanged since its last snapshot (a cheap, bounded fingerprint), so idle panes cost nothing and a pane is only re-read when its content actually changes. Explicit session auto-save still forces a full snapshot of every pane. Diagnosed with `malloc_history` on a live release process.
- **`surface.focus` RPC**: The `surface.focus` cmux RPC now correctly focuses the target pane. Three bugs fixed: (1) pane ID lookup in `handleFocusPane` fell back to grid index when `paneId` is nil (matching the same logic as `surface.list`), (2) `focusSurface` now always calls `NSApp.activate` so the trm window comes to front even when another app is focused, (3) `TerminalWindowRestoration` skips macOS native window restoration when `TRM_CONFIG` is set, preventing stale surfaces from a prior session from interfering with a freshly-requested config.
- **`surface.list` duplicate responses**: When multiple windows exist and none is the main window (e.g. trm is in the background), only the first (oldest) controller now responds to cmux queries. Previously both controllers responded, producing duplicate surface entries.
- **Crash opening a new pane (Cmd-T) in release builds**: The Zig `Surface.Options` struct was missing the trailing `reconnect_session_id` field that exists in the `ghostty_surface_config_s` C struct (`include/ghostty.h`) and the Swift `SurfaceConfiguration`. When a split inherited its config via `ghostty_surface_inherited_config`, Swift read that field from uninitialized memory past the end of the Zig struct. In ReleaseFast that memory was garbage (a non-nil bogus pointer), so `String(cString:)` called `strlen` on it and crashed with `EXC_BAD_ACCESS`. Debug builds zero-fill `undefined` memory, so the field read as nil and the bug was invisible there. The field is now declared on the Zig struct so the ABI matches.

## 0.2.4 (2026-03-12, build 14406)

### Added

- **cmux-compatible API**: Dual-protocol support on the Text Tap socket. Tools built for cmux automatically work with trm. Supports `system.ping`, `system.capabilities`, `system.identify`, `surface.list`, `surface.send_text`, `surface.send_key`, `workspace.list`, `workspace.current`, and `notification.create`. Phase 2 methods (`surface.list`, `system.identify`) use a response queue through Swift for live data.
- **cmux CLI subcommands**: New `trm ping`, `trm list-surfaces`, `trm identify`, `trm capabilities`, `trm send-key`, and `trm send-text` commands using the cmux protocol.
- **cmux env vars**: Child processes receive `CMUX_SOCKET_PATH`, `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `TRM_SOCKET_PATH`, and `TRM_PANE_ID` environment variables for tool integration.

## 0.2.3 (2026-03-08, build 14400)

### Added

- **Notification rings**: Panes needing attention now glow with an animated blue ring border that pulses until the pane is focused. Replaces the small icon-only indicator.
- **CLI socket API**: Full-featured `trm` CLI with subcommands: `notify`, `list-panes`, `send`, `send-all`, `send-command`, `mark-connected`, `mark-disconnected`, `open-browser`, `status`, and `raw`. Communicates over the Text Tap Unix socket.
- **Split browser pane**: Open a WebView alongside terminal panes with Cmd+Shift+L. Accessible from the View menu and via `trm open-browser --url URL`.
- **Agent browser integration**: Scriptable WebView API for AI agents. New socket actions: `browser_eval` (execute JS), `browser_navigate`, `browser_snapshot` (accessibility tree), `browser_click`, `browser_fill`. CLI subcommands: `browser-eval`, `browser-navigate`, `browser-snapshot`, `browser-click`, `browser-fill`.

### Fixed

- **Notification pane ID**: Notifications now correctly identify the source pane instead of always using the focused pane.

## 0.2.2 (2026-02-22, build ≈14390)

### Added

- **Cmd+1–9 pane switching**: Cmd+1–9 now switches between panes in the grid instead of macOS window tabs. Intercepted directly in key event handling for minimal latency. Previous/next (Cmd+[/]) wrap around. Falls back to tab switching when only one pane exists.
- **Session save/restore**: Grid layout and pane state persist across app restarts, including jagged grid configurations and pane move positions.
- **Text Tap send pipeline**: Route commands through the ghostty surface PTY via Text Tap, enabling external tools to send text to specific panes.
- **Service plugin hot-reload**: Service plugins automatically reload when `trm.toml` config changes.

### Fixed

- **Quick action Enter key**: Quick action buttons now send the Enter keypress (`\r`) as a separate PTY write from the command text, fixing commands not executing in tools like Claude Code.
- **Watermark flash on pane move**: Fixed rapid pane-move causing watermark shine to fire repeatedly by observing notifications directly in WatermarkView.

## 0.2.1 (2026-02-18, build ≈14383)

### Added

- **Quick Actions**: Save frequently-used commands as persistent pill buttons on terminal panes. Select text in the terminal, right-click "Save as Quick Action...", and name it. Actions appear as green pills at the bottom-right of the matching pane — click to run, hover to reveal an X to delete. Stored in `.trm-actions.toml` alongside your `trm.toml`, with file watcher hot-reload and session persistence. Supports pane watermark matching and optional SF Symbol icons.

## 0.2.0 (2026-02-17, build ≈14380)

### Added

- **Server URL detection**: Terminal panes automatically scan output for local dev-server URLs (`localhost`, `127.0.0.1`, `0.0.0.0`, `[::1]` with a port) and display a clickable banner at the top of the pane. Click to open in an inline webview pane, shift-click to copy. When multiple URLs are detected, clicking the banner opens a dropdown listing each one. Supports custom regex patterns via the `patterns` field in `[[panes]]` config for matching tunnels, ngrok, localtunnel, etc.

## 0.1.0 (2026-02-15, build 14377) — first trm release

### Added

- **Inline webview panes**: HTTP/HTTPS URLs opened from terminal processes (via OSC 8 hyperlink clicks or `open` command) now open in an inline webview pane within the grid instead of the system browser. Each webview pane includes a minimal toolbar with the page title and a close button. Non-HTTP schemes (file://, mailto://) and `.text` kind URLs (config files) retain their previous behavior.
- **Claude Code context usage tracking**: Real-time visibility into Claude Code's context window consumption. A compact bottom-right pill shows current usage percentage with color-coded gauge (green/yellow/orange/red). Tap to expand for token counts, daily/weekly usage totals, and auto-compact warnings. Data flows from Claude Code hooks via Text Tap socket using the new `context_update` message type. Usage history persists across sessions with 7-day retention. Drop-in hook script at `scripts/claude-context-trm.sh`.
- **Native notifications via Text Tap**: New `notify` action in the Text Tap API. External tools (like Claude Code) can send `{"type":"action","action":"notify","title":"...","body":"..."}` to the Text Tap socket, and trm displays a native macOS notification via `UNUserNotificationCenter`. Includes a ready-to-use hook script at `scripts/claude-notify-trm.sh`.
- **CLI install script**: `scripts/install-cli.sh` installs a `trm` command to `/usr/local/bin`.

### Fixed

- **Documents folder permission prompts**: Pane surfaces now default to the home directory when no `cwd` is configured, avoiding repeated macOS TCC permission dialogs on startup.
- **Alt+Tab shows "trm"**: Set `CFBundleName = trm` across all Xcode build configurations. Updated all XIB window titles from "Ghostty" to "trm".
