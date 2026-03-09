#!/bin/bash
# trm CLI — command-line interface for the trm terminal multiplexer.
#
# Communicates with the running trm app via the Text Tap Unix socket.
# Socket path: /tmp/trm.sock (release) or /tmp/trm-debug.sock (debug)
#
# Usage:
#   trm <command> [options]
#
# Commands:
#   (no args)                    Launch the trm app
#   notify --title T [--body B]  Send a notification to a pane
#   list-panes                   List active panes
#   send --pane P --text T       Send text to a pane's PTY
#   send-all --text T            Send text to all panes
#   send-command --pane P --cmd C Send a command to a pane
#   mark-connected --pane P      Mark a pane as connected to this tool
#   mark-disconnected --pane P   Mark a pane as disconnected
#   open-browser --url U [--pane P] Open a URL in a split browser pane
#   status                       Show socket connection status
#   raw <json>                   Send raw JSON to the socket

set -e

# Determine socket path
if [ -n "$TRM_SOCKET_PATH" ]; then
    SOCKET_PATH="$TRM_SOCKET_PATH"
elif [ -e "/tmp/trm.sock" ]; then
    SOCKET_PATH="/tmp/trm.sock"
elif [ -e "/tmp/trm-debug.sock" ]; then
    SOCKET_PATH="/tmp/trm-debug.sock"
else
    SOCKET_PATH="/tmp/trm.sock"
fi

# Helper: send JSON to socket and read response
send_to_socket() {
    local json="$1"
    if [ ! -S "$SOCKET_PATH" ]; then
        echo "Error: trm socket not found at $SOCKET_PATH" >&2
        echo "Is trm running?" >&2
        exit 1
    fi
    # Use socat if available, fall back to nc
    if command -v socat &>/dev/null; then
        echo "$json" | socat - UNIX-CONNECT:"$SOCKET_PATH"
    elif command -v nc &>/dev/null; then
        echo "$json" | nc -U -w 1 "$SOCKET_PATH"
    else
        # Pure bash: use /dev/tcp redirect via coproc
        # Fall back to python if available
        if command -v python3 &>/dev/null; then
            python3 -c "
import socket, sys, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.sendall(b'$json\n')
s.settimeout(2.0)
try:
    data = s.recv(4096)
    sys.stdout.write(data.decode())
except socket.timeout:
    pass
s.close()
"
        else
            echo "Error: requires socat, nc, or python3" >&2
            exit 1
        fi
    fi
}

# Escape a string for JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

# -----------------------------------------------------------------
# Command dispatch
# -----------------------------------------------------------------
COMMAND="${1:-}"

case "$COMMAND" in
    ""|"--help"|"-h")
        if [ -z "$COMMAND" ]; then
            # No args: launch the app
            APP_PATH=""
            for candidate in \
                "/Applications/trm.app" \
                "$HOME/Applications/trm.app" \
                "$(dirname "$0")/../macos/build/ReleaseLocal/trm.app" \
                "$(dirname "$0")/../macos/build/Debug/trm.app"; do
                if [ -d "$candidate" ]; then
                    APP_PATH="$candidate"
                    break
                fi
            done
            if [ -n "$APP_PATH" ]; then
                TRM_CWD="$(pwd)" open -a "$APP_PATH"
                exit 0
            fi
        fi
        cat <<HELP
trm — CLI for the trm terminal multiplexer

Usage: trm <command> [options]

Commands:
  (no args)                         Launch the trm app
  notify   --title T [--body B]     Send a notification
           [--pane P]               Target pane (uses connected pane if omitted)
  list-panes                        List active panes (JSON)
  send     --pane P --text T        Send text to a pane's PTY
  send-all --text T                 Send text to all panes
  send-command --pane P --cmd C     Send a command to a pane
  mark-connected --pane P [--app N] Mark a pane as connected
  mark-disconnected --pane P        Disconnect from a pane
  open-browser --url U [--pane P]   Open URL in split browser pane
  status                            Show socket connection info
  raw <json>                        Send raw JSON to the socket

