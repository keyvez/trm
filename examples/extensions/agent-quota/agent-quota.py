#!/usr/bin/env python3
"""Agent Quota — flagship example trm extension.

Consumes `context_usage` events from the trm host (fed by Claude Code's
Stop/PreCompact hooks through the Text Tap socket) and publishes a
`metric_pill` overlay showing context-window usage, colored by severity.

Protocol: newline-delimited JSON. stdin: host events. stdout: plugin
messages. Must print {"type": "ready"} at startup and flush every line.
"""

import json
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def color_for(pct):
    if pct >= 85:
        return "red"
    if pct >= 60:
        return "yellow"
    return "green"


def main():
    emit({"type": "ready"})

    # Panes we've seen output on — the pill is shown on all of them, since
    # the host's context feed is app-wide (one Claude session at a time).
    seen_panes = set()
    last_pct = None

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue

        kind = msg.get("type")
        if kind == "stop":
            break
        elif kind == "terminal_output":
            pane = msg.get("pane")
            if pane is not None and pane not in seen_panes:
                seen_panes.add(pane)
                if last_pct is not None:
                    publish(seen_panes, last_pct)
        elif kind == "pane_closed":
            seen_panes.discard(msg.get("pane"))
        elif kind == "context_usage":
            pct = int(msg.get("percentage", 0))
            last_pct = pct
            publish(seen_panes or {0}, pct)


def publish(panes, pct):
    value = f"{pct}%"
    color = color_for(pct)
    emit({
        "type": "state",
        "overlay": "metric_pill",
        "alignment": "toptrailing",
        "panes": {str(p): ["ctx", value, color] for p in panes},
    })


if __name__ == "__main__":
    main()
