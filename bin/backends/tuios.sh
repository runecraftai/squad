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
# provenance. A window whose agent is gone is `dead` - a restored agentless
# `none` pane or a finished `done` pane whose foreground program exited - and
# that is the recovery-grade signal; a classified blocking prompt is `blocked`,
# never ordinary work.
#
# Shared, backend-neutral normalized-transition shape and the single-owner
# status->action policy table (bin/sq-transition-lib.sh). TUIOS versions with
# subscribe support use its native agent-state stream for prompt wakes. Older
# supported versions retain level-reconcile polling through
# fm_backend_tuios_poll_transition; both paths share the same transition policy.
SQUAD_BACKEND_TUIOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=bin/sq-transition-lib.sh
. "$SQUAD_BACKEND_TUIOS_ROOT/bin/sq-transition-lib.sh"

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
  command -v flock >/dev/null 2>&1 || { echo "error: backend=tuios selected but 'flock' is not installed (required to serialize per-session workspace allocation)" >&2; return 1; }
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

fm_backend_tuios_workspace_setting() {  # -> preferred workspace, or empty when unset
  local file="${SQUAD_BACKEND_CONFIG_DIR}/tuios-workspace" value
  local -a config_lines=()
  [ -f "$file" ] || { printf ''; return 0; }
  mapfile -t config_lines < "$file" || { echo 'error: cannot read config/tuios-workspace' >&2; return 1; }
  [ "${#config_lines[@]}" -eq 1 ] && [[ "${config_lines[0]}" =~ ^[1-9][0-9]*$ ]] || {
    echo 'error: config/tuios-workspace must contain one positive workspace number' >&2
    return 1
  }
  value=${config_lines[0]}
  printf '%s' "$value"
}

fm_backend_tuios_workspace_leased() {  # <session> <workspace>
  local session=$1 workspace=$2 meta meta_session meta_workspace
  for meta in "$SQUAD_BACKEND_STATE_DIR"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" backend)" = tuios ] || continue
    meta_session=$(fm_meta_get "$meta" tuios_session)
    meta_workspace=$(fm_meta_get "$meta" tuios_workspace_id)
    [ "$meta_session" = "$session" ] && [ "$meta_workspace" = "$workspace" ] && return 0
  done
  return 1
}

