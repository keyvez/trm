+++
title = "Text Tap API"
description = "Protocol reference for trm's Text Tap API: a Unix domain socket interface for external process integration."
weight = 5
+++

The Text Tap API is a Unix domain socket server that lets external processes subscribe to terminal output, send input to panes, and execute structured actions. It enables scripting, automation, and integration with external tools.

## Configuration

```toml
[text_tap]
enabled = true
socket_path = "/tmp/trm.sock"
```

When `enabled` is `true` (the default), trm listens on the specified Unix domain socket. Any process on the system can connect and interact with trm using the newline-delimited JSON protocol described below.

## Protocol

All communication uses **newline-delimited JSON** over a Unix domain socket. Each message is a single line of JSON terminated by `\n`.

### Connection

Connect to the socket using any Unix domain socket client:

```sh
# Using socat
socat - UNIX-CONNECT:/tmp/trm.sock

# Using netcat (if it supports Unix sockets)
nc -U /tmp/trm.sock
```

Or programmatically in Python:

```python
import socket
import json

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("/tmp/trm.sock")

def send(msg):
    sock.sendall((json.dumps(msg) + "\n").encode())

def recv():
    data = b""
    while not data.endswith(b"\n"):
        data += sock.recv(4096)
    return json.loads(data.decode())
```

---

## Client-to-Server Commands

### list

List the number of available panes.

```json
{"list": true}
```

**Response:**

```json
{"panes": 9}
```

### subscribe

Subscribe to live content updates from panes. New clients are automatically subscribed to all panes.

```json
// Subscribe to all panes
{"subscribe": "all"}

// Subscribe to a specific pane (0-indexed)
{"subscribe": 0}
```

Once subscribed, the server sends content updates whenever the pane's visible content changes (throttled to at most one update per 250ms per pane).

### unsubscribe

Stop receiving updates from a specific pane.

```json
{"unsubscribe": 0}
```

### send

Send raw input text to one or more panes. The input is written directly to the pane's PTY, so include `\r` for Enter.

```json
// Send to a specific pane
{"send": 0, "input": "ls -la\r"}

// Send to all panes
{"send": "all", "input": "echo hello\r"}
```

**Response:**

```json
{"ok": true}
```

### action

Execute a structured `TermaniaAction`. This is the most powerful command, supporting pane lifecycle management, metadata changes, navigation, and more.

```json
{"action": {"type": "send_command", "pane": 0, "command": "ls -la"}}
```

**Response:**

```json
{"ok": true}
```

---

## Server-to-Client Messages

### Content updates

Sent to subscribed clients when a pane's visible content changes.

```json
{"pane": 0, "content": "user@host:~$ ls\nDocuments  Downloads  Desktop\nuser@host:~$ "}
```

### Pane count

Response to a `list` command.

```json
{"panes": 9}
```

### Acknowledgment

Response to `send` and `action` commands.

```json
{"ok": true}
```

### Error

Response when an `action` command has an invalid format.

```json
{"error": "invalid action format"}
```

---

## TermaniaAction Reference

The `action` command accepts any `TermaniaAction` as its value. These are the same actions that the LLM integration uses internally.

### Terminal I/O

#### send_command

Send a command to a specific pane (appends `\r` automatically).

```json
{"action": {"type": "send_command", "pane": 0, "command": "ls -la"}}
```

#### send_to_all

Send a command to all terminal panes.

```json
{"action": {"type": "send_to_all", "command": "clear"}}
```

### Pane Metadata

#### set_title

Rename a pane's title bar.

```json
{"action": {"type": "set_title", "pane": 0, "title": "My Shell"}}
```

#### set_watermark

Set a large background watermark on a pane.

```json
{"action": {"type": "set_watermark", "pane": 0, "watermark": "PROD"}}
```

#### clear_watermark

Remove a pane's watermark.

```json
{"action": {"type": "clear_watermark", "pane": 0}}
```

### WebView Control

#### navigate

Navigate a webview pane to a new URL.

```json
{"action": {"type": "navigate", "pane": 3, "url": "https://example.com"}}
```

### Notes Control

#### set_content

Set the text content of a notes pane.

```json
{"action": {"type": "set_content", "pane": 4, "content": "Updated notes content"}}
```

### Pane Lifecycle

#### spawn_pane

Create a new pane. All fields except `pane_type` are optional.

```json
{"action": {
    "type": "spawn_pane",
    "pane_type": "terminal",
    "title": "New Shell",
    "command": "/bin/bash",
    "cwd": "~/projects",
    "watermark": "NEW"
}}
```

Other optional fields: `url` (for webview), `content` (for notes), `row`.

