#!/usr/bin/env bash
# Exact Orca daemon-terminal lifecycle, sourced by sq-afk-launch.sh.
# Requests no focus flag (real host focus behaviour is unverified) and never
# creates/removes a worktree or stops a runtime; cleanup requests close only for
# the exact daemon terminal it created, never another terminal's tab. Real
# create/cleanup semantics are covered by docs/verification/runtime-backends.md.
# A pre-create intent survives ambiguous CLI returns. Recovery requires a
# recorded runtime-issued daemon identity and a complete identity-bound inventory;
# titles are display-only. Handle-less lost responses always remain uncertain.

fm_afk_launch_orca_primary() {  # [exact-target]; never guesses an unresolved primary
  local primary=${1:-${SQUAD_SUPERVISOR_TARGET:-}}
  if [ -z "$primary" ] || [ "$primary" = pending ]; then
    fm_afk_launch_log 'Orca supervisor has no exact primary terminal handle; set SQUAD_SUPERVISOR_TARGET to the primary this away session supervises'
    return 1
  fi
  printf '%s' "$primary"
}

fm_afk_launch_orca_resolve() {  # 0: adopted/exact; 2: proven absent; 1: uncertain
  local extra=$SQUAD_AFK_REC_EXTRA inventory terminal count endpoint parent base
  if [ "$SQUAD_AFK_REC_TARGET" != pending ]; then return 0; fi
  if ! printf '%s' "$extra" | jq -e '.endpoint.backend == "orca" and (.endpoint.target | type == "string" and length > 0)' >/dev/null; then
    fm_afk_launch_log 'Orca create outcome remains uncertain: no daemon identity was recorded; preserving the pending intent (no create retry)'
    return 1
  fi
  # Neither a title nor a new terminal in the same worktree proves ownership.
  # The create receipt is recorded before any subsequent runtime lookup.
  base=$(CDPATH='' cd -- "$SQUAD_BASE" && pwd -P) || return 1
  parent=$(fm_supervisor_native_endpoint orca "$(printf '%s' "$extra" | jq -er '.parent.target')") || return 1
  if ! printf '%s' "$extra" | jq -e --argjson parent "$parent" --arg base "$base" '.parent == $parent and .parent.path == $base' >/dev/null; then
    fm_afk_launch_log 'Orca pending parent identity does not match this base and primary; preserving the pending intent'
    return 1
  fi
  # Search the whole runtime: a handle moved to another worktree is an identity
  # mismatch, not proof that the terminal disappeared from the original one.
  if ! inventory=$(orca terminal list --limit 10000 --json) \
    || ! terminal=$(printf '%s' "$inventory" | jq -ce --argjson rec "$extra" '
      select(.ok == true and .result.truncated == false and ._meta.runtimeId == $rec.parent.runtime
        and (.result.hostScope.omittedHostIds | type == "array" and length == 0)
        and (.result.terminals | type == "array")
        and all(.result.terminals[]; (.handle | type == "string" and length > 0)
          and (.worktreeId | type == "string") and (.worktreePath | type == "string")))
      | [.result.terminals[] | select(.handle == $rec.endpoint.target)]'); then
    fm_afk_launch_log 'Orca create outcome remains uncertain; preserving the pending intent (no create retry)'
    return 1
  fi
  count=$(printf '%s' "$terminal" | jq -r 'length') || return 1
  case "$count" in
    0) return 2 ;;
    1) ;;
    *) fm_afk_launch_log 'Orca pending identity matches multiple terminal candidates; preserving the pending intent without touching any terminal'; return 1 ;;
  esac
  terminal=$(printf '%s' "$terminal" | jq -er '.[0].handle') || return 1
  endpoint=$(fm_supervisor_native_endpoint orca "$terminal") || return 1
  if ! printf '%s' "$extra" | jq -e --argjson endpoint "$endpoint" '.endpoint == $endpoint' >/dev/null \
    || ! printf '%s' "$inventory" | jq -e --argjson endpoint "$endpoint" '
      all(.result.terminals[] | select(.handle == $endpoint.target);
        .incarnationId == $endpoint.incarnation and .worktreeId == $endpoint.worktree and .worktreePath == $endpoint.path)' >/dev/null; then
    fm_afk_launch_log 'Orca pending daemon identity changed; preserving the pending intent'
    return 1
  fi
  fm_afk_launch_orca_owned "$terminal" "$extra" || return 1
  fm_afk_launch_record_write orca "$terminal" "$extra" || return 1
  SQUAD_AFK_REC_TARGET=$terminal
  SQUAD_AFK_REC_EXTRA=$extra
}

fm_afk_launch_orca_scope() {  # recorded/daemon state owns this; the caller's environment is not authority
  local owner
  [ "${SQUAD_AFK_REC_BACKEND:-}" = orca ] && return 0
  [ "${SQUAD_SUPERVISOR_BACKEND:-}" = orca ] && return 0
  owner=$(daemon_lock_owner 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  [ -f "$owner/orca-owner" ] && [ ! -L "$owner/orca-owner" ]
}

fm_afk_launch_orca_daemon_owned() {
  local owner token
  owner=$(daemon_lock_owner) || return 1
  token=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -er '.owner | select(type == "string" and length > 0)') || return 1
  [ -f "$owner/orca-owner" ] && [ ! -L "$owner/orca-owner" ] \
    && [ "$(cat "$owner/orca-owner")" = "$token" ]
}

