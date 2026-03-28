#!/bin/bash
# test-focus-rpc.sh — smoke test for the surface.focus RPC.
#
# Launches a fresh debug trm instance with a 1×3 grid (3 panes),
# waits for it to start, then focuses the last pane (which runs claude).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$REPO_ROOT/macos/build/Build/Products/Debug/trm.app"
SOCK="/tmp/trm-debug.sock"

if [ ! -d "$APP" ]; then
    echo "Error: debug build not found at $APP" >&2
    exit 1
fi

# Kill any running trm instances so the new one can bind the socket
echo "Killing existing trm instances..."
pkill -9 -x trm 2>/dev/null || true
sleep 0.5

# Remove stale socket file so the new instance can bind it
rm -f "$SOCK"

# Clear autosave so session restore doesn't interfere
find "$HOME/Library/Application Support/trm/sessions" -maxdepth 1 -name '_autosave*' -delete 2>/dev/null || true
echo "Cleared autosave"

# Clear macOS native window restoration state so NSWindowRestoration doesn't
# replay the previous session (which would create surfaces without pane IDs).
rm -rf "$HOME/Library/Saved Application State/app.roj.trm.savedState" 2>/dev/null || true
echo "Cleared macOS window state"

# Write the session file
SESSION="$REPO_ROOT/sessions/focus-rpc-test.toml"
cat > "$SESSION" <<'EOF'
title = "Focus RPC Test"
session_persistence = false

[grid]
rows = 1
cols = 3

[[panes]]
command = "/bin/zsh"

[[panes]]
command = "/bin/zsh"

[[panes]]
command = "/bin/zsh"
initial_commands = ["claude"]
EOF

echo "Launching $APP..."
TRM_CONFIG="$SESSION" "$APP/Contents/MacOS/trm" &
TRM_PID=$!
echo "trm PID: $TRM_PID"

# Poll until the socket accepts connections (up to 30s)
echo "Waiting for socket at $SOCK..."
for i in $(seq 1 60); do
    if python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect('$SOCK')
    s.close()
    sys.exit(0)
except:
    sys.exit(1)
" 2>/dev/null; then
        echo "Socket ready (${i} x 0.5s)"
        break
    fi
    if ! kill -0 "$TRM_PID" 2>/dev/null; then
        echo "Error: trm process $TRM_PID died" >&2
        exit 1
    fi
    sleep 0.5
done

if ! python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try: s.connect('$SOCK'); s.close()
except: sys.exit(1)
" 2>/dev/null; then
    echo "Error: could not connect to $SOCK after 30s" >&2
    exit 1
fi

# List surfaces
echo "Surfaces:"
python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCK')
s.sendall(b'{\"id\":\"ls\",\"method\":\"surface.list\",\"params\":{}}\n')
s.settimeout(3)
try: print(s.recv(8192).decode())
except: pass
s.close()
"

# Find the highest-numbered surface
LAST_SURFACE=$(python3 -c "
import socket, re, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCK')
s.sendall(b'{\"id\":\"ls2\",\"method\":\"surface.list\",\"params\":{}}\n')
s.settimeout(3)
try: data = s.recv(8192).decode()
except: data = ''
s.close()
ids = re.findall(r'surface-(\d+)', data)
if not ids: sys.exit(1)
print(f'surface-{max(int(x) for x in ids)}')
" 2>/dev/null || true)

if [ -z "$LAST_SURFACE" ]; then
    echo "Error: could not determine last surface ID" >&2
    exit 1
fi

# Give the app a moment to finish initializing all surfaces after socket connects
sleep 2

echo "Focusing $LAST_SURFACE (claude pane)..."
python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCK')
s.sendall(b'{\"id\":\"fs\",\"method\":\"surface.focus\",\"params\":{\"surface_id\":\"$LAST_SURFACE\"}}\n')
s.settimeout(2)
try: print(s.recv(8192).decode())
except: pass
s.close()
"
echo "Done."
