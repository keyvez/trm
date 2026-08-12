# trm — 100% CPU layout spin on window restore: handoff report

**Date:** 2026-08-12
**Branch:** `agent-overview` (HEAD `32e25f8b5`)
**Build under test:** trm 0.3.0 (14431), macOS 26.5.1, arm64
**Status:** partially fixed. The Session Browser bugs are fixed and verified. The
core layout spin is **NOT fixed** and its cause is still unknown.

---

## 1. The symptom

The user reports trm "freezing" / "hanging" when restoring a window, especially
from the Session Browser. Observed reality:

- The app is **not deadlocked**. It pegs **one core at 100%** indefinitely.
- The main thread is inside a non-terminating **SwiftUI layout loop**.
- The app often remains partly responsive (autosave timers keep firing), which is
  why it reads as a "freeze" rather than a spin.
- RSS climbs to **400–660 MB** while spinning.
- It does not self-recover. The user force-quits.

### Terminology warning for the next agent

Early in the investigation "hang" was used loosely. Be precise:

- **Spin** = 100% CPU, main thread in SwiftUI layout, app semi-responsive. This is
  the real bug.
- **Burst** = periodic 1.5–3 s CPU spikes from poll timers. This is normal-ish and
  was initially mistaken for the spin. Do not conflate them: `ps %cpu` averages
  over a long window and will show a duty cycle as a steady number.

---

## 2. The spin signature (stable across every reproduction)

From `sample <pid>`, main thread, ~800–1100 frames deep:

```
NSRunLoop.flushObservers
  NSHostingView.beginTransaction
    GraphHost.flushTransactions
      AG::Subgraph::update
        GeometryReaderLayout.placeSubviews          <-- loop head
          _ZStackLayout.sizeThatFits
            ViewDimensions.subscript.getter
              LayoutEngineBox.explicitAlignment      (x5)
                UnaryLayoutEngine.childPlacement
                  _FrameLayout.commonPlacement
                    StackLayout.placeChildren        (x22)
                      ... recurses ...
```

Frequently with `CoreText` / `NSCoreTypesetter` / ICU `RuleBasedBreakIterator` at
the leaves (text measurement being redone every pass), and `ViewSizeCache.get`
missing every time.

**Saved samples** — these live in this directory on the original machine but are
gitignored (`.trm-debug/*.txt`, ~600 KB each). Regenerate with
`sample <pid> 5 -file out.txt` while reproducing per §7.

| File | What it captured |
|---|---|
| `sample-recovered-6overviews.txt` | Spin after opening `recovered.toml` (12 panes, 6 agent overviews), 6 sessions verified attached |
| `sample-7windows-no-overviews.txt` | **Spin with ZERO overview panes** — the decisive one, see §4 |
| `sample-resize-hang.txt` | Spin during window resize, showing AppKit `_layoutSubtreeWithOldSize:` driving into `NSHostingView.layout()` |

---

## 3. What was fixed (verified by measurement)

All measured with the browser actually on screen / against real files.

### 3.1 Session Browser open pinned a core — FIXED
`SessionBrowserView.swift`. The group tile grid used `LazyVGrid` inside a
`ScrollView`. A lazy grid is a lazy V-stack of lazy H-rows; inside a scroll view
each must estimate the size of tiles it has not built while
`ScrollViewUtilities.contentFrame` feeds those estimates back as the proposal. It
never converged.

**Fix:** replaced with eager `VStack`/`HStack` rows (a window's panes are a
handful of tiles; eager layout is cheap and terminates).
**Result: 100% → 0.2%.** `LazyVStackLayout`/`LazyHStackLayout` gone from samples.

### 3.2 Resize with browser open pinned a core — FIXED
`SessionBrowserController.swift`. The browser is a singleton with
`isReleasedWhenClosed = false` and implemented **no** `NSWindowDelegate` close
handling, so closing it only hid the window. Its `NSHostingView` and whole
SwiftUI graph stayed resident and took part in every layout pass; each window
resize drove AppKit's `_layoutSubtreeWithOldSize:` into `NSHostingView.layout()`
for an invisible window.

**Fix:** `windowWillClose` sets `contentView = nil`; `show()` rebuilds it via
`installContentView()`.
**Result: 100% → 0.5%.**

### 3.3 Opening a window from the browser reloaded the list — FIXED
`open()` / `openGroup()` called `reload()` while the browser stayed on screen,
re-laying-out the whole session list at the moment a new terminal window was
being built. Now they call `dismissAfterOpening()` instead.

### 3.4 Transcript read cost (the "leak") — FIXED
`AgentTranscript.swift` + `AgentOverviewPane.swift`. Each agent overview pane
read a **12 MB tail** of the Claude JSONL and JSON-parsed it **every 1.5 s**.

User's real files: `dev/fasmac` largest is **69.5 MB** (227 MB total),
`dev/tow` 36 MB, `dev/trm` 12.9 MB.

