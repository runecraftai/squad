#!/usr/bin/env bash
# bin/backends/tuios.sh - explicit TUIOS session-provider adapter.
#
# TUIOS owns only session/pane lifecycle. Squad and fob retain task/worktree
# ownership. Every persisted target is <session-name>:<opaque-window-id>.
# TUIOS is never inferred from ambient markers; configure it explicitly.

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
# may silently resolve.
SQUAD_BACKEND_TUIOS_JQ_LIB='
  def tids: [ (.id // empty), (.window_id // empty),
              (if (.window | type) == "object" then (.window.id // empty) else (.window // empty) end) ]
            | map(select(type == "string" and length > 0));
  def tlabels: [ (.name // empty), (.title // empty), (.custom_name // empty), (.display_name // empty),
                 (if (.window | type) == "object" then (.window.name // empty), (.window.title // empty), (.window.custom_name // empty), (.window.display_name // empty) else empty end) ]
            | map(select(type == "string" and length > 0));
'

fm_backend_tuios_list_windows_json() {  # <session> -> validated windows inventory
  local session=$1 json
  json=$(fm_backend_tuios_cli "$session" list-windows --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    type == "object"
    and (.windows | type == "array")
    and all(.windows[]; type == "object" and ((tids | unique | length) == 1))
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
    (tids | unique | length) == 1 and (tids | index($id)) != null
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
    | if length == 1 then (.[0].cwd // .[0].window.cwd // empty) else empty end'
}

fm_backend_tuios_composer_state() {  # Pi UI is not proof of delivery: return unknown.
  printf 'unknown'
}

fm_backend_tuios_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected]
  local target=$1 text=$2 expected=${6:-}
  # A transport write and an empty composer cannot establish accepted delivery.
  # Never retry Enter or retype from this generic adapter; Pi tasks use the
  # task-bound native dropbox in sq-send.sh when available.
  fm_backend_tuios_send_literal "$target" "$text" "$expected" || { printf 'send-failed'; return 0; }
  fm_backend_tuios_send_key "$target" Enter "$expected" >/dev/null 2>&1 || { printf 'uncertain-delivery'; return 0; }
  printf 'uncertain-delivery'
}

fm_backend_tuios_target_exists() {  # <target> [expected-label]
  fm_backend_tuios_target_ready "$@"
}

fm_backend_tuios_busy_state() {  # <target>
  printf 'unknown'
}

fm_backend_tuios_agent_state() {  # <target>
  local target=$1 info agents windows state foreground present
  fm_backend_tuios_parse_target "$target" || { printf 'unreadable'; return 0; }
  windows=$(fm_backend_tuios_list_windows_json "$SQUAD_BACKEND_TUIOS_SESSION") || { printf 'unreadable'; return 0; }
  # Presence matches the requested id against every identity candidate, so a
  # field disagreement can never turn a live window into authoritative absence.
  present=$(printf '%s' "$windows" | jq -r --arg id "$SQUAD_BACKEND_TUIOS_WINDOW" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tids | index($id)) != null)] | length' 2>/dev/null) || { printf 'unreadable'; return 0; }
  if [ "$present" = 0 ]; then printf 'missing'; return 0; fi
  [ "$present" = 1 ] || { printf 'unreadable'; return 0; }
  info=$(fm_backend_tuios_window_info "$SQUAD_BACKEND_TUIOS_SESSION" "$SQUAD_BACKEND_TUIOS_WINDOW") || { printf 'unreadable'; return 0; }
  agents=$(fm_backend_tuios_cli "$SQUAD_BACKEND_TUIOS_SESSION" list-agents --all --json 2>/dev/null) || { printf 'unreadable'; return 0; }
  # Agent inventory is authoritative for identity. get-window's process hint
  # is not: live Pi may report foreground=false while list-agents identifies Pi.
  foreground=$(printf '%s' "$agents" | jq -r --arg id "$SQUAD_BACKEND_TUIOS_WINDOW" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.agents[]?, .windows[]?]
    | map(select((tids | index($id)) != null))
    | unique_by(tids | unique | join(","))
    | if length == 1 then (.[0].foreground // .[0].harness_id // .[0].harness // .[0].program // empty) else empty end' 2>/dev/null)
  [ -n "$foreground" ] || { printf 'ambiguous'; return 0; }
  state=$(printf '%s' "$agents" | jq -r --arg id "$SQUAD_BACKEND_TUIOS_WINDOW" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.agents[]?, .windows[]?]
    | map(select((tids | index($id)) != null))
    | unique_by(tids | unique | join(","))
    | if length == 1 then (.[0].state // empty) else empty end' 2>/dev/null)
  case "$state" in working|needs_input|done|idle|errored) printf 'alive' ;; *) printf 'ambiguous' ;; esac
}

fm_backend_tuios_kill() {  # <target> [unused] [expected-label]
  local target=$1 expected=${3:-} session window inventory selected='' candidate matched
  fm_backend_tuios_target_ready "$target" "$expected" || return 1
  session=$SQUAD_BACKEND_TUIOS_SESSION
  window=$SQUAD_BACKEND_TUIOS_WINDOW
  # TUIOS exposes close-window on its control protocol but not as a CLI verb.
  # Its documented tmux shim provides a session-scoped pane id; resolve that
  # id by the exact opaque TUIOS id before issuing the one-pane kill.
  inventory=$(TUIOS_SESSION="$session" "$(fm_backend_tuios_bin)" tmux list-panes -a \
    -F '#{pane_id} #{tuios_window_id}' 2>/dev/null) || return 1
  while IFS=' ' read -r candidate matched; do
    [ "$matched" = "$window" ] || continue
    case "$candidate" in %[0-9]*) : ;; *) return 1 ;; esac
    [ -z "$selected" ] || return 1
    selected=$candidate
  done <<EOF
$inventory
EOF
  [ -n "$selected" ] || return 1
  TUIOS_SESSION="$session" "$(fm_backend_tuios_bin)" tmux kill-pane -t "$selected" >/dev/null
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
  printf '%s' "$configured"
}

fm_backend_tuios_create_task() {  # <session> <task-label> <cwd> -> opaque window ID
  local session=$1 label=$2 cwd=$3 windows id
  windows=$(fm_backend_tuios_list_windows_json "$session") || { echo "error: cannot read TUIOS window inventory for '$session'" >&2; return 1; }
  if printf '%s' "$windows" | jq -e --arg label "$label" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
    [.windows[] | select((tlabels | index($label)) != null)] | length > 0
  ' >/dev/null; then
    echo "error: TUIOS task label '$label' already exists in '$session'" >&2
    return 1
  fi
  id=$("$(fm_backend_tuios_bin)" new-window "$label" --session "$session" --cwd "$cwd" --no-focus --print-id 2>/dev/null) || return 1
  case "$id" in ''|*[!A-Za-z0-9._@%-]*) echo 'error: TUIOS returned malformed opaque window id' >&2; return 1 ;; esac
  fm_backend_tuios_target_ready "$session:$id" "$label" || return 1
  printf '%s' "$id"
}
