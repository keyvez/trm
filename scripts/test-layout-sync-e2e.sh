#!/bin/bash
# Headless E2E test for live layout sync between trm UIs (server-backed UI
# phase 2 tail). Two app instances attach to the same zmx-backed window:
# a primary (Text Tap on a private socket) and a mirror (layout_mirror=true,
# following the primary; its own tap on a second private socket purely for
# introspection). A swap_panes action on the primary's socket must show up
# in the mirror's layout within a few seconds.
#
# Safety:
#   - Only the two PIDs launched here are killed — never a running trm.
#   - Instances are SIGKILLed well before their 30 s autosave timer fires,
#     and SIGKILL skips the applicationWillTerminate autosave, so the real
#     _autosave_* checkpoints are never touched. (Mirror-role windows no
#     longer autosave at all, but the E2E primary would.)
#   - All sockets/sessions use trm-e2e-* names.
set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${TRM_E2E_APP:-$REPO_DIR/macos/build/ReleaseLocal/trm.app/Contents/MacOS/trm}"
ZMX_BIN="$(dirname "$APP_BIN")/zmx"
export ZMX_DIR="${ZMX_DIR:-$HOME/.trm/zmx}"

# All per-run resources carry $$ so concurrent runs can't collide or
# cross-destroy each other's sockets/daemons.
PRIMARY_SOCK="/tmp/trm-e2e-$$.sock"
MIRROR_SOCK="/tmp/trm-e2e-$$-mirror.sock"
WINDOW_ID="E2E-WINDOW-$$"
TMPDIR_E2E="$(mktemp -d -t trm-layout-e2e)"
PRIMARY_PID=""
MIRROR_PID=""
WATCHDOG_PIDS=""
S1="trm-e2e-$$-1"; S2="trm-e2e-$$-2"; S3="trm-e2e-$$-3"
SESSIONS="$S1 $S2 $S3"

fail() { echo "FAIL: $*" >&2; cleanup; exit 1; }

cleanup() {
    # Kill only the instances we started. SIGKILL on purpose: no
    # applicationWillTerminate autosave.
    for w in $WATCHDOG_PIDS; do kill "$w" 2>/dev/null; done
    [ -n "$PRIMARY_PID" ] && kill -9 "$PRIMARY_PID" 2>/dev/null
    [ -n "$MIRROR_PID" ] && kill -9 "$MIRROR_PID" 2>/dev/null
    for s in $SESSIONS; do
        "$ZMX_BIN" kill "$s" --force >/dev/null 2>&1
    done
    rm -f "$PRIMARY_SOCK" "$MIRROR_SOCK"
    rm -rf "$TMPDIR_E2E"
}
trap cleanup EXIT INT TERM

# HARD safety deadline, one watchdog per instance started at ITS launch:
# each instance dies before its own 30 s autosave timer can fire, no matter
# how slowly the assertion loops below run. This is what actually enforces
# the "never touches the real checkpoints" guarantee.
start_watchdog_for() { # $1 = pid to kill 25 s from now
    ( sleep 25; kill -9 "$1" 2>/dev/null ) &
    WATCHDOG_PIDS="$WATCHDOG_PIDS $!"
}

[ -x "$APP_BIN" ] || fail "app binary not found: $APP_BIN"
[ -x "$ZMX_BIN" ] || fail "zmx binary not found: $ZMX_BIN"

# --- 1. Session daemons ------------------------------------------------------
for s in $SESSIONS; do
    "$ZMX_BIN" kill "$s" --force >/dev/null 2>&1
    "$ZMX_BIN" run "$s" -d /bin/zsh || fail "zmx run $s"
done

# --- 2. Configs --------------------------------------------------------------
PRIMARY_TOML="$TMPDIR_E2E/primary.toml"
MIRROR_TOML="$TMPDIR_E2E/mirror.toml"

{
    echo "window_id = \"$WINDOW_ID\""
    echo ""
    echo "[grid]"
    echo "rows = 1"
    echo "cols = 3"
    echo ""
    for s in $SESSIONS; do
        echo "[[panes]]"
        echo "pane_type = \"terminal\""
        echo "zmx_session = \"$s\""
        echo ""
    done
    echo "[text_tap]"
    echo "enabled = true"
    echo "socket_path = \"$PRIMARY_SOCK\""
} > "$PRIMARY_TOML"

{
    echo "layout_mirror = true"
    echo "window_id = \"$WINDOW_ID\""
    echo "text_tap_socket = \"$PRIMARY_SOCK\""
    echo ""
    echo "[grid]"
    echo "rows = 1"
    echo "cols = 3"
    echo ""
    for s in $SESSIONS; do
        echo "[[panes]]"
        echo "pane_type = \"terminal\""
        echo "zmx_session = \"$s\""
        echo ""
    done
    # A real mirror runs with the tap disabled; the E2E enables it on a
    # PRIVATE socket so the test can introspect the mirror's layout. The
    # mirror role comes from layout_mirror, not from the tap state.
    echo "[text_tap]"
    echo "enabled = true"
    echo "socket_path = \"$MIRROR_SOCK\""
} > "$MIRROR_TOML"

