#!/usr/bin/env bash
# Exact Orca daemon-terminal lifecycle, sourced by sq-afk-launch.sh.
# Requests no focus flag (real host focus behaviour is unverified) and never
# creates/removes a worktree or stops a runtime; cleanup requests close only for
# the exact daemon terminal it created, never another terminal's tab. Real
# create/cleanup semantics are covered by docs/verification/runtime-backends.md.
# A pre-create intent survives ambiguous CLI returns. Recovery requires a
# recorded runtime-issued daemon identity and a complete identity-bound inventory;
# titles are display-only. Handle-less lost responses always remain uncertain.

# Per-invocation memo of a pending record already proven absent, so one command
# derives its lifecycle decisions from a single evidence round.
SQUAD_AFK_ORCA_PROOF=
SQUAD_AFK_ORCA_PROOF_EXTRA=

fm_afk_launch_orca_primary() {  # [exact-target]; never guesses an unresolved primary
  local primary=${1:-${SQUAD_SUPERVISOR_TARGET:-}}
  if [ -z "$primary" ] || [ "$primary" = pending ]; then
    fm_afk_launch_log 'Orca supervisor has no exact primary terminal handle; set SQUAD_SUPERVISOR_TARGET to the primary this away session supervises'
    return 1
  fi
  printf '%s' "$primary"
}

fm_afk_launch_orca_pending_match() {  # read-only: 0 exact single live match; 2 proven absent; 1 uncertain
  local extra=$SQUAD_AFK_REC_EXTRA inventory terminal count endpoint parent base
  SQUAD_AFK_ORCA_PENDING_TARGET=
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
  if ! inventory=$(orca terminal list --limit 10000 --json); then
    fm_afk_launch_log 'Orca daemon identity is recorded but the runtime terminal inventory could not be read; preserving the pending intent (no create retry)'
    return 1
  fi
  if ! terminal=$(printf '%s' "$inventory" | jq -ce --argjson rec "$extra" '
      select(.ok == true and .result.truncated == false and ._meta.runtimeId == $rec.parent.runtime
        and (.result.hostScope.omittedHostIds | type == "array" and length == 0)
        and (.result.terminals | type == "array")
        and all(.result.terminals[]; (.handle | type == "string" and length > 0)
          and (.worktreeId | type == "string") and (.worktreePath | type == "string")))
      | [.result.terminals[] | select(.handle == $rec.endpoint.target)]'); then
    fm_afk_launch_log 'Orca daemon identity is recorded but the runtime terminal inventory is incomplete, truncated, host-scope omitted, or from another runtime; preserving the pending intent (no create retry)'
    return 1
  fi
  count=$(printf '%s' "$terminal" | jq -r 'length') || return 1
  case "$count" in
    0)
      # Absence of the recorded handle alone is insufficient if an unclaimed
      # live terminal still matches its binding. Use the same conjunctive proof
      # as the explicitly approved release path, without changing any record.
      if fm_afk_launch_orca_release_evidence "$inventory"; then
        fm_afk_launch_log "pending release proof branch=$SQUAD_AFK_ORCA_RELEASE_BRANCH handle=$(printf '%s' "$extra" | jq -r .endpoint.target)"
        return 2
      fi
      fm_afk_launch_log "pending release refused branch=$SQUAD_AFK_ORCA_RELEASE_BRANCH handle=$(printf '%s' "$extra" | jq -r .endpoint.target) candidates=${SQUAD_AFK_ORCA_CANDIDATES:-unknown}; preserving the pending intent"
      return 1
      ;;
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
  SQUAD_AFK_ORCA_PENDING_TARGET=$terminal
}

fm_afk_launch_orca_resolve() {  # 0: adopted/exact; 2: proven absent; 1: uncertain
  local match target
  if [ "$SQUAD_AFK_REC_TARGET" != pending ]; then return 0; fi
  if [ "$SQUAD_AFK_ORCA_PROOF" = absent ] && [ "$SQUAD_AFK_ORCA_PROOF_EXTRA" = "$SQUAD_AFK_REC_EXTRA" ]; then
    return 2
  fi
  fm_afk_launch_orca_pending_match
  match=$?
  if [ "$match" -eq 2 ]; then
    SQUAD_AFK_ORCA_PROOF=absent
    SQUAD_AFK_ORCA_PROOF_EXTRA=$SQUAD_AFK_REC_EXTRA
    return 2
  fi
  [ "$match" -eq 0 ] || return 1
  target=$SQUAD_AFK_ORCA_PENDING_TARGET
  fm_afk_launch_orca_owned "$target" "$SQUAD_AFK_REC_EXTRA" || return 1
  fm_afk_launch_record_write orca "$target" "$SQUAD_AFK_REC_EXTRA" || return 1
  SQUAD_AFK_REC_TARGET=$target
}

