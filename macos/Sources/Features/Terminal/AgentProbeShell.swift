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

    /// POSIX-shell counterpart of `AgentSessionLocator.latestClaudeTranscript`.
    ///
    /// Claude keeps one process alive across `/clear`, but moves the chat to a
    /// new JSONL. `bridgeSessionId` stays stable for that process and differs
    /// between neighbouring panes, while `lastSequenceNum` advances across
    /// the replacement files. Keep this fragment shared by both remote probe
    /// implementations so an Overview and the Session Browser cannot drift.
    static let claudeBridgeFunctions: String = [
        "claude_bridge_line() {",
        "  tail -c 262144 \"$1\" 2>/dev/null",
        "    | grep '\"type\"[[:space:]]*:[[:space:]]*\"bridge-session\"'",
        "    | tail -1;",
        "};",
        "claude_bridge_id() {",
        "  printf '%s\\n' \"$1\"",
        "    | sed -n 's/.*\"bridgeSessionId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p';",
        "};",
        "claude_bridge_sequence() {",
        "  printf '%s\\n' \"$1\"",
        "    | sed -n 's/.*\"lastSequenceNum\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p';",
        "};",
        "claude_bridge_latest() {",
        "  current=\"$1\"; [ -f \"$current\" ] || return 0;",
        "  line=\"$(claude_bridge_line \"$current\")\";",
        "  bridge=\"$(claude_bridge_id \"$line\")\";",
        "  [ -n \"$bridge\" ] || { printf '%s\\n' \"$current\"; return 0; };",
        "  currentb=\"$(stat -f %B \"$current\" 2>/dev/null)\";",
        "  [ -n \"$currentb\" ] || { printf '%s\\n' \"$current\"; return 0; };",
        "  best=\"$current\"; bestb=\"$currentb\";",
        "  bestseq=\"$(claude_bridge_sequence \"$line\")\";",
        "  case \"$bestseq\" in ''|*[!0-9]*) bestseq=0 ;; esac;",
        "  dir=${current%/*};",
        "  for f in \"$dir\"/*.jsonl; do",
        "    [ -f \"$f\" ] || continue; [ \"$f\" != \"$current\" ] || continue;",
        "    b=\"$(stat -f %B \"$f\" 2>/dev/null)\";",
        "    [ -n \"$b\" ] && [ \"$b\" -ge \"$currentb\" ] || continue;",
        "    candidate=\"$(claude_bridge_line \"$f\")\";",
        "    id=\"$(claude_bridge_id \"$candidate\")\"; [ \"$id\" = \"$bridge\" ] || continue;",
        "    seq=\"$(claude_bridge_sequence \"$candidate\")\";",
        "    case \"$seq\" in ''|*[!0-9]*) seq=0 ;; esac;",
        "    take=0; [ \"$seq\" -gt \"$bestseq\" ] && take=1;",
        "    [ \"$seq\" -eq \"$bestseq\" ] && [ \"$b\" -gt \"$bestb\" ] && take=1;",
        "    if [ \"$take\" -eq 1 ]; then best=\"$f\"; bestb=\"$b\"; bestseq=\"$seq\"; fi;",
        "  done;",
        "  printf '%s\\n' \"$best\";",
        "};",
    ].joined(separator: " ")

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
    /// file written since the agent started, preferring the earliest file born
    /// at/after that process over one admitted only by clock slack, and for
    /// Codex the rollout whose own `cwd` matches the agent's.
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
        "  after=\"\"; afterb=0; afterstub=\"\"; afterstubb=0;",
        "  before=\"\"; beforeb=0; beforestub=\"\"; beforestubb=0;",
        "  for f in \"$dir\"/*.jsonl; do",
        "    [ -e \"$f\" ] || continue;",
        "    b=\"$(stat -f %B \"$f\" 2>/dev/null)\" || continue;",
        "    m=\"$(stat -f %m \"$f\" 2>/dev/null)\" || continue;",
        "    [ \"$b\" -ge \"$earliest\" ] || continue;",
        "    [ \"$m\" -ge \"$started\" ] || continue;",
        "    isstub=0; [ $(( m - b )) -lt 60 ] && [ $(( now - m )) -gt 300 ] && isstub=1;",
        "    if [ \"$b\" -ge \"$started\" ]; then",
        "      if [ \"$isstub\" -eq 1 ]; then",
        "        if [ -z \"$afterstub\" ] || [ \"$b\" -lt \"$afterstubb\" ]; then afterstub=\"$f\"; afterstubb=\"$b\"; fi;",
        "      elif [ -z \"$after\" ] || [ \"$b\" -lt \"$afterb\" ]; then after=\"$f\"; afterb=\"$b\"; fi;",
        "    else",
        // When clock slack is needed, the closest pre-start file is the
        // plausible one — not the oldest file admitted by the entire window.
        "      if [ \"$isstub\" -eq 1 ]; then",
        "        if [ -z \"$beforestub\" ] || [ \"$b\" -gt \"$beforestubb\" ]; then beforestub=\"$f\"; beforestubb=\"$b\"; fi;",
        "      elif [ -z \"$before\" ] || [ \"$b\" -gt \"$beforeb\" ]; then before=\"$f\"; beforeb=\"$b\"; fi;",
        "    fi;",
        "  done;",
        "  if [ -n \"$after\" ]; then printf '%s\\n' \"$after\";",
        "  elif [ -n \"$afterstub\" ]; then printf '%s\\n' \"$afterstub\";",
        "  elif [ -n \"$before\" ]; then printf '%s\\n' \"$before\";",
        "  elif [ -n \"$beforestub\" ]; then printf '%s\\n' \"$beforestub\";",
        "  else newest_jsonl \"$dir\"; fi;",
        "};",

        claudeBridgeFunctions,

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
        "  AG=\"$(agent_under \"$SP\")\"; [ -n \"$AG\" ] || return 0;",
        "  AP=\"${AG%% *}\"; AK=\"${AG##* }\";",
        // The hook's record when there is one: the agent's own word about
        // where it writes beats anything inferred from timestamps. Records
        // outlive processes, though, so require both a fresh record and a path
        // kind that agrees with the process currently in this pane.
        "  ST=\"$(started_at \"$AP\")\";",
        "  if [ -n \"$2\" ] && [ -f \"$HOME/.trm/agent-sessions/$2\" ]; then",
        "    REC=\"$HOME/.trm/agent-sessions/$2\"; RP=\"$(cat \"$REC\" 2>/dev/null)\";",
        "    RM=\"$(stat -f %m \"$REC\" 2>/dev/null)\"; fresh=1;",
        "    [ -n \"$ST\" ] && { [ -n \"$RM\" ] && [ \"$RM\" -ge $(( ST - 30 )) ]; } || fresh=0;",
        "    if [ \"$fresh\" -eq 1 ] && [ -n \"$RP\" ] && [ -f \"$RP\" ]; then",
        "      case \"$AK:$RP\" in",
        "        codex:*/.codex/sessions/*.jsonl) echo \"codex $RP\"; return 0 ;;",
        "        claude:*/.claude/projects/*.jsonl) RP=\"$(claude_bridge_latest \"$RP\")\"; echo \"claude $RP\"; return 0 ;;",
        "      esac;",
        "    fi;",
        "  fi;",
        "  ACWD=\"$(cwd_of \"$AP\")\";",
        "  if [ \"$AK\" = codex ]; then",
        "    P=\"$(codex_rollout \"$ACWD\" \"$ST\")\";",
        "    [ -n \"$P\" ] || P=\"$(codex_rollout \"$ACWD\" \"\")\";",
        "    [ -n \"$P\" ] || P=\"$(find \"$HOME/.codex/sessions\" -type f -name '*.jsonl' 2>/dev/null -exec ls -t {} + 2>/dev/null | head -1)\";",
        "    [ -n \"$P\" ] && echo \"codex $P\"; return 0;",
        "  fi;",
        "  [ -n \"$ACWD\" ] || return 0;",
        "  ENC=\"$(printf %s \"$ACWD\" | tr './_' '---')\";",
        "  P=\"$(born_after \"$HOME/.claude/projects/$ENC\" \"$AP\")\";",
        "  [ -n \"$P\" ] && P=\"$(claude_bridge_latest \"$P\")\";",
        "  [ -n \"$P\" ] && echo \"claude $P\";",
        "};",
    ].joined(separator: " ")
}
