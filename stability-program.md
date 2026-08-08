# trm Stability Research Program

Adapted from Karpathy's autoresearch protocol. Instead of optimizing val_bpb,
we optimize for **zero crashes, zero undefined behavior, and robust error handling**
in the termania Zig codebase.

## Metric

Each experiment is measured by:
- `zig build test` — must pass (0 failures)
- `zig build` — must compile cleanly
- Code review: does the change eliminate a real crash/UB/data-loss path?

## Scope

Only files in `src/termania/` are modified:
- `capi.zig` — C API boundary, FFI safety
- `text_tap.zig` — Unix socket server, client handling
- `llm.zig` — LLM response parsing, action dispatch
- `config.zig` — TOML config parsing
- `grid.zig` — Grid layout management
- `input.zig` — Input state machine
- `plugin.zig` — Plugin lifecycle

## Experiment Loop

LOOP FOREVER:

1. Identify a specific bug, crash path, or undefined behavior
2. Write a targeted fix (minimal, focused)
3. `zig build test` — verify no regressions
4. `zig build` — verify clean compilation
5. If both pass: commit with `fix: <description>`
6. If tests fail: revert and try a different approach
7. Log result in `stability-results.tsv`

## Issue Categories (priority order)

1. **CRITICAL**: Buffer overflows, use-after-free, undefined behavior, panics
2. **HIGH**: Silent data loss, unhandled errors, resource leaks
3. **MEDIUM**: Missing bounds checks, edge case handling
4. **LOW**: Code quality, defensive programming

## Rules

- One fix per commit — atomic, reviewable changes
- Never break existing tests
- Add tests for every fix where possible
- Simpler fixes are better — don't over-engineer
- If a fix is risky, skip it
