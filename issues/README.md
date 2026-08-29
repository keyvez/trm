# Per-issue files

One file per tracked issue. `ISSUES.md` at the repo root stays the index —
it holds the report and the status. These files hold the record: what was
wrong, what was actually done about it, how it was verified, and what a
reviewer should look at.

The split is deliberate. Duplicating the report into both places would let
them drift, and the index is the thing people scan.

## What is committed

Only `issues/*.md`. `issues/artifacts/` is gitignored — screenshots, screen
recordings, logs and raw payloads go there and can be as large and as messy
as they need to be.

trm itself appends to `issues/artifacts/<ID>/responses.md` when you answer an
issue from the checklist window, and writes the "work on this next" marker to
`issues/artifacts/next.md`. It never edits `ISSUES.md` or these records.

## Status values

    DEPLOYED  fixed and live
    STAGED    fixed in a working tree, not deployed
    OPEN      not fixed
