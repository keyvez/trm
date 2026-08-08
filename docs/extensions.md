# trm Extensions

Extensions live at `~/Library/Application Support/trm/extensions/<name>/`
with an `extension.toml` manifest. They hot-reload when edited, can be
disabled per pane (like built-in plugins) or globally
(`defaults write` key `trm.ext.enabled.<name>`), and come in two kinds.

The fastest way to create one: **command palette → "Create Extension..."**
or `trm ext create "<description>"`. The configured LLM generates the
extension, trm validates and dry-runs it, and you confirm its capability
list before it installs.

## Kind 1: rules (preferred)

Declarative if-this-then-that. No code runs — triggers and actions are
evaluated natively with per-rule cooldowns and bounded regex inputs, so a
rules extension cannot leak memory or hang trm.

```toml
name = "build-fail-notify"
version = "1"
kind = "rules"
description = "Notify when a build fails"

[[rules]]
cooldown_seconds = 10          # min seconds between fires (default 5)

[rules.trigger]
type = "output_regex"          # see trigger list
pattern = "BUILD FAILED"
scope = "all"                  # all | watermark:<name> | pane:<id>

[[rules.actions]]
type = "notify"
title = "Build failed"
body = "A pane printed BUILD FAILED"

[[rules.actions]]
type = "set_watermark"
pane = "trigger"               # the pane that fired, or a fixed id
watermark = "FAILED"
```

**Triggers**

| type               | fields             | fires when                                    |
| ------------------ | ------------------ | --------------------------------------------- |
| `output_regex`     | `pattern`, `scope` | a pane's visible text matches (polled ~3s)    |
| `command_finished` | `scope`            | a shell command finishes (OSC 133)            |
| `pane_closed`      |                    | a pane closes                                 |
| `attention`        |                    | an agent needs attention (notification rings) |
| `context_usage`    | `threshold_pct`    | context usage crosses the threshold (edge)    |
| `interval`         | `seconds`          | every N seconds (fires once app-wide)         |

**Actions**: `send_command`, `send_to_all`, `set_watermark`, `set_title`,
`clear_watermark`, `focus_pane`, `spawn_pane`, `close_pane`, `message`,
`notify` (`title`/`body`), `run_shell` (`command`, detached, 30s timeout),
`open_url` (`url`). Pane-targeted actions take `pane = "trigger"` (default)
or a pane id.

## Kind 2: program

An executable in any language, speaking newline-delimited JSON on
stdin/stdout. Programs run out-of-process under supervision:

- crash → restart with backoff (2s/4s/8s, then left dead until reload)
- memory over `memory_limit_mb` (default 256) → SIGKILL + supervised restart
- CPU over `cpu_limit_seconds` (default 300) → killed by `ulimit -t`
- actions are **capability-gated**; ~20 denials kills the extension

```toml
name = "agent-quota"
kind = "program"
description = "Claude context usage pill"
exec = "agent-quota.py"
capabilities = []              # display-only needs none
memory_limit_mb = 64
```

Capabilities: `send_input` (send_command/send_to_all), `pane_control`
(spawn/close/focus panes, open_url), `pane_decorate` (watermarks/titles),
`notifications` (notify). Terminal output events are always delivered.

**Protocol.** Print `{"type": "ready"}` at startup and flush every line.

Host → plugin events:

```json
{"type":"configure","config":{"patterns":["..."]}}
{"type":"start"}
{"type":"terminal_output","pane":0,"text":"...","hash":"..."}
{"type":"pane_closed","pane":0}
{"type":"command_finished","pane":0}
{"type":"context_usage","used_tokens":120000,"total_tokens":200000,"percentage":60,"session_id":"..."}
{"type":"stop"}
```

Plugin → host messages:

```json
{"type":"ready"}
{"type":"state","overlay":"metric_pill","alignment":"toptrailing","panes":{"0":["ctx","60%","yellow"]}}
{"type":"action","actions":[{"type":"notify","title":"t","body":"b"}]}
{"type":"error","message":"..."}
```

Overlay templates (the host renders everything; plugins send only data):
`metric_pill` (`["label","value","green|yellow|red|gray"]`),
`attention_icon` (`true`), `process_pill` (`true`),
`server_url_banner` (`["url", ...]`).

See `examples/extensions/agent-quota/` for a complete working program.