# --- 3. Launch both instances ------------------------------------------------
rm -f "$PRIMARY_SOCK" "$MIRROR_SOCK"

TRM_CONFIG="$PRIMARY_TOML" "$APP_BIN" >/dev/null 2>&1 &
PRIMARY_PID=$!
start_watchdog_for "$PRIMARY_PID"

for _ in $(seq 1 50); do [ -S "$PRIMARY_SOCK" ] && break; sleep 0.2; done
[ -S "$PRIMARY_SOCK" ] || fail "primary tap socket never appeared"

TRM_CONFIG="$MIRROR_TOML" "$APP_BIN" >/dev/null 2>&1 &
MIRROR_PID=$!
start_watchdog_for "$MIRROR_PID"

for _ in $(seq 1 50); do [ -S "$MIRROR_SOCK" ] && break; sleep 0.2; done
[ -S "$MIRROR_SOCK" ] || fail "mirror tap socket never appeared"

# --- 4. Socket helpers -------------------------------------------------------
query_layout() { # $1 = socket path → prints the layout JSON object
    python3 - "$1" <<'PY'
import json, socket, sys
sock_path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(sock_path)
s.sendall(b'{"id":"e2e","method":"surface.list","params":{}}\n')
buf = b""
try:
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
except socket.timeout:
    pass
s.close()
for line in buf.split(b"\n"):
    if not line.strip():
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    if obj.get("id") == "e2e" and obj.get("ok"):
        print(json.dumps(obj["result"].get("layout", {})))
        sys.exit(0)
sys.exit(1)
PY
}

send_line() { # $1 = socket path, $2 = json line
    python3 - "$1" "$2" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
try:
    s.recv(4096)
except socket.timeout:
    pass
s.close()
PY
}

cells_of() { # $1 = layout json → prints cells joined by ","
    python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1]).get("cells", [])))' "$1"
}

# --- 5. Wait for the mirror to sync the initial snapshot ---------------------
EXPECT_INITIAL="$S1,$S2,$S3"
MIRROR_LAYOUT=""
for _ in $(seq 1 30); do
    MIRROR_LAYOUT="$(query_layout "$MIRROR_SOCK" 2>/dev/null)" || MIRROR_LAYOUT=""
    if [ -n "$MIRROR_LAYOUT" ]; then
        [ "$(cells_of "$MIRROR_LAYOUT")" = "$EXPECT_INITIAL" ] && break
    fi
    sleep 0.3
done
[ -n "$MIRROR_LAYOUT" ] || fail "mirror never answered surface.list"
[ "$(cells_of "$MIRROR_LAYOUT")" = "$EXPECT_INITIAL" ] \
    || fail "mirror initial layout: $(cells_of "$MIRROR_LAYOUT") (want $EXPECT_INITIAL)"
echo "$MIRROR_LAYOUT" | grep -q '"role": *"mirror"' \
    || fail "mirror window did not take the mirror role: $MIRROR_LAYOUT"

# --- 6. Swap panes 0<->2 on the primary, assert the mirror follows -----------
send_line "$PRIMARY_SOCK" '{"type": "action", "action": "swap_panes", "pane_a": 0, "pane_b": 2}'

EXPECT_SWAPPED="$S3,$S2,$S1"
SWAPPED=""
for _ in $(seq 1 20); do   # up to ~6 s (0.5 s poll + 200 ms debounce + apply)
    LAYOUT="$(query_layout "$MIRROR_SOCK" 2>/dev/null)" || LAYOUT=""
    if [ -n "$LAYOUT" ] && [ "$(cells_of "$LAYOUT")" = "$EXPECT_SWAPPED" ]; then
        SWAPPED=yes
        break
    fi
    sleep 0.3
done
[ -n "$SWAPPED" ] || fail "mirror never showed swapped layout (last: $(cells_of "${LAYOUT:-{}}"))"

# Sanity: the primary shows the same swapped order.
PRIMARY_LAYOUT="$(query_layout "$PRIMARY_SOCK")" || fail "primary surface.list failed"
[ "$(cells_of "$PRIMARY_LAYOUT")" = "$EXPECT_SWAPPED" ] \
    || fail "primary layout mismatch: $(cells_of "$PRIMARY_LAYOUT")"

echo "PASS: mirror followed the primary's swap ($EXPECT_INITIAL -> $EXPECT_SWAPPED)"
exit 0