#### close_pane

Close a pane by index.

```json
{"action": {"type": "close_pane", "pane": 2}}
```

#### replace_pane

Replace a pane's type in-place (e.g., swap a terminal for a webview).

```json
{"action": {
    "type": "replace_pane",
    "pane": 0,
    "pane_type": "webview",
    "title": "Docs",
    "url": "https://docs.rs"
}}
```

### Layout

#### swap_panes

Swap two panes' positions in the grid.

```json
{"action": {"type": "swap_panes", "a": 0, "b": 4}}
```

#### focus_pane

Focus a specific pane.

```json
{"action": {"type": "focus_pane", "pane": 2}}
```

### User Communication

#### message

Display a message to the user (informational, no side effects on panes).

```json
{"action": {"type": "message", "text": "Build completed successfully!"}}
```

### Notifications

#### notify

Show a native macOS notification with a title and body. Useful for external tool hooks (e.g. Claude Code "waiting for input" notifications).

```json
{"type": "action", "action": "notify", "title": "Claude Code", "body": "Claude is waiting for your input"}
```

The notification is delivered via `UNUserNotificationCenter` and appears as a standard macOS banner/alert. A ready-to-use hook script is provided at `scripts/claude-notify-trm.sh`.

### context_update

Report Claude Code context window usage to trm. This is designed to be sent by a Claude Code hook script that wraps the hook's stdin JSON as the payload.

```json
{"type": "context_update", "payload": {
    "context_window": {
        "used": 100000,
        "total": 200000,
        "used_percentage": 50
    },
    "session_id": "abc123",
    "hook_type": "PostToolUse"
}}
```

**Payload fields:**

| Field | Type | Description |
|-------|------|-------------|
| `context_window.used` | integer | Tokens consumed in the current context |
| `context_window.total` | integer | Maximum context window size |
| `context_window.used_percentage` | integer | Usage percentage (0-100) |
| `session_id` | string | Claude Code session identifier |
| `hook_type` | string | The hook event type (`PostToolUse`, `PreCompact`, `Stop`) |

When `hook_type` is `"PreCompact"`, trm displays a warning indicator that auto-compaction is imminent.

**Response:**

```json
{"status": "queued"}
```

A ready-to-use hook script is provided at `scripts/claude-context-trm.sh`. Configure it in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "/path/to/trm/scripts/claude-context-trm.sh"}]}],
    "PreCompact": [{"matcher": "", "hooks": [{"type": "command", "command": "/path/to/trm/scripts/claude-context-trm.sh"}]}],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/path/to/trm/scripts/claude-context-trm.sh"}]}]
  }
}
```

### context_usage (TermaniaAction)

The `context_update` message is internally converted to a `context_usage` TermaniaAction:

```json
{"action": {"type": "context_usage", "used_tokens": 100000, "total_tokens": 200000, "percentage": 50, "session_id": "abc123", "is_pre_compact": false}}
```

---

## Example: Automation Script

Here is a complete Python script that connects to trm, lists panes, sends a command, and subscribes to output:

```python
#!/usr/bin/env python3
"""Example Text Tap client for trm."""

import socket
import json
import sys
import time

SOCKET_PATH = "/tmp/trm.sock"

def connect():
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    return sock

def send_msg(sock, msg):
    sock.sendall((json.dumps(msg) + "\n").encode())

def recv_msg(sock):
    data = b""
    while not data.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("Socket closed")
        data += chunk
    return json.loads(data.decode().strip())

def main():
    sock = connect()

    # List panes
    send_msg(sock, {"list": True})
    resp = recv_msg(sock)
    print(f"Panes: {resp['panes']}")

    # Send a command to pane 0
    send_msg(sock, {"send": 0, "input": "echo 'Hello from Text Tap!'\r"})
    resp = recv_msg(sock)
    print(f"Send result: {resp}")

    # Subscribe to pane 0 and print updates
    send_msg(sock, {"subscribe": 0})
    print("Subscribed to pane 0. Listening for updates...")

    try:
        while True:
            msg = recv_msg(sock)
            if "content" in msg:
                print(f"[Pane {msg['pane']}] {msg['content'][:80]}...")
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()

if __name__ == "__main__":
    main()
```

---

## Throttling

Content broadcasts are throttled to at most one update per 250ms per pane. If the content has not changed since the last broadcast, no update is sent even if the interval has elapsed.

## Security

The Text Tap socket is a local Unix domain socket with standard file permissions. Any process running as the same user can connect. If you need to restrict access, adjust the file permissions on the socket path or change `socket_path` to a location with restricted access.