Environment:
  TRM_SOCKET_PATH   Override socket path (default: /tmp/trm.sock)

Socket protocol: Newline-delimited JSON over Unix socket.
HELP
        ;;

    notify)
        shift
        TITLE="" BODY="" PANE=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --title) TITLE="$2"; shift 2 ;;
                --body)  BODY="$2"; shift 2 ;;
                --pane)  PANE="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$TITLE" ]; then
            echo "Error: --title is required" >&2
            exit 1
        fi
        TITLE_ESC=$(json_escape "$TITLE")
        BODY_ESC=$(json_escape "${BODY:-}")
        send_to_socket "{\"type\": \"action\", \"action\": \"notify\", \"title\": \"$TITLE_ESC\", \"body\": \"$BODY_ESC\"}"
        ;;

    list-panes)
        send_to_socket '{"type": "list_panes"}'
        ;;

    send)
        shift
        PANE="" TEXT=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --pane) PANE="$2"; shift 2 ;;
                --text) TEXT="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$PANE" ] || [ -z "$TEXT" ]; then
            echo "Error: --pane and --text are required" >&2
            exit 1
        fi
        TEXT_ESC=$(json_escape "$TEXT")
        send_to_socket "{\"type\": \"send\", \"pane\": $PANE, \"text\": \"$TEXT_ESC\"}"
        ;;

    send-all)
        shift
        TEXT=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --text) TEXT="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$TEXT" ]; then
            echo "Error: --text is required" >&2
            exit 1
        fi
        TEXT_ESC=$(json_escape "$TEXT")
        send_to_socket "{\"type\": \"send_all\", \"text\": \"$TEXT_ESC\"}"
        ;;

    send-command)
        shift
        PANE="" CMD=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --pane) PANE="$2"; shift 2 ;;
                --cmd)  CMD="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$PANE" ] || [ -z "$CMD" ]; then
            echo "Error: --pane and --cmd are required" >&2
            exit 1
        fi
        CMD_ESC=$(json_escape "$CMD")
        send_to_socket "{\"type\": \"action\", \"action\": \"send_command\", \"pane\": $PANE, \"command\": \"$CMD_ESC\"}"
        ;;

    mark-connected)
        shift
        PANE="" APP=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --pane) PANE="$2"; shift 2 ;;
                --app)  APP="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$PANE" ]; then
            echo "Error: --pane is required" >&2
            exit 1
        fi
        if [ -n "$APP" ]; then
            APP_ESC=$(json_escape "$APP")
            send_to_socket "{\"type\": \"mark_connected\", \"pane\": $PANE, \"app\": \"$APP_ESC\"}"
        else
            send_to_socket "{\"type\": \"mark_connected\", \"pane\": $PANE}"
        fi
        ;;

    mark-disconnected)
        shift
        PANE=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --pane) PANE="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$PANE" ]; then
            echo "Error: --pane is required" >&2
            exit 1
        fi
        send_to_socket "{\"type\": \"mark_disconnected\", \"pane\": $PANE}"
        ;;

    open-browser)
        shift
        URL="" PANE=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --url)  URL="$2"; shift 2 ;;
                --pane) PANE="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$URL" ]; then
            echo "Error: --url is required" >&2
            exit 1
        fi
        URL_ESC=$(json_escape "$URL")
        if [ -n "$PANE" ]; then
            send_to_socket "{\"type\": \"action\", \"action\": \"open_browser\", \"url\": \"$URL_ESC\", \"pane\": $PANE}"
        else
            send_to_socket "{\"type\": \"action\", \"action\": \"open_browser\", \"url\": \"$URL_ESC\"}"
        fi
        ;;

    status)
        send_to_socket '{"type": "subscribe", "app": "trm-cli"}'
        send_to_socket '{"type": "list_panes"}'
        ;;

    raw)
        shift
        if [ -z "$1" ]; then
            echo "Error: JSON argument required" >&2
            exit 1
        fi
        send_to_socket "$1"
        ;;

    *)
        echo "Unknown command: $COMMAND" >&2
        echo "Run 'trm --help' for usage" >&2
        exit 1
        ;;
esac
