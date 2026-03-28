#!/bin/bash
# start-claude.sh — launch trm with a multi-pane layout and start Claude Code in the last pane.
#
# Opens a 2×2 grid of panes. The bottom-right pane automatically starts
# Claude Code. After a short delay, this script focuses that pane.
#
# Usage:
#   ./scripts/start-claude.sh [--panes N] [--delay SECONDS] [--session PATH]
#
# Options:
#   --panes   N       Number of panes (default: 4, last one gets claude)
#   --delay   S       Seconds to wait before focusing the claude pane (default: 3)
#   --session PATH    Path to a custom session TOML (overrides --panes)
#   --no-focus        Skip the auto-focus step

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NUM_PANES=4
DELAY=3
SESSION_PATH=""
AUTO_FOCUS=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --panes)   NUM_PANES="$2"; shift 2 ;;
        --delay)   DELAY="$2"; shift 2 ;;
        --session) SESSION_PATH="$2"; shift 2 ;;
        --no-focus) AUTO_FOCUS=false; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Resolve session path — treat relative paths as relative to repo root
if [ -z "$SESSION_PATH" ]; then
    SESSION_PATH="$REPO_ROOT/sessions/claude.toml"
elif [[ "$SESSION_PATH" != /* ]]; then
    SESSION_PATH="$REPO_ROOT/$SESSION_PATH"
fi

if [ ! -f "$SESSION_PATH" ]; then
    echo "Error: session file not found: $SESSION_PATH" >&2
    exit 1
fi

TRM_CLI="$SCRIPT_DIR/trm-cli.sh"
if [ ! -x "$TRM_CLI" ]; then
    # Try installed trm command
    TRM_CLI="trm"
fi

# Find the trm app
APP_PATH=""
for candidate in \
    "$REPO_ROOT/macos/build/Build/Products/Debug/trm.app" \
    "/Applications/trm.app" \
    "$HOME/Applications/trm.app" \
    "$REPO_ROOT/macos/build/ReleaseLocal/trm.app" \
    "$REPO_ROOT/macos/build/Release/trm.app" \
    "$REPO_ROOT/macos/build/Debug/trm.app"; do
    if [ -d "$candidate" ]; then
        APP_PATH="$candidate"
        break
    fi
done

if [ -z "$APP_PATH" ]; then
    echo "Error: trm.app not found. Build it first with:" >&2
    echo "  cd macos && xcodebuild -scheme Ghostty -configuration Debug build" >&2
    exit 1
fi

echo "Launching $APP_PATH with session: $SESSION_PATH"
TRM_CONFIG="$SESSION_PATH" open -a "$APP_PATH"

if [ "$AUTO_FOCUS" = false ]; then
    exit 0
fi

# Wait for the app to start and connect to the socket
echo "Waiting ${DELAY}s for Claude Code to start..."
sleep "$DELAY"

# Find the socket path
if [ -e "/tmp/trm.sock" ]; then
    SOCKET_PATH="/tmp/trm.sock"
elif [ -e "/tmp/trm-debug.sock" ]; then
    SOCKET_PATH="/tmp/trm-debug.sock"
else
    echo "Warning: trm socket not found — skipping auto-focus" >&2
    exit 0
fi

# List surfaces and find the last one by surface ID number
SURFACES=$(TRM_SOCKET_PATH="$SOCKET_PATH" "$TRM_CLI" list-surfaces 2>/dev/null || true)
if [ -z "$SURFACES" ]; then
    echo "Warning: no surfaces found — skipping auto-focus" >&2
    exit 0
fi

# Extract the highest-numbered surface-N ID from the response
LAST_SURFACE=$(echo "$SURFACES" | python3 -c "
import sys, json, re
data = sys.stdin.read()
# Find all surface-N patterns
ids = re.findall(r'surface-(\d+)', data)
if not ids:
    sys.exit(1)
max_id = max(int(x) for x in ids)
print(f'surface-{max_id}')
" 2>/dev/null || true)

if [ -z "$LAST_SURFACE" ]; then
    echo "Warning: could not determine last surface ID — skipping auto-focus" >&2
    exit 0
fi

echo "Focusing $LAST_SURFACE (Claude Code pane)"
TRM_SOCKET_PATH="$SOCKET_PATH" "$TRM_CLI" focus-surface --surface "$LAST_SURFACE"
