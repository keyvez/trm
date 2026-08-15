#!/usr/bin/env python3
"""Prepare a trm session TOML for mirror / remote-attach launches.

trm's window state lives server-side: pane processes in zmx session daemons,
layout in checkpointed session TOML. That makes a window attachable from a
second UI — locally (zmx mirrors multi-client) or from another machine over
SSH. This script produces the config such a UI launches with.

Modes:
  --latest-autosave            Print the path of the newest auto-saved window
                               TOML (the current window state) and exit.
  --local < in.toml > out      Passthrough transform for a local mirror UI:
                               panes keep their zmx_session (native reattach);
                               the Text Tap server is disabled so the mirror
                               doesn't steal the primary UI's socket. The
                               primary's window_id and text_tap_socket
                               top-level keys pass through, so the mirror
                               subscribes to live layout updates.
  --remote HOST [--zmx PATH]   Transform for a remote UI: each server-backed
                               terminal pane's command becomes
                               `ssh -t HOST ZMX attach <session>`, so the PTY
                               stream rides SSH while rendering stays local.
                               text_tap_socket is dropped (the remote socket
                               path is meaningless locally), so remote UIs
                               show a layout snapshot, not live sync.

Both transforms mark the output with layout_mirror = true, which makes the
launched UI a mirror: it follows the primary's layout, disables local layout
edits, and never autosaves the shared window.

Layout-only fields (grid, watermarks, stacks, agent overviews) pass through
untouched in both transforms.
"""

import argparse
import glob
import os
import re
import sys

DEFAULT_REMOTE_ZMX = "/Applications/trm.app/Contents/MacOS/zmx"

SESSIONS_DIR = os.path.expanduser(
    "~/Library/Application Support/trm/sessions"
)

# Pane-block keys that describe the *local* process backing and must not be
# forwarded to a remote UI (the remote attach command replaces them).
REMOTE_DROP_KEYS = ("command", "initial_commands", "initial_command",
                    "zmx_session", "scrollback_file", "cwd")


def latest_autosave() -> str | None:
    files = glob.glob(os.path.join(SESSIONS_DIR, "_autosave_*.toml"))
    files = [f for f in files if not f.endswith("_manifest.json")]
    if not files:
        return None
    return max(files, key=os.path.getmtime)


def toml_str(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def transform(lines: list[str], remote_host: str | None, zmx_path: str) -> list[str]:
    """Rewrite pane blocks; append a disabled Text Tap section."""
    out: list[str] = []
    pane: list[str] | None = None

    def flush():
        nonlocal pane
        if pane is None:
            return
        if remote_host is None:
            out.extend(pane)
        else:
            is_terminal = True
            session = None
            for line in pane:
                stripped = line.strip()
                if stripped.startswith("pane_type"):
                    is_terminal = '"terminal"' in stripped
                m = re.match(r'zmx_session\s*=\s*"(.*)"', stripped)
                if m:
                    session = m.group(1)
            if is_terminal and session:
                kept = [
                    line for line in pane
                    if not line.strip().startswith(REMOTE_DROP_KEYS)
                ]
                # ZMX_DIR pins trm's standard socket dir on the remote; the
                # sessions being mirrored were created by the remote trm app,
                # which keeps them there. Single quotes so $HOME expands on
                # the remote machine.
                attach = (f"ssh -t {remote_host} 'ZMX_DIR=\"$HOME/.trm/zmx\" "
                          f"\"{zmx_path}\" attach {session}'")
                # Insert the attach command right after the [[panes]] header.
                kept.insert(1, f"command = {toml_str(attach)}")
                out.extend(kept)
            else:
                # Webview/plugin/overview panes carry no process; pass through.
                out.extend(pane)
        pane = None

    for line in lines:
        if line.strip() == "[[panes]]":
            flush()
            pane = [line]
        elif pane is not None:
            if line.strip().startswith("[") and not line.strip().startswith("[["):
                # A new non-pane section ends the pane list.
                flush()
                out.append(line)
            else:
                pane.append(line)
        else:
            # A remote UI can't reach the primary's local socket; drop the
            # top-level key so no layout sync client starts.
            if remote_host is not None and line.strip().startswith("text_tap_socket"):
                continue
            out.append(line)
    flush()

    # Mark the launched UI as a mirror: it follows the primary's layout and
    # never autosaves the shared window. Top-level keys must precede the
    # first section, so insert at the very top.
    out.insert(0, "layout_mirror = true")

    # The mirror UI must not bind the primary UI's Text Tap socket.
    out.append("")
    out.append("[text_tap]")
    out.append("enabled = false")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--latest-autosave", action="store_true")
    mode.add_argument("--local", action="store_true")
    mode.add_argument("--remote", metavar="HOST")
    ap.add_argument("--zmx", default=DEFAULT_REMOTE_ZMX)
    args = ap.parse_args()

    if args.latest_autosave:
        path = latest_autosave()
        if not path:
            print("no auto-saved session found", file=sys.stderr)
            return 1
        print(path)
        return 0

    lines = sys.stdin.read().splitlines()
    host = args.remote if args.remote else None

    if args.local and not any(
        line.strip().startswith("text_tap_socket") for line in lines
    ):
        print(
            "warning: source session has no text_tap_socket — the primary's "
            "Text Tap is disabled or the autosave predates layout sync; the "
            "mirror will show a static snapshot without live layout sync",
            file=sys.stderr,
        )

    for line in transform(lines, host, args.zmx):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
