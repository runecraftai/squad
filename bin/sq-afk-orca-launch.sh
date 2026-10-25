#!/usr/bin/env bash
# Exact Orca daemon-terminal lifecycle, sourced by sq-afk-launch.sh.
# Never creates/removes a worktree, switches focus, stops a runtime, or closes a
# tab. A pre-create intent survives ambiguous CLI returns; no blind create retry.

fm_afk_launch_orca_primary() {  # [exact-target]; never guesses an unresolved primary
  local primary=${1:-${SQUAD_SUPERVISOR_TARGET:-}}
  if [ -z "$primary" ] || [ "$primary" = pending ]; then
    fm_afk_launch_log 'Orca supervisor has no exact primary terminal handle; set SQUAD_SUPERVISOR_TARGET to the primary this away session supervises'
    return 1
  fi
  printf '%s' "$primary"
}

fm_afk_launch_orca_resolve() {  # pending creation -> exact identity, read-only
  local extra=$SQUAD_AFK_REC_EXTRA inventory terminal count endpoint
  if [ "$SQUAD_AFK_REC_TARGET" != pending ]; then return 0; fi
  inventory=$(orca terminal list --worktree "id:$(printf '%s' "$extra" | jq -er '.parent.worktree')" --json) || return 1
  terminal=$(printf '%s' "$inventory" | jq -ce --argjson rec "$extra" '
    select(.ok == true and .result.truncated == false and ._meta.runtimeId == $rec.parent.runtime)
    | [.result.terminals[] | select(.title == $rec.title and .worktreeId == $rec.parent.worktree and .worktreePath == $rec.parent.path)]') || return 1
  count=$(printf '%s' "$terminal" | jq length)
  [ "$count" -eq 1 ] || { fm_afk_launch_log 'Orca create outcome remains uncertain; preserving the pending intent (no create retry)'; return 1; }
  terminal=$(printf '%s' "$terminal" | jq -er '.[0].handle') || return 1
  endpoint=$(fm_supervisor_native_endpoint orca "$terminal") || return 1
  printf '%s' "$extra" | jq -e --argjson endpoint "$endpoint" '.parent.runtime == $endpoint.runtime' >/dev/null || return 1
  extra=$(printf '%s' "$extra" | jq -ce --argjson endpoint "$endpoint" '. + {endpoint:$endpoint}') || return 1
  fm_afk_launch_record_write orca "$terminal" "$extra" || return 1
  SQUAD_AFK_REC_TARGET=$terminal
  SQUAD_AFK_REC_EXTRA=$extra
}

fm_afk_launch_orca_daemon_owned() {
  local owner title
  owner=$(daemon_lock_owner) || return 1
  title=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -er .title) || return 1
  [ -f "$owner/orca-owner" ] && [ ! -L "$owner/orca-owner" ] \
    && [ "$(cat "$owner/orca-owner")" = "$title" ]
}

fm_afk_launch_orca_owned() {  # <target> <record-json>
  local target=$1 extra=$2 endpoint title
  [ "$target" != pending ] || return 1
  endpoint=$(fm_supervisor_native_endpoint orca "$target") || return 1
  printf '%s' "$extra" | jq -e --argjson endpoint "$endpoint" '.endpoint == $endpoint and .parent.runtime == $endpoint.runtime and .parent.worktree == $endpoint.worktree and .parent.path == $endpoint.path' >/dev/null || return 1
  title=$(orca terminal show --terminal "$target" --json | jq -er '.result.terminal.title') || return 1
  [ "$title" = "$(printf '%s' "$extra" | jq -er .title)" ]
}

fm_afk_launch_orca_absent() {  # <target> <record-json>
  local target=$1 extra=$2 status inventory runtime
  [ "$target" != pending ] || return 1
  runtime=$(printf '%s' "$extra" | jq -er '.endpoint.runtime') || return 1
  status=$(orca status --json) || return 1
  printf '%s' "$status" | jq -e --arg runtime "$runtime" '.ok == true and .result.runtime.reachable == true and .result.runtime.state == "ready" and .result.runtime.runtimeId == $runtime' >/dev/null || return 1
  inventory=$(orca terminal list --worktree "id:$(printf '%s' "$extra" | jq -er '.parent.worktree')" --json) || return 1
  printf '%s' "$inventory" | jq -e --arg target "$target" --arg runtime "$runtime" '
    .ok == true and ._meta.runtimeId == $runtime and .result.truncated == false and ((.result.hostScope.omittedHostIds // []) | length == 0) and (.result.terminals | type == "array") and all(.result.terminals[]; (.handle | type == "string")) and all(.result.terminals[]; .handle != $target)' >/dev/null
}

fm_afk_launch_create_orca() {  # <commander-target> <commander-backend>
  local target=$1 ready parent title extra entry cmd out terminal endpoint
  ready=$(fm_supervisor_native_ready_once "$SQUAD_AFK_LAUNCH_STATE" "$target") || return 1
  parent=$(printf '%s' "$ready" | jq -c .endpoint) || return 1
  title="sq-afk-$(node -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))')" || return 1
  extra=$(jq -cn --argjson parent "$parent" --arg title "$title" '{parent:$parent,title:$title}') || return 1
  # Write before creating: a lost response is never permission to create again.
  fm_afk_launch_record_write orca pending "$extra" || return 1
  # Consumed by the launcher across sourced files.
  # shellcheck disable=SC2034
  SQUAD_AFK_REC_BACKEND=orca
  SQUAD_AFK_REC_TARGET=pending
  SQUAD_AFK_REC_EXTRA=$extra
  entry=$(fm_afk_launch_entry_cmd)
  printf -v cmd 'exec env SQUAD_BASE=%q SQUAD_HOME=%q SQUAD_STATE_OVERRIDE=%q SQUAD_AFK_STATE_PREPARED=1 SQUAD_AFK_ORCA_OWNER=%q SQUAD_SUPERVISOR_HARNESS=%q SQUAD_SUPERVISOR_BACKEND=orca SQUAD_SUPERVISOR_TARGET=%q %q' \
    "$SQUAD_BASE" "$SQUAD_BASE" "$SQUAD_AFK_LAUNCH_STATE" "$title" "$(printf '%s' "$ready" | jq -r .provider)" "$target" "$entry"
  out=$(orca terminal create --worktree "id:$(printf '%s' "$parent" | jq -r .worktree)" --title "$title" --command "$cmd" --json)
  # Regardless of the CLI exit, only exact native identity can settle creation.
  terminal=$(printf '%s' "$out" | jq -er 'select(.ok == true) | .result.terminal.handle' 2>/dev/null) || terminal=
  if [ -n "$terminal" ]; then
    endpoint=$(fm_supervisor_native_endpoint orca "$terminal") || return 1
    extra=$(printf '%s' "$extra" | jq -ce --argjson endpoint "$endpoint" '. + {endpoint:$endpoint}') || return 1
    fm_afk_launch_orca_owned "$terminal" "$extra" || return 1
    fm_afk_launch_record_write orca "$terminal" "$extra" || return 1
    SQUAD_AFK_REC_TARGET=$terminal
    SQUAD_AFK_REC_EXTRA=$extra
  else
    fm_afk_launch_orca_resolve || return 1
  fi
  fm_afk_launch_commit_terminal orca "$SQUAD_AFK_REC_TARGET" "$SQUAD_AFK_REC_EXTRA" 1 || return 1
  fm_afk_launch_log 'daemon launched in an exact unfocused Orca terminal; no worktree or primary tab changed'
}
