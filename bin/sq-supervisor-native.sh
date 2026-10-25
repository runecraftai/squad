#!/usr/bin/env bash
# Native supervisor delivery contract, independent of the terminal backend and
# receiver harness. Currently Orca endpoints and the Pi receiver are proven.
# Usage: sq-supervisor-native.sh endpoint <backend> <exact-target>
#        sq-supervisor-native.sh dir <state> <exact-target> (path only; no mkdir)
# SQUAD_SUPERVISOR_HARNESS selects the receiver adapter; otherwise detect the
# caller. The launcher forwards the proven readiness provider to the daemon,
# whose process ancestry belongs to the runtime, not to the primary harness.
# Prints the local runtime/terminal incarnation binding, or refuses read-only.
# Sourced API: fm_supervisor_native_ready[_once]/submit/retire/pending <state> <target>,
# fm_supervisor_native_unresolved <state> [exact-target].
# Requests bind endpoint + receiver process; only consumed acknowledgements retire
# buffer prefixes. No timeout, process death or transport error authorizes replay.
SQUAD_NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_supervisor_native_endpoint() {  # <backend> <target>
  local backend=$1 target=$2 status terminal
  [ "$backend" = orca ] || { echo "error: no native endpoint binding for $backend" >&2; return 1; }
  [ -z "${ORCA_ENVIRONMENT:-}${ORCA_PAIRING_CODE:-}" ] || { echo 'error: Orca supervisor requires a local host for process identity verification; unset ORCA_ENVIRONMENT/ORCA_PAIRING_CODE' >&2; return 1; }
  case "$target" in term_*|term-*) ;; *) echo 'error: Orca supervisor requires an exact runtime-issued terminal handle' >&2; return 1 ;; esac
  if ! command -v orca >/dev/null || ! command -v jq >/dev/null; then
    echo 'error: Orca supervisor needs orca and jq on PATH' >&2; return 1
  fi
  status=$(orca status --json) || {
    echo 'error: orca status --json failed; start the selected local Orca host, confirm it answers that command, and retry' >&2; return 1
  }
  printf '%s' "$status" | jq -e '.ok == true and .result.runtime.reachable == true and .result.runtime.state == "ready" and (.result.runtime.runtimeId | type == "string" and length > 0)' >/dev/null || {
    echo 'error: Orca supervisor requires a reachable ready runtime with runtimeId; start the selected local Orca host first' >&2; return 1;
  }
  terminal=$(orca terminal show --terminal "$target" --json) || {
    echo "error: \`orca terminal show --terminal $target --json\` failed; verify that exact runtime-issued handle on the selected local Orca host" >&2; return 1
  }
  jq -cen --arg target "$target" --argjson s "$status" --argjson t "$terminal" '
    select($t.ok == true and $t._meta.runtimeId == $s.result.runtime.runtimeId)
    | $t.result.terminal as $t | select($t != null)
    | select($t.handle == $target and $t.connected == true and $t.writable == true and $t.orphaned == false and $t.executionHostId == "local")
    | select(all([$t.incarnationId,$t.worktreeId,$t.worktreePath][]; type == "string" and length > 0))
    | {backend:"orca",target:$target,runtime:$s.result.runtime.runtimeId,incarnation:$t.incarnationId,worktree:$t.worktreeId,path:$t.worktreePath}' || {
      echo "error: Orca supervisor target $target is mismatched, disconnected, orphaned, remote, or lacks incarnation/worktree identity" >&2; return 1;
    }
}

fm_supervisor_native_dir() {  # <state> <target>
  local key
  key=$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update("orca\\0" + process.argv[1]).digest("hex"))' "$2") || {
    echo 'error: Orca supervisor needs node on PATH to derive the native handoff directory' >&2; return 1
  }
  printf '%s/.away-handoff/%s' "$1" "$key"
}

