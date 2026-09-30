#!/usr/bin/env bash
# bin/backends/tuios.sh - explicit TUIOS session-provider adapter.
#
# TUIOS owns only session/pane lifecycle. Squad and fob retain task/worktree
# ownership. Every persisted target is <session-name>:<opaque-window-id>.
# TUIOS is never inferred from ambient markers; configure it explicitly.
#
# Verified against the installed TUIOS 0.8.0 binary (`tuios --version`,
# `tuios list-verbs`, `tuios --skill`). Every mechanism used here is
# version-matched to that binary; docs/tuios-backend.md owns the behavior
# contract and docs/verification/runtime-backends.md owns the live evidence.
#
# Delivery is agent-aware. The generic UI submit uses the daemon's queue
# (`queue-prompt`), which types a message only once the agent is at rest and
# never over a prompt the agent is waiting on, and classifies the entry as
# stalled when the agent shows no sign of taking it. Success is only reported
# on an observed postcondition (the entry was taken, or it waits safely for the
# next rest); nothing is ever retyped after bytes were typed.
#
# State is read from the daemon's own report (`list-agents --all` plus
# `get-agent-state`), preserving source/confidence/harness/blocked_by
# provenance. A window holding no attributable agent is `dead`, which is the
# recovery-grade signal after a daemon restart; a classified blocking prompt is
# `blocked`, never ordinary work.

fm_backend_tuios_bin() {
  printf '%s' "${SQUAD_TUIOS_BIN:-tuios}"
}

fm_backend_tuios_cli_check() {
  local bin version major minor patch
  bin=$(fm_backend_tuios_bin)
  command -v "$bin" >/dev/null 2>&1 || { echo "error: tuios CLI not found: $bin" >&2; return 1; }
  version=$("$bin" --version 2>/dev/null) || { echo 'error: tuios version query failed' >&2; return 1; }
  version=$(printf '%s\n' "$version" | sed -nE 's/^tuios version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1)
  [ -n "$version" ] || { echo 'error: unrecognized tuios version output' >&2; return 1; }
  IFS=. read -r major minor patch <<EOF
$version
EOF
  case "$patch" in ''|*[!0-9]*) echo 'error: malformed TUIOS version' >&2; return 1 ;; esac
  { [ "$major" -gt 0 ] || { [ "$major" -eq 0 ] && [ "$minor" -ge 8 ]; }; } || {
    echo "error: tuios >=0.8.0 is required; found $version" >&2
    return 1
  }
}

fm_backend_tuios_tool_check() {
  fm_backend_tuios_cli_check || return 1
  command -v jq >/dev/null 2>&1 || { echo "error: backend=tuios selected but 'jq' is not installed (required to parse TUIOS JSON output)" >&2; return 1; }
}

fm_backend_tuios_cli() {  # <session> <verb> <args...>
  local session=$1 verb=$2
  shift 2
  [ -n "$session" ] || { echo 'error: TUIOS session is required' >&2; return 1; }
  "$(fm_backend_tuios_bin)" "$verb" --session "$session" "$@"
}

