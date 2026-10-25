#!/usr/bin/env bash
# sq-afk-launch.sh - the single owner of the away-mode daemon TERMINAL lifecycle:
# launch it in a launcher-owned tracked terminal per backend, record its exact id,
# tear it down by that exact id, and reconcile a leaked one after a crash.
#
# Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/sq-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever
# terminal it is already in. Harnesses with a native in-pane tracked-background
# tool (claude, grok) run it there directly and it is fine. A harness with NO
# native background mechanism (pi) has to manufacture a terminal, and doing that
# by SPLITTING the commander's active pane visibly shrinks it - the regression this
# script fixes. Instead this creates a non-visible tracked terminal (a herdr tab/
# workspace with --no-focus, or a detached tmux session) that never touches the
# commander's active tab, and NEVER uses shell `&` (which herdr/codex can reap).
#
# Correct supervisor targeting: the daemon finds the commander pane to inject into
# from its OWN inherited env (discover_supervisor_pane). Running it in a
# separate terminal would make it discover its OWN pane, so this captures the
# commander pane FIRST (from the pane this script runs in) and passes it in as
# SQUAD_SUPERVISOR_TARGET/SQUAD_SUPERVISOR_BACKEND explicitly.
#
# Usage:
#   sq-afk-launch.sh start     Capture the commander pane, then (unless the daemon
#                              is already running) launch the daemon in a fresh
#                              launcher-owned terminal for the detected backend and
#                              record it. Idempotent: an already-running daemon
#                              just refreshes state/.afk; a recorded-but-dead
#                              terminal is reconciled (closed by id) first.
#   sq-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#   sq-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
#                              cleanup flushes WHILE state/.afk is still present,
#                              wait for it, close the recorded terminal by exact
#                              id, then clear state/.afk last.
#   sq-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#   sq-afk-launch.sh status   Print one read-only machine-readable health line and
#                              return zero only when active state is healthy.
#
# Supported supervisor targets: herdr, tmux, TUIOS, and explicit native-only Orca.
# herdr (a `--no-focus` workspace) and tmux (a detached session) launch the daemon
# terminal without touching the commander's active tab; TUIOS uses an exact
# newly-created detached session and refuses all cleanup unless its recorded
# identity still matches and it remains unattached.
# Orca's create call requests no focus flag and never creates or removes a
# worktree; whether the host focuses, keeps, or hides the new terminal is
# unverified, so treat it as possibly visible or focused.
#
# Test seam: SQUAD_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal (default bin/sq-afk-start.sh), so a topology test can run a harmless
# placeholder instead of a real daemon. SQUAD_SUPERVISOR_TARGET/SQUAD_SUPERVISOR_BACKEND
# override the captured commander pane/backend (an isolated lab pane in tests).
set -u

