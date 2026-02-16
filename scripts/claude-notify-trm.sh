#!/bin/bash
# Claude Code notification hook for trm.
# Sends a notify action to the Text Tap socket so trm shows a native macOS notification.
#
# Usage: Add to ~/.claude/settings.json:
#   "hooks": {
#     "Notification": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/trm/scripts/claude-notify-trm.sh" }]
#     }]
#   }

SOCKET="${TRM_SOCKET_PATH:-/tmp/trm.sock}"

echo '{"type":"action","action":"notify","title":"Claude Code","body":"Claude is waiting for your input"}' | nc -U "$SOCKET"