# Shared jq definitions - the single owner for how a TUIOS window record is read.
# Identity candidates are collected from every documented shape and a record
# whose candidates disagree is a contradiction, never something a lookup order
# may silently resolve. `tstr`/`tbool` normalize optional scalar fields so a
# missing or differently-typed field can never fail a read that must stay
# authoritative.
# shellcheck disable=SC2016  # Single quotes are deliberate: $v/$r belong to the jq program, not the shell.
SQUAD_BACKEND_TUIOS_JQ_LIB='
  def tstr($v): if ($v | type) == "string" then $v else "" end;
  def tbool($v): if ($v | type) == "boolean" then $v else false end;
  def tnum($v): if ($v | type) == "number" then $v else 0 end;
  def tids: [ (.id // empty), (.window_id // empty),
              (if (.window | type) == "object" then (.window.id // empty) else (.window // empty) end) ]
            | map(select(type == "string" and length > 0));
  def tlabels: [ (.name // empty), (.title // empty), (.custom_name // empty), (.display_name // empty),
                 (if (.window | type) == "object" then (.window.name // empty), (.window.title // empty), (.window.custom_name // empty), (.window.display_name // empty) else empty end) ]
            | map(select(type == "string" and length > 0));
  def tworkspaces: [ (.workspace // empty),
                     (if (.window | type) == "object" then (.window.workspace // empty) else empty end) ]
                   | map(select(type == "number"));
  def terror: [ (.error? // empty)
                | if type == "object" then (.code // .message // .detail // empty) else . end
                | select(type == "string" and length > 0) ]
            | length > 0;
'

fm_backend_tuios_list_windows_json() {  # <session> -> validated windows inventory
  local session=$1 json
  json=$(fm_backend_tuios_cli "$session" list-windows --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    type == "object"
    and (terror | not)
    and (.windows | type == "array")
    and all(.windows[]; type == "object" and ((tids | unique | length) == 1))
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}

fm_backend_tuios_workspace_setting() {  # -> configured integer, or empty when disabled
  local file="${SQUAD_BACKEND_CONFIG_DIR}/tuios-workspace" value
  local -a lines=()
  [ -f "$file" ] || { printf ''; return 0; }
  mapfile -t lines < "$file" || { echo 'error: cannot read config/tuios-workspace' >&2; return 1; }
  [ "${#lines[@]}" -eq 1 ] || {
    echo 'error: config/tuios-workspace must contain exactly one line' >&2
    return 1
  }
  value=${lines[0]}
  [ -n "$value" ] && [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || {
    echo 'error: config/tuios-workspace must contain one non-negative workspace number' >&2
    return 1
  }
  printf '%s' "$value"
}

fm_backend_tuios_list_workspaces_json() {  # <session> -> validated authoritative inventory
  local session=$1 json
  json=$(fm_backend_tuios_cli "$session" list-workspaces --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e '
    type == "object" and (.success == true) and (.workspaces | type == "array")
    and all(.workspaces[]; type == "object" and (.workspace | type == "number" and floor == .))
    and ([.workspaces[].workspace] | unique | length) == (.workspaces | length)
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}

fm_backend_tuios_validate_workspace() {  # <session> <workspace>
  local inventory=$2
  inventory=$(fm_backend_tuios_list_workspaces_json "$1") || {
    echo 'error: cannot read authoritative TUIOS workspace inventory' >&2
    return 1
  }
  printf '%s' "$inventory" | jq -e --argjson ws "$2" '[.workspaces[].workspace] | index($ws) != null' >/dev/null || {
    echo "error: configured TUIOS workspace '$2' does not exist in the session" >&2
    return 1
  }
}

fm_backend_tuios_parse_target() {  # <target> -> session and opaque window id globals
  local target=$1
  case "$target" in *:*) ;; *) return 1 ;; esac
  SQUAD_BACKEND_TUIOS_SESSION=${target%%:*}
  SQUAD_BACKEND_TUIOS_WINDOW=${target#*:}
  [ -n "$SQUAD_BACKEND_TUIOS_SESSION" ] && [ -n "$SQUAD_BACKEND_TUIOS_WINDOW" ] \
    && [ "$SQUAD_BACKEND_TUIOS_WINDOW" != "$target" ] \
    && ! printf '%s' "$SQUAD_BACKEND_TUIOS_WINDOW" | grep -q ':'
}

fm_backend_tuios_window_info() {  # <session> <opaque-window-id>
  local session=$1 window=$2 json
  json=$(fm_backend_tuios_cli "$session" get-window --json -- "$window" 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e --arg id "$window" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    (terror | not)
    and ((tids | unique | length) == 1)
    and ((tids | index($id)) != null)
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}

fm_backend_tuios_target_ready() {  # <target> [expected-label]
  local target=$1 expected=${2:-} info
  fm_backend_tuios_parse_target "$target" || return 1
  info=$(fm_backend_tuios_window_info "$SQUAD_BACKEND_TUIOS_SESSION" "$SQUAD_BACKEND_TUIOS_WINDOW") || return 1
  if [ -n "$expected" ]; then
    printf '%s' "$info" | jq -e --arg label "$expected" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
      (tlabels | index($label)) != null
    ' >/dev/null 2>&1 || return 1
  fi
}

fm_backend_tuios_capture() {  # <target> <lines> [expected-label]
  local target=$1 lines=$2 expected=${3:-}
  fm_backend_tuios_target_ready "$target" "$expected" || return 1
  fm_backend_tuios_cli "$SQUAD_BACKEND_TUIOS_SESSION" capture-pane \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" --scrollback --lines "$lines" 2>/dev/null
}

fm_backend_tuios_send_literal() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected=${3:-}
  fm_backend_tuios_target_ready "$target" "$expected" || return 1
  fm_backend_tuios_cli "$SQUAD_BACKEND_TUIOS_SESSION" send-text \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" -- "$text"
}

fm_backend_tuios_send_key() {  # <target> <key> [expected-label]
  local target=$1 key=$2 expected=${3:-}
  fm_backend_tuios_target_ready "$target" "$expected" || return 1
  fm_backend_tuios_cli "$SQUAD_BACKEND_TUIOS_SESSION" send-keys \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" -- "$key"
}

fm_backend_tuios_send_text_line() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected=${3:-}
  # TUIOS send-text submits a command when its literal payload ends in newline.
  # Keep the shell line in one write instead of risking a stranded partial line.
  fm_backend_tuios_send_literal "$target" "$text
" "$expected"
}

fm_backend_tuios_current_path() {  # <target>
  local target=$1 windows
  fm_backend_tuios_parse_target "$target" || return 1
  # list-windows always carries the daemon cwd, while get-window omits it for a
  # session with an attached client, so read the validated inventory instead.
  windows=$(fm_backend_tuios_list_windows_json "$SQUAD_BACKEND_TUIOS_SESSION") || return 1
  printf '%s' "$windows" | jq -r --arg id "$SQUAD_BACKEND_TUIOS_WINDOW" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tids | index($id)) != null)]
    | if length == 1 then (.[0].cwd // (if (.[0].window | type) == "object" then .[0].window.cwd else empty end) // empty) else empty end'
}

# --- protocol discovery ------------------------------------------------
# The daemon's own verb catalogue is the authority for what this daemon
# supports (TUIOS --skill "The whole contract"). Each row is
# <verb>:<required-parameter,...>. Protocol discovery runs at backend
# detection (fm_backend_tuios_container_ensure) so a daemon that is older or
# narrower than this adapter fails loudly before any task is created.
SQUAD_BACKEND_TUIOS_PROTOCOL_REQUIRED='capture-pane:session,window
close-window:session,window
get-agent-state:session,window
get-window:session,window
list-agents:session,all
list-queued:session,window
list-windows:session
new-window:session,name,cwd,focus
peek-prompt:session,window
queue-prompt:session,window,text
resume-agent:session,window
send-keys:session,window
send-text:session,window'

fm_backend_tuios_protocol_check() {  # <session>
  local catalogue problems required=$SQUAD_BACKEND_TUIOS_PROTOCOL_REQUIRED workspace
  workspace=$(fm_backend_tuios_workspace_setting) || return 1
  if [ -n "$workspace" ]; then
    required="${required}
list-workspaces:session
new-window:session,name,cwd,focus,workspace"
  fi
  catalogue=$("$(fm_backend_tuios_bin)" list-verbs --json 2>/dev/null) || {
    echo 'error: TUIOS verb catalogue is unreadable; refusing to drive an unverified daemon' >&2
    return 1
  }
  if ! printf '%s' "$catalogue" | jq -e '
      type == "object"
      and ((.version // null) | type == "number")
      and ((.daemon_version // "") | type == "string" and length > 0)
      and (.verbs | type == "array" and length > 0)
      and all(.verbs[]; ((.verb // .name // "") | type == "string" and length > 0))
    ' >/dev/null 2>&1; then
    echo 'error: TUIOS verb catalogue is malformed; refusing to drive an unverified daemon' >&2
    return 1
  fi
  problems=$(printf '%s' "$catalogue" | jq -r --arg required "$required" '
    (.verbs | map({(.verb // .name): ((.params // []) | map(.name) | map(select(type == "string")))}) | add) as $have
    | $required | split("\n") | map(select(length > 0))
    | map(split(":") as $row
          | ($have[$row[0]] // null) as $params
          | if $params == null then "missing verb \($row[0])"
            else ($row[1] | split(","))[] as $p
                 | if ($params | index($p)) == null then "\($row[0]) has no parameter \($p)" else empty end
            end)
    | .[]' 2>/dev/null) || {
    echo 'error: TUIOS verb catalogue could not be validated; refusing to drive an unverified daemon' >&2
    return 1
  }
  if [ -n "$problems" ]; then
    echo "error: TUIOS daemon is missing protocol support this adapter requires: $(printf '%s' "$problems" | tr '\n' ';' | sed 's/;*$//')" >&2
    return 1
  fi
}

# --- state, prompt, and provenance -------------------------------------
# fm_backend_tuios_boot_id: the daemon's own random id for this daemon start
# (TUIOS list-verbs subscribe / docs/control-protocol). A boot id that differs
# from the one recorded at spawn is direct evidence that the daemon restarted
# and every pane came back as a fresh shell. Read-only; empty on any failure.
fm_backend_tuios_boot_id() {  # <session>
  local session=$1 out
  out=$("$(fm_backend_tuios_bin)" list-attention --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r 'if (type == "object") and ((.boot_id // "") | type == "string") then (.boot_id // empty) else empty end' 2>/dev/null
}

# fm_backend_tuios_agent_report_json: one normalized, provenance-preserving read
# of the requested window. Prints a JSON object and returns 0 when the inventory
# is authoritative; returns 1 (printing nothing) when the target is malformed or
# any read failed or contradicted itself. Fields come straight from the daemon's
# own report: state, source, confidence, harness_id, foreground, needs_you,
# blocked_by, ready, completion_seq, finished_unread, agent_session_id, queued.
fm_backend_tuios_agent_report_json() {  # <target>
  local target=$1 windows present agents
  fm_backend_tuios_parse_target "$target" || return 1
  windows=$(fm_backend_tuios_list_windows_json "$SQUAD_BACKEND_TUIOS_SESSION") || return 1
  present=$(printf '%s' "$windows" | jq -r --arg id "$SQUAD_BACKEND_TUIOS_WINDOW" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tids | index($id)) != null)] | length' 2>/dev/null) || return 1
  case "$present" in
    0) printf '{"present":false}'; return 0 ;;
    1) : ;;
    *) return 1 ;;
  esac
  agents=$(fm_backend_tuios_cli "$SQUAD_BACKEND_TUIOS_SESSION" list-agents --all --json 2>/dev/null) || return 1
  printf '%s' "$agents" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    type == "object"
    and (terror | not)
    and ((.agents // []) | type == "array")
    and all((.agents // [])[]; type == "object" and ((tids | unique | length) == 1))
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$agents" | jq -c --arg id "$SQUAD_BACKEND_TUIOS_WINDOW" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    ([.agents[] | select((tids | index($id)) != null)]
     | unique_by(tids | unique | join(","))) as $match
    | if ($match | length) != 1 then {"present": true, "contradictory": true}
      else ($match[0]) as $r
        | (if tstr($r.display_name) != "" then tstr($r.display_name) else tstr($r.name) end) as $name
        | {
            present: true,
            contradictory: false,
            name: $name,
            state: tstr($r.state),
            source: tstr($r.source),
            confidence: tstr($r.confidence),
            harness_id: tstr($r.harness_id),
            foreground: tstr($r.foreground),
            agent_session_id: tstr($r.agent_session_id),
            needs_you: tbool($r.needs_you),
            blocked_by: tstr($r.blocked_by),
            ready: tbool($r.ready),
            completion_seq: tnum($r.completion_seq),
            finished_unread: tbool($r.finished_unread),
            queued: tnum($r.queued)
          }
      end'
}

# fm_backend_tuios_attributed: 0 when a normalized report carries positive agent
# attribution (a named harness, a detected foreground program, or a non-default
# report confidence). A bare shell reports state=none with all three empty, so
# this is what separates "restored agentless pane" from "agent is running".
fm_backend_tuios_attributed() {  # <report-json>
  printf '%s' "$1" | jq -e '
    ((.harness_id // "") | length > 0)
    or ((.foreground // "") | length > 0)
    or (((.confidence // "") | length > 0) and (.confidence != "none"))' >/dev/null 2>&1
}

fm_backend_tuios_composer_state() {  # <target>
  # The daemon exposes no generic "ordinary composer is empty" bit, and raw UI
  # text is not proof of delivery, so this stays unknown. A classified blocking
  # prompt is never reported as an empty composer either, so no caller types
  # into a pane that is waiting on a prompt.
  printf 'unknown'
}

fm_backend_tuios_busy_state() {  # <target>
  local target=$1 report state
  report=$(fm_backend_tuios_agent_report_json "$target") || { printf 'unknown'; return 0; }
  [ "$(printf '%s' "$report" | jq -r '.present')" = true ] || { printf 'unknown'; return 0; }
  [ "$(printf '%s' "$report" | jq -r '.contradictory')" = true ] && { printf 'unknown'; return 0; }
  state=$(printf '%s' "$report" | jq -r '.state')
  case "$state" in
    working) printf 'busy' ;;
    # needs_input (approval or question) and errored are the daemon's own
    # "a person is needed" states (needs_you). Neither is ordinary work.
    needs_input|errored) printf 'blocked' ;;
    idle|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_tuios_agent_state() {  # <target>
  local target=$1 report state
  report=$(fm_backend_tuios_agent_report_json "$target") || { printf 'unreadable'; return 0; }
  [ "$(printf '%s' "$report" | jq -r '.present')" = true ] || { printf 'missing'; return 0; }
  [ "$(printf '%s' "$report" | jq -r '.contradictory')" = true ] && { printf 'unreadable'; return 0; }
  # Positive attribution is what makes an agent certified as running.
  if fm_backend_tuios_attributed "$report"; then
    printf 'alive'
    return 0
  fi
  state=$(printf '%s' "$report" | jq -r '.state')
  case "$state" in
    ''|none)
      # A restored session keeps its window ids and names but starts a fresh
      # shell in every pane, so this is the post-restart "lenient endpoint, no
      # agent" case: recovery-grade `dead`, never `ambiguous`.
      printf 'dead'
      ;;
    *)
      # A state with no attribution is an incomplete or contradictory report;
      # it never licenses a duplicate relaunch, so it stays ambiguous.
      printf 'ambiguous'
      ;;
  esac
}

# fm_backend_tuios_prompt_json: the blocking prompt the pane is waiting on, read
# with the daemon's prompt verb. Prints the peek-prompt JSON object (whose
# `lines`, `message`, `options`, `kind`, `prompt_id` and `reason` fields are the
# documented prompt content) only when the pane is on needs_input; returns 1
# otherwise or on any read failure.
fm_backend_tuios_prompt_json() {  # <target>
  local target=$1 out
  fm_backend_tuios_parse_target "$target" || return 1
  out=$("$(fm_backend_tuios_bin)" peek-prompt --session "$SQUAD_BACKEND_TUIOS_SESSION" \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    type == "object" and (terror | not) and (.success != false) and (.blocked == true)
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

fm_backend_tuios_prompt_summary() {  # <target>
  local target=$1 prompt line kind reason
  prompt=$(fm_backend_tuios_prompt_json "$target") || return 0
  kind=$(printf '%s' "$prompt" | jq -r '.kind // "needs_input"')
  if [ "$(printf '%s' "$prompt" | jq -r '.found')" = true ]; then
    line=$(printf '%s' "$prompt" | jq -r '(.message // "") | if . != "" then . else (.lines // [] | .[-1] // "") end')
  else
    reason=$(printf '%s' "$prompt" | jq -r '.reason // empty')
    line=$reason
  fi
  # One bounded line: the prompt text is another program's screen and must not
  # break the caller's one-line state contract.
  line=$(printf '%s' "$line" | tr '\n\r\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')
  line=$(printf '%s' "$line" | cut -c1-160)
  if [ -n "$line" ]; then
    printf '%s: %s' "$kind" "$line"
  else
    printf '%s (prompt not readable)' "$kind"
  fi
}

# --- delivery ----------------------------------------------------------
fm_backend_tuios_error_text() {  # <json-envelope>
  printf '%s' "$1" | jq -r '
    (.error // empty)
    | if type == "object" then (.code // .message // .detail // empty) else . end' 2>/dev/null
}

# fm_backend_tuios_queue_error_verdict: classify the daemon's refusal. The CLI
# folds the socket error code into its message, so the documented stable code is
# matched when present and the live-verified documented wording is matched
# otherwise; anything unrecognized stays a plain send failure so a caller never
# mistakes a refusal for a delivery.
fm_backend_tuios_queue_error_verdict() {  # <error-text>
  local text=$1
  case "$text" in
    # Live wording (TUIOS 0.8.0): "the queue for window <id> holds 8 messages,
    # as many as [agents.queue] max allows."
    *queue_full*|*'as many as [agents.queue] max'*) printf 'queue_full' ;;
    *agent_blocked*|*'on needs_input'*) printf 'agent_blocked' ;;
    *prompt_stalled*|*'no sign of taking'*|*'did not turn working'*) printf 'prompt_stalled' ;;
    *not_ready*|*'not ready'*|*'mid-turn'*) printf 'not_ready' ;;
    # The daemon only queues for a pane it knows holds an agent. A harness it
    # cannot attribute gets the pre-existing literal write instead, and that
    # path never claims success.
    *'runs no agent tuios knows of'*) printf 'no_agent' ;;
    *) printf 'send-failed' ;;
  esac
}

fm_backend_tuios_queue_entries_json() {  # <session> [window]
  local session=$1 window=${2:-} out
  if [ -n "$window" ]; then
    out=$("$(fm_backend_tuios_bin)" queue ls --session "$session" --window "$window" --json 2>/dev/null) || return 1
  else
    out=$("$(fm_backend_tuios_bin)" queue ls --session "$session" --json 2>/dev/null) || return 1
  fi
  printf '%s' "$out" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    type == "object" and (terror | not) and (.success != false)
    and ((.entries // []) | type == "array")
    and all((.entries // [])[]; type == "object")
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# fm_backend_tuios_queue_verdict: the observable postcondition of one queued
# message. `empty` means the agent took it, or it waits safely for the agent's
# next rest (the daemon types one entry per rest and never over a blocking
# prompt). `stalled` means the entry was typed and the agent showed no sign of
# taking it: never retype, inspect the pane. Any unreadable observation stays
# inconclusive rather than claiming a delivery.
#
# The bounded observation window only matters for an entry the daemon is
# actively typing: the daemon's own stall gate is a few seconds after Enter, so
# the default 10s covers it. A deadline that arrives while the entry is still
# being typed reports `empty` because the entry is demonstrably not stalled, and
# the daemon owns delivery from there; its Inbox question is the durable signal
# if the agent later fails to take it.
fm_backend_tuios_queue_verdict() {  # <session> <window> <queue-id>
  local session=$1 window=$2 qid=$3 entries state i=0
  local max=${SQUAD_TUIOS_QUEUE_POLLS:-20} interval=${SQUAD_TUIOS_QUEUE_POLL_INTERVAL:-0.5}
  while :; do
    entries=$(fm_backend_tuios_queue_entries_json "$session" "$window") || { printf 'unreadable'; return 0; }
    state=$(printf '%s' "$entries" | jq -r --arg q "$qid" '
      [(.entries // [])[] | select((.id // "") == $q)][0].state // empty' 2>/dev/null)
    case "$state" in
      '') printf 'empty'; return 0 ;;          # typed and taken
      stalled) printf 'stalled'; return 0 ;;   # typed, not taken
      waiting) printf 'empty'; return 0 ;;     # queued for the next rest
      delivering) : ;;                         # being typed now: observe
      *) printf 'empty'; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -ge "$max" ] && { printf 'empty'; return 0; }
    sleep "$interval"
  done
}

fm_backend_tuios_send_text_queue() {  # <target> <text> [expected-label] -> verdict
  local target=$1 text=$2 expected=${3:-} out rc err verdict qid
  fm_backend_tuios_target_ready "$target" "$expected" || { printf 'send-failed'; return 0; }
  out=$("$(fm_backend_tuios_bin)" queue --session "$SQUAD_BACKEND_TUIOS_SESSION" \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" --json -- "$text" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    err=$(fm_backend_tuios_error_text "$out")
    fm_backend_tuios_queue_error_verdict "$err"
    return 0
  fi
  if ! printf '%s' "$out" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'type == "object" and (terror | not)' >/dev/null 2>&1; then
    # Bytes may already have been queued: never report success without an
    # unambiguous entry id, and never retype.
    printf 'uncertain-delivery'
    return 0
  fi
  qid=$(printf '%s' "$out" | jq -r '.id // empty')
  if [ -z "$qid" ]; then
    printf 'uncertain-delivery'
    return 0
  fi
  verdict=$(fm_backend_tuios_queue_verdict "$SQUAD_BACKEND_TUIOS_SESSION" "$SQUAD_BACKEND_TUIOS_WINDOW" "$qid")
  printf '%s' "$verdict"
}

fm_backend_tuios_send_text_raw() {  # <target> <text> [expected-label] -> verdict
  local target=$1 text=$2 expected=${3:-}
  # The pre-existing literal write, kept only for a pane the daemon knows holds
  # no agent (so it can neither be queued for nor hold a classified prompt). It
  # proves only that bytes reached the terminal, so it never claims a delivery
  # and never retries.
  fm_backend_tuios_send_literal "$target" "$text" "$expected" || { printf 'send-failed'; return 0; }
  fm_backend_tuios_send_key "$target" Enter "$expected" >/dev/null 2>&1 || { printf 'uncertain-delivery'; return 0; }
  printf 'uncertain-delivery'
}

fm_backend_tuios_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected]
  local target=$1 text=$2 expected=${6:-} report state verdict
  # Agent-aware delivery. A pane the daemon reports as blocked is refused
  # WITHOUT typing: free text would answer its prompt, and a silently deferred
  # steer would make delivery unpredictable. Everything else goes through the
  # daemon's queue, which waits for rest and never types over a prompt the agent
  # is waiting on.
  report=$(fm_backend_tuios_agent_report_json "$target") || report=
  if [ -n "$report" ] && [ "$(printf '%s' "$report" | jq -r '.present')" = true ] \
    && [ "$(printf '%s' "$report" | jq -r '.contradictory')" != true ]; then
    state=$(printf '%s' "$report" | jq -r '.state')
    if [ "$state" = needs_input ]; then
      printf 'agent_blocked'
      return 0
    fi
  fi
  verdict=$(fm_backend_tuios_send_text_queue "$target" "$text" "$expected")
  if [ "$verdict" = no_agent ]; then
    fm_backend_tuios_send_text_raw "$target" "$text" "$expected"
    return 0
  fi
  printf '%s' "$verdict"
}

fm_backend_tuios_target_exists() {  # <target> [expected-label]
  fm_backend_tuios_target_ready "$@"
}

# --- recovery ----------------------------------------------------------
# fm_backend_tuios_resume_agent: resume the conversation the daemon recorded for
# the pane after a daemon restart, using the product's own resume verb (the
# command comes from the harness manifest and the recorded conversation id, so
# nothing caller-chosen is typed). Prints one verdict:
#   live           a reporting agent still owns the pane; nothing to recover
#   no_conversation the daemon recorded no conversation for the pane
#   unsupported    the harness manifest has no [resume] command
#   not_ready      the pane's shell is not at its prompt
#   resumed        the resume command was typed into the restored pane
#   unreadable     the endpoint or inventory could not be read
#   failed         the daemon refused for another reason
fm_backend_tuios_resume_agent() {  # <target> [harness]
  local target=$1 report state session out rc err
  report=$(fm_backend_tuios_agent_report_json "$target") || { printf 'unreadable'; return 0; }
  [ "$(printf '%s' "$report" | jq -r '.present')" = true ] || { printf 'unreadable'; return 0; }
  [ "$(printf '%s' "$report" | jq -r '.contradictory')" = true ] && { printf 'unreadable'; return 0; }
  # Any positively attributed report is a reporting agent that still owns the
  # pane, exactly like fm_backend_tuios_agent_state's `alive`. Never type the
  # conversation resume command into a pane a live agent is still driving, even
  # when it is between turns or finished its last one.
  if fm_backend_tuios_attributed "$report"; then
    printf 'live'; return 0
  fi
  state=$(printf '%s' "$report" | jq -r '.state')
  case "$state" in
    working|needs_input) printf 'live'; return 0 ;;
  esac
  if [ -z "$(printf '%s' "$report" | jq -r '.agent_session_id')" ]; then
    printf 'no_conversation'
    return 0
  fi
  fm_backend_tuios_parse_target "$target" || { printf 'unreadable'; return 0; }
  session=$SQUAD_BACKEND_TUIOS_SESSION
  out=$("$(fm_backend_tuios_bin)" resume-agent --session "$session" \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" --json 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'type == "object" and (terror | not) and (.success == true)' >/dev/null 2>&1; then
    printf 'resumed'
    return 0
  fi
  err=$(fm_backend_tuios_error_text "$out")
  case "$err" in
    *'has no resume command'*|*'no resume command'*) printf 'unsupported' ;;
    *'no conversation is recorded'*) printf 'no_conversation' ;;
    *not_ready*|*'not at its prompt'*) printf 'not_ready' ;;
    *) printf 'failed' ;;
  esac
}

# --- lifecycle ---------------------------------------------------------
fm_backend_tuios_kill() {  # <target> [unused] [expected-label]
  local target=$1 expected=${3:-} out reason
  # The exact window identity and the recorded task label are both verified
  # before anything is closed, so only the recorded task window can ever be
  # closed. The close itself is TUIOS's own window-close path (the `close-window`
  # control verb, which the CLI surfaces as `run-command CloseWindow`), addressed
  # by the exact session and opaque window id - never the tmux compatibility
  # shim, which would resolve a shim pane id instead. `run-command` exits 0 even
  # on failure, so its own result envelope is the only success signal.
  fm_backend_tuios_target_ready "$target" "$expected" || return 1
  out=$("$(fm_backend_tuios_bin)" run-command --session "$SQUAD_BACKEND_TUIOS_SESSION" \
    CloseWindow "$SQUAD_BACKEND_TUIOS_WINDOW" --json 2>/dev/null) || return 1
  if ! printf '%s' "$out" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'type == "object" and (terror | not) and (.success == true)' >/dev/null 2>&1; then
    # Surface the daemon's own message instead of suppressing it: the caller
    # needs to know whether the window was already gone or the call was refused.
    reason=$(printf '%s' "$out" | jq -r '
      (.error // .message // "")
      | if type == "object" then (.code // .message // "") else . end
      | if type == "string" then . else tostring end' 2>/dev/null)
    [ -n "$reason" ] || reason='the daemon refused without a reason'
    echo "error: TUIOS refused to close $SQUAD_BACKEND_TUIOS_SESSION:$SQUAD_BACKEND_TUIOS_WINDOW: $reason" >&2
    return 1
  fi
}

fm_backend_tuios_resolve_bare_selector() {  # <name>
  echo "error: TUIOS selectors require task metadata or an exact session:window ID" >&2
  return 1
}

fm_backend_tuios_container_ensure() {  # <project-cwd> -> existing explicit session only
  local configured=${SQUAD_TUIOS_SESSION:-} workspace
  [ -n "$configured" ] || { echo 'error: set SQUAD_TUIOS_SESSION explicitly to an owned TUIOS session' >&2; return 1; }
  fm_backend_endpoint_atom_valid "$configured" || { echo 'error: SQUAD_TUIOS_SESSION must be a single safe session-name atom' >&2; return 1; }
  fm_backend_tuios_tool_check || return 1
  workspace=$(fm_backend_tuios_workspace_setting) || return 1
  "$(fm_backend_tuios_bin)" session-info --session "$configured" >/dev/null 2>&1 || {
    echo "error: configured TUIOS session '$configured' is not live; refusing to create or adopt a session" >&2
    return 1
  }
  # Backend detection validates the daemon's own verb catalogue before any task
  # window is created, so a narrower or older daemon fails here, loudly.
  fm_backend_tuios_protocol_check "$configured" || return 1
  if [ -n "$workspace" ]; then fm_backend_tuios_validate_workspace "$configured" "$workspace" || return 1; fi
  printf '%s' "$configured"
}

fm_backend_tuios_same_label_window() {  # <session> <task-label> -> opaque id, or empty
  local session=$1 label=$2 windows count
  windows=$(fm_backend_tuios_list_windows_json "$session") || return 1
  count=$(printf '%s' "$windows" | jq -r --arg label "$label" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tlabels | index($label)) != null)] | length' 2>/dev/null) || return 1
  [ "$count" = 1 ] || return 1
  printf '%s' "$windows" | jq -r --arg label "$label" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tlabels | index($label)) != null)][0] | tids[0] // empty'
}

fm_backend_tuios_create_task() {  # <session> <task-label> <cwd> -> opaque window ID
  local session=$1 label=$2 cwd=$3 windows id workspace
  workspace=$(fm_backend_tuios_workspace_setting) || return 1
  if [ -n "$workspace" ]; then
    fm_backend_tuios_validate_workspace "$session" "$workspace" || return 1
  fi
  windows=$(fm_backend_tuios_list_windows_json "$session") || { echo "error: cannot read TUIOS window inventory for '$session'" >&2; return 1; }
  if printf '%s' "$windows" | jq -e --arg label "$label" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tlabels | index($label)) != null)] | length > 0
  ' >/dev/null; then
    echo "error: TUIOS task label '$label' already exists in '$session'; close that window or use the recorded task's recovery path" >&2
    return 1
  fi
  if [ -n "$workspace" ]; then
    id=$("$(fm_backend_tuios_bin)" new-window "$label" --session "$session" --cwd "$cwd" --workspace "$workspace" --no-focus --print-id 2>/dev/null) || return 1
  else
    id=$("$(fm_backend_tuios_bin)" new-window "$label" --session "$session" --cwd "$cwd" --no-focus --print-id 2>/dev/null) || return 1
  fi
  case "$id" in ''|*[!A-Za-z0-9._@%-]*) echo 'error: TUIOS returned malformed opaque window id' >&2; return 1 ;; esac
  fm_backend_tuios_target_ready "$session:$id" "$label" || {
    fm_backend_tuios_kill "$session:$id" '' "$label" >/dev/null 2>&1 || true
    return 1
  }
  if [ -n "$workspace" ]; then
    windows=$(fm_backend_tuios_list_windows_json "$session") || {
      echo 'error: cannot verify TUIOS task workspace placement' >&2
      fm_backend_tuios_kill "$session:$id" '' "$label" >/dev/null 2>&1 || true
      return 1
    }
    printf '%s' "$windows" | jq -e --arg id "$id" --argjson ws "$workspace" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
      [.windows[] | select((tids | index($id)) != null)] as $matches
      | ($matches | length) == 1
        and (($matches[0] | tworkspaces | unique) as $found
             | ($found | length) == 1 and $found[0] == $ws)
    ' >/dev/null 2>&1 || {
      echo 'error: TUIOS task window placement is missing, contradictory, or incorrect' >&2
      fm_backend_tuios_kill "$session:$id" '' "$label" >/dev/null 2>&1 || true
      return 1
    }
  fi
  printf '%s' "$id"
}

# fm_backend_tuios_reuse_restored_task: the post-restart relaunch path. A daemon
# restart restores every session with its names and window ids but a fresh shell
# in every pane, so a task's exact recorded window can still exist with its
# label and no agent. Reusing it is safe only with positive evidence that the
# daemon actually restarted since the task was spawned (the recorded boot id
# differs) AND that no agent is attributable to the window now. Anything less
# keeps the duplicate-label refusal.
fm_backend_tuios_reuse_restored_task() {  # <session> <task-label> <recorded-boot-id>
  local session=$1 label=$2 recorded_boot=$3 current_boot id report
  [ -n "$recorded_boot" ] || return 1
  current_boot=$(fm_backend_tuios_boot_id "$session") || return 1
  [ -n "$current_boot" ] && [ "$current_boot" != "$recorded_boot" ] || return 1
  id=$(fm_backend_tuios_same_label_window "$session" "$label") || return 1
  [ -n "$id" ] || return 1
  report=$(fm_backend_tuios_agent_report_json "$session:$id") || return 1
  [ "$(printf '%s' "$report" | jq -r '.present')" = true ] || return 1
  [ "$(printf '%s' "$report" | jq -r '.contradictory')" != true ] || return 1
  fm_backend_tuios_attributed "$report" && return 1
  printf '%s' "$id"
}
