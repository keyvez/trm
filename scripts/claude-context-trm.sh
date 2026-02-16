#!/bin/bash
# Claude Code context usage hook for trm.
# Reads the hook JSON from stdin, wraps it in a context_update message,
# and sends it to the Text Tap socket so trm can display context usage.
#
# Usage: Add to ~/.claude/settings.json:
#   "hooks": {
#     "PostToolUse": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/trm/scripts/claude-context-trm.sh" }]
#     }],
#     "PreCompact": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/trm/scripts/claude-context-trm.sh" }]
#     }],
#     "Stop": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/trm/scripts/claude-context-trm.sh" }]
#     }]
#   }

SOCKET="${TRM_SOCKET_PATH:-/tmp/trm.sock}"

# Read the full hook payload from stdin
PAYLOAD=$(cat)

# Wrap in a context_update message and send to the Text Tap socket
printf '{"type":"context_update","payload":%s}\n' "$PAYLOAD" | nc -U "$SOCKET" 2>/dev/null || true