fm_afk_launch_orca_owned() {  # <target> <record-json>
  local target=$1 extra=$2 endpoint
  [ "$target" != pending ] || return 1
  endpoint=$(fm_supervisor_native_endpoint orca "$target") || return 1
  printf '%s' "$extra" | jq -e --argjson endpoint "$endpoint" '.endpoint == $endpoint and .parent.runtime == $endpoint.runtime and .parent.worktree == $endpoint.worktree and .parent.path == $endpoint.path' >/dev/null
}

fm_afk_launch_orca_absent() {  # <target> <record-json>
  local target=$1 extra=$2 status inventory runtime
  if [ "$target" = pending ]; then
    fm_afk_launch_orca_resolve
    [ "$?" -eq 2 ]
    return
  fi
  runtime=$(printf '%s' "$extra" | jq -er '.endpoint.runtime') || return 1
  status=$(orca status --json) || return 1
  printf '%s' "$status" | jq -e --arg runtime "$runtime" '.ok == true and .result.runtime.reachable == true and .result.runtime.state == "ready" and .result.runtime.runtimeId == $runtime' >/dev/null || return 1
  inventory=$(orca terminal list --limit 10000 --json) || return 1
  printf '%s' "$inventory" | jq -e --arg target "$target" --arg runtime "$runtime" '
    .ok == true and ._meta.runtimeId == $runtime and .result.truncated == false and (.result.hostScope.omittedHostIds | type == "array" and length == 0) and (.result.terminals | type == "array") and all(.result.terminals[]; (.handle | type == "string")) and all(.result.terminals[]; .handle != $target)' >/dev/null
}

fm_afk_launch_create_orca() {  # <commander-target> <commander-backend>
  local target=$1 ready parent title owner extra entry cmd out endpoint
  ready=$(fm_supervisor_native_ready_once "$SQUAD_AFK_LAUNCH_STATE" "$target") || return 1
  parent=$(printf '%s' "$ready" | jq -c .endpoint) || return 1
  owner=$(node -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))') || return 1
  title="sq-afk-$owner"
  extra=$(jq -cn --argjson parent "$parent" --arg title "$title" --arg owner "$owner" '{parent:$parent,title:$title,owner:$owner}') || return 1
  # Write before creating: a lost response is never permission to create again.
  fm_afk_launch_record_write orca pending "$extra" || return 1
  # Consumed by the launcher across sourced files.
  # shellcheck disable=SC2034
  SQUAD_AFK_REC_BACKEND=orca
  SQUAD_AFK_REC_TARGET=pending
  SQUAD_AFK_REC_EXTRA=$extra
  entry=$(fm_afk_launch_entry_cmd)
  printf -v cmd 'exec env SQUAD_BASE=%q SQUAD_HOME=%q SQUAD_STATE_OVERRIDE=%q SQUAD_AFK_STATE_PREPARED=1 SQUAD_AFK_ORCA_OWNER=%q SQUAD_SUPERVISOR_HARNESS=%q SQUAD_SUPERVISOR_BACKEND=orca SQUAD_SUPERVISOR_TARGET=%q %q' \
    "$SQUAD_BASE" "$SQUAD_BASE" "$SQUAD_AFK_LAUNCH_STATE" "$owner" "$(printf '%s' "$ready" | jq -r .provider)" "$target" "$entry"
  out=$(orca terminal create --worktree "id:$(printf '%s' "$parent" | jq -r .worktree)" --title "$title" --command "$cmd" --json)
  # Persist the runtime receipt BEFORE probing. A failed post-create lookup or
  # a shell changing its title must not discard the identity already returned.
  # The requested path is bound by the response's exact worktree id; create's
  # receipt need not repeat worktreePath (the installed Linux host does not).
  endpoint=$(printf '%s' "$out" | jq -ce --argjson parent "$parent" '
    select(.ok == true and ._meta.runtimeId == $parent.runtime)
    | .result.terminal | select(.worktreeId == $parent.worktree)
    | select(all([.handle,.incarnationId][]; type == "string" and length > 0))
    | {backend:"orca",target:.handle,runtime:$parent.runtime,incarnation:.incarnationId,worktree:.worktreeId,path:$parent.path}' 2>/dev/null) || endpoint=
  if [ -n "$endpoint" ]; then
    extra=$(printf '%s' "$extra" | jq -ce --argjson endpoint "$endpoint" '. + {endpoint:$endpoint}') || return 1
    fm_afk_launch_record_write orca pending "$extra" || return 1
    SQUAD_AFK_REC_EXTRA=$extra
  fi
  # Regardless of CLI exit, only the recorded identity can settle creation.
  # An entirely lost receipt remains handle-less and is never guessed/retried.
  fm_afk_launch_orca_resolve || return 1
  fm_afk_launch_commit_terminal orca "$SQUAD_AFK_REC_TARGET" "$SQUAD_AFK_REC_EXTRA" 1 || return 1
  fm_afk_launch_log 'daemon launched in an exact Orca terminal; Squad requested no focus flag and created no worktree or primary split (real host focus behaviour is unverified)'
}