fm_supervisor_native_owner_only() {  # <path>: same rule as the receiver's safeDir
  local path=$1 expected_uid owner mode
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  expected_uid=$(id -u) || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    owner=$(stat -f '%u' "$path" 2>/dev/null) || return 1
    mode=$(stat -f '%Lp' "$path" 2>/dev/null) || return 1
  else
    owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
    mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
  fi
  [ "$owner" = "$expected_uid" ] || return 1
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  [ $(( 8#$mode & 077 )) -eq 0 ]
}

fm_supervisor_native_safe_dir() {  # <state> <target>
  local dir
  dir=$(fm_supervisor_native_dir "$1" "$2") || return 1
  # The receiver creates owner-only directories; refuse a permissive replacement.
  fm_supervisor_native_owner_only "$1/.away-handoff" && fm_supervisor_native_owner_only "$dir" || return 1
  printf '%s' "$dir"
}

fm_supervisor_native_ready() {  # <state> <target> -> readiness JSON
  local state=$1 target=$2 harness dir file ready endpoint pid identity holder
  harness=${SQUAD_SUPERVISOR_HARNESS:-}
  if [ -n "$harness" ]; then
    [ "$harness" = pi ] || {
      echo "error: Orca supervisor harness '$harness' is unsupported: native draft/modal safety and consumed-message acknowledgement are not proven for it; set SQUAD_SUPERVISOR_HARNESS=pi to use the proven Pi receiver, or select a supported supervisor backend" >&2; return 1;
    }
  else
    harness=$("$SQUAD_NATIVE_DIR/sq-harness.sh") || harness=unknown
    [ "$harness" = pi ] || {
      echo "error: Orca supervisor harness detection resolved '$harness', not the proven Pi receiver, from this process ancestry: native draft/modal safety and consumed-message acknowledgement are proven only for Pi; run the lifecycle from inside the exact Pi primary that owns this base, or set SQUAD_SUPERVISOR_HARNESS=pi explicitly (the primary's own readiness record still has to prove the receiver)" >&2; return 1;
    }
  fi
  endpoint=$(fm_supervisor_native_endpoint orca "$target") || return 1
  [ "$(printf '%s' "$endpoint" | jq -r .path)" = "$(cd "$SQUAD_BASE" && pwd -P)" ] || { echo 'error: Orca supervisor worktree path does not match this Squad base' >&2; return 1; }
  dir=$(fm_supervisor_native_safe_dir "$state" "$target") || { echo 'error: Orca Pi supervisor native readiness is missing; load the project away-handoff extension in the exact local primary' >&2; return 1; }
  file="$dir/ready.json"
  [ -f "$file" ] && [ ! -L "$file" ] || {
    echo 'error: Orca Pi supervisor native readiness record is missing or unreadable; load the project away-handoff extension in the exact local primary and confirm it owns this state directory' >&2; return 1;
  }
  ready=$(jq -ce --argjson endpoint "$endpoint" --argjson now "$(date '+%s')" '
    select(.version == 1 and .provider == "pi" and .endpoint == $endpoint)
    | select((.pid | type == "number" and . > 1 and floor == .) and (.identity | type == "string" and length > 0) and (.session | type == "string" and test("^[a-f0-9]{64}$")))
    | select((.idle | type == "boolean") and (.draft | type == "boolean") and (.prompts | type == "number" and . >= 0) and (.sending | type == "boolean"))
    | select((.heartbeat | type == "number") and ($now * 1000 - .heartbeat) >= -1000 and ($now * 1000 - .heartbeat) <= 5000)' "$file") || {
      echo 'error: Orca Pi supervisor native readiness is stale or names another endpoint/incarnation; inspect the primary rather than typing a fallback' >&2; return 1;
    }
  pid=$(printf '%s' "$ready" | jq -r .pid)
  identity=$(printf '%s' "$ready" | jq -r .identity)
  # shellcheck source=bin/sq-stand-to-lib.sh
  SQUAD_STATE_OVERRIDE="$state" . "$SQUAD_NATIVE_DIR/sq-stand-to-lib.sh"
  fm_pid_alive "$pid" && [ "$(fm_pid_identity "$pid")" = "$identity" ] || { echo 'error: Orca supervisor native receiver died or changed identity' >&2; return 1; }
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || { echo 'error: Orca supervisor needs the exact live primary session owner' >&2; return 1; }
  holder=$(tr -d '[:space:]' < "$state/.lock")
  [ "$holder" = "$pid" ] || { echo 'error: Orca native receiver is not the primary session owner' >&2; return 1; }
  printf '%s' "$ready"
}

# An entry-point guard and the main path it precedes run in the same process, so
# a successful probe is reused instead of spawning the runtime CLI again. Live
# daemon revalidation keeps calling fm_supervisor_native_ready directly.
fm_supervisor_native_ready_once() {  # <state> <target> -> readiness JSON
  local key="$1|$2" ready
  if [ "${SQUAD_SUPERVISOR_NATIVE_ONCE_KEY:-}" = "$key" ]; then
    printf '%s' "${SQUAD_SUPERVISOR_NATIVE_ONCE_JSON:-}"
    return 0
  fi
  ready=$(fm_supervisor_native_ready "$1" "$2") || return 1
  SQUAD_SUPERVISOR_NATIVE_ONCE_KEY=$key
  SQUAD_SUPERVISOR_NATIVE_ONCE_JSON=$ready
  printf '%s' "$ready"
}

fm_supervisor_native_ack() {  # <dir> -> true only for the exact consumed request
  [ -f "$1/request.json" ] && [ ! -L "$1/request.json" ] && [ -f "$1/result.json" ] && [ ! -L "$1/result.json" ] || return 1
  jq -e --slurpfile request "$1/request.json" '
    .status == "handled" and .id == $request[0].id and .receiver == $request[0].receiver and .endpoint == $request[0].endpoint' "$1/result.json" >/dev/null
}

fm_supervisor_native_pending() {  # <state> <target>; uncertainty is pending forever
  local dir
  dir=$(fm_supervisor_native_dir "$1" "$2") || return 0
  # A consumed but not yet retired request also keeps lifecycle ownership:
  # malformed/mismatched buffer coverage must never be reported as completion.
  [ -e "$dir/request.json" ] || [ -L "$dir/request.json" ]
}

fm_supervisor_native_unresolved() {  # <state> [exact-target]; any published request, even without its target
  local dir bound target=${2:-}
  for dir in "$1"/.away-handoff/*/; do
    [ -d "$dir" ] || continue
    [ -e "$dir/request.json" ] || [ -L "$dir/request.json" ] || continue
    [ -n "$target" ] || return 0
    # Settling one exact primary never accounts for a request published for a
    # different one, so an unreadable or foreign binding stays unresolved.
    bound=$(jq -r 'if type == "object" then .endpoint.target // "" else "" end' "$dir/request.json" 2>/dev/null) || bound=
    [ "$bound" = "$target" ] || return 0
  done
  return 1
}

fm_supervisor_native_submit() {  # <state> <target> <message> <covered-lines>
  local state=$1 target=$2 message=$3 lines=$4 ready dir request tmp id prefix
  ready=$(fm_supervisor_native_ready "$state" "$target") || return 1
  dir=$(fm_supervisor_native_safe_dir "$state" "$target") || return 1
  request="$dir/request.json"
  # Nothing ever replaces an unresolved request, even after restart/reconnect.
  if [ -e "$request" ] || [ -L "$request" ]; then return 1; fi
  case "$lines" in ''|*[!0-9]*) return 1 ;; esac
  [ "$lines" -gt 0 ] || return 1
  id=$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))') || return 1
  prefix=$(head -n "$lines" "$state/.subsuper-escalations") || return 1
  tmp=$(mktemp "$dir/.request.XXXXXX") || return 1
  jq -n --arg id "$id" --arg message "$message" --arg prefix "$prefix" --argjson lines "$lines" --argjson ready "$ready" '
    {version:1,id:$id,provider:$ready.provider,endpoint:$ready.endpoint,receiver:{pid:$ready.pid,identity:$ready.identity,session:$ready.session},message:$message,lines:$lines,prefix:$prefix}' > "$tmp" \
    && chmod 600 "$tmp" && ln "$tmp" "$request"
  local result=$?
  rm -f "$tmp"
  [ "$result" -eq 0 ] || return 1
  # Publishing is not consumption. The next flush observes the receiver's ack.
  return 1
}

# shellcheck disable=SC2034 # Refusal reasons are read by sourcing callers that keep the request.
fm_supervisor_native_retire() {  # <state> <target>
  local state=$1 target=$2 dir lines expected actual buf
  SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON=""
  dir=$(fm_supervisor_native_safe_dir "$state" "$target") \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='owner-only handoff directory is missing or replaced'; return 1; }
  fm_supervisor_native_ack "$dir" \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='no exact consumed acknowledgement for the current request'; return 1; }
  jq -e --arg target "$target" '.version == 1 and .endpoint.backend == "orca" and .endpoint.target == $target' "$dir/request.json" >/dev/null \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON="request is not bound to endpoint $target"; return 1; }
  lines=$(jq -er '.lines | select(type == "number" and floor == . and . > 0)' "$dir/request.json") \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='request has no valid covered line count'; return 1; }
  expected=$(jq -er '.prefix' "$dir/request.json") \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='request has no readable buffer prefix'; return 1; }
  buf="$state/.subsuper-escalations"
  if ! [ -f "$buf" ] || [ "$(wc -l < "$buf")" -lt "$lines" ]; then
    SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON="escalation buffer no longer covers the acknowledged $lines line(s)"
    return 1
  fi
  actual=$(head -n "$lines" "$buf") \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='escalation buffer is unreadable'; return 1; }
  [ "$expected" = "$actual" ] \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='acknowledged prefix no longer matches the escalation buffer head'; return 1; }
  tail -n "+$((lines + 1))" "$buf" > "$buf.retire.$$" \
    || { rm -f "$buf.retire.$$"; SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='escalation buffer could not be rewritten'; return 1; }
  mv "$buf.retire.$$" "$buf" \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='retired buffer rewrite could not be committed'; return 1; }
  # On a crash before unlink, a mismatched prefix remains blocked, never replayed.
  rm -f "$dir/request.json" \
    || { SQUAD_SUPERVISOR_NATIVE_RETIRE_REASON='buffer retired but request.json could not be removed'; return 1; }
  [ -s "$buf" ] || rm -f "$buf.since" "$state/.subsuper-inject-wedged"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    endpoint) fm_supervisor_native_endpoint "${2:-}" "${3:-}" ;;
    dir) fm_supervisor_native_dir "${2:-}" "${3:-}" ;;
    *) echo 'usage: sq-supervisor-native.sh endpoint <backend> <exact-target>' >&2; exit 2 ;;
  esac
fi
