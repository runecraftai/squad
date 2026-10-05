#!/usr/bin/env bash
# Exact TUIOS daemon-session lifecycle for sq-afk-launch.sh.

fm_afk_launch_tuios_sessions() {
  local json bin
  fm_backend_source tuios || return 1
  bin=$(fm_backend_tuios_bin)
  json=$("$bin" list-sessions --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e 'type == "array" and all(.[]; type == "object" and (.name | type == "string") and (.id | type == "string") and (.attached | type == "boolean") and (.windows | type == "array"))' >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}

fm_afk_launch_tuios_owned() {  # <session:window> <session-id>
  local target=$1 expected_id=$2 session window sessions
  case "$target" in *:*) ;; *) return 1 ;; esac
  session=${target%%:*}; window=${target#*:}
  [ -n "$session" ] && [ -n "$window" ] && [ "$window" != "$target" ] \
    && [ -n "$expected_id" ] && ! printf '%s' "$window" | grep -q ':' || return 1
  sessions=$(fm_afk_launch_tuios_sessions) || return 1
  printf '%s' "$sessions" | jq -e --arg name "$session" --arg id "$expected_id" --arg window "$window" '
    [.[] | select(.name == $name and .id == $id)] as $s
    | ($s | length) == 1 and $s[0].attached == false
      and ($s[0].windows | length) == 1 and $s[0].windows[0].id == $window
  ' >/dev/null 2>&1
}

fm_afk_launch_tuios_session_absent() {  # <session:window>
  local target=$1 session sessions
  case "$target" in *:*) ;; *) return 1 ;; esac
  session=${target%%:*}
  [ -n "$session" ] || return 1
  sessions=$(fm_afk_launch_tuios_sessions) || return 1
  ! printf '%s' "$sessions" | jq -e --arg name "$session" 'any(.[]; .name == $name)' >/dev/null 2>&1
}

fm_afk_launch_tuios_create_result() {  # <session-name> -> session-id<TAB>window-id
  local name=$1 sessions
  sessions=$(fm_afk_launch_tuios_sessions) || return 1
  printf '%s' "$sessions" | jq -er --arg name "$name" '
    [.[] | select(.name == $name)] as $s
    | if ($s | length) == 1 and $s[0].attached == false and ($s[0].windows | length) == 1
      then "\($s[0].id)\t\($s[0].windows[0].id)" else empty end
  ' 2>/dev/null
}

fm_afk_launch_tuios_unattached_pair() {  # <session> <session-id> <first-window> <second-window>
  local session=$1 session_id=$2 first=$3 second=$4 sessions
  sessions=$(fm_afk_launch_tuios_sessions) || return 1
  printf '%s' "$sessions" | jq -e --arg name "$session" --arg id "$session_id" --arg first "$first" --arg second "$second" '
    [.[] | select(.name == $name and .id == $id)] as $s
    | ($s | length) == 1 and $s[0].attached == false and ($s[0].windows | length) == 2
      and ([$s[0].windows[].id] | sort) == ([$first, $second] | sort)
  ' >/dev/null 2>&1
}

fm_afk_launch_create_tuios() {  # <commander-target> <commander-backend>
  local commander_target=$1 commander_backend=$2 hash nonce session entry out created session_id boot_window daemon_window label bin
  fm_backend_source tuios || return 1
  bin=$(fm_backend_tuios_bin)
  fm_backend_tuios_cli_check || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Require the existing primary TUIOS daemon; `new` must not start a shared daemon.
  fm_afk_launch_tuios_sessions >/dev/null || { fm_afk_launch_log "TUIOS daemon is not readable; refusing to start or adopt one"; return 1; }
  hash=$(printf '%s' "$SQUAD_BASE" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="sq-afk-daemon-$hash-$nonce"
  if "$bin" list-sessions --json 2>/dev/null | jq -e --arg name "$session" 'any(.[]; .name == $name)' >/dev/null 2>&1; then
    fm_afk_launch_log "generated TUIOS session name already exists; refusing to adopt it"
    return 1
  fi
  if ! "$bin" new --detach "$session" >/dev/null 2>&1; then
    fm_afk_launch_log "could not create the uniquely named detached TUIOS daemon session"
    return 1
  fi
  created=$(fm_afk_launch_tuios_create_result "$session") || {
    fm_afk_launch_log "new TUIOS session was not positively identified as detached and singly-windowed"
    return 1
  }
  IFS=$'\t' read -r session_id boot_window <<< "$created"
  [ -n "$session_id" ] && [ -n "$boot_window" ] || return 1
  if ! fm_afk_launch_record_write tuios "$session:$boot_window" "$session_id"; then
    fm_afk_launch_log "failed to record exact TUIOS session ownership; preserving the unclassified session"
    return 1
  fi
  entry=$(fm_afk_launch_entry_cmd)
  label="$SQUAD_AFK_LAUNCH_WS_LABEL"
  out=$("$bin" new-window --json --session "$session" --no-focus --cwd "$SQUAD_BASE" \
    "$label" -- env "SQUAD_BASE=$SQUAD_BASE" "SQUAD_HOME=$SQUAD_BASE" \
    "SQUAD_SUPERVISOR_TARGET=$commander_target" "SQUAD_SUPERVISOR_BACKEND=$commander_backend" "$entry" 2>/dev/null) || {
      fm_afk_launch_log "TUIOS daemon window creation failed; exact session record retained for safe recovery"
      return 1
    }
  daemon_window=$(printf '%s' "$out" | jq -r '.window_id // .result.window_id // empty' 2>/dev/null) || daemon_window=
  if [ -z "$daemon_window" ]; then
    fm_afk_launch_log "TUIOS did not return the daemon window id; refusing to guess it"
    return 1
  fi
  local windows
  windows=$(fm_backend_tuios_list_windows_json "$session") || return 1
  if ! printf '%s' "$windows" | jq -e --arg id "$daemon_window" --arg label "$label" "$SQUAD_BACKEND_TUIOS_JQ_LIB"'
      type == "object" and any(.windows[]; (tids | index($id)) != null and (tlabels | index($label)) != null)
    ' >/dev/null 2>&1; then
    fm_afk_launch_log "TUIOS daemon window identity or label did not validate"
    return 1
  fi
  if ! fm_afk_launch_record_write tuios "$session:$daemon_window" "$session_id"; then
    fm_afk_launch_log "failed to update the TUIOS daemon terminal record"
    return 1
  fi
  if ! fm_afk_launch_tuios_unattached_pair "$session" "$session_id" "$boot_window" "$daemon_window"; then
    fm_afk_launch_log "TUIOS session changed or became attached during launch; preserving both windows"
    return 1
  fi
  out=$("$bin" run-command --session "$session" CloseWindow "$boot_window" --json 2>/dev/null) || return 1
  if ! printf '%s' "$out" | jq -e '.success == true or .result.success == true' >/dev/null 2>&1; then
    fm_afk_launch_log "TUIOS refused to close the exact bootstrap window; preserving session"
    return 1
  fi
  SQUAD_AFK_REC_BACKEND=tuios
  SQUAD_AFK_REC_TARGET="$session:$daemon_window"
  SQUAD_AFK_REC_EXTRA=$session_id
  fm_afk_launch_commit_terminal tuios "$SQUAD_AFK_REC_TARGET" "$session_id" 1 || return 1
  fm_afk_launch_log "daemon launched in the new detached TUIOS session, supervising $commander_target"
}