fm_afk_launch_orca_pending_state() {  # read-only status token for a pending intent
  fm_afk_launch_orca_pending_match
  case "$?" in
    0) printf 'recoverable' ;;
    2) printf 'absent' ;;
    *) printf 'uncertain' ;;
  esac
}

fm_afk_launch_orca_claimed_terminals() {  # read-only task-recorded terminal targets as JSON
  local meta backend target claimed='[]'
  for meta in "$SQUAD_AFK_LAUNCH_STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ ! -f "$meta" ] || [ ! -r "$meta" ] || [ -L "$meta" ]; then
      fm_afk_launch_log "task metadata $meta is not a readable regular file; refusing handle-less release"
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta") || return 1
    if [ "$backend" = orca ]; then
      target=$(fm_backend_meta_exact_value "$meta" terminal) || target=
      if [ -z "$target" ] && ! fm_backend_orca_declares_no_terminal "$meta"; then
        fm_afk_launch_log "task metadata $meta records an Orca task without exactly one terminal handle; refusing handle-less release"
        return 1
      fi
    else
      target=$(fm_backend_target_of_meta "$meta") || target=
    fi
    [ -n "$target" ] || continue
    claimed=$(printf '%s' "$claimed" | jq -c --arg target "$target" '. + [$target]') || return 1
  done
  printf '%s' "$claimed"
}