fm_backend_tuios_next_workspace() {  # <session> -> lowest unused, unnamed existing workspace
  local session=$1 inventory windows preferred candidate
  inventory=$(fm_backend_tuios_list_workspaces_json "$session") || {
    echo 'error: cannot read authoritative TUIOS workspace inventory' >&2
    return 1
  }
  windows=$(fm_backend_tuios_list_windows_json "$session") || {
    echo 'error: cannot read authoritative TUIOS window inventory' >&2
    return 1
  }
  printf '%s' "$inventory" | jq -e '
    (.workspaces | type) == "array" and (.workspaces | length) > 0
    and all(.workspaces[]; (.workspace | type) == "number" and .workspace > 0
            and (.window_count | type) == "number" and .window_count >= 0
            and ((.name // "") | type) == "string")
  ' >/dev/null 2>&1 || { echo 'error: TUIOS workspace inventory is malformed' >&2; return 1; }
  printf '%s' "$windows" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    all(.windows[]; (tworkspaces | unique | length) == 1)
  ' >/dev/null 2>&1 || { echo 'error: TUIOS window workspace inventory is incomplete or contradictory' >&2; return 1; }
  preferred=$(fm_backend_tuios_workspace_setting) || return 1
  if [ -n "$preferred" ] && ! printf '%s' "$inventory" | jq -e --argjson ws "$preferred" '[.workspaces[].workspace] | index($ws) != null' >/dev/null 2>&1; then
    echo "error: configured TUIOS workspace '$preferred' is absent from the session" >&2
    return 1
  fi
  local -a candidates=()
  [ -z "$preferred" ] || candidates+=("$preferred")
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && candidates+=("$candidate")
  done < <(printf '%s' "$inventory" | jq -r '.workspaces[].workspace' | sort -n)
  for candidate in "${candidates[@]}"; do
    printf '%s' "$inventory" | jq -e --argjson ws "$candidate" '
      [.workspaces[] | select(.workspace == $ws)] as $w
      | ($w | length) == 1 and $w[0].window_count == 0 and ($w[0].name // "") == ""
    ' >/dev/null 2>&1 || continue
    printf '%s' "$windows" | jq -e --argjson ws "$candidate" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
      any(.windows[]; (tworkspaces | index($ws)) != null)
    ' >/dev/null 2>&1 && continue
    fm_backend_tuios_workspace_leased "$session" "$candidate" && continue
    printf '%s' "$candidate"
    return 0
  done
  echo 'error: no empty, unnamed TUIOS workspace is available for this task' >&2
  return 1
}

fm_backend_tuios_name_workspace() {  # <session> <workspace> <name>
  local session=$1 workspace=$2 name=$3 inventory
  if [ -n "$name" ]; then
    fm_backend_tuios_cli "$session" set-workspace-name "$workspace" "$name" >/dev/null 2>&1 || return 1
  else
    fm_backend_tuios_cli "$session" set-workspace-name "$workspace" >/dev/null 2>&1 || return 1
  fi
  inventory=$(fm_backend_tuios_list_workspaces_json "$session") || return 1
  printf '%s' "$inventory" | jq -e --argjson ws "$workspace" --arg name "$name" '
    [.workspaces[] | select(.workspace == $ws)] as $w
    | ($w | length) == 1 and ($w[0].name // "") == $name
  ' >/dev/null 2>&1
}

fm_backend_tuios_workspace_for_window() {  # <session> <window> -> exact workspace number
  local session=$1 window=$2 inventory
  inventory=$(fm_backend_tuios_list_windows_json "$session") || return 1
  printf '%s' "$inventory" | jq -er --arg id "$window" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tids | index($id)) != null)] as $matches
    | if ($matches | length) == 1
         and (($matches[0] | tworkspaces | unique | length) == 1)
      then ($matches[0] | tworkspaces[0]) else error("ambiguous workspace") end
  ' 2>/dev/null
}

fm_backend_tuios_unname_workspace_if_empty() {  # <session> <workspace> <task-label>
  local session=$1 workspace=$2 label=$3 inventory windows
  [[ "$workspace" =~ ^[1-9][0-9]*$ ]] || return 1
  inventory=$(fm_backend_tuios_list_workspaces_json "$session") || return 1
  windows=$(fm_backend_tuios_list_windows_json "$session") || return 1
  printf '%s' "$windows" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    all(.windows[]; (tworkspaces | unique | length) == 1)
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$windows" | jq -e --argjson ws "$workspace" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    any(.windows[]; (tworkspaces | index($ws)) != null)
  ' >/dev/null 2>&1 && return 1
  printf '%s' "$inventory" | jq -e --argjson ws "$workspace" --arg label "$label" '
    [.workspaces[] | select(.workspace == $ws)] as $w
    | ($w | length) == 1 and ($w[0].window_count == 0) and ($w[0].name == $label)
  ' >/dev/null 2>&1 || return 1
  fm_backend_tuios_name_workspace "$session" "$workspace" ''
}

fm_backend_tuios_release_task_workspace() {  # <task-id> <meta-file>
  local id=$1 meta=$2 session window workspace label inventory windows present name
  [ "$(fm_meta_get "$meta" backend)" = tuios ] || return 0
  session=$(fm_meta_get "$meta" tuios_session)
  window=$(fm_meta_get "$meta" tuios_window_id)
  workspace=$(fm_meta_get "$meta" tuios_workspace_id)
  [ -n "$workspace" ] || return 0
  [ "$(fm_meta_get "$meta" endpoint_task_id)" = "$id" ] || return 1
  [ "$(fm_meta_get "$meta" window)" = "$session:$window" ] || return 1
  [[ "$workspace" =~ ^[1-9][0-9]*$ ]] || return 1
  label="sq-$id"
  windows=$(fm_backend_tuios_list_windows_json "$session") || return 1
  printf '%s' "$windows" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    all(.windows[]; (tworkspaces | unique | length) == 1)
  ' >/dev/null 2>&1 || { echo 'error: cannot safely verify TUIOS workspace occupancy' >&2; return 1; }
  present=$(printf '%s' "$windows" | jq -r --arg id "$window" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tids | index($id)) != null)] | length
  ' 2>/dev/null) || return 1
  [ "$present" = 0 ] || { echo "error: task window $session:$window remains; retaining its workspace claim" >&2; return 1; }
  printf '%s' "$windows" | jq -e --argjson ws "$workspace" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    any(.windows[]; (tworkspaces | index($ws)) != null)
  ' >/dev/null 2>&1 && { echo "error: workspace $workspace still contains another window; retaining task metadata" >&2; return 1; }
  inventory=$(fm_backend_tuios_list_workspaces_json "$session") || return 1
  printf '%s' "$inventory" | jq -e --argjson ws "$workspace" '
    [.workspaces[] | select(.workspace == $ws)] as $w
    | ($w | length) == 1 and ($w[0].window_count == 0)
  ' >/dev/null 2>&1 || { echo "error: workspace $workspace is absent or still has windows; retaining task metadata" >&2; return 1; }
  name=$(printf '%s' "$inventory" | jq -r --argjson ws "$workspace" '
    [.workspaces[] | select(.workspace == $ws)] | if length == 1 then (.[0].name // "") else empty end
  ' 2>/dev/null) || return 1
  [ -n "$name" ] || return 0
  [ "$name" = "$label" ] || return 0
  fm_backend_tuios_name_workspace "$session" "$workspace" '' || {
    echo "error: could not restore the task workspace name for $id; retaining its metadata" >&2
    return 1
  }
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

fm_backend_tuios_capture_rendered() {  # <target> [expected-label]
  local target=$1 expected=${2:-}
  fm_backend_tuios_target_ready "$target" "$expected" || return 1
  fm_backend_tuios_cli "$SQUAD_BACKEND_TUIOS_SESSION" capture-pane \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" 2>/dev/null
}

fm_backend_tuios_send_literal() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected=${3:-}
  fm_backend_tuios_target_ready "$target" "$expected" || return 1
  fm_backend_tuios_cli "$SQUAD_BACKEND_TUIOS_SESSION" send-text \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" -- "$text"
}

# fm_backend_tuios_caller_pane: the pane this process types from, which is the
# pane TUIOS checks a typing grant against. The daemon's own placement of this
# caller is authoritative, so it is tried first; the pane environment is the
# fallback for a caller whose placement the kernel cannot report.
fm_backend_tuios_caller_pane() {
  local out
  out=$("$(fm_backend_tuios_bin)" pane-grants --json 2>/dev/null) || out=
  if [ -n "$out" ]; then
    out=$(printf '%s' "$out" | jq -r '
      select(.pane == true)
      | select((.session | type) == "string" and (.session | length) > 0)
      | select((.window | type) == "string" and (.window | length) > 0)
      | "\(.session):\(.window)"' 2>/dev/null || true)
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  # TUIOS_PANE_ID is the id Squad already uses as a caller's own window target
  # everywhere else, and TUIOS_WINDOW_ID is only an alternative: the guarded lab
  # treats that one as optional, so it cannot be the only fallback.
  if [ -n "${TUIOS_SESSION:-}" ] && [ -n "${TUIOS_PANE_ID:-}" ]; then
    printf '%s:%s' "$TUIOS_SESSION" "$TUIOS_PANE_ID"
    return 0
  fi
  if [ -n "${TUIOS_SESSION:-}" ] && [ -n "${TUIOS_WINDOW_ID:-}" ]; then
    printf '%s:%s' "$TUIOS_SESSION" "$TUIOS_WINDOW_ID"
    return 0
  fi
  return 1
}

# fm_backend_tuios_grant_refusal: true only when the daemon refused the key
# because the typing pane lacks the respond grant. The live refusal sentence is
# one signal and a structured error code or message is the other, so a daemon
# that reports the condition as JSON keeps the sanctioned remedy. Any other
# refusal stays an ordinary send failure with its full diagnostic intact.
fm_backend_tuios_grant_refusal() {  # <refusal-output>
  local out=$1 text
  case "$out" in
    *'needs the respond grant'*) return 0 ;;
  esac
  text=$(printf '%s' "$out" | jq -r '
    (.error // .)
    | if type == "object" then (.code // .message // .detail // empty) else . end
    | select(type == "string")' 2>/dev/null) || return 1
  [ -n "$text" ] || return 1
  text=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  case "$text" in
    *respond*) ;;
    *) return 1 ;;
  esac
  case "$text" in
    *grant*|*need*|*require*|*missing*|*refus*|*denied*|*blocked*) return 0 ;;
  esac
  return 1
}

# fm_backend_tuios_respond_error_verdict: classify a refused respond call. The
# installed CLI renders the documented stable codes as prose, so the
# live-verified refusal sentences are matched alongside the code tokens;
# anything unrecognized stays uncertain because a lost reply may follow an
# answer that did land.
fm_backend_tuios_respond_error_verdict() {  # <refusal-output>
  case "$1" in
    *prompt_changed*|*'respond pressed nothing'*|*'not the one prompt_id names'*|*'is asking something else now, so nothing was answered'*)
      printf 'prompt_changed' ;;
    *risk_unacknowledged*|*'matches a risk rule'*|*'may deny a risky call and never allow one'*)
      printf 'risk_matched' ;;
    *not_human*|*forbidden*|*'respond grant'*|*'is for the person at an attached client'*)
      printf 'not_authorized' ;;
    *) printf 'uncertain' ;;
  esac
}

