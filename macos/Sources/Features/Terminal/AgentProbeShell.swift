import Foundation

/// The shell that finds an agent's transcript on a machine, wherever that
/// machine is.
///
/// Two things need this and used to carry their own copy: the Agent Overview's
/// mirror, resolving one pane's transcript to stream, and the Session Browser,
/// resolving one per session to summarise. They drifted — the browser's copy
/// only read the hook's record, so on a machine without the hook installed
/// every tile fell back to `claude --dangerously-skip-permissions`, which is
/// the same tile for every pane and no use for finding anything.
///
/// Kept as shell rather than sent as a program because the far side is only
/// ever asked to run `/bin/sh`: no trm version, no interpreter, nothing to
/// install.
enum AgentProbeShell {

    /// Functions the callers compose with. Defines, in order:
    ///
    /// - `cwd_of <pid>` — a process's working directory
    /// - `started_at <pid>` — unix time it started
    /// - `agent_under <shell-pid>` — prints `<pid> <claude|codex>` for the
    ///   agent running under a shell, walking a few levels down
    /// - `resolve_transcript <shell-pid>` — prints `<kind> <path>`, the whole
    ///   answer
    ///
    /// The selection rules match `AgentSessionLocator` on the local side: a
    /// file written since the agent started, preferring the earliest such file
    /// over a later one made beside it, and for Codex the rollout whose own
    /// `cwd` matches the agent's.
    static let functions: String = [
        "cwd_of() { lsof -a -p \"$1\" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; };",
        "newest_jsonl() { ls -t \"$1\"/*.jsonl 2>/dev/null | head -1; };",

        "started_at() {",
        "  et=\"$(ps -o etime= -p \"$1\" 2>/dev/null | tr -d ' ')\";",
        "  [ -n \"$et\" ] || return 0;",
        "  secs=\"$(printf %s \"$et\" | awk -F'[-:]' '{ if (NF==4) print $1*86400+$2*3600+$3*60+$4; else if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print $1 }')\";",
        "  echo $(( $(date +%s) - secs ));",
        "};",

        "agent_under() {",
        "  queue=\"$1\"; depth=0;",
        "  while [ -n \"${queue# }\" ] && [ \"$depth\" -lt 6 ]; do",
        "    next=\"\";",
        "    for pid in $queue; do",
        "      base=\"$(basename \"$(ps -o comm= -p \"$pid\" 2>/dev/null)\" 2>/dev/null)\";",
        "      case \"$base\" in",
        "        claude) echo \"$pid claude\"; return 0 ;;",
        "        codex)  echo \"$pid codex\"; return 0 ;;",
        "      esac;",
        "      next=\"$next $(pgrep -P \"$pid\" 2>/dev/null | tr '\\n' ' ')\";",
        "    done;",
        "    queue=\"$next\"; depth=$((depth+1));",
        "  done;",
        "};",

        // Claude: the first transcript in the project directory born after the
        // agent started and written to since — which is what rules out a stub
        // created moments before it launched.
        "born_after() {",
        "  dir=\"$1\"; apid=\"$2\";",
        "  started=\"$(started_at \"$apid\")\";",
        "  [ -n \"$started\" ] || { newest_jsonl \"$dir\"; return; };",
        "  now=\"$(date +%s)\"; earliest=$(( started - 30 ));",
        "  best=\"\"; bestb=0; stub=\"\"; stubb=0;",
        "  for f in \"$dir\"/*.jsonl; do",
        "    [ -e \"$f\" ] || continue;",
        "    b=\"$(stat -f %B \"$f\" 2>/dev/null)\" || continue;",
        "    m=\"$(stat -f %m \"$f\" 2>/dev/null)\" || continue;",
        "    [ \"$b\" -ge \"$earliest\" ] || continue;",
        "    [ \"$m\" -ge \"$started\" ] || continue;",
        "    if [ $(( m - b )) -lt 60 ] && [ $(( now - m )) -gt 300 ]; then",
        "      if [ -z \"$stub\" ] || [ \"$b\" -lt \"$stubb\" ]; then stub=\"$f\"; stubb=\"$b\"; fi;",
        "      continue;",
        "    fi;",
        "    if [ -z \"$best\" ] || [ \"$b\" -lt \"$bestb\" ]; then best=\"$f\"; bestb=\"$b\"; fi;",
        "  done;",
        "  if [ -n \"$best\" ]; then printf '%s\\n' \"$best\";",
        "  elif [ -n \"$stub\" ]; then printf '%s\\n' \"$stub\";",
        "  else newest_jsonl \"$dir\"; fi;",
        "};",

        // Codex: rollouts record the directory they were started in, and that
        // is the only thing tying one to a pane — without it every Codex pane
        // on a machine binds to the same conversation.
        "codex_rollout() {",
        "  cwd=\"$1\"; started=\"$2\";",
        "  [ -n \"$cwd\" ] || return 0;",
        "  find \"$HOME/.codex/sessions\" -type f -name '*.jsonl' 2>/dev/null -exec ls -t {} + 2>/dev/null",
        "    | head -40",
        "    | while IFS= read -r f; do",
        "        h=\"$(head -1 \"$f\" 2>/dev/null)\";",
        "        case \"$h\" in",
        "          *\"\\\"cwd\\\":\\\"$cwd\\\"\"*|*\"\\\"cwd\\\": \\\"$cwd\\\"\"*) ;;",
        "          *) continue ;;",
        "        esac;",
        "        if [ -n \"$started\" ]; then",
        "          m=\"$(stat -f %m \"$f\" 2>/dev/null)\";",
        "          [ -n \"$m\" ] && [ \"$m\" -lt \"$started\" ] && continue;",
        "        fi;",
        "        echo \"$f\"; break;",
        "      done",
        "    | head -1;",
        "};",

        "resolve_transcript() {",
        "  SP=\"$1\"; [ -n \"$SP\" ] || return 0;",
        // The hook's record when there is one: the agent's own word about
        // where it writes beats anything inferred from timestamps.
        "  if [ -n \"$2\" ] && [ -f \"$HOME/.trm/agent-sessions/$2\" ]; then",
        "    RP=\"$(cat \"$HOME/.trm/agent-sessions/$2\" 2>/dev/null)\";",
        "    if [ -n \"$RP\" ] && [ -f \"$RP\" ]; then",
        "      case \"$RP\" in */.codex/*) echo \"codex $RP\" ;; *) echo \"claude $RP\" ;; esac; return 0;",
        "    fi;",
        "  fi;",
        "  AG=\"$(agent_under \"$SP\")\"; [ -n \"$AG\" ] || return 0;",
        "  AP=\"${AG%% *}\"; AK=\"${AG##* }\";",
        "  ACWD=\"$(cwd_of \"$AP\")\";",
        "  if [ \"$AK\" = codex ]; then",
        "    ST=\"$(started_at \"$AP\")\";",
        "    P=\"$(codex_rollout \"$ACWD\" \"$ST\")\";",
        "    [ -n \"$P\" ] || P=\"$(codex_rollout \"$ACWD\" \"\")\";",
        "    [ -n \"$P\" ] || P=\"$(find \"$HOME/.codex/sessions\" -type f -name '*.jsonl' 2>/dev/null -exec ls -t {} + 2>/dev/null | head -1)\";",
        "    [ -n \"$P\" ] && echo \"codex $P\"; return 0;",
        "  fi;",
        "  [ -n \"$ACWD\" ] || return 0;",
        "  ENC=\"$(printf %s \"$ACWD\" | tr './_' '---')\";",
        "  P=\"$(born_after \"$HOME/.claude/projects/$ENC\" \"$AP\")\";",
        "  [ -n \"$P\" ] && echo \"claude $P\";",
        "};",
    ].joined(separator: " ")
}