SQUAD_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SQUAD_AFK_LAUNCH_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
case "$SQUAD_BASE" in
  /*) ;;
  *)
    SQUAD_AFK_LAUNCH_HOME_INPUT=$SQUAD_BASE
    SQUAD_BASE=$(CDPATH='' cd -- "$SQUAD_AFK_LAUNCH_HOME_INPUT" 2>/dev/null && pwd -P) || {
      echo "error: SQUAD_BASE directory cannot be resolved: $SQUAD_AFK_LAUNCH_HOME_INPUT" >&2
      exit 1
    }
    ;;
esac
if [ -n "${SQUAD_STATE_OVERRIDE:-}" ]; then
  case "$SQUAD_STATE_OVERRIDE" in
    /*) ;;
    *)
      SQUAD_AFK_LAUNCH_STATE_INPUT=$SQUAD_STATE_OVERRIDE
      SQUAD_STATE_OVERRIDE=$(CDPATH='' cd -- "$SQUAD_AFK_LAUNCH_STATE_INPUT" 2>/dev/null && pwd -P) || {
        echo "error: SQUAD_STATE_OVERRIDE directory cannot be resolved: $SQUAD_AFK_LAUNCH_STATE_INPUT" >&2
        exit 1
      }
      ;;
  esac
fi
SQUAD_AFK_LAUNCH_STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
SQUAD_AFK_LAUNCH_RECORD="$SQUAD_AFK_LAUNCH_STATE/.afk-daemon-terminal"
SQUAD_AFK_LAUNCH_LOCK="$SQUAD_AFK_LAUNCH_STATE/.afk-launch.lock"
SQUAD_AFK_LAUNCH_WS_LABEL="Squad-afk-daemon"

# shellcheck source=bin/sq-backend.sh
. "$SQUAD_AFK_LAUNCH_DIR/sq-backend.sh"
# shellcheck source=bin/sq-afk-tuios-launch.sh
. "$SQUAD_AFK_LAUNCH_DIR/sq-afk-tuios-launch.sh"
# shellcheck source=bin/sq-supervisor-native.sh
. "$SQUAD_AFK_LAUNCH_DIR/sq-supervisor-native.sh"
# shellcheck source=bin/sq-afk-orca-launch.sh
. "$SQUAD_AFK_LAUNCH_DIR/sq-afk-orca-launch.sh"
# shellcheck source=bin/sq-supervisor-target-lib.sh
. "$SQUAD_AFK_LAUNCH_DIR/sq-supervisor-target-lib.sh"
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${SQUAD_SUPERVISOR_BACKEND:-}" = orca ]; then
  case "${1:-start}" in
    start|start-native) fm_supervisor_native_ready_once "$SQUAD_AFK_LAUNCH_STATE" "${SQUAD_SUPERVISOR_TARGET:-}" >/dev/null || exit 1 ;;
  esac
fi
# sq-afk-start.sh provides the daemon-lock liveness helpers and
# fm_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/sq-afk-start.sh
. "$SQUAD_AFK_LAUNCH_DIR/sq-afk-start.sh"
set +e

fm_afk_launch_log() { printf 'sq-afk-launch: %s\n' "$*" >&2; }

fm_afk_launch_lock_owned() {
  local pid expected actual
  [ -d "$SQUAD_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(cat "$SQUAD_AFK_LAUNCH_LOCK/pid" 2>/dev/null) || return 1
  expected=$(cat "$SQUAD_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null) || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

fm_afk_launch_lock_acquire() {
  local attempt=0 incomplete=0 identity
  mkdir -p "$SQUAD_AFK_LAUNCH_STATE" || return 1
  while [ "$attempt" -lt 200 ]; do
    attempt=$((attempt + 1))
    if mkdir "$SQUAD_AFK_LAUNCH_LOCK" 2>/dev/null; then
      if ! printf '%s' "$$" > "$SQUAD_AFK_LAUNCH_LOCK/pid"; then
        rm -rf "$SQUAD_AFK_LAUNCH_LOCK"
        return 1
      fi
      identity=$(fm_pid_identity "$$" 2>/dev/null) || {
        rm -rf "$SQUAD_AFK_LAUNCH_LOCK"
        return 1
      }
      if [ -z "$identity" ] || ! printf '%s' "$identity" > "$SQUAD_AFK_LAUNCH_LOCK/pid-identity"; then
        rm -rf "$SQUAD_AFK_LAUNCH_LOCK"
        return 1
      fi
      return 0
    fi
    if [ ! -s "$SQUAD_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$SQUAD_AFK_LAUNCH_LOCK/pid-identity" ]; then
      incomplete=$((incomplete + 1))
      if [ "$incomplete" -lt 20 ]; then
        sleep 0.05
        continue
      fi
    else
      incomplete=0
    fi
    if ! fm_afk_launch_lock_owned; then
      rm -rf "$SQUAD_AFK_LAUNCH_LOCK" 2>/dev/null || return 1
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  fm_afk_launch_log "timed out waiting for launcher lock"
  return 1
}

fm_afk_launch_lock_release() {
  local pid
  pid=$(cat "$SQUAD_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "$$" ] || return 0
  rm -rf "$SQUAD_AFK_LAUNCH_LOCK"
}

fm_afk_launch_usage() {
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${SQUAD_AFK_LAUNCH_ENTRY:-$SQUAD_ROOT/bin/sq-afk-start.sh}"
}

fm_afk_launch_record_write() {  # <backend> <target> <extra>
  local pending
  mkdir -p "$SQUAD_AFK_LAUNCH_STATE" || return 1
  pending=$(mktemp "$SQUAD_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$SQUAD_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_flag_write() {
  local pending="$SQUAD_AFK_LAUNCH_STATE/.afk.pending.$$"
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$SQUAD_AFK_LAUNCH_STATE/.afk" || { rm -f "$pending"; return 1; }
}

# Read the recorded terminal into SQUAD_AFK_REC_BACKEND/SQUAD_AFK_REC_TARGET. The third
# field (a herdr workspace id, kept for the record's own documentation) is not
# needed to close by id, so it is discarded. Returns 1 when no record exists.
fm_afk_launch_record_read() {
  local extra record
  SQUAD_AFK_REC_BACKEND=""; SQUAD_AFK_REC_TARGET=""; extra=""
  [ -f "$SQUAD_AFK_LAUNCH_RECORD" ] || return 1
  record=$(cat "$SQUAD_AFK_LAUNCH_RECORD" 2>/dev/null) || record=""
  IFS=$'\t' read -r SQUAD_AFK_REC_BACKEND SQUAD_AFK_REC_TARGET extra \
    < "$SQUAD_AFK_LAUNCH_RECORD" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$SQUAD_AFK_REC_BACKEND" ] || [ -z "$SQUAD_AFK_REC_TARGET" ]; then
    fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  SQUAD_AFK_REC_EXTRA=$extra
  case "$SQUAD_AFK_REC_BACKEND" in
    orca)
      printf '%s' "$extra" | jq -e --arg target "$SQUAD_AFK_REC_TARGET" '
        (.title | type == "string" and startswith("sq-afk-")) and .parent.backend == "orca"
        and (.parent.target | type == "string" and length > 0)
        and (($target == "pending" and .endpoint == null) or (.endpoint.backend == "orca" and .endpoint.target == $target))' >/dev/null
      ;;
    herdr|tuios) [ -n "$extra" ] ;;
    tmux) : ;;
    none) [ "$SQUAD_AFK_REC_TARGET" = - ] && [ "$extra" = native ] ;;
    *) return 2 ;;
  esac || { fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

fm_afk_launch_record_validate_if_present() {
  local result
  fm_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

# Close a recorded terminal by EXACT id (never a broad sweep). The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
fm_afk_launch_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2
  case "$backend" in
    orca)
      fm_afk_launch_orca_owned "$target" "$SQUAD_AFK_REC_EXTRA" || return 1
      local out
      out=$(orca terminal close --terminal "$target" --json) || return 1
      printf '%s' "$out" | jq -e '.ok == true' >/dev/null
      ;;
    herdr)
      fm_backend_source herdr || return 1
      local session=${target%%:*} pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "$target" 2>/dev/null
      ;;
    tuios)
      fm_backend_source tuios || return 1
      fm_afk_launch_tuios_owned "$target" "$SQUAD_AFK_REC_EXTRA" || return 1
      local tuios_session=${target%%:*}
      "$(fm_backend_tuios_bin)" kill-session "$tuios_session" >/dev/null 2>&1
      ;;
    none)
      return 0
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_afk_launch_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 session pane out result code
  case "$backend" in
    orca) fm_afk_launch_orca_absent "$target" "$SQUAD_AFK_REC_EXTRA" ;;
    tuios)
      fm_afk_launch_tuios_session_absent "$target"
      ;;
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1)
      result=$?
      [ "$result" -ne 0 ] || return 1
      code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || return 1
      [ "$code" = pane_not_found ]
      ;;
    tmux)
      out=$(tmux has-session -t "$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eq "can't find session"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_marker_age() {
  local marker=$1 stamp now
  [ -f "$marker" ] || { printf 'na'; return 0; }
  stamp=$(cat "$marker" 2>/dev/null) || { printf 'na'; return 0; }
  case "$stamp" in
    ''|*[!0-9]*) printf 'na'; return 0 ;;
  esac
  now=$(date '+%s')
  [ "$stamp" -le "$now" ] || stamp=$now
  printf '%s' "$((now - stamp))"
}

fm_afk_launch_status() {
  local active=0 terminal=absent daemon=dead housekeeping_age scan_age read_result healthy=0
  [ -e "$SQUAD_AFK_LAUNCH_STATE/.afk" ] && active=1
  if daemon_lock_held_by_live_daemon; then daemon=alive; fi
  fm_afk_launch_record_read >/dev/null 2>&1
  read_result=$?
  case "$read_result" in
    0)
      if [ "$SQUAD_AFK_REC_BACKEND" = none ]; then
        terminal=not-applicable
      elif fm_afk_launch_terminal_alive "$SQUAD_AFK_REC_BACKEND" "$SQUAD_AFK_REC_TARGET"; then
        terminal=alive
      else
        terminal=dead
      fi
      ;;
    1) terminal=absent ;;
    2) terminal=invalid ;;
  esac
  housekeeping_age=$(fm_afk_launch_marker_age "$SQUAD_AFK_LAUNCH_STATE/.subsuper-last-housekeep")
  scan_age=$(fm_afk_launch_marker_age "$SQUAD_AFK_LAUNCH_STATE/.subsuper-last-scan")
  if [ "$active" -eq 1 ] && [ "$daemon" = alive ] \
    && { [ "$terminal" = alive ] || [ "$terminal" = not-applicable ]; } \
    && [ "$read_result" -eq 0 ]; then
    healthy=1
  fi
  printf 'active=%s terminal=%s daemon=%s housekeeping_age=%s scan_age=%s\n' \
    "$active" "$terminal" "$daemon" "$housekeeping_age" "$scan_age"
  [ "$read_result" -eq 2 ] && return 2
  if [ "${SQUAD_AFK_REC_BACKEND:-}" = orca ]; then
    local primary
    primary=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -er .parent.target) || return 1
    if [ "$daemon" = alive ] && ! fm_afk_launch_orca_daemon_owned; then return 1; fi
    fm_supervisor_native_ready "$SQUAD_AFK_LAUNCH_STATE" "$primary" >/dev/null || return 1
    if fm_supervisor_native_pending "$SQUAD_AFK_LAUNCH_STATE" "$primary" \
      || fm_supervisor_native_unresolved "$SQUAD_AFK_LAUNCH_STATE" "$primary"; then
      fm_afk_launch_log 'Orca native delivery or buffer retirement is pending/uncertain'
      return 1
    fi
  fi
  [ "$healthy" -eq 1 ]
}

fm_afk_launch_close_recorded() {
  local close_result=0
  fm_afk_launch_close_terminal "$SQUAD_AFK_REC_BACKEND" "$SQUAD_AFK_REC_TARGET" || close_result=$?
  if fm_afk_launch_terminal_absent "$SQUAD_AFK_REC_BACKEND" "$SQUAD_AFK_REC_TARGET"; then
    rm -f "$SQUAD_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

fm_afk_launch_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    orca) fm_afk_launch_orca_owned "$target" "$SQUAD_AFK_REC_EXTRA" ;;
    tuios)
      fm_afk_launch_tuios_owned "$target" "$SQUAD_AFK_REC_EXTRA"
      ;;
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    tmux)
      tmux has-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 attempt=0 started=$SECONDS
  if [ -n "${SQUAD_AFK_LAUNCH_ENTRY:-}" ]; then
    fm_afk_launch_terminal_alive "$backend" "$target"
    return
  fi
  # Wall-clock bounded: each Orca terminal-alive probe spawns the Orca CLI, so
  # probing on every 50ms tick would stretch a failing start far past the short
  # readiness budget. Cheap daemon ownership is checked every tick; the
  # expensive identity probe runs early and then rarely.
  while [ $((SECONDS - started)) -lt 5 ]; do
    attempt=$((attempt + 1))
    if daemon_lock_held_by_live_daemon; then
      if [ "$backend" != orca ] || fm_afk_launch_orca_daemon_owned; then return 0; fi
    fi
    if [ "$backend" != orca ] || [ "$attempt" -le 2 ] || [ $((attempt % 20)) -eq 0 ]; then
      fm_afk_launch_terminal_alive "$backend" "$target" || return 1
    fi
    sleep 0.05
  done
  return 1
}

fm_afk_launch_commit_terminal() {  # <backend> <target> <extra> [already-recorded]
  local backend=$1 target=$2 extra=$3 already_recorded=${4:-0}
  if [ "$already_recorded" -ne 1 ] && ! fm_afk_launch_record_write "$backend" "$target" "$extra"; then
    fm_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    fm_afk_launch_close_terminal "$backend" "$target"
    return 1
  fi
  if ! fm_afk_launch_wait_ready "$backend" "$target"; then
    fm_afk_launch_log "daemon did not become ready; closing $backend:$target"
    SQUAD_AFK_REC_BACKEND=$backend
    SQUAD_AFK_REC_TARGET=$target
    fm_afk_launch_close_recorded
    return 1
  fi
}

fm_afk_launch_herdr_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane attempt=0
  while [ "$attempt" -lt 20 ]; do
    attempt=$((attempt + 1))
    workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { sleep 0.05; continue; }
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || return 1
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
    [ -n "$wsid" ] || return 1
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || { sleep 0.05; continue; }
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]?] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || return 1
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null) || return 1
    [ -n "$pane" ] || return 1
    printf '%s\t%s' "$wsid" "$pane"
    return 0
  done
  return 1
}

# Settling one exact primary is only complete when no other primary's request
# still covers a prefix of the shared escalation buffer.
fm_afk_launch_native_settle() {  # <exact-primary> <preserve-message>
  local primary=$1 message=$2
  fm_supervisor_native_retire "$SQUAD_AFK_LAUNCH_STATE" "$primary" || true
  if fm_supervisor_native_pending "$SQUAD_AFK_LAUNCH_STATE" "$primary"; then
    fm_afk_launch_log "$message (${FM_SUPERVISOR_NATIVE_RETIRE_REASON:-no consumed acknowledgement})"
    return 1
  fi
  if fm_supervisor_native_unresolved "$SQUAD_AFK_LAUNCH_STATE" "$primary"; then
    fm_afk_launch_log "$message (an unresolved native request for another primary still covers this escalation buffer; settle that exact endpoint first)"
    return 1
  fi
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {  # [exact-primary]
  local read_result primary
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    if [ "$SQUAD_AFK_REC_BACKEND" = orca ]; then
      fm_afk_launch_orca_resolve || return 1
      primary=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -er .parent.target) || return 1
      fm_afk_launch_native_settle "$primary" 'Orca escalation is unresolved, preserving lifecycle during reconciliation' || return 1
    fi
    fm_afk_launch_log "reconciling leaked daemon terminal ${SQUAD_AFK_REC_BACKEND}:${SQUAD_AFK_REC_TARGET}"
    fm_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  elif fm_afk_launch_orca_scope || fm_supervisor_native_unresolved "$SQUAD_AFK_LAUNCH_STATE"; then
    primary=$(fm_afk_launch_orca_primary "${1:-}") || return 1
    fm_afk_launch_native_settle "$primary" 'Orca native request remains unresolved even without a terminal record, preserving it' || return 1
  fi
}

fm_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$SQUAD_AFK_LAUNCH_STATE/.afk" \
    "$SQUAD_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$SQUAD_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$SQUAD_AFK_LAUNCH_STATE/.subsuper-inject-wedged" || result=1
  if [ "$had_afk" -eq 1 ]; then
    cp "$backup/.afk" "$SQUAD_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$backup/$artifact" ]; then
      cp -p "$backup/$artifact" "$SQUAD_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    fm_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Launch the daemon in a non-visible herdr terminal in the COMMANDER's session
# (so the daemon can inject into the commander pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the commander's active tab. Prints the record line on success.
fm_afk_launch_create_herdr() {  # <commander-target> <commander-backend>
  local commander_target=$1 commander_backend=$2 session out wsid pane entry cmd label recovered create_result
  session=${commander_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$commander_target" ]; then
    fm_afk_launch_log "cannot derive herdr session from commander target '$commander_target'"
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  label=${SQUAD_AFK_LAUNCH_LABEL:-"$SQUAD_AFK_LAUNCH_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$SQUAD_BASE" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    fm_afk_launch_log "herdr create failed after returning exact ids; closing $session:$pane"
    if fm_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
      SQUAD_AFK_REC_BACKEND=herdr
      SQUAD_AFK_REC_TARGET="$session:$pane"
      fm_afk_launch_close_recorded || true
    else
      fm_afk_launch_log "failed to persist exact id for failed herdr create"
    fi
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$session" "$label") || {
      fm_afk_launch_log "herdr create did not yield a recoverable exact workspace/pane id"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
  fi
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env SQUAD_BASE=%q SQUAD_HOME=%q SQUAD_SUPERVISOR_TARGET=%q SQUAD_SUPERVISOR_BACKEND=%q %q' \
    "$SQUAD_BASE" "$SQUAD_BASE" "$commander_target" "$commander_backend" "$entry")
  if ! fm_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
    fm_afk_launch_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    fm_afk_launch_close_terminal herdr "$session:$pane"
    return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    SQUAD_AFK_REC_BACKEND=herdr
    SQUAD_AFK_REC_TARGET="$session:$pane"
    fm_afk_launch_close_recorded || true
    return 1
  fi
  fm_afk_launch_commit_terminal herdr "$session:$pane" "$wsid" 1 || return 1
  fm_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $commander_target"
}

# Launch the daemon in a detached tmux session (never a split-window in the
# commander's window). tmux pane ids are server-global, so the daemon reaches the
# commander pane by its %id from this separate session.
fm_afk_launch_create_tmux() {  # <commander-target> <commander-backend>
  local commander_target=$1 commander_backend=$2 session entry cmd hash nonce
  hash=$(printf '%s' "$SQUAD_BASE" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="sq-afk-daemon-$hash-$nonce"
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env SQUAD_BASE=%q SQUAD_HOME=%q SQUAD_SUPERVISOR_TARGET=%q SQUAD_SUPERVISOR_BACKEND=%q %q' \
    "$SQUAD_BASE" "$SQUAD_BASE" "$commander_target" "$commander_backend" "$entry")
  if ! fm_afk_launch_record_write tmux "$session" ""; then
    fm_afk_launch_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_afk_launch_log "failed to create detached tmux daemon session '$session'"
    if ! rm -f "$SQUAD_AFK_LAUNCH_RECORD"; then
      fm_afk_launch_log "failed to remove planned tmux daemon record after creation failure"
    fi
    return 1
  fi
  fm_afk_launch_commit_terminal tmux "$session" "" 1 || return 1
  fm_afk_launch_log "daemon launched in detached tmux session '$session', supervising $commander_target"
}

fm_afk_launch_start() {
  local commander_target commander_backend backup artifact had_afk=0 result
  local pane_line pane_status=0 fallback_note
  if [ -e "$SQUAD_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/sq-afk-return.sh check before re-entering away mode"
    return 1
  fi
  # Capture the commander pane FIRST, before creating anything. The shared
  # resolution validates every detected marker in preference order and settles on
  # the first target that exists, so a stale preferred marker (a herdr pane id
  # left in the environment, say) falls through to the next one instead of
  # sending the daemon to a terminal it could never inject into. An explicit
  # SQUAD_SUPERVISOR_TARGET/SQUAD_SUPERVISOR_BACKEND stays authoritative.
  pane_line=$(discover_supervisor_pane) || pane_status=$?
  IFS=$'\t' read -r commander_backend commander_target _ _ _ fallback_note <<< "$pane_line"
  if [ "$fallback_note" != "-" ]; then
    fm_afk_launch_log "supervisor pane fallback: $fallback_note; using $commander_target on backend $commander_backend"
  fi
  if [ "$pane_status" -ne 0 ] || [ -z "$commander_target" ] || [ -z "$commander_backend" ]; then
    fm_afk_launch_log "could not resolve the commander supervisor pane (set SQUAD_SUPERVISOR_TARGET and SQUAD_SUPERVISOR_BACKEND)"
    return 1
  fi

  mkdir -p "$SQUAD_AFK_LAUNCH_STATE"

  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    if [ "$commander_backend" = orca ]; then
      fm_afk_launch_record_read || { fm_afk_launch_log 'a daemon is already running without an Orca terminal ownership record; refusing to refresh away mode'; return 1; }
      [ "$SQUAD_AFK_REC_BACKEND" = orca ] || { fm_afk_launch_log "a live '$SQUAD_AFK_REC_BACKEND' daemon is already running; stop it before switching to an Orca supervisor"; return 1; }
      fm_afk_launch_orca_resolve || return 1
      fm_afk_launch_orca_owned "$SQUAD_AFK_REC_TARGET" "$SQUAD_AFK_REC_EXTRA" || { fm_afk_launch_log 'the running Orca daemon terminal no longer matches its recorded identity; refusing to refresh away mode'; return 1; }
      fm_afk_launch_orca_daemon_owned || { fm_afk_launch_log 'the running Orca daemon process does not own its recorded terminal; refusing to refresh away mode'; return 1; }
      local current bound recorded live
      current=$(fm_supervisor_native_endpoint orca "$commander_target") || { fm_afk_launch_log "the selected Orca primary $commander_target no longer resolves to a ready readable endpoint; refusing to refresh away mode"; return 1; }
      if ! printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -e --argjson current "$current" '.parent == $current' >/dev/null; then
        bound=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -r '.parent.target // empty' 2>/dev/null) || bound=
        if [ "$bound" = "$commander_target" ]; then
          recorded=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -r '.parent | "runtime=\(.runtime // "unknown") incarnation=\(.incarnation // "unknown")"' 2>/dev/null) || recorded=
          live=$(printf '%s' "$current" | jq -r '"runtime=\(.runtime // "unknown") incarnation=\(.incarnation // "unknown")"' 2>/dev/null) || live=
          fm_afk_launch_log "the selected Orca primary $commander_target changed identity since this daemon was launched (recorded ${recorded:-unknown}; current ${live:-unknown}); stop away mode before restarting it against the reconnected primary"
        else
          fm_afk_launch_log "a live Orca daemon is already bound to primary handle '${bound:-unknown}', not $commander_target; stop it before switching primary"
        fi
        return 1
      fi
    fi
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$SQUAD_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$SQUAD_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$SQUAD_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$SQUAD_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$SQUAD_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! fm_afk_launch_reconcile "$commander_target"; then
    result=1
  else
    if fm_afk_clear_stale_artifacts "$SQUAD_AFK_LAUNCH_STATE"; then
      result=0
    else
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$commander_backend" in
      herdr) fm_afk_launch_create_herdr "$commander_target" "$commander_backend"; result=$? ;;
      tmux)  fm_afk_launch_create_tmux "$commander_target" "$commander_backend"; result=$? ;;
      tuios) fm_afk_launch_create_tuios "$commander_target" "$commander_backend"; result=$? ;;
      orca) fm_afk_launch_create_orca "$commander_target" "$commander_backend"; result=$? ;;
      *)
        fm_afk_launch_log "no daemon-terminal launch primitive for backend '$commander_backend' yet (supported: herdr, tmux, tuios, orca)"
        result=1
        ;;
    esac
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native() {
  local backup artifact had_afk=0 result=0
  mkdir -p "$SQUAD_AFK_LAUNCH_STATE" || return 1
  if [ -e "$SQUAD_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/sq-afk-return.sh check before re-entering away mode"
    return 1
  fi
  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$SQUAD_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$SQUAD_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$SQUAD_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$SQUAD_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$SQUAD_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  fm_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_clear_stale_artifacts "$SQUAD_AFK_LAUNCH_STATE"; then
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    elif ! fm_afk_launch_flag_write; then
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_record_write none - native || result=1
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_stop() {
  local pid pid_identity current_identity result=0 read_result primary
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  if [ "$read_result" -eq 1 ] && fm_afk_launch_orca_scope; then
    if daemon_lock_held_by_live_daemon; then
      fm_afk_launch_log 'Orca live daemon has no terminal ownership record; refusing to signal it'
      return 1
    fi
    primary=$(fm_afk_launch_orca_primary) || return 1
    fm_afk_launch_native_settle "$primary" 'Orca native request remains unresolved; stop is not complete' || return 1
  fi
  if [ "$read_result" -eq 1 ] && fm_supervisor_native_unresolved "$SQUAD_AFK_LAUNCH_STATE"; then
    fm_afk_launch_log 'a native escalation request is unresolved without a recorded daemon terminal; set SQUAD_SUPERVISOR_TARGET to the exact primary and reconcile before stopping'
    return 1
  fi
  if [ "$read_result" -eq 0 ] && [ "$SQUAD_AFK_REC_BACKEND" = tuios ] \
    && ! fm_afk_launch_terminal_alive tuios "$SQUAD_AFK_REC_TARGET" \
    && ! fm_afk_launch_terminal_absent tuios "$SQUAD_AFK_REC_TARGET"; then
    fm_afk_launch_log "TUIOS daemon session is attached or unreadable; preserving away mode and refusing session cleanup"
    return 1
  fi
  if [ "$read_result" -eq 0 ] && [ "$SQUAD_AFK_REC_BACKEND" = orca ]; then
    fm_afk_launch_orca_resolve || return 1
    if ! fm_afk_launch_orca_owned "$SQUAD_AFK_REC_TARGET" "$SQUAD_AFK_REC_EXTRA" \
      && ! fm_afk_launch_orca_absent "$SQUAD_AFK_REC_TARGET" "$SQUAD_AFK_REC_EXTRA"; then
      fm_afk_launch_log 'Orca daemon identity is uncertain; preserving away mode and process'
      return 1
    fi
    if daemon_lock_held_by_live_daemon && ! fm_afk_launch_orca_daemon_owned; then
      fm_afk_launch_log 'Orca daemon process ownership does not match the recorded terminal; refusing to signal it'
      return 1
    fi
    primary=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -er .parent.target) || return 1
    # A live daemon alone retires its buffer during the SIGTERM flush, and the
    # post-exit gate below re-checks the result. A consumed-but-not-yet-retired
    # request is delivered, not unresolved, so it must not block that shutdown.
    if ! daemon_lock_held_by_live_daemon; then
      fm_afk_launch_native_settle "$primary" 'Orca native request or buffer retirement remains unresolved; stop is not complete, preserving lifecycle for inspection' || return 1
    fi
  fi
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate).
  pid=""
  pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  fi
  if [ -n "$pid" ]; then
    if [ "${SQUAD_AFK_REC_BACKEND:-}" = orca ]; then
      local owner expected_identity
      owner=$(daemon_lock_owner) || return 1
      expected_identity=$(cat "$owner/pid-identity" 2>/dev/null) || return 1
      if ! fm_afk_launch_orca_daemon_owned || [ "$(daemon_lock_pid)" != "$pid" ] \
        || [ "$expected_identity" != "$pid_identity" ] || [ "$(fm_pid_identity "$pid")" != "$pid_identity" ]; then
        fm_afk_launch_log 'Orca daemon process changed before stop; preserving lifecycle without signalling'
        return 1
      fi
    fi
    if ! kill -TERM "$pid" 2>/dev/null; then
      fm_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    # The sentry may be inside its configured poll sleep when the daemon is
    # stopped, so allow one default poll interval for its signal trap to run.
    for _ in $(seq 1 100); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
      fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    }
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  if [ "$read_result" -eq 0 ] && [ "$SQUAD_AFK_REC_BACKEND" = orca ]; then
    fm_afk_launch_native_settle "$primary" 'Orca shutdown delivery or buffer retirement is unresolved; stop is not complete, preserving lifecycle for retry' || return 1
  fi
  # (2) Close the daemon's own terminal by exact id.
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_close_recorded || result=1
  fi
  if [ "$result" -ne 0 ] && [ "${SQUAD_AFK_REC_BACKEND:-}" = orca ]; then
    fm_afk_launch_log 'Orca terminal cleanup is unconfirmed; stop is not complete'
    return 1
  fi
  # (3) Clear the away-mode flag LAST.
  if ! rm -f "$SQUAD_AFK_LAUNCH_STATE/.afk"; then
    fm_afk_launch_log "failed to clear away-mode flag"
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_log "away mode stopped; daemon terminal torn down and .afk cleared"
  else
    fm_afk_launch_log "away mode stopped; terminal teardown remains recorded for retry"
  fi
  return "$result"
}

fm_afk_launch_main() {
  local result
  # Traps first, lock second. Acquiring before the handlers exist leaves a
  # window where a signal terminates this process by default action and leaks
  # the lock directory, which then blocks the next away-mode launch until the
  # stale-owner reclaim path clears it. fm_afk_launch_lock_release only removes
  # a lock this process owns, so arming it before acquisition is safe.
  if [ "${1:-start}" = status ]; then
    fm_afk_launch_status
    return $?
  fi
  # Orca capability and target proof precede even the launch lock/state mkdir.
  case "${1:-start}" in
    start|start-native)
      if [ "${SQUAD_SUPERVISOR_BACKEND:-}" = orca ]; then
        fm_supervisor_native_ready_once "$SQUAD_AFK_LAUNCH_STATE" "${SQUAD_SUPERVISOR_TARGET:-}" >/dev/null || return 1
        [ "${1:-start}" = start ] || { fm_afk_launch_log 'Orca requires start, not start-native, for exact terminal ownership'; return 1; }
        # Only a create path is protected by that pending gate: an already
        # running daemon just refreshes state/.afk and creates nothing.
        if ! daemon_lock_held_by_live_daemon; then
          local primary
          primary=$(fm_afk_launch_orca_primary) || return 1
          if fm_supervisor_native_pending "$SQUAD_AFK_LAUNCH_STATE" "$primary"; then
            fm_afk_launch_log 'Orca native delivery remains uncertain; inspect the existing request before starting another away session'
            return 1
          fi
          if fm_supervisor_native_unresolved "$SQUAD_AFK_LAUNCH_STATE" "$primary"; then
            fm_afk_launch_log 'an unresolved native request for another primary still covers this escalation buffer; settle that exact endpoint before starting another away session'
            return 1
          fi
        fi
      fi
      ;;
  esac
  trap fm_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  fm_afk_launch_lock_acquire || return 1
  case "${1:-start}" in
    start) fm_afk_launch_start ;;
    start-native) fm_afk_launch_start_native ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_lock_release || result=1
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