fm_backend_tuios_send_key() {  # <target> <key> [expected-label]
  local target=$1 key=$2 expected=${3:-} out rc
  # Only a refusal sets this, and only to the pane whose grant is missing, so a
  # caller can name the sanctioned remedy without parsing the daemon's prose.
  # shellcheck disable=SC2034 # Set for the sourcing caller; this adapter never reads it.
  SQUAD_BACKEND_PANE_GRANT_TARGET=
  fm_backend_tuios_target_ready "$target" "$expected" || return 1
  out=$("$(fm_backend_tuios_bin)" send-keys --session "$SQUAD_BACKEND_TUIOS_SESSION" \
    --window "$SQUAD_BACKEND_TUIOS_WINDOW" -- "$key" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_backend_tuios_grant_refusal "$out"; then
      # Squad has a sanctioned remedy for this refusal, so forward only the
      # daemon's own refusal sentence: its remaining lines are the provider's
      # remediation advice, which names the raw verb Squad's guard denies.
      [ -z "$out" ] || printf '%s\n' "$(printf '%s' "$out" | head -n 1)" >&2
      # TUIOS requires respond on the pane that TYPES the answer, never on the
      # blocked pane, so name that pane rather than the target.
      # shellcheck disable=SC2034 # Set for the sourcing caller; this adapter never reads it.
      SQUAD_BACKEND_PANE_GRANT_TARGET=$(fm_backend_tuios_caller_pane || true)
    else
      [ -z "$out" ] || printf '%s\n' "$out" >&2
    fi
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

fm_backend_tuios_send_text_line() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected=${3:-}
  # TUIOS send-text submits a command when its literal payload ends in newline.
  # Keep the shell line in one write instead of risking a stranded partial line.
  fm_backend_tuios_send_literal "$target" "$text
" "$expected"
}

# fm_backend_tuios_respond answers only the exact prompt the supervisor read.
# The daemon rechecks prompt_id atomically and enforces its respond authority;
# this call is deliberately never retried because a lost reply may follow a
# successful answer.
fm_backend_tuios_respond() {  # <target> <action> <prompt-id> [value]
  local target=$1 action=$2 prompt_id=$3 value=${4:-} session window prompt catalog out rc settled confirmed
  SQUAD_BACKEND_PANE_GRANT_TARGET=
  fm_backend_tuios_parse_target "$target" || { echo 'error: malformed TUIOS prompt target' >&2; return 1; }
  [ -n "$prompt_id" ] || { echo 'error: TUIOS prompt id is required; nothing was answered' >&2; return 1; }
  case "$action" in approve|deny|choose|text) ;; *) echo "error: unsupported TUIOS prompt action '$action'; persistent approvals are not automated" >&2; return 1 ;; esac
  case "$action" in choose|text)
    [ -n "$value" ] || { echo "error: TUIOS action '$action' requires a value; nothing was answered" >&2; return 1; }
    ;;
  esac
  catalog=$("$(fm_backend_tuios_bin)" list-verbs --json 2>/dev/null) || { echo 'error: TUIOS capability catalog unavailable; prompt response is unsupported' >&2; return 1; }
  printf '%s' "$catalog" | jq -e '
    any(.verbs[]; .verb == "respond" and ([.params[]?.name] | index("action") != null)
      and ([.params[]?.name] | index("prompt_id") != null))
  ' >/dev/null 2>&1 || { echo 'error: installed TUIOS daemon has no prompt-specific respond capability' >&2; return 1; }
  session=$SQUAD_BACKEND_TUIOS_SESSION
  window=$SQUAD_BACKEND_TUIOS_WINDOW
  prompt=$(fm_backend_tuios_prompt_json "$target") || { echo 'error: target is not currently waiting on a readable TUIOS prompt; nothing was answered' >&2; return 1; }
  [ "$(printf '%s' "$prompt" | jq -r '.prompt_id // empty')" = "$prompt_id" ] || {
    echo 'error: TUIOS prompt changed since it was read; nothing was answered; read the current prompt before deciding again' >&2
    return 1
  }
  printf '%s' "$prompt" | jq -e --arg action "$action" '(.actions // []) | index($action) != null' >/dev/null 2>&1 || {
    echo "error: current TUIOS prompt does not accept action '$action'; nothing was answered" >&2
    return 1
  }
  if [ "$action" = choose ]; then
    case "$value" in ''|*[!0-9]*|0) echo 'error: choose requires a positive option number; nothing was answered' >&2; return 1 ;; esac
    fm_backend_tuios_prompt_option_numbers "$prompt" | grep -qx -- "$value" || {
      echo 'error: chosen option is not present in the current prompt; nothing was answered' >&2
      return 1
    }
  fi
  local -a args=(respond --json --session "$session" --window "$window" --prompt-id "$prompt_id" "$action")
  # A free-text answer may begin with `-`, which the CLI would parse as a flag.
  [ -z "$value" ] || args+=(-- "$value")
  out=$("$(fm_backend_tuios_bin)" "${args[@]}" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    case "$(fm_backend_tuios_respond_error_verdict "$out")" in
      prompt_changed) echo 'error: TUIOS confirmed nothing was answered because the prompt changed; read the new prompt before deciding again' >&2; return 1 ;;
      risk_matched) echo 'error: TUIOS refused this risk-matched approval; nothing was answered and no risk acknowledgement was inferred' >&2; return 1 ;;
      not_authorized)
        # shellcheck disable=SC2034 # Set for the sourcing caller to print the sanctioned grant remedy.
        SQUAD_BACKEND_PANE_GRANT_TARGET=$(fm_backend_tuios_caller_pane || true)
        echo 'error: TUIOS refused this caller; nothing was answered; use an authorized person or pane with the respond grant' >&2
        return 1
        ;;
    esac
    echo 'error: TUIOS response outcome may be uncertain; do not retry until peek-prompt confirms the current state' >&2
    return 1
  fi
  settled=$(printf '%s' "$out" | jq -r '.settled_by // empty' 2>/dev/null)
  if printf '%s' "$out" | jq -e --arg id "$prompt_id" '
    (.success == true) and (.prompt_id == $id)
  ' >/dev/null 2>&1; then confirmed=true; else confirmed=false; fi
  [ "$confirmed" = true ] || {
    echo 'error: TUIOS did not confirm the exact prompt response; outcome may be uncertain; inspect the prompt before any retry' >&2
    return 1
  }
  if [ "$settled" = prompt ]; then
    printf '%s\n' "$out"
    echo 'error: the exact prompt was answered, but another prompt appeared; inspect it instead of retrying' >&2
    return 1
  fi
  if [ "$settled" = gone ]; then
    printf '%s\n' "$out"
    echo 'error: the exact prompt was answered, but the operator window closed as it was typed; do not retry; inspect the task instead' >&2
    return 1
  fi
  [ "$settled" = state ] || {
    echo 'error: TUIOS did not confirm the blocked prompt cleared; outcome may be uncertain; inspect the prompt before any retry' >&2
    return 1
  }
  printf '%s\n' "$out"
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
  local catalogue problems required="${SQUAD_BACKEND_TUIOS_PROTOCOL_REQUIRED}
