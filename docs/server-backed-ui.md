# Server-backed UI (disposable-trm architecture)

trm is moving to a tmux-like split: terminal processes live in per-pane
session daemons (zmx), window layout lives in continuously checkpointed
session TOML, and the trm app is a disposable UI that attaches to both.
Killing the UI — including `kill -9` or a crash — loses nothing; a
relaunched trm re-attaches to everything.

## Phase 1 — shipped

- `session_persistence` defaults to **true**: every pane runs under a zmx
  session daemon. The UI holds no process state worth preserving.
- **Continuous layout checkpoint**: window layouts auto-save every 30 s
  (plus on window close / quit), so non-graceful UI exits still leave an
  attachable record. Saved layouts include zmx session names, stacking,
  agent-overview panes, and placements.
- **Instant re-attach**: at launch, when the latest auto-save is fully
  backed by live session daemons (every terminal pane has a running
  `zmx_session`), trm restores it immediately — no dialog. The dialog only
  appears for unbacked/partial saves or explicit `TRM_CONFIG` launches.

The dev loop this enables: rebuild → `scripts/reinstall-trm.sh` (re-signs
with a stable identity so permissions survive) → quit/kill trm → relaunch →
everything is back, processes untouched. This is the practical substitute
for hot reload until phase 2.

Verification (60 s): open trm, run `while true; do date; sleep 1; done` in
a pane, wait ~35 s for a checkpoint, `kill -9 <trm pid>`, relaunch trm —
the window returns without a dialog and the loop never stopped
(`trm sessions` lists the daemons at any point).

## Phase 2 — multi-UI attach (shipped)

- **Instant attach for explicit configs**: a `TRM_CONFIG` launch whose
  panes are all backed by live daemons opens directly — attaching to
  running state never asks questions.
- **`trm mirror`**: opens a second trm UI attached to the current
  window's sessions. zmx multi-client does the PTY mirroring — typing and
  output appear in every attached UI. Verified end-to-end: two UIs, both
  `clients=2` on the daemons, input injected server-side rendered in both;
  either UI can be `kill -9`ed with zero process impact.
- The mirror UI's Text Tap server is disabled (it must not steal the
  primary's socket).
- **Live layout sync (shipped)**: layout edits in the primary propagate
  to attached mirrors within ~1 s. How it works:
  - *Window identity*: every window has a stable UUID, persisted as a
    top-level `window_id` key in its checkpoint TOML alongside
    `text_tap_socket` (the primary's Text Tap socket path).
    `mirror-session.py` passes both through and adds
    `layout_mirror = true`, which marks the launched UI as a mirror.
  - *Transport*: the mirror connects to the primary's Text Tap socket as
    a client and sends `{"type": "layout_subscribe", "window": "<uuid>"}`.
    The primary broadcasts `{"type": "layout_update", "window", "revision",
    "toml"}` lines — the full serialized session TOML as a snapshot,
    debounced ~200 ms after any layout change (order, grid shape, stacks,
    pane sizes, agent overviews). No diffs: snapshots are idempotent, so a
    dropped message self-heals on the next one. New subscribers are pushed
    a snapshot immediately; per-client outbound buffering on the server
    keeps a slow mirror from tearing lines.
  - *In-place apply*: the mirror matches panes by identity (terminals by
    `zmx_session`, webviews by URL, plugins by kind+title, overviews by
    their terminal) and mutates order/shape/stacks/fractions in place —
    PTY views are never rebuilt. Only genuinely added/removed panes are
    created or dropped; closing a pane on the mirror side never kills the
    shared zmx daemon. Watermarks follow snapshots too, though a
    watermark-only edit doesn't trigger a broadcast by itself (it rides
    along on the next layout change).
  - *Ownership*: the primary owns the layout. Mirrors have local layout
    editing disabled and never autosave the shared window (a mirror
    process's checkpoint timer previously clobbered the primary's
    `_autosave_*` files; it now stands down entirely). If the primary
    dies, mirrors keep the last layout and PTYs stay live via zmx;
    the mirror reconnects with backoff and resyncs when a primary
    returns. Pane size fractions now round-trip through the checkpoint
    TOML too (`row_fractions`, `col_fractions`, `stack_fractions`).

## Phase 3 — remote UI (shipped, first cut)

**`trm attach-remote <ssh-host>`**: fetches the remote machine's latest
window checkpoint, rewrites each server-backed pane to
`ssh -t <host> zmx attach <session>` (`scripts/mirror-session.py`), and
opens a local trm on it — the remote window's layout, GPU-rendered
locally, PTYs streaming over SSH. Uses the same remote-attach mechanics
as the shipped `ssh -t host …/zmx attach <name>` flow; requires key-based
SSH to the host and trm installed on both ends. Overview/webview panes
pass through as layout (their data sources are machine-local).

Still open in phase 3: full remote parity — remote agent-overview data,
live layout sync for remote attaches (the local mirror sync rides a unix
socket; a remote UI would need the socket forwarded over SSH —
`mirror-session.py --remote` drops `text_tap_socket` for now, so remote
UIs show a snapshot), reconnect-on-drop for SSH panes.