Measured on the 69.5 MB file: a 12 MB window costs **~156 ms** to read+parse. Six
overview panes = **~0.94 s of work per 1.5 s tick** (≈63% of a core, permanently)
plus megabytes of transient Foundation objects per pass. This is almost certainly
the memory growth the user called a "leak".

**Fix:** `tailBytes` 12 MB → **3 MB** (both `AgentTranscriptReader` and
`CodexTranscriptReader`), plus phase-staggered poll timers so panes created
together don't parse on the same tick.
**Result: 156 ms → 41–49 ms per read.** Verified the 3 MB window still yields both
`lastUserPrompt` and the assistant message on all three real projects, and still
clears a ~2.7 MB base64 screenshot line (the original reason for MB-sized
windows). Samples now show **zero** transcript-parsing frames.

### 3.5 `fullHistory` round-trip bug — FIXED
trm wrote `overview_mode = "fullHistory"` but
`AgentOverviewSections(tomlValue:)` only parsed `prompt|activity|reply|errors`,
so every restored overview silently fell back to `.default`. Now accepted as
"all sections".

### 3.6 zmx leader-on-connect (committed, HEAD)
`vendor/zmx/src/main.zig`: upstream promotes a leader only on user *input*, and
only the leader may resize the pty. A pane restored into a session whose previous
client disconnected had its resize dropped. Now a connecting client claims vacant
leadership. Recorded in `vendor/zmx/UPSTREAM`. **This is real but was NOT the
cause of the spin.**

---

## 4. THE KEY FINDING — the spin is not about Agent Overviews

Most of the investigation targeted `AgentOverviewView`, because the spin always
reproduced with `recovered.toml` (6 terminals + 6 `agent_overview` panes). **That
was a red herring.**

On 2026-08-12 the user launched trm and got 7 restored windows (debris from a test
harness). That instance was spinning at 100% / 660 MB. Its sample
(`sample-7windows-no-overviews.txt`) shows the **identical loop signature** in
windows containing:

- **zero** `agent_overview` panes
- **zero** `zmx_session` references
- 6 plain terminal panes each, `cwd = /Users/gaurav`
- 140-byte scrollback files

So the spin needs **neither overview panes, nor transcripts, nor attached
sessions.** Any hypothesis rooted in `AgentOverviewView` is disproven.

### Attempts to reproduce synthetically — ALL CLEAN (could not reproduce)

| Config | Result |
|---|---|
| 1 window, 6 plain panes, 1×6 | ~2% |
| 3 windows via manifest | 2.2% |
| 7 windows via manifest | 1.8% |
| 7 windows + Session Browser open | clean |
| 6 terminals + 1/2/4/6 overviews (synthetic, `prompt,activity,reply`) | 3.1 / 2.8 / 3.1 / **3.9%** |
| 6 terminals + 6 overviews, `fullHistory` | 3.6% |
| `recovered.toml` (6 terminals + 6 overviews) | **100% — spins every time** |

Note row 5: **six overview panes restoring simultaneously does NOT reproduce it.**
This directly refutes the "too many overviews at once" hypothesis, and means
staggering their *creation* would not help (staggering their *polling* was still
worth doing for §3.4, but it is a separate concern).

### The open question

`recovered.toml` spins; a structurally identical synthetic config does not. The
difference must be in what those specific panes bind to at runtime. Leading
untested candidate: the 7 spinning windows had **non-empty `scrollback_file`
entries** being restored into panes, which none of the clean synthetic configs
had. That is the next experiment.

---

## 5. What was tried and did NOT work

Five fixes were shipped, measured, and **failed**. All have been reverted; none
are in the current tree. Do not retry these:

1. **Double-attach guard** — theory that two zmx clients on one PTY wedged it.
   Wrong: zmx is multi-client by design and broadcasts to all. (The
   reveal-instead-of-reopen behaviour was kept as a UX improvement.)
2. **zmx leader-on-connect** — real bug, fixed, but did not stop the spin.
3. **`codeBlock` horizontal `ScrollView` rewrite** (`AgentOverviewView`) — the
   nested-scroll-view-vs-`.infinity`-frame theory. Tried both a `GeometryReader`
   wrapper and a full rewrite to wrapping text. Neither changed the spin.
4. **`GeometryReader` supplying a definite height to the overview's outer
   `ScrollView`** — reverted; no effect. (Note: this construct *appeared* in the
   loop head in one sample, which is misleading — removing it changed nothing.)
5. **Clamping the overview pane in `TrmGridView`** (`.frame(maxWidth/maxHeight:
   .infinity)` + `.clipped()`) — no effect. A reduced version was kept because it
   is harmless and stops a short message leaving the pane part-empty.
6. **`minimumScaleFactor` → fixed font size** on the browser's `PaneWatermark` —
   theory that the width↔font-size search never converged. No measurable effect,
   but kept: it is strictly cheaper and renders identically.

---

## 6. METHODOLOGY WARNING — read this before trusting any measurement