# Read-only proof for an explicitly approved pending release: a complete live
# census cross-checked against every task terminal. A recorded handle must be
# absent AND no unclaimed terminal may match its binding. Runtime/incarnation
# changes alone never prove absence. 0: release proof; 2: named candidates;
# 1: incomplete evidence. The caller logs SQUAD_AFK_ORCA_RELEASE_BRANCH.
fm_afk_launch_orca_release_evidence() {  # [inventory-json]
  local extra=$SQUAD_AFK_REC_EXTRA parent runtime status inventory claimed target
  SQUAD_AFK_ORCA_CANDIDATES=
  SQUAD_AFK_ORCA_RELEASE_BRANCH=incomplete-evidence
  parent=$(printf '%s' "$extra" | jq -ce '.parent') || return 1
  target=$(printf '%s' "$extra" | jq -r '.endpoint.target // empty') || return 1
  status=$(orca status --json) || return 1
  runtime=$(printf '%s' "$status" | jq -er '
    select(.ok == true and .result.runtime.reachable == true and .result.runtime.state == "ready")
    | .result.runtime.runtimeId | select(type == "string" and length > 0)') || return 1
  # The existing handle-less procedure still requires its original runtime.
  # An identity-bearing record instead needs actual absence in the current
  # runtime; a surviving handle blocks release even across a runtime change.
  if [ -z "$target" ]; then
    printf '%s' "$parent" | jq -e --arg runtime "$runtime" '.runtime == $runtime' >/dev/null || return 1
  fi
  inventory=${1:-}
  if [ -z "$inventory" ]; then
    inventory=$(orca terminal list --limit 10000 --json) || return 1
  fi
  printf '%s' "$inventory" | jq -e --arg runtime "$runtime" '
    .ok == true and ._meta.runtimeId == $runtime and .result.truncated == false
    and (.result.hostScope.omittedHostIds | type == "array" and length == 0)
    and (.result.terminals | type == "array")
    and all(.result.terminals[]; (.handle | type == "string" and length > 0)
      and (.worktreeId | type == "string" and length > 0) and (.worktreePath | type == "string" and length > 0))' >/dev/null || return 1
  if [ -n "$target" ] && printf '%s' "$inventory" | jq -e --arg target "$target" 'any(.result.terminals[]; .handle == $target)' >/dev/null; then
    SQUAD_AFK_ORCA_CANDIDATES=$target
    SQUAD_AFK_ORCA_RELEASE_BRANCH=live-recorded-handle
    return 2
  fi
  claimed=$(fm_afk_launch_orca_claimed_terminals) || return 1
  SQUAD_AFK_ORCA_CANDIDATES=$(printf '%s' "$inventory" | jq -r --argjson parent "$parent" --argjson claimed "$claimed" '
    [ .result.terminals[]
      | select(.handle != $parent.target)
      | select((.worktreeId == $parent.worktree) or (.worktreePath == $parent.path))
      | select(.handle as $handle | $claimed | index($handle) | not)
      | .handle ] | unique | .[]') || return 1
  if [ -n "$SQUAD_AFK_ORCA_CANDIDATES" ]; then
    SQUAD_AFK_ORCA_RELEASE_BRANCH=candidate-binding-exists
    return 2
  fi
  if [ -n "$target" ]; then
    SQUAD_AFK_ORCA_RELEASE_BRANCH=absent-handle-no-candidates
  else
    SQUAD_AFK_ORCA_RELEASE_BRANCH=handle-less-no-candidates
  fi
  return 0
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
  local owner marker token
  owner=$(daemon_lock_owner) || return 1
  [ -f "$owner/orca-owner" ] && [ ! -L "$owner/orca-owner" ] || return 1
  marker=$(cat "$owner/orca-owner") || return 1
  if token=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -er '.owner | select(type == "string" and length > 0)' 2>/dev/null); then
    [ "$marker" = "$token" ] && return 0
    fm_afk_launch_log 'recorded Orca launch token does not match the daemon lock owner marker; refusing to treat the process as this terminal owner'
    return 1
  fi
  # A record from the pre-token launcher carries only its stored title, which
  # the old launcher also wrote into the lock marker. It verifies the process
  # already bound by the exact recorded terminal identity; it never selects a
  # terminal by title.
  token=$(printf '%s' "$SQUAD_AFK_REC_EXTRA" | jq -er '.title | select(type == "string" and length > 0)' 2>/dev/null) || {
    fm_afk_launch_log 'recorded Orca daemon has no launch token and no legacy title marker; cannot prove process ownership, so it will not be signalled; inspect state/.afk-daemon-terminal and use the commander-approved permanent-uncertainty recovery in docs/orca-backend.md'
    return 1
  }
  [ "$marker" = "$token" ] && return 0
  fm_afk_launch_log 'legacy Orca title marker does not match the recorded terminal owner; refusing to treat the process as this terminal owner'
  return 1
}

fm_afk_launch_orca_owned() {  # <target> <record-json>
  local target=$1 extra=$2 endpoint
  [ "$target" != pending ] || return 1
  endpoint=$(fm_supervisor_native_endpoint orca "$target") || return 1
  printf '%s' "$extra" | jq -e --argjson endpoint "$endpoint" '.endpoint == $endpoint and .parent.target != $endpoint.target and .parent.runtime == $endpoint.runtime and .parent.worktree == $endpoint.worktree and .parent.path == $endpoint.path' >/dev/null
}

fm_afk_launch_orca_absent() {  # <target> <record-json>
  local target=$1 extra=$2 status inventory runtime
  if [ "$target" = pending ]; then
    # Absence is proved once by fm_afk_launch_orca_resolve; this predicate never
    # adopts a reappearing terminal or rewrites the record as a side effect.
    [ "$SQUAD_AFK_ORCA_PROOF" = absent ] && [ "$SQUAD_AFK_ORCA_PROOF_EXTRA" = "$extra" ]
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
  local target=$1 ready parent title owner extra entry cmd out endpoint rejected
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
    | .result.terminal | select(.worktreeId == $parent.worktree and .handle != $parent.target)
    | select(all([.handle,.incarnationId][]; type == "string" and length > 0))
    | {backend:"orca",target:.handle,runtime:$parent.runtime,incarnation:.incarnationId,worktree:.worktreeId,path:$parent.path}' 2>/dev/null) || endpoint=
  if [ -z "$endpoint" ] && rejected=$(printf '%s' "$out" | jq -r --argjson parent "$parent" '
      def shown: if type == "string" and length > 0 then . else "missing" end;
      select(.ok == true and (.result.terminal | type) == "object")
      | .result.terminal as $t
      | (if ._meta.runtimeId != $parent.runtime then "runtimeId \(._meta.runtimeId | shown) is not the recorded \($parent.runtime)"
         elif ($t.handle | type) != "string" or ($t.handle | length) == 0 then "handle is not a usable string"
         elif ($t.incarnationId | type) != "string" or ($t.incarnationId | length) == 0 then "incarnationId is not a usable string"
         elif $t.handle == $parent.target then "handle \($t.handle | shown) is the primary terminal"
         elif ($t.worktreeId | type) != "string" or $t.worktreeId != $parent.worktree then "worktreeId \($t.worktreeId | shown) is not the requested \($parent.worktree)"
         else "the receipt does not identify a distinct daemon terminal"
         end) as $reason
      | "Orca create receipt was rejected (\($reason)); returned handle=\($t.handle | shown) worktreeId=\($t.worktreeId | shown) runtime=\(._meta.runtimeId | shown); preserving the pending intent without adopting or closing it"' 2>/dev/null) && [ -n "$rejected" ]; then
    fm_afk_launch_log "$rejected"
  fi
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
