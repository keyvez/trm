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

## Phase 2 — window server (planned)

A single `trm-server` daemon owning the *window* abstraction: layout,
pane registry, watermarks, stacks, overview panes — today reconstructed
from TOML by each UI instance. The UI becomes a pure client: subscribe to
layout state, attach pane surfaces via zmx, publish input/layout edits.
Multiple UIs can then show the same window live (local + remote), and
layout changes propagate between them. Candidate transport: extend the
Text Tap / cmux socket protocol (already speaks JSON, already has
surface.list, focus, spawn).

## Phase 3 — remote UI (planned)

Same client protocol over SSH forwarding: a remote trm renders locally
(its own Metal surfaces) while PTY bytes stream through forwarded zmx
sockets and layout state through the trm-server socket. tmux semantics,
GPU-rendered.
