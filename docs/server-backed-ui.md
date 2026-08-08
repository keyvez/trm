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
  primary's socket); layout in a mirror is a snapshot, not yet live-synced.

Still open in phase 2: **live layout sync** — layout edits in one UI
propagating to others. Requires window identity + an ownership/broadcast
protocol; candidate transport is the Text Tap / cmux socket (already
JSON, already has surface.list/focus/spawn). Until then, a mirror
re-opened via `trm mirror` picks up the latest checkpoint.

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
live layout sync over the same channel, reconnect-on-drop for SSH panes.