list-workspaces:session
set-workspace-name:session,workspace,name
new-window:session,name,cwd,focus,workspace"
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

# fm_backend_tuios_finished_agentless: 0 when the daemon's own report positively
# establishes a finished agent whose program has exited: the daemon's finished
# state (`done`), no detected foreground program, and agent provenance that does
# not come from a foreground program (a named harness or a non-`none`
# confidence). A live agent reports a foreground program in every observed
# shape, and a state that is not positively finished stays out of this class, so
# an ambiguous or contradictory report never becomes a recovery license.
fm_backend_tuios_finished_agentless() {  # <report-json>
  printf '%s' "$1" | jq -e '
    (.state == "done")
    and (((.foreground // "") | length) == 0)
    and ((((.harness_id // "") | length) > 0)
         or (((.confidence // "") | length > 0) and (.confidence != "none")))' >/dev/null 2>&1
}

# fm_backend_tuios_agent_running: 0 when the report certifies a running agent -
# positive attribution that is not the finished, foreground-less shape. This is
# the single predicate behind `alive` and the resume refusal, so a finished
# agent whose program is gone can never be mistaken for a live one.
fm_backend_tuios_agent_running() {  # <report-json>
  fm_backend_tuios_attributed "$1" || return 1
  fm_backend_tuios_finished_agentless "$1" && return 1
  return 0
}

# --- composer state ----------------------------------------------------
# The daemon exposes no "composer is empty" bit, so the composer is read from
# the pane the same way the other adapters read theirs: a positively identified
# composer frame whose rows are all blank is `empty`; any content in it is
# `pending`; anything that cannot be identified as a composer frame (no frame, a
# frame that is not at the bottom of the pane, a dead shell prompt, an unreadable
# capture) is `unknown`. `unknown` never authorizes a write, and a classified
# blocking prompt is refused earlier by the busy state, so this only widens the
# proof of "empty" - it never turns an ambiguous pane into an empty one.
#
# Two frame shapes are recognized, both observed live:
#   boxed  `╭──╮` / `│ … │` / `╰──╯`   a customized Pi editor, and claude, whose
#                                       bordered row carries a `>` prompt glyph;
#   ruled  `────` / editor rows / `────`  stock Pi (1.1.0), which draws only a
#                                       full-width rule above and below its
#                                       editor and no side borders.
# Every row between the two borders is judged together, so a multi-line draft
# whose last line is blank is still `pending`. The frame must be the last thing
# on the pane apart from a short footer, so an earlier tool-output box or a
# markdown rule in the scrollback is never mistaken for the composer.
# Only the `boxed` shape is a bordered composer container; the `ruled` editor row
# is bare, so a lone shell glyph typed there is not an empty agent composer.
# Classification is delegated to the one shared owner.
SQUAD_BACKEND_TUIOS_COMPOSER_LINES=${SQUAD_BACKEND_TUIOS_COMPOSER_LINES:-30}
SQUAD_BACKEND_TUIOS_COMPOSER_FOOTER_MAX=${SQUAD_BACKEND_TUIOS_COMPOSER_FOOTER_MAX:-4}
SQUAD_BACKEND_TUIOS_COMPOSER_ROWS_MAX=${SQUAD_BACKEND_TUIOS_COMPOSER_ROWS_MAX:-12}
SQUAD_BACKEND_TUIOS_IDLE_RE=${SQUAD_BACKEND_TUIOS_IDLE_RE:-}
# shellcheck source=bin/sq-composer-lib.sh
. "$SQUAD_BACKEND_TUIOS_ROOT/bin/sq-composer-lib.sh"

fm_backend_tuios_composer_from_capture() {  # stdin: plain pane capture -> empty|pending|unknown
  local -a rows=()
  local line t i n bottom=-1 top=-1 trailing=0 content_rows=0 content="" kind=
  local rule_re='^(─|━|═){8,}$'
  while IFS= read -r line || [ -n "$line" ]; do rows+=("$line"); done
  n=${#rows[@]}
  i=$((n - 1))
  while [ "$i" -ge 0 ]; do
    t="${rows[$i]#"${rows[$i]%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    if [ -n "$t" ]; then
      case "$t" in
        '╰'*'╯'|'└'*'┘'|'┗'*'┛') bottom=$i; kind=boxed; break ;;
      esac
      if [[ $t =~ $rule_re ]]; then bottom=$i; kind=ruled; break; fi
      trailing=$((trailing + 1))
      [ "$trailing" -le "$SQUAD_BACKEND_TUIOS_COMPOSER_FOOTER_MAX" ] || break
    fi
    i=$((i - 1))
  done
  [ "$bottom" -ge 0 ] || { printf 'unknown'; return 0; }
  i=$((bottom - 1))
  while [ "$i" -ge 0 ] && [ "$content_rows" -le "$SQUAD_BACKEND_TUIOS_COMPOSER_ROWS_MAX" ]; do
    t="${rows[$i]#"${rows[$i]%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    if [ "$kind" = boxed ]; then
      case "$t" in
        '╭'*'╮'|'┌'*'┐'|'┏'*'┓') top=$i; break ;;
        '│'*'│') t=${t#│}; t=${t%│} ;;
        '┃'*'┃') t=${t#┃}; t=${t%┃} ;;
        *) break ;;
      esac
    elif [[ $t =~ $rule_re ]]; then
      top=$i; break
    fi
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    content_rows=$((content_rows + 1))
    if [ -n "$t" ]; then content="$t${content:+ $content}"; fi
    i=$((i - 1))
  done
  { [ "$top" -ge 0 ] && [ "$content_rows" -gt 0 ]; } || { printf 'unknown'; return 0; }
  local bordered=0
  [ "$kind" = boxed ] && bordered=1
  fm_composer_classify_content "$bordered" "$content" "$SQUAD_BACKEND_TUIOS_IDLE_RE"
}

fm_backend_tuios_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cap verdict
  cap=$(fm_backend_tuios_capture "$target" "$SQUAD_BACKEND_TUIOS_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  verdict=$(printf '%s\n' "$cap" | fm_backend_tuios_composer_from_capture)
  if [ "$verdict" = empty ] && [ "$(fm_backend_tuios_agent_state "$target")" != alive ]; then
    printf 'unknown'
    return 0
  fi
  printf '%s' "$verdict"
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
  # Positive attribution that is not the finished, foreground-less shape is what
  # makes an agent certified as running.
  if fm_backend_tuios_agent_running "$report"; then
    printf 'alive'
    return 0
  fi
  # A finished agent whose foreground program is gone no longer owns the pane:
  # this is the second recovery-grade shape, alongside the post-restart `none`
  # pane below.
  if fm_backend_tuios_finished_agentless "$report"; then
    printf 'dead'
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

# fm_backend_tuios_prompt_option_numbers: the numbers a person presses for the
# prompt's options. The daemon's peek-prompt carries each option's authoritative
# on-screen number in `n`; a daemon that reports plain strings has only their
# positions, which is the same numbering for that shape.
fm_backend_tuios_prompt_option_numbers() {  # <prompt-json>
  printf '%s' "$1" | jq -r '
    (.options // []) | to_entries[]
    | if (.value | type) == "object" and ((.value.n | type) == "number")
      then .value.n else (.key + 1) end' 2>/dev/null
}

fm_backend_tuios_prompt_summary() {  # <target>
  local target=$1 prompt line kind reason options
  prompt=$(fm_backend_tuios_prompt_json "$target") || return 0
  kind=$(printf '%s' "$prompt" | jq -r '.kind // "needs_input"')
  options=''
  if [ "$(printf '%s' "$prompt" | jq -r '.found')" = true ]; then
    line=$(printf '%s' "$prompt" | jq -r '(.message // "") | if . != "" then . else (.lines // [] | .[-1] // "") end')
    # Numbered options, when the daemon's prompt read carries any: each entry
    # is either a plain string or an object (label/text/name) whose `n` is the
    # number the person actually sees, rendered as "2) <opt> 5) <opt> ...".
    # Absent or empty stays "" so an older daemon with no options field changes
    # nothing below.
    options=$(printf '%s' "$prompt" | jq -r '
      (.options // []) as $o
      | if ($o | length) > 0 then
          [$o | to_entries[]
           | ((if (.value | type) == "object" and ((.value.n | type) == "number")
               then .value.n else (.key + 1) end) | tostring)
             + ") "
             + (.value | if type == "string" then . else (.label // .text // .name // tostring) end)]
          | join(" ")
        else "" end' 2>/dev/null)
  else
    reason=$(printf '%s' "$prompt" | jq -r '.reason // empty')
    line=$reason
  fi
  # One bounded line: the prompt text is another program's screen and must not
  # break the caller's one-line state contract.
  line=$(printf '%s' "$line" | tr '\n\r\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')
  line=$(printf '%s' "$line" | cut -c1-160)
  if [ -n "$options" ]; then
    options=$(printf '%s' "$options" | tr '\n\r\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')
    options=$(printf '%s' "$options" | cut -c1-160)
  fi
  if [ -n "$line" ]; then
    if [ -n "$options" ]; then
      printf '%s: %s [%s]' "$kind" "$line" "$options"
    else
      printf '%s: %s' "$kind" "$line"
    fi
  else
    printf '%s (prompt not readable)' "$kind"
  fi
}

# fm_backend_tuios_prompt_hash: the dedupe identity of the pane's blocking
# prompt - a hash of the kind and message/line only, so a later poll that
# merely surfaces numbered options for the SAME prompt is not read as a changed
# prompt. Prints the hash and returns 0 only when the daemon positively read
# the prompt (`.found`); an unreadable, absent, or unparsable read returns 1 so
# the caller keeps its dedupe markers instead of treating missing content as a
# new prompt.
fm_backend_tuios_prompt_hash() {  # <target>
  local prompt identity
  prompt=$(fm_backend_tuios_prompt_json "$1") || return 1
  [ "$(printf '%s' "$prompt" | jq -r '.found')" = true ] || return 1
  identity=$(printf '%s' "$prompt" | jq -r '
    ((.kind // "needs_input") + "\n"
     + ((.message // "") as $m
        | if ($m | tostring) != "" then ($m | tostring)
          else ((.lines? // []) | if type == "array" then ((.[-1] // "") | tostring) else "" end)
          end))
  ') || return 1
  printf '%s' "$identity" | fm_backend_tuios_text_hash
}

# --- backend-neutral transition producer (level-reconcile / poll path) ------
# TUIOS versions with subscribe support satisfy fm_backend_has_push and use the
# sentry's event-wait splice. The native stream is only a wake signal; the
# authoritative per-window level is re-read before action. Older versions still
# produce the SAME normalized transition record (bin/sq-transition-lib.sh) on
# the ordinary poll instead: fm_backend_tuios_poll_transition reads current
# state (fm_backend_tuios_busy_state), translates it into the shared
# idle|working|blocked|done|unknown vocabulary, and routes it through the same
# policy table and per-pane dedupe shape herdr's event stream uses
# (fm_backend_tuios_apply_transition mirrors fm_backend_herdr_apply_transition
# in bin/backends/herdr.sh - same contract, same marker-file convention keyed
# like the sentry's own .stale-<key>).
#
# A blocked verdict alone is not a complete dedupe key: a pane can report
# needs_input for one prompt, have it dismissed, and immediately need_input
# again for a DIFFERENT prompt, with no intervening non-blocked read to clear
# the marker. The prompt's own content, hashed, is the rest of the key:
# fm_backend_tuios_poll_transition clears the escalation marker itself whenever
# that hash changes while still blocked, so a changed prompt is always treated
# as a fresh edge even with no `working`/`idle` edge in between. A read that
# fails to produce the prompt at all is not a change: the markers stand until a
# later readable read establishes a genuinely different prompt.
SQUAD_BACKEND_TUIOS_ESCALATED_PREFIX=".tuios-escalated-"
SQUAD_BACKEND_TUIOS_PROMPT_HASH_PREFIX=".tuios-prompt-"

fm_backend_tuios_text_hash() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q
  else
    md5sum | cut -d' ' -f1
  fi
}

# fm_backend_tuios_escalation_marker: the per-pane dedupe marker path for a
# <window> ("<session>:<opaque-window-id>"), keyed identically to the sentry's
# .stale-<key> (tr ':/.' '___'), under <state_dir>.
fm_backend_tuios_escalation_marker() {  # <state_dir> <window>
  local state=$1 window=$2 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s/%s%s' "$state" "$SQUAD_BACKEND_TUIOS_ESCALATED_PREFIX" "$key"
}

fm_backend_tuios_prompt_hash_marker() {  # <state_dir> <window>
  local state=$1 window=$2 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s/%s%s' "$state" "$SQUAD_BACKEND_TUIOS_PROMPT_HASH_PREFIX" "$key"
}

# fm_backend_tuios_normalize_status: translate the adapter's own busy
# vocabulary (busy|blocked|idle|unknown, fm_backend_tuios_busy_state) into the
# shared transition vocabulary (bin/sq-transition-lib.sh). "done" has no
# distinct busy_state verdict - it already folds into "idle" there - so it
# needs no separate case here.
fm_backend_tuios_normalize_status() {  # <busy-verdict>
  case "$1" in
    busy) printf 'working' ;;
    blocked) printf 'blocked' ;;
    idle) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_tuios_apply_transition: route one normalized record through the
# shared policy table, maintaining the per-pane dedupe marker under
# <state_dir>. On a fresh `actionable` (blocked) edge - policy actionable AND
# no marker yet - prints the record on stdout and returns 0 (the caller stops
# and hands the record up). Any other policy action, or an already-marked
# actionable edge, returns 1 with no output. Mirrors
# fm_backend_herdr_apply_transition's actionable branch exactly; TUIOS's own
# poll_transition below owns clearing the marker on a positively-read
# non-blocked status (absorb/defer) and on a changed prompt, so the absorb
# branch herdr's version carries is not needed here.
fm_backend_tuios_apply_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id to action window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  window="$session:$pane_id"
  marker=$(fm_backend_tuios_escalation_marker "$state" "$window")
  if [ "$action" = actionable ] && [ ! -e "$marker" ]; then
    printf '%s' "$record"
    return 0
  fi
  return 1
}

fm_backend_tuios_commit_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id window
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  window="$session:$pane_id"
  : > "$(fm_backend_tuios_escalation_marker "$state" "$window")"
}

fm_backend_tuios_clear_escalation_marker() {  # <state_dir> <window>
  rm -f "$(fm_backend_tuios_escalation_marker "$1" "$2")" 2>/dev/null || true
}

# fm_backend_tuios_clear_transition: the full teardown-time cleanup (dispatched
# as fm_backend_clear_transition tuios ...) - clears both the escalation marker
# and the prompt-hash marker, so a retired task leaves no dedupe state behind.
fm_backend_tuios_clear_transition() {  # <state_dir> <window>
  local state=$1 window=$2
  [ -n "$window" ] || return 0
  fm_backend_tuios_clear_escalation_marker "$state" "$window"
  rm -f "$(fm_backend_tuios_prompt_hash_marker "$state" "$window")" 2>/dev/null || true
}

# fm_backend_tuios_poll_transition: level-reconcile producer called on the
# ordinary per-window poll cycle and on native-event reconnect/edges. Prints the
# normalized record and returns 0 on a fresh actionable edge for the caller to
# hand to handle_push_transition; returns 1 when the pane is
# STILL blocked but already escalated for its current prompt (the caller must
# still skip the ordinary stale/wedge machinery, just without a fresh wake);
# returns 2 when the pane is not currently blocked (the caller falls through to
# the existing poll machinery unchanged, exactly as before this producer
# existed); returns 3 when the pane was previously escalated but the current
# native read is an ambiguous fallback (the caller must skip the ordinary
# stale/wedge machinery without a fresh wake, so a blocked pane whose read
# failed is never reclassified as stale).
#
# The clear/keep decision comes from the shared policy table on the normalized
# status. A positively-read non-blocked status (absorb/defer) clears both
# markers, since the pane is demonstrably no longer waiting; a fallback read
# (unknown - an unreadable or contradictory inventory) keeps them, so a single
# transient read failure cannot re-arm a prompt that is still standing. The
# prompt identity is treated the same way: only a positively-read prompt whose
# hash differs from the last readable one re-arms, while an unreadable prompt
# read keeps the markers so a transient peek-prompt failure cannot duplicate a
# wake.
fm_backend_tuios_poll_transition() {  # <state_dir> <session> <window>
  local state=$1 session=$2 window=$3 native status action prompt_hash hash_marker stored record hit
  native=$(fm_backend_tuios_busy_state "$window" 2>/dev/null) || native=unknown
  status=$(fm_backend_tuios_normalize_status "$native")
  action=$(fm_transition_policy "$status")
  if [ "$action" != actionable ]; then
    if [ "$action" = fallback ]; then
      [ -e "$(fm_backend_tuios_escalation_marker "$state" "$window")" ] && return 3
      return 2
    fi
    fm_backend_tuios_clear_transition "$state" "$window"
    return 2
  fi
  hash_marker=$(fm_backend_tuios_prompt_hash_marker "$state" "$window")
  stored=$(cat "$hash_marker" 2>/dev/null || true)
  if prompt_hash=$(fm_backend_tuios_prompt_hash "$window" 2>/dev/null); then
    if [ -n "$stored" ] && [ "$stored" != "$prompt_hash" ]; then
      fm_backend_tuios_clear_escalation_marker "$state" "$window"
    fi
    printf '%s' "$prompt_hash" > "$hash_marker"
  fi
  record=$(fm_transition_record "${window#*:}" "" "" blocked "")
  hit=$(fm_backend_tuios_apply_transition "$state" "$session" "$record") || return 1
  printf '%s' "$hit"
}

# fm_backend_tuios_events_capable: the installed daemon's own catalog is the
# authority for native subscriptions. The catalog describes the binary
# (`tuios list-verbs` takes no session), so the probe is session-independent and
# the dispatcher's session argument is deliberately not taken. This is optional
# so older supported TUIOS versions continue using the ordinary level-reconcile
# poll.
fm_backend_tuios_events_capable() {
  local catalog bin
  bin=$(fm_backend_tuios_bin)
  command -v python3 >/dev/null 2>&1 || return 1
  catalog=$("$bin" list-verbs --json 2>/dev/null) || return 1
  printf '%s' "$catalog" | jq -e '
    (.verbs | type) == "array"
    and any(.verbs[]; (.verb == "subscribe")
      and ([.params[]?.name] | index("session") != null)
      and ([.params[]?.name] | index("types") != null)
      and ([.returns[]?.name] | index("seq") != null)
      and ([.returns[]?.name] | index("boot_id") != null))
  ' >/dev/null 2>&1
}

# fm_backend_tuios_wait_transition: subscribe before reconciling, then treat each
# event only as a prompt to re-read the exact task window. The per-prompt marker
# makes reconnect/replay duplicates harmless; gaps and reader failures return 2
# so the sentry falls back to bounded polling.
fm_backend_tuios_wait_transition() {  # <session> <timeout> <state_dir> <window...>
  local session=$1 timeout=$2 state=$3; shift 3
  local windows=("$@") w bin reader=() fifo_dir fifo reader_pid line event_window record hit rc=1 reader_rc=0
  [ "${#windows[@]}" -gt 0 ] || return 2
  if [ "${SQUAD_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_tuios_events_capable || return 2
  fi
  bin=$(fm_backend_tuios_bin)
  reader=(python3 "$SQUAD_BACKEND_TUIOS_ROOT/bin/backends/tuios-eventwait.py" "$bin" "$session" "$timeout")
  for w in "${windows[@]}"; do reader+=("${w#*:}"); done
  fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/sq-tuios-eventwait.XXXXXX") || return 2
  fifo="$fifo_dir/events"
  if ! mkfifo "$fifo" 2>/dev/null; then rm -rf "$fifo_dir"; return 2; fi
  "${reader[@]}" > "$fifo" 2>/dev/null &
  reader_pid=$!
  if ! exec 9< "$fifo"; then kill "$reader_pid" 2>/dev/null || true; wait "$reader_pid" 2>/dev/null || true; rm -rf "$fifo_dir"; return 2; fi
  if ! IFS= read -r -u 9 line || [ "$line" != "@subscribed" ]; then
    rc=2
  else
    # Reconcile after subscription is live: an already blocked prompt is not
    # lost between the sentry's previous poll and the stream connection.
    for w in "${windows[@]}"; do
      if hit=$(fm_backend_tuios_poll_transition "$state" "$session" "$w"); then printf '%s' "$hit"; rc=0; break; fi
    done
  fi
  while [ "$rc" -eq 1 ] && IFS= read -r -u 9 line; do
    [ -n "$line" ] || continue
    event_window=$(printf '%s' "$line" | cut -f1)
    [ -n "$event_window" ] || continue
    w="$session:$event_window"
    if hit=$(fm_backend_tuios_poll_transition "$state" "$session" "$w"); then printf '%s' "$hit"; rc=0; break; fi
  done
  if [ "$rc" -eq 0 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  if [ "$rc" -eq 2 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  wait "$reader_pid" 2>/dev/null || reader_rc=$?
  exec 9<&-
  rm -rf "$fifo_dir" 2>/dev/null || true
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && return 2
  [ "$reader_rc" -eq 0 ] && return 1
  return 2
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
    # The daemon only queues for a pane it knows holds an agent. Delivery is
    # queue-only, so a harness it cannot attribute is refused outright: nothing
    # is typed into that terminal and nothing is retried.
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
  # Agent-targeted delivery is queue-only. A pane without an attributed agent
  # is not a reason to type into its terminal: refuse rather than switching to
  # a raw keyboard path whose delivery and prompt safety cannot be established.
  printf '%s' "$verdict"
}

fm_backend_tuios_target_exists() {  # <target> [expected-label]
  fm_backend_tuios_target_ready "$@"
}

# --- recovery ----------------------------------------------------------
# fm_backend_tuios_resume_agent: resume the conversation the daemon recorded for
# the pane once its agent is gone (a daemon restart or a finished agent exit),
# using the product's own resume verb (the command comes from the harness
# manifest and the recorded conversation id, so nothing caller-chosen is typed).
# Prints one verdict:
#   live           a running agent still owns the pane; nothing to recover
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
  # A running agent (any positively attributed report that is not the finished,
  # foreground-less shape) still owns the pane, exactly like
  # fm_backend_tuios_agent_state's `alive`. Never type the conversation resume
  # command into a pane a live agent is still driving, even when it is between
  # turns or finished its last one.
  if fm_backend_tuios_agent_running "$report"; then
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
  local configured=${SQUAD_TUIOS_SESSION:-}
  [ -n "$configured" ] || { echo 'error: set SQUAD_TUIOS_SESSION explicitly to an owned TUIOS session' >&2; return 1; }
  fm_backend_endpoint_atom_valid "$configured" || { echo 'error: SQUAD_TUIOS_SESSION must be a single safe session-name atom' >&2; return 1; }
  fm_backend_tuios_tool_check || return 1
  "$(fm_backend_tuios_bin)" session-info --session "$configured" >/dev/null 2>&1 || {
    echo "error: configured TUIOS session '$configured' is not live; refusing to create or adopt a session" >&2
    return 1
  }
  # Backend detection validates the daemon's own verb catalogue before any task
  # window is created, so a narrower or older daemon fails here, loudly.
  fm_backend_tuios_protocol_check "$configured" || return 1
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

fm_backend_tuios_create_task() {  # <session> <task-label> <cwd> -> opaque window ID and workspace
  (
  local session=$1 label=$2 cwd=$3 windows id workspace lockfile lock_fd lockroot
  lockroot=${XDG_RUNTIME_DIR:-$SQUAD_BACKEND_CONFIG_DIR}
  # Keep a stable file separate from the legacy lock directory: flock releases
  # ownership on process exit, and this path must never be unlinked while waiters
  # may have it open or they could lock different inodes.
  lockfile="$lockroot/.squad-tuios-workspace-${session}.flock"
  mkdir -p "$lockroot" || return 1
  command -v flock >/dev/null 2>&1 || { echo "error: backend=tuios selected but 'flock' is not installed (required to serialize per-session workspace allocation)" >&2; return 1; }
  exec {lock_fd}>"$lockfile" || { echo "error: cannot open TUIOS workspace lock '$lockfile'" >&2; return 1; }
  flock -x -w 10 "$lock_fd" || { echo 'error: timed out waiting for TUIOS workspace allocation' >&2; return 1; }
  windows=$(fm_backend_tuios_list_windows_json "$session") || { echo "error: cannot read TUIOS window inventory for '$session'" >&2; return 1; }
  if printf '%s' "$windows" | jq -e --arg label "$label" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tlabels | index($label)) != null)] | length > 0
  ' >/dev/null; then
    echo "error: TUIOS task label '$label' already exists in '$session'; close that window or use the recorded task's recovery path" >&2
    return 1
  fi
  workspace=$(fm_backend_tuios_next_workspace "$session") || return 1
  fm_backend_tuios_name_workspace "$session" "$workspace" "$label" || {
    echo "error: could not name TUIOS workspace $workspace for task '$label'" >&2
    fm_backend_tuios_unname_workspace_if_empty "$session" "$workspace" "$label" >/dev/null 2>&1 || true
    return 1
  }
  id=$("$(fm_backend_tuios_bin)" new-window "$label" --session "$session" --cwd "$cwd" --workspace "$workspace" --no-focus --print-id 2>/dev/null) || {
    fm_backend_tuios_unname_workspace_if_empty "$session" "$workspace" "$label" >/dev/null 2>&1 || true
    return 1
  }
  case "$id" in ''|*[!A-Za-z0-9._@%-]*)
    echo 'error: TUIOS returned malformed opaque window id' >&2
    id=$(fm_backend_tuios_same_label_window "$session" "$label" 2>/dev/null || true)
    if [ -n "$id" ] && [ "$(fm_backend_tuios_workspace_for_window "$session" "$id" 2>/dev/null || true)" = "$workspace" ]; then
      fm_backend_tuios_kill "$session:$id" '' "$label" >/dev/null 2>&1 || true
    fi
    fm_backend_tuios_unname_workspace_if_empty "$session" "$workspace" "$label" >/dev/null 2>&1 || true
    return 1
    ;;
  esac
  fm_backend_tuios_target_ready "$session:$id" "$label" || {
    fm_backend_tuios_kill "$session:$id" '' "$label" >/dev/null 2>&1 || true
    fm_backend_tuios_unname_workspace_if_empty "$session" "$workspace" "$label" >/dev/null 2>&1 || true
    return 1
  }
  windows=$(fm_backend_tuios_list_windows_json "$session") || {
    echo 'error: cannot verify TUIOS task workspace placement' >&2
    fm_backend_tuios_kill "$session:$id" '' "$label" >/dev/null 2>&1 || true
    fm_backend_tuios_unname_workspace_if_empty "$session" "$workspace" "$label" >/dev/null 2>&1 || true
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
    fm_backend_tuios_unname_workspace_if_empty "$session" "$workspace" "$label" >/dev/null 2>&1 || true
    return 1
  }
  printf '%s\t%s\n' "$id" "$workspace"
  )
}

# fm_backend_tuios_reuse_restored_task: reuse the task's recorded window when
# its endpoint is recovery-grade agentless. Two shapes qualify. A finished agent
# whose program has exited is proven by the daemon's own
# finished-and-foreground-less report alone, so it needs no boot evidence and
# works even when the task metadata predates the `tuios_boot_id=` marker. A
# restored pane after a daemon restart needs a changed boot id plus state=none
# with no attribution, because only the restart explains its fresh shell.
# Anything else - a detected foreground program, a live or ambiguous state, an
# unreadable or contradictory report - keeps the duplicate-label refusal.
fm_backend_tuios_reuse_restored_task() {  # <session> <task-label> <recorded-boot-id>
  local session=$1 label=$2 recorded_boot=$3 current_boot id report state
  id=$(fm_backend_tuios_same_label_window "$session" "$label") || return 1
  [ -n "$id" ] || return 1
  report=$(fm_backend_tuios_agent_report_json "$session:$id") || return 1
  [ "$(printf '%s' "$report" | jq -r '.present')" = true ] || return 1
  [ "$(printf '%s' "$report" | jq -r '.contradictory')" != true ] || return 1
  if fm_backend_tuios_finished_agentless "$report"; then
    printf '%s' "$id"
    return 0
  fi
  [ -n "$recorded_boot" ] || return 1
  current_boot=$(fm_backend_tuios_boot_id "$session") || return 1
  [ -n "$current_boot" ] && [ "$current_boot" != "$recorded_boot" ] || return 1
  state=$(printf '%s' "$report" | jq -r '.state')
  case "$state" in
    ''|none)
      fm_backend_tuios_attributed "$report" && return 1
      printf '%s' "$id"
      ;;
    *) return 1 ;;
  esac
}
