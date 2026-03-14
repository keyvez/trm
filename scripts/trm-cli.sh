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
#   browser-navigate --url U     Navigate browser to a URL
#   browser-eval --js CODE       Evaluate JavaScript in browser
#   browser-snapshot             Snapshot browser accessibility tree
#   browser-click --selector S   Click an element in the browser
#   browser-fill --selector S --text T  Fill a form field
#   status                       Show socket connection status
#   raw <json>                   Send raw JSON to the socket
#   ping                         Ping (cmux protocol)
#   list-surfaces                List surfaces (cmux protocol)
#   identify                     Identify focused surface (cmux protocol)
#   capabilities                 List cmux methods
#   send-key --key K             Send a named key (cmux protocol)
#   send-text --text T           Send text (cmux protocol)

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
    local timeout="${2:-2}"
    if [ ! -S "$SOCKET_PATH" ]; then
        echo "Error: trm socket not found at $SOCKET_PATH" >&2
        echo "Is trm running?" >&2
        exit 1
    fi
    # Use python3 for reliable bidirectional communication.
    # nc closes on stdin EOF before async responses arrive.
    if command -v python3 &>/dev/null; then
        python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.sendall(b'$json\n')
s.settimeout($timeout)
try:
    data = s.recv(8192)
    sys.stdout.write(data.decode())
except socket.timeout:
    pass
s.close()
"
    elif command -v socat &>/dev/null; then
        echo "$json" | socat -t "$timeout" - UNIX-CONNECT:"$SOCKET_PATH"
    elif command -v nc &>/dev/null; then
        echo "$json" | nc -U -w "$timeout" "$SOCKET_PATH"
    else
        echo "Error: requires python3, socat, or nc" >&2
        exit 1
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
  browser-navigate --url U          Navigate browser to URL
  browser-eval --js CODE            Evaluate JavaScript in browser
  browser-snapshot                   Snapshot browser accessibility tree
  browser-click --selector S        Click an element in the browser
  browser-fill --selector S --text T Fill a form field in the browser
  status                            Show socket connection info
  raw <json>                        Send raw JSON to the socket

cmux-compatible commands:
  ping                              Ping the terminal (cmux protocol)
  list-surfaces                     List surfaces with IDs and focus state
  identify                          Identify focused window/workspace/surface
  capabilities                      List supported cmux methods
  send-key --key K [--surface S]    Send a named key (Enter, Tab, Up, etc.)
  send-text --text T [--surface S]  Send text via cmux protocol

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

    browser-navigate)
        shift
        URL=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --url) URL="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$URL" ]; then
            echo "Error: --url is required" >&2
            exit 1
        fi
        URL_ESC=$(json_escape "$URL")
        send_to_socket "{\"type\": \"action\", \"action\": \"browser_navigate\", \"url\": \"$URL_ESC\"}"
        ;;

    browser-eval)
        shift
        JS=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --js) JS="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$JS" ]; then
            echo "Error: --js is required" >&2
            exit 1
        fi
        JS_ESC=$(json_escape "$JS")
        send_to_socket "{\"type\": \"action\", \"action\": \"browser_eval\", \"code\": \"$JS_ESC\"}"
        ;;

    browser-snapshot)
        send_to_socket '{"type": "action", "action": "browser_snapshot"}'
        ;;

    browser-click)
        shift
        SELECTOR=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --selector) SELECTOR="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$SELECTOR" ]; then
            echo "Error: --selector is required" >&2
            exit 1
        fi
        SEL_ESC=$(json_escape "$SELECTOR")
        send_to_socket "{\"type\": \"action\", \"action\": \"browser_click\", \"selector\": \"$SEL_ESC\"}"
        ;;

    browser-fill)
        shift
        SELECTOR="" TEXT=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --selector) SELECTOR="$2"; shift 2 ;;
                --text)     TEXT="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$SELECTOR" ] || [ -z "$TEXT" ]; then
            echo "Error: --selector and --text are required" >&2
            exit 1
        fi
        SEL_ESC=$(json_escape "$SELECTOR")
        TEXT_ESC=$(json_escape "$TEXT")
        send_to_socket "{\"type\": \"action\", \"action\": \"browser_fill\", \"selector\": \"$SEL_ESC\", \"text\": \"$TEXT_ESC\"}"
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

    # cmux-compatible subcommands
    ping)
        send_to_socket '{"id":"cli-ping","method":"system.ping","params":{}}'
        ;;

    list-surfaces)
        send_to_socket '{"id":"cli-ls","method":"surface.list","params":{}}' 3
        ;;

    identify)
        send_to_socket '{"id":"cli-id","method":"system.identify","params":{}}' 3
        ;;

    capabilities)
        send_to_socket '{"id":"cli-caps","method":"system.capabilities","params":{}}'
        ;;

    send-key)
        shift
        KEY="" SURFACE=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --key)     KEY="$2"; shift 2 ;;
                --surface) SURFACE="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$KEY" ]; then
            echo "Error: --key is required" >&2
            exit 1
        fi
        KEY_ESC=$(json_escape "$KEY")
        if [ -n "$SURFACE" ]; then
            SURFACE_ESC=$(json_escape "$SURFACE")
            send_to_socket "{\"id\":\"cli-sk\",\"method\":\"surface.send_key\",\"params\":{\"key\":\"$KEY_ESC\",\"surface_id\":\"$SURFACE_ESC\"}}"
        else
            send_to_socket "{\"id\":\"cli-sk\",\"method\":\"surface.send_key\",\"params\":{\"key\":\"$KEY_ESC\"}}"
        fi
        ;;

    send-text)
        shift
        TEXT="" SURFACE=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --text)    TEXT="$2"; shift 2 ;;
                --surface) SURFACE="$2"; shift 2 ;;
                *) echo "Unknown option: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$TEXT" ]; then
            echo "Error: --text is required" >&2
            exit 1
        fi
        TEXT_ESC=$(json_escape "$TEXT")
        if [ -n "$SURFACE" ]; then
            SURFACE_ESC=$(json_escape "$SURFACE")
            send_to_socket "{\"id\":\"cli-st\",\"method\":\"surface.send_text\",\"params\":{\"text\":\"$TEXT_ESC\",\"surface_id\":\"$SURFACE_ESC\"}}"
        else
            send_to_socket "{\"id\":\"cli-st\",\"method\":\"surface.send_text\",\"params\":{\"text\":\"$TEXT_ESC\"}}"
        fi
        ;;

    *)
        echo "Unknown command: $COMMAND" >&2
        echo "Run 'trm --help' for usage" >&2
        exit 1
        ;;
esac
