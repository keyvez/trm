+++
title = "Send to Pane"
description = "Guide to auto-sending commands to AI agent panes in trm from external processes like MCP servers, Flutter apps, and shell scripts."
weight = 6
+++

Send to Pane lets external processes type keystrokes into a trm pane running Claude Code (or any watched process). This enables fully automatic workflows where a Flutter app user sends feedback and Claude picks it up within a second -- no manual `process_queue` call needed.

## How It Works

```
Flutter app user taps "Send Feedback"
  → flan_flutter posts a VM service extension event
  → flan_mcp receives onUserMessageQueued callback
  → TrmPaneBridge connects to /tmp/trm.sock
  → Detects which pane is running Claude (via process tree walk)
  → Sends: {"type":"send","pane":0,"text":"process_queue\r"}
  → trm buffers the command in the Zig C API send queue
  → Swift timer drains the queue every 0.5s
  → Text and Enter are written to the ghostty surface PTY
    (Enter is sent as a separate write after a 50ms delay
     so raw-mode programs like Claude Code process it correctly)
  → Claude Code receives "process_queue" + Enter, executes the tool
  → Messages drain from the Flutter app queue
```

There are two connectors: a **shell script** for manual or scripted use, and a **Dart bridge** that plugs into flan_mcp for automatic triggering.

---

## Prerequisites

- **trm** running with Text Tap enabled (the default)
- A pane running Claude Code (the `send_text_indicator` service plugin will show a teal "flan" pill at the bottom-left when the MCP bridge is connected)
- For the Dart bridge: **flan_mcp** cloned at `~/Documents/Code/flutter/flan_mcp`

Verify trm's socket is up:

```sh
# Should print the number of panes
echo '{"type":"list_panes"}' | nc -U /tmp/trm.sock
```

---

## Option A: Shell Script (Manual Use)

### Setup

The script lives in your project at `scripts/send-to-claude-pane.sh`. It uses Python 3 (ships with macOS) for socket and JSON handling.

**Location:** `~/dev/fasmac/scripts/send-to-claude-pane.sh`

### Usage

```sh
# Send "process_queue" to the Claude pane (default)
./scripts/send-to-claude-pane.sh

# Send a custom command
./scripts/send-to-claude-pane.sh "some_other_command"
```

### What it does

1. Connects to the Text Tap socket at `$TRM_SOCKET_PATH` (defaults to `/tmp/trm.sock`)
2. Sends `{"type":"list_panes"}` to get the pane count
3. Walks the process tree from the caller's PID to find which trm child corresponds to the caller's pane
4. Sends `{"type":"send","pane":N,"text":"process_queue\r"}` to that pane
6. If multiple claude panes are found, lists them with PIDs and prompts you to choose
7. If none are found, prints an error

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TRM_SOCKET_PATH` | `/tmp/trm.sock` | Path to the trm Text Tap socket |

### Example: Wire it to a Claude Code hook

You can trigger this script from a Claude Code hook so it runs after specific events:

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "/Users/gaurav/dev/fasmac/scripts/send-to-claude-pane.sh"
      }]
    }]
  }
}
```

---

## Option B: Dart Bridge (Automatic with flan_mcp)

This is the fully automatic option. When a Flutter app user sends feedback via the flan_flutter overlay, the flan_mcp server receives the event and immediately types `process_queue` into the Claude Code pane.

### Files

Two files were added to flan_mcp (no core changes):

| File | Purpose |
|------|---------|
| `lib/src/trm_pane_bridge.dart` | `TrmPaneBridge` class -- socket connection, pane detection, input sending |
| `bin/flan_mcp_trm.dart` | Separate entry point that wraps `flan_mcp.dart` and adds the bridge |

### How TrmPaneBridge works

- Connects to the trm Unix socket via `dart:io` (`InternetAddress` with `InternetAddressType.unix`)
- Detects the Claude pane using the same `pgrep`/`ps` recursive child-process scan as the shell script
- **Caches** the detected pane index for 5 minutes (re-detects on failure or cache expiry)
- **Debounces** sends with a 500ms window (rapid user messages only trigger one `process_queue`)
- **Reconnects** automatically if the socket drops
- If multiple claude panes are found, logs a warning and uses the first one

### Setup

#### 1. Update the MCP server config

Change your project's `.mcp.json` to use the trm-aware entry point instead of the standard one:

**`~/dev/fasmac/.mcp.json`** (before):

```json
{
  "mcpServers": {
    "flan": {
      "command": "flan_mcp",
      "args": []
    }
  }
}
```

**`~/dev/fasmac/.mcp.json`** (after):

```json
{
  "mcpServers": {
    "flan": {
      "command": "dart",
      "args": [
        "run",
        "/Users/gaurav/Documents/Code/flutter/flan_mcp/packages/flan_mcp/bin/flan_mcp_trm.dart",
        "-l", "INFO"
      ],
      "cwd": "/Users/gaurav/Documents/Code/flutter/flan_mcp"
    }
  }
}
```

This switches from the globally-installed `flan_mcp` binary to the new `flan_mcp_trm.dart` entry point, which has the TrmPaneBridge baked in.

#### 2. Verify the trm session config

Your `trm.toml` needs a pane running Claude Code. The `send_text_indicator` service plugin auto-detects it -- no extra config is needed.

**`~/dev/fasmac/trm.toml`:**

```toml
title = "fasmac"
rows = 2
cols = 2

[[panes]]
title = "Claude"
cwd = "/Users/gaurav/dev/fasmac"
initial_commands = ["claude --dangerously-skip-permissions"]
watermark = "claude"

[[panes]]
title = "backend"
cwd = "/Users/gaurav/dev/fasmac"
initial_commands = ["./run-backend.sh"]
watermark = "backend"

[[panes]]
title = "backend"
cwd = "/Users/gaurav/dev/fasmac"
initial_commands = ["./run-extraction.sh"]
watermark = "extraction"

[[panes]]
title = "frontend"
cwd = "/Users/gaurav/dev/fasmac"
initial_commands = ["./run-frontend.sh"]
watermark = "frontend"
```

