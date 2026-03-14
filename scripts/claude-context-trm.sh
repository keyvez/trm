#!/bin/bash
# Claude Code context usage hook for trm.
# Reads the hook JSON from stdin, extracts transcript_path, parses the JSONL
# transcript to compute context window usage, and sends a context_update
# message to the Text Tap socket so trm can display context usage.
#
# Usage: Add to ~/.claude/settings.json:
#   "hooks": {
#     "Stop": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/trm/scripts/claude-context-trm.sh" }]
#     }],
#     "PreCompact": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/trm/scripts/claude-context-trm.sh" }]
#     }]
#   }

SOCKET="${TRM_SOCKET_PATH:-/tmp/trm.sock}"

# Read the full hook payload from stdin
PAYLOAD=$(cat)

# Extract fields from the hook payload
TRANSCRIPT=$(echo "$PAYLOAD" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id // empty')
HOOK_TYPE=$(echo "$PAYLOAD" | jq -r '.hook_event_name // empty')

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  exit 0
fi

# Find last assistant message with usage data (read from end for speed)
USAGE=$(tail -100 "$TRANSCRIPT" | jq -s '
  [.[] | select(.type == "assistant" and .message.usage)] | last |
  .message.usage // empty
')

if [ -z "$USAGE" ] || [ "$USAGE" = "null" ]; then
  exit 0
fi

# Compute token counts
INPUT=$(echo "$USAGE" | jq '(.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)')
TOTAL=200000  # All current Claude models use 200k context
PCT=$(( INPUT * 100 / TOTAL ))
[ "$PCT" -gt 100 ] && PCT=100

# Build and send context_update
printf '{"type":"context_update","payload":{"context_window":{"used":%d,"total":%d,"used_percentage":%d},"session_id":"%s","hook_type":"%s"}}\n' \
  "$INPUT" "$TOTAL" "$PCT" "$SESSION_ID" "$HOOK_TYPE" \
  | nc -U "$SOCKET" 2>/dev/null || true