Several conclusions in this investigation were **wrong because the measurement was
invalid**. The failure mode: driving the UI with AppleScript
`click at {x, y}`, where the click silently misses (window moved, scrolled, or not
yet loaded), no window opens, and CPU is then measured on an **idle app** — which
reads as a clean pass.

This produced at least three false conclusions ("the grid is innocent",
"`messageSection` is the culprit", "`codeBlock` is confirmed"), each of which cost
a build/install/reproduce cycle.

**Always verify the action actually happened before trusting CPU numbers.** The
guard used here:

```bash
ZMX_DIR=$HOME/.trm/zmx /Applications/trm.app/Contents/MacOS/zmx list \
  | grep -c 'clients=1'     # must be >= 6 for recovered.toml, else DISCARD the run
```

When that guard was added, an earlier "messageSection is the culprit" result
reversed to "still spins".

---

## 7. Reproduction recipe

```bash
# 1. Ensure the 6 sessions recovered.toml references are alive:
ZMX_DIR=$HOME/.trm/zmx /Applications/trm.app/Contents/MacOS/zmx list
#    needs: trm-327321e2 trm-0e67b2e9 trm-0e716674 trm-68c70449 trm-856d1c68 trm-fad1a43e

# 2. Launch trm, open Session Browser (Cmd+Shift+S), click "Open Window"
#    on the `recovered` group.

# 3. VERIFY it actually opened (see §6) — must show 6 attached.

# 4. Watch CPU:
P=$(pgrep -f '/Applications/trm.app/Contents/MacOS/trm$')
for i in $(seq 1 20); do printf "%s " "$(ps -o %cpu= -p $P|tr -d ' ')"; sleep 0.5; done

# 5. Sample it:
sample $P 5 -file /tmp/spin.txt
```

`recovered.toml` lives in `~/Library/Application Support/trm/sessions/`.

---

## 8. Suggested next steps

1. **Test the scrollback hypothesis.** Build a config whose panes have non-empty
   `scrollback_file` entries (the clean synthetic tests all lacked these) and see
   whether that alone reproduces the spin. This is the single most promising
   untested difference.
2. **Bisect `TrmGridView` by construct, not by guess.** The loop head is
   `GeometryReaderLayout.placeSubviews` → `_ZStackLayout.sizeThatFits` →
   `explicitAlignment`. `TrmGridView.content` (multi-pane path,
   `TrmGridView.swift:286`) is
   `ZStack { GeometryReader { ZStack(alignment: .topLeading) { ... } } }` — note
   the inner ZStack's explicit `.topLeading`, which is what puts alignment-guide
   resolution inside the sizing pass.

   Candidates worth stubbing **one at a time** (each an `.overlay(...)` on the
   pane cell; `liveSummaryOverlay` carries an explicit `alignment: .bottom`,
   making it the most suspicious given the trace):
   - `TrmGridView.swift:990` `.overlay(watermarkOverlay(forPaneId:))`
   - `TrmGridView.swift:991` `.overlay(servicePluginOverlays(forPaneId:))`
   - `TrmGridView.swift:992` `.overlay(liveSummaryOverlay(forPaneId:), alignment: .bottom)`
   - the same trio on the non-stacked path at `:742`, `:754`, `:757`, `:760`
   - per-cell `.position(...)` + `.animation(value: PaneSlot(...))`
     (`TrmGridView.swift:324-343`)

   Stubbing the entire overview body to `Color.gray` DID stop the spin in one
   valid run, but disabling `messageSection` alone did NOT. So stub at the
   **pane-cell level in `TrmGridView`**, not inside `AgentOverviewView`.
3. **Consider `Self._printChanges()`** or Instruments' SwiftUI template to see
   which view's body is re-evaluating, rather than inferring from stacks.
4. **Do not re-litigate the Agent Overview.** §4 rules it out.

---

## 9. Current state of the working tree

Uncommitted, all building and installed (`/Applications/trm.app`, 2026-08-12 07:09):

```
CHANGELOG.md                                    |  1 +
macos/Sources/Features/Terminal/AgentOverviewPane.swift | 20 +   (poll stagger)
macos/Sources/Features/Terminal/AgentOverviewView.swift | 89 +-  (codeBlock wrap, VStack)
macos/Sources/Features/Terminal/AgentTranscript.swift   | 16 +-  (3MB tail, fullHistory)
macos/Sources/Features/Terminal/SessionBrowserController.swift | 62 +- (teardown, dismiss)
macos/Sources/Features/Terminal/SessionBrowserView.swift       | 92 +- (eager grid, watermark)
macos/Sources/Features/Terminal/TrmGridView.swift              | 13 +- (overview frame)
```

No debug stubs remain (`grep -rn "BISECT" macos/Sources` is clean).

Build: `zig build -Doptimize=ReleaseFast -Dxcframework-target=native -Demit-macos-app=true`
Install: `./scripts/reinstall-trm.sh "$(pwd)/zig-out/trm.app"`
(Must use `/opt/homebrew/opt/zig@0.15/bin/zig`, not bare `zig`.)
