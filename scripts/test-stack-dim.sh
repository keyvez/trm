#!/bin/bash
# test-stack-dim.sh — Automated test for the stacked-pane dim bug.
#
# Usage:
#   scripts/test-stack-dim.sh            # build then test
#   scripts/test-stack-dim.sh --no-build # skip build, use last debug binary
#
# What it does:
#   1. Optionally builds the debug app (xcodebuild).
#   2. Launches the debug trm.app with the stack-dim-test session
#      (2 stacked panes + 1 standalone, all cwd=/tmp to avoid sandbox dialogs).
#   3. trm takes its own screenshot via CGWindowListCreateImageFromArray after
#      TRM_SCREENSHOT_DELAY seconds, then exits — no external screencapture tool
#      needed, so user focus changes on the Mac do not affect the result.
#   4. Opens the screenshot for inspection.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION_FILE="$REPO_ROOT/sessions/stack-dim-test.toml"
DEBUG_APP="$REPO_ROOT/macos/build/Build/Products/Debug/trm.app"
SCREENSHOT_DIR="$REPO_ROOT/test-screenshots"
SCREENSHOT="$SCREENSHOT_DIR/stack-dim-$(date +%Y%m%d-%H%M%S).png"

mkdir -p "$SCREENSHOT_DIR"

# ── 1. Build ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" != "--no-build" ]]; then
    echo "Building debug app…"
    xcodebuild \
        -project "$REPO_ROOT/macos/trm.xcodeproj" \
        -scheme trm \
        -configuration Debug \
        -derivedDataPath "$REPO_ROOT/macos/build" \
        build 2>&1 | grep -E "error:|Build succeeded|FAILED|Compiling|Linking" | tail -10
    echo "Build done."
fi

if [[ ! -d "$DEBUG_APP" ]]; then
    echo "Error: debug app not found at $DEBUG_APP"
    exit 1
fi

echo "Binary:  $(stat -f '%Sm  %N' -t '%Y-%m-%d %H:%M:%S' "$DEBUG_APP/Contents/MacOS/trm")"
echo "Session: $SESSION_FILE"
echo "Screenshot will be written to: $SCREENSHOT"

# ── 2. Kill any existing debug trm instance ───────────────────────────────────
EXISTING=$(pgrep -f "Build/Products/Debug/trm.app" 2>/dev/null || true)
if [[ -n "$EXISTING" ]]; then
    echo "Killing existing debug trm (pid $EXISTING)…"
    kill "$EXISTING" 2>/dev/null || true
    sleep 0.5
fi

# ── 3. Launch with the test session ──────────────────────────────────────────
echo "Launching debug trm… (will auto-screenshot in 8 s then quit)"
# Launch the binary directly (not via 'open') so env vars are inherited.
# TRM_CONFIG is read by parseTrmConfigPath() before Ghostty's own arg parsing.
# TRM_SCREENSHOT_PATH tells trm to take its own screenshot then quit, so we
# don't need screencapture or worry about Mac focus changes during the test.
# TRM_SCREENSHOT_DELAY controls how many seconds to wait before capturing.

# Kill any lingering instance first.
pkill -f "Build/Products/Debug/trm.app" 2>/dev/null || true
sleep 0.3

TRM_CONFIG="$SESSION_FILE" \
TRM_SCREENSHOT_PATH="$SCREENSHOT" \
TRM_SCREENSHOT_DELAY="8" \
"$DEBUG_APP/Contents/MacOS/trm"

# ── 4. Verify screenshot was written ─────────────────────────────────────────
if [[ ! -f "$SCREENSHOT" ]]; then
    echo "ERROR: screenshot not found at $SCREENSHOT"
    exit 1
fi
echo "Screenshot: $SCREENSHOT"

echo ""
echo "PASS if: both stacked panes appear at the SAME brightness."
echo "FAIL if: the bottom pane (PANE-BOTTOM-OF-STACK) is dimmer than the top."