The Claude pane (pane 0) will show a teal "flan" pill at the bottom-left once the MCP bridge connects, confirming that the send-to-pane pipeline is active.

#### 3. Launch and test

```sh
# 1. Open trm from the fasmac directory
cd ~/dev/fasmac && trm

# 2. Wait for Claude Code to start in pane 0

# 3. In the Flutter app, connect via flan:
#    Claude calls: connect("ws://127.0.0.1:PORT/ws")

# 4. User taps feedback in the Flutter app overlay

# 5. Watch pane 0 -- "process_queue" should appear as typed input
#    within ~1 second
```

#### 4. Optional: custom socket path

If you changed trm's socket path in `config.toml`:

```toml
[text_tap]
socket_path = "/tmp/my-custom.sock"
```

Pass it to the entry point:

```json
{
  "mcpServers": {
    "flan": {
      "command": "dart",
      "args": [
        "run",
        "/Users/gaurav/Documents/Code/flutter/flan_mcp/packages/flan_mcp/bin/flan_mcp_trm.dart",
        "-l", "INFO",
        "--trm-socket", "/tmp/my-custom.sock"
      ],
      "cwd": "/Users/gaurav/Documents/Code/flutter/flan_mcp"
    }
  }
}
```

Or set the environment variable for the shell script:

```sh
TRM_SOCKET_PATH=/tmp/my-custom.sock ./scripts/send-to-claude-pane.sh
```

---

## CLI Options

`flan_mcp_trm.dart` accepts all the same options as `flan_mcp.dart`, plus one additional flag:

| Flag | Description |
|------|-------------|
| `--help` / `-h` | Print usage |
| `--version` | Print version |
| `--log-level` / `-l` | Log level: `FINEST`, `FINE`, `INFO`, `WARNING`, `SEVERE` |
| `--log-file` | Log to a file instead of stderr |
| `--sse-port` | Run as SSE server instead of stdio |
| `--trm-socket` | Path to the trm Text Tap socket (defaults to `$TRM_SOCKET_PATH` or `/tmp/trm.sock`) |

---

## Debugging

### Check if the socket is alive

```sh
echo '{"type":"list_panes"}' | nc -U /tmp/trm.sock
# Expected: {"pane_count":4}
```

### Check if Claude is detected

The teal "flan" pill at the bottom-left of the pane confirms the MCP bridge is connected. If it's not showing:

- Make sure `flan_mcp_trm.dart` is running (check your `.mcp.json` config)
- Verify the trm socket exists: `ls -la /tmp/trm.sock`
- Check that the `send_text_indicator` service plugin is registered (it is by default)

### Check the bridge logs

Run with `FINEST` logging to see bridge activity:

```json
{
  "mcpServers": {
    "flan": {
      "command": "dart",
      "args": [
        "run",
        "/Users/gaurav/Documents/Code/flutter/flan_mcp/packages/flan_mcp/bin/flan_mcp_trm.dart",
        "-l", "FINEST",
        "--log-file", "/tmp/flan_mcp_trm.log"
      ],
      "cwd": "/Users/gaurav/Documents/Code/flutter/flan_mcp"
    }
  }
}
```

Then tail the log:

```sh
tail -f /tmp/flan_mcp_trm.log
```

You should see messages like:

```
[INFO][TrmPaneBridge] Connected to trm socket at /tmp/trm.sock
[INFO][TrmPaneBridge] Detected Claude pane: 0
[INFO][TrmPaneBridge] Sent "process_queue" to trm pane 0
```

### Test the shell script standalone

```sh
cd ~/dev/fasmac
./scripts/send-to-claude-pane.sh "echo hello"
# Expected: Sent 'echo hello' to pane 0.
```

---

## Architecture

The send pipeline crosses three layers:

1. **Text Tap server** (Zig, `text_tap.zig`) — accepts JSON over the Unix socket, parses `send` messages, and appends them to `pending_commands`.

2. **C API bridge** (Zig, `capi.zig`) — `termania_poll()` drains pending commands and buffers them in a fixed-size send queue on the CApp struct. `termania_drain_send()` pops one entry at a time for Swift to consume.

3. **Swift timer** (`Trm.swift`) — fires every 0.5s, calls `poll()` + `drainSendCommands()`, and posts `NotificationCenter` events to `BaseTerminalController`.

4. **Surface routing** (`BaseTerminalController.swift`) — receives the notification, resolves the target `SurfaceView`, and calls `ghostty_surface_binding_action("text:...")` to write bytes to the PTY master fd.

**Key detail:** trailing `\r` or `\n` is split from the text body and sent as a separate PTY write after a 50ms delay. Programs using raw terminal mode (like Claude Code's ink-based UI) need this separation to distinguish typed text from the Enter key press.

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Socket not found at /tmp/trm.sock` | trm is not running or Text Tap is disabled | Start trm; check `[text_tap] enabled = true` in config.toml |
| `No pane running 'claude' found` | Claude Code hasn't started yet, or the process name doesn't match | Wait for Claude to finish loading; check `pgrep claude` |
| `process_queue` types but nothing happens | flan_mcp is not connected to a Flutter app | Claude needs to call `connect("ws://...")` first |
| Debounced sends | Multiple rapid user messages | Expected behavior -- only one `process_queue` per 500ms. The tool drains all queued messages at once |
| Bridge reconnects frequently | trm was restarted | Normal -- the bridge auto-reconnects and re-detects the pane |
