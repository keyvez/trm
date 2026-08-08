#!/bin/bash
# Claude Code notification hook for trm.
#
# Sends a notify action to the Text Tap socket so trm shows a first-class
# notification attached to the pane the hook fired from — clicking the banner
# focuses that pane. Falls back to an AppleScript notification when trm isn't
# running (e.g. Claude Code launched from Terminal.app or over SSH).
#
# Usage: Add to ~/.claude/settings.json:
#   "hooks": {
#     "Notification": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/trm/scripts/claude-notify-trm.sh" }]
#     }],
#     "Stop": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/trm/scripts/claude-notify-trm.sh" }]
#     }]
#   }

SOCKET="${TRM_SOCKET_PATH:-/tmp/trm.sock}"

# Read the hook payload from stdin (may be empty if invoked manually).
PAYLOAD=$(cat 2>/dev/null)

TITLE="Claude Code"
HOOK_TYPE=""
MESSAGE=""
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  HOOK_TYPE=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null)
  # The Notification hook carries the reason Claude wants attention.
  MESSAGE=$(printf '%s' "$PAYLOAD" | jq -r '.message // empty' 2>/dev/null)
fi

if [ -z "$MESSAGE" ]; then
  if [ "$HOOK_TYPE" = "Stop" ]; then
    MESSAGE="Claude finished working"
  else
    MESSAGE="Claude is waiting for your input"
  fi
fi

# Escape for embedding in JSON: backslashes first, then double quotes, then
# collapse any newlines so the payload stays a single JSON line.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

TITLE_ESC=$(json_escape "$TITLE")
BODY_ESC=$(json_escape "$MESSAGE")

# Identify the pane this hook fired from so trm can attach the notification to
# it — clicking the banner then focuses this pane. trm exports TRM_PANE_ID into
# every pane's shell. Without it, trm has to guess from connected clients,
# which picks the wrong pane when several agents are running.
PANE_FIELD=""
case "$TRM_PANE_ID" in
  ''    ) ;;                                    # not running under trm
  *[!0-9]* ) ;;                                 # non-numeric: ignore
  *     ) PANE_FIELD=",\"pane\":$TRM_PANE_ID" ;;
esac

# Send to trm. If the socket isn't there, or nc can't reach it, fall back to
# an AppleScript banner so the user still gets notified.
if [ -S "$SOCKET" ] && printf '{"type":"action","action":"notify","title":"%s","body":"%s"%s}\n' \
     "$TITLE_ESC" "$BODY_ESC" "$PANE_FIELD" | nc -U "$SOCKET" 2>/dev/null; then
  exit 0
fi

osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" 2>/dev/null || true
exit 0
