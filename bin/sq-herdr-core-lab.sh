#!/usr/bin/env bash
# bin/sq-herdr-core-lab.sh - guarded live lab for the herdr-core backend.
#
# Usage:
#   SQUAD_HC_LAB=1 bin/sq-herdr-core-lab.sh [--help]
#
# What it proves, end to end, against a PRIVATE herdr-core core:
#   1. the adapter refuses to drive a session whose core is not listening, and
#      that refusal starts no core (the private socket is still absent after it);
#   2. a real `bin/sq-spawn.sh` task lands on that private core: `backend=herdr-core`
#      with `hc_session=`, `hc_address=` and `hc_core_id=`, and the terminal carries
#      the `squad.task=<id>` label with its foreground cwd in the recorded worktree;
#   3. `bin/sq-peek.sh` reads the program's screen, `bin/sq-crew-state.sh` reports
#      the program's own native blocked verdict with its prompt, and `bin/sq-send.sh`
#      delivers text with a confirmed verdict;
#   4. `bin/sq-teardown.sh` closes exactly that address and leaves nothing behind,
#      and the leased worktree returns to the pool.
#
# Isolation. The commander's live core serves the desktop app and the phone, so
# nothing here ever addresses it. The lab creates its own core by exporting a
# private `HC_SESSION` plus scratch `XDG_RUNTIME_DIR`, `XDG_CONFIG_HOME` and
# `XDG_STATE_HOME` under a short temp root (the product refuses a socket path
# longer than the kernel limit, so the root stays short), and it stops only that
# core, by session, at the end.
#
# Tripwire. Before provisioning, the lab records the ambient `default` core's
# identity, pid, version and full terminal inventory - read only, and only after
# the adapter's own unix-socket listener probe proves a listener answers on that
# socket, because a socket file left behind by a dead core is not a running core
# and the next `hc` call on it would start one with this lab's environment. After
# the private core is stopped and removed, the identical read must be byte-identical;
# a missing, stopped, or changed default core is a hard failure, never a warning.
#
# Never run this against the commander's core, never point it at `default`, and
# never use its core-start path as a way to bring a shared core up.
set -u

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The spawn project must be a checkout on its default branch, so the default is
# the shared repository this worktree belongs to (its primary checkout), never
# the task worktree the lab itself is running from.
LAB_COMMON_GIT=$(cd "$(git -C "$LAB_DIR" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || LAB_COMMON_GIT=
LAB_PROJECT=${SQUAD_HC_LAB_PROJECT:-${LAB_COMMON_GIT%/.git}}
KEEP_TEMP=0
TEMP=
SESSION=
PRIVATE_CORE=

fm_lab_say() { printf 'herdr-core-lab: %s\n' "$*"; }
fm_lab_error() { printf 'herdr-core-lab: %s\n' "$*" >&2; }

fm_lab_usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p'
}

# fm_lab_socket: the private core's socket, by the same rule `hc` and the adapter
# use - the runtime directory when set, otherwise the per-session state folder.
fm_lab_socket() {  # <session>
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    printf '%s/herdr-core/%s.sock' "$XDG_RUNTIME_DIR" "$1"
    return 0
  fi
  printf '%s/herdr-core/%s/%s.sock' "${XDG_STATE_HOME:-${HOME:-}/.local/state}" "$1" "$1"
}

# The tripwire must read the AMBIENT core, so it restores the caller's own XDG
# selection and drops the lab's HC_SESSION/HC_SOCKET for the duration of the read.
fm_lab_ambient() {  # <command...>
  local -a env_args=(-u HC_SESSION -u HC_SOCKET)
  local -a env_sets=()
  if [ "$AMBIENT_RUNTIME_SET" = 1 ]; then
    env_sets+=("XDG_RUNTIME_DIR=$AMBIENT_RUNTIME")
  else
    env_args+=(-u XDG_RUNTIME_DIR)
  fi
  if [ "$AMBIENT_CONFIG_SET" = 1 ]; then
    env_sets+=("XDG_CONFIG_HOME=$AMBIENT_CONFIG")
  else
    env_args+=(-u XDG_CONFIG_HOME)
  fi
  if [ "$AMBIENT_STATE_SET" = 1 ]; then
    env_sets+=("XDG_STATE_HOME=$AMBIENT_STATE")
  else
    env_args+=(-u XDG_STATE_HOME)
  fi
  env "${env_args[@]}" "${env_sets[@]}" "$@"
}

# fm_lab_ambient_listener_probe: the adapter's own unix-socket listener probe,
# run under the caller's ambient selection. Only a listener that accepts a
# connection may license an `hc` read: a socket file left behind by a dead core
# would make the next `hc` call start one.
#   0  a listener answers on <socket>
#   1  nothing is listening
#   2  no probe client could decide, so the caller fails closed
fm_lab_ambient_listener_probe() {  # <socket>
  local socket=$1
  # shellcheck disable=SC2016 # the script's $1/$2 are its own positional args
  fm_lab_ambient bash -c '
    . "$1/bin/sq-backend.sh" >/dev/null 2>&1 || exit 2
    fm_backend_source herdr-core >/dev/null 2>&1 || exit 2
    fm_backend_herdr_core_listener_probe "$2"' _ "$LAB_DIR" "$socket"
}

# fm_lab_ambient_socket: the ambient default core's socket, resolved by the
# adapter's own rule under the caller's selection, so a host without
# XDG_RUNTIME_DIR finds the core in the state directory instead of a
# `/run/user/<uid>` path that hc never used.
fm_lab_ambient_socket() {  # <session>
  # shellcheck disable=SC2016 # the script's $1/$2 are its own positional args
  fm_lab_ambient bash -c '
    . "$1/bin/sq-backend.sh" >/dev/null 2>&1 || exit 2
    fm_backend_source herdr-core >/dev/null 2>&1 || exit 2
    fm_backend_herdr_core_socket "$2"' _ "$LAB_DIR" "$1"
}

# fm_lab_default_unit_state: read-only identity and inventory of the ambient
# core. It refuses unless the adapter's listener probe proves a core answers on
# the socket, so this read can never be the call that starts a core.
fm_lab_default_unit_state() {
  local socket status inventory probe_rc=0
  socket=$(fm_lab_ambient_socket default) || {
    fm_lab_error 'cannot resolve the default core socket for the tripwire'
    return 1
  }
  [ -S "$socket" ] || {
    fm_lab_error "the default core is not running (no socket at $socket); the tripwire needs the commander's core already up, and this lab never starts it"
    return 1
  }
  fm_lab_ambient_listener_probe "$socket" || probe_rc=$?
  if [ "$probe_rc" -eq 1 ]; then
    fm_lab_error "no listener answers on the default core socket $socket (a socket file left by a dead core); the tripwire never starts a core, so start Herdr or run 'hc server start' yourself and rerun"
    return 1
  fi
  if [ "$probe_rc" -ne 0 ]; then
    fm_lab_error "cannot prove a listener answers on the default core socket $socket (no unix-socket probe client could decide); the tripwire never starts a core, so refusing rather than risking a start"
    return 1
  fi
  status=$(fm_lab_ambient hc server status --json 2>/dev/null) || {
    fm_lab_error 'cannot read the default core status for the tripwire'
    return 1
  }
  inventory=$(fm_lab_ambient hc ls --all --json 2>/dev/null) || {
    fm_lab_error 'cannot read the default core inventory for the tripwire'
    return 1
  }
  jq -c -n --argjson status "$status" --argjson inventory "$inventory" '
    {core: ($status.core.id // ""), pid: ($status.pid // 0), version: ($status.version // ""),
     live: ($status.live // 0), finished: ($status.finished // 0),
     terminals: [($inventory.terminals // []) | sort_by(.address)[] | {address, state, name}]}'
}

fm_lab_stop_private_core() {
  [ -n "$PRIVATE_CORE" ] || return 0
  local socket
  socket=$(fm_lab_socket "$SESSION")
  case "$socket" in
    "$TEMP"/*) ;;
    *)
      fm_lab_error "refusing to stop a core whose socket '$socket' is outside this lab's temp root"
      return 1
      ;;
  esac
  [ -S "$socket" ] || { PRIVATE_CORE=; return 0; }
  # Scoped by the private HC_SESSION and asserted against the private socket
  # path above: this stops the lab's own core, never the commander's.
  hc server stop --json >/dev/null 2>&1 || {
    fm_lab_error "could not stop the private core for session $SESSION"
    return 1
  }
  PRIVATE_CORE=
}

fm_lab_cleanup() {
  local rc=$?
  fm_lab_stop_private_core || rc=1
  if [ -n "$TEMP" ] && [ "$KEEP_TEMP" = 0 ] && [ -d "$TEMP" ]; then
    rm -rf "$TEMP"
  elif [ -n "$TEMP" ]; then
    fm_lab_say "evidence kept: $TEMP"
  fi
  exit "$rc"
}

fm_lab_fail() {
  KEEP_TEMP=1
  fm_lab_error "FAILED: $*"
  exit 1
}

case "${1:-}" in
  --help|-h)
    fm_lab_usage
    exit 0
    ;;
  '') ;;
  *)
    fm_lab_error "unknown argument: $1"
    exit 2
    ;;
esac

[ "${SQUAD_HC_LAB:-0}" = 1 ] || {
  fm_lab_error 'set SQUAD_HC_LAB=1 to run the live herdr-core lab'
  exit 0
}
command -v hc >/dev/null 2>&1 || fm_lab_fail 'hc is not installed'
command -v jq >/dev/null 2>&1 || fm_lab_fail 'jq is not installed'
command -v fob >/dev/null 2>&1 || fm_lab_fail 'fob is not installed (the lab spawns a real fob worktree)'
[ -d "$LAB_PROJECT" ] || fm_lab_fail "project directory not found: $LAB_PROJECT"
# The lab owns its own core selection; an ambient one would make every address
# ambiguous and could point a destructive step at the wrong core.
[ -z "${HC_SESSION:-}" ] || fm_lab_fail 'HC_SESSION is already set; run the lab from a plain shell'
[ -z "${HC_SOCKET:-}" ] || fm_lab_fail 'HC_SOCKET is already set; run the lab from a plain shell'

# The ambient selection the tripwire restores for every read of the default core.
AMBIENT_RUNTIME=${XDG_RUNTIME_DIR:-}
AMBIENT_CONFIG=${XDG_CONFIG_HOME:-}
AMBIENT_STATE=${XDG_STATE_HOME:-}
AMBIENT_RUNTIME_SET=0 AMBIENT_CONFIG_SET=0 AMBIENT_STATE_SET=0
[ -z "${XDG_RUNTIME_DIR:-}" ] || AMBIENT_RUNTIME_SET=1
[ -z "${XDG_CONFIG_HOME:-}" ] || AMBIENT_CONFIG_SET=1
[ -z "${XDG_STATE_HOME:-}" ] || AMBIENT_STATE_SET=1

trap fm_lab_cleanup EXIT
trap 'KEEP_TEMP=1; exit 130' INT
trap 'KEEP_TEMP=1; exit 143' TERM

BEFORE=$(fm_lab_default_unit_state) || exit 1
fm_lab_say "tripwire default-core-before=$(printf '%s' "$BEFORE" | jq -c '{core, pid, live, finished, terminals}')"

TEMP=$(mktemp -d "${TMPDIR:-/tmp}/sqhc-lab.XXXXXX") || fm_lab_fail 'cannot create the lab temp root'
XDG_RUNTIME_DIR="$TEMP/r"
XDG_CONFIG_HOME="$TEMP/c"
XDG_STATE_HOME="$TEMP/s"
SESSION="sq-lab-$$-${RANDOM}"
HC_SESSION="$SESSION"
export XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_STATE_HOME HC_SESSION
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" || fm_lab_fail 'cannot create the lab XDG roots'

SOCKET=$(fm_lab_socket "$SESSION")
[ "${#SOCKET}" -le 100 ] || fm_lab_fail "the private socket path is too long for the kernel limit: $SOCKET"
LAB_BASE="$TEMP/base"
mkdir -p "$LAB_BASE/state" "$LAB_BASE/data" || fm_lab_fail 'cannot create the lab base'
LAB_BASE_LABEL=$(
  SQUAD_BASE="$LAB_BASE" SQUAD_ROOT_OVERRIDE="$LAB_DIR" \
    bash -c '. "$SQUAD_ROOT_OVERRIDE/bin/sq-backend.sh" || exit 1
             fm_backend_source herdr-core || exit 1
             fm_backend_herdr_core_base_name'
) || fm_lab_fail 'cannot derive the base label'
[ -n "$LAB_BASE_LABEL" ] || fm_lab_fail 'the base label is empty'
fm_lab_say "lab session=$SESSION socket=$SOCKET"

# --- 1. the adapter never starts a core ------------------------------------

fm_lab_container_ensure() {  # <cwd>
  (
    SQUAD_BASE="$LAB_BASE" SQUAD_STATE_OVERRIDE="$LAB_BASE/state" \
    SQUAD_ROOT_OVERRIDE="$LAB_DIR" \
      bash -c '. "$SQUAD_ROOT_OVERRIDE/bin/sq-backend.sh" || exit 1
               fm_backend_source herdr-core || exit 1
               fm_backend_herdr_core_container_ensure "$1"' _ "$1"
  )
}

no_core_out=$(fm_lab_container_ensure "$TEMP" 2>&1) && no_core_rc=0 || no_core_rc=$?
[ "$no_core_rc" -ne 0 ] || fm_lab_fail 'the adapter accepted a session with no listening core'
case "$no_core_out" in
  *'Squad never starts the core'*) ;;
  *) fm_lab_fail "the missing-core refusal did not name the no-start rule: $no_core_out" ;;
esac
[ ! -e "$SOCKET" ] || fm_lab_fail 'the refused call created a core socket, so the adapter started a core'
fm_lab_say 'no-start proof: refused with no listening core, and the private socket is still absent'

# --- 2. provision the private core ----------------------------------------

hc server start --json >/dev/null 2>&1 || fm_lab_fail "cannot start the private core for session $SESSION"
[ -S "$SOCKET" ] || fm_lab_fail 'the private core did not publish its socket'
PRIVATE_CORE=$(hc server status --json 2>/dev/null | jq -r '.core.id // empty') || PRIVATE_CORE=
[ -n "$PRIVATE_CORE" ] || fm_lab_fail 'the private core did not report an identity'
fm_lab_say "private core id=$PRIVATE_CORE"

# --- 3. spawn a real task on it -------------------------------------------

ID="sq-hc-lab-$(date +%Y%m%d%H%M%S)-$$"
PROBE="$TEMP/probe.sh"
ANSWER_FILE="$TEMP/answer.txt"
cat > "$PROBE" <<'PROBE_SH'
#!/usr/bin/env bash
# A scripted reporting program: it stands in for a harness that emits OSC 7501,
# so the lab proves the adapter's native state read without spending a model
# call. Its whole purpose is to be observable and steerable.
set -u
emit() { printf '\033]7501;%s\033\\' "$1"; }
printf 'HC-LAB READY\n'
emit 'state=working:app=hc-lab'
sleep 3
msg=$(printf 'Answer the lab question' | base64 | tr -d '\n')
emit "state=blocked:app=hc-lab:kind=question:msg=$msg"
sleep 4
emit 'state=working:app=hc-lab'
sleep 3
emit 'state=idle:app=hc-lab'
printf 'HC-LAB WAITING FOR INPUT\n'
IFS= read -r answer || answer=''
printf 'HC-LAB ANSWER: %s\n' "$answer"
printf '%s\n' "$answer" > "$1"
emit 'state=done:app=hc-lab'
sleep 120
PROBE_SH
chmod +x "$PROBE"

fm_lab_say "spawning $ID on project $LAB_PROJECT"
# The spawn contract requires a brief at the base's own data path; the scripted
# probe ignores its content, so this is a stand-in that keeps the real spawn path.
mkdir -p "$LAB_BASE/data/$ID" || fm_lab_fail 'cannot create the lab task data directory'
printf '# Task\n\nherdr-core backend lab probe: this task exists only to exercise the backend.\nDo not edit anything; report the lab answer and stop.\n\nReport status by appending one line:\n\n    echo "{state}: {note}" >> %s/%s.status\n' \
  "$LAB_BASE/state" "$ID" \
  > "$LAB_BASE/data/$ID/brief.md" || fm_lab_fail 'cannot write the lab brief'
spawn_out=$(
  SQUAD_BASE="$LAB_BASE" SQUAD_STATE_OVERRIDE="$LAB_BASE/state" \
  SQUAD_DATA_OVERRIDE="$LAB_BASE/data" SQUAD_ROOT_OVERRIDE="$LAB_DIR" \
  SQUAD_BACKEND=herdr-core \
    "$LAB_DIR/bin/sq-spawn.sh" "$ID" "$LAB_PROJECT" "bash $PROBE $ANSWER_FILE" \
      --backend herdr-core --recon 2>&1
) || fm_lab_fail "spawn failed: $spawn_out"
spawn_line=$(printf '%s\n' "$spawn_out" | grep -E '^spawned ' | tail -1)
fm_lab_say "spawn: ${spawn_line:-$spawn_out}"

META="$LAB_BASE/state/$ID.meta"
[ -f "$META" ] || fm_lab_fail "no task metadata at $META"
meta_field() { grep "^$1=" "$META" | tail -1 | cut -d= -f2-; }
[ "$(meta_field backend)" = herdr-core ] || fm_lab_fail 'the task was not recorded on backend=herdr-core'
[ "$(meta_field hc_session)" = "$SESSION" ] || fm_lab_fail 'the recorded hc_session is not the private session'
ADDRESS=$(meta_field hc_address)
RECORDED_CORE=$(meta_field hc_core_id)
WT=$(meta_field worktree)
TARGET=$(meta_field window)
[ -n "$ADDRESS" ] || fm_lab_fail 'no hc_address recorded'
[ "$RECORDED_CORE" = "$PRIVATE_CORE" ] || fm_lab_fail "the recorded core id '$RECORDED_CORE' is not the private core '$PRIVATE_CORE'"
[ "$TARGET" = "$SESSION:$ADDRESS" ] || fm_lab_fail "the recorded window '$TARGET' is not session:address"
[ -d "$WT" ] || fm_lab_fail "the recorded worktree is missing: $WT"
fm_lab_say "recorded backend=herdr-core hc_session=$SESSION hc_address=$ADDRESS hc_core_id=$RECORDED_CORE worktree=$WT"

terminal=$(hc get --json "$ADDRESS" 2>/dev/null) || fm_lab_fail "the private core does not know address $ADDRESS"
[ "$(printf '%s' "$terminal" | jq -r '.labels["squad.task"] // ""')" = "$ID" ] \
  || fm_lab_fail 'the terminal does not carry this task label'
[ "$(printf '%s' "$terminal" | jq -r '.labels["squad.base"] // ""')" = "$LAB_BASE_LABEL" ] \
  || fm_lab_fail 'the terminal does not carry the base label'
fg_cwd=$(printf '%s' "$terminal" | jq -r '.foreground.cwd // ""')
[ "$(cd "$fg_cwd" 2>/dev/null && pwd -P)" = "$(cd "$WT" && pwd -P)" ] \
  || fm_lab_fail "the terminal foreground cwd '$fg_cwd' is not the recorded worktree '$WT'"
fm_lab_say "terminal: address=$ADDRESS label=squad.task:$ID foreground-cwd=$fg_cwd"
fm_lab_say "private inventory after spawn: $(hc ls --json | jq -c '[.terminals[] | {address, name, status}]')"

# --- 4. native state, peek, and crew state --------------------------------

wait_for_status() {  # <wanted> <timeout-secs>
  local wanted=$1 deadline=$(( $(date +%s) + $2 )) state
  while [ "$(date +%s)" -le "$deadline" ]; do
    state=$(hc get --json "$ADDRESS" 2>/dev/null | jq -r '.status.state // ""')
    [ "$state" = "$wanted" ] && return 0
    sleep 1
  done
  return 1
}

wait_for_status blocked 40 \
  || fm_lab_fail "the program never reported blocked (last: $(hc get --json "$ADDRESS" | jq -c '.status'))"
crew=$(SQUAD_BASE="$LAB_BASE" SQUAD_STATE_OVERRIDE="$LAB_BASE/state" \
  SQUAD_DATA_OVERRIDE="$LAB_BASE/data" SQUAD_ROOT_OVERRIDE="$LAB_DIR" \
  "$LAB_DIR/bin/sq-crew-state.sh" "$ID" 2>&1) || fm_lab_fail "crew state failed: $crew"
case "$crew" in
  *'blocked'*) ;;
  *) fm_lab_fail "crew state did not report the native blocked verdict: $crew" ;;
esac
case "$crew" in
  *'Answer the lab question'*) ;;
  *) fm_lab_fail "crew state did not carry the program's own prompt: $crew" ;;
esac
fm_lab_say "crew-state: $crew"

peek=$(SQUAD_BASE="$LAB_BASE" SQUAD_STATE_OVERRIDE="$LAB_BASE/state" \
  SQUAD_DATA_OVERRIDE="$LAB_BASE/data" SQUAD_ROOT_OVERRIDE="$LAB_DIR" \
  "$LAB_DIR/bin/sq-peek.sh" "$ID" 40 2>&1) || fm_lab_fail "peek failed: $peek"
case "$peek" in
  *'HC-LAB READY'*) ;;
  *) fm_lab_fail "peek did not read the program's screen: $peek" ;;
esac
fm_lab_say 'peek: read the program screen through the adapter'

# --- 5. delivery ----------------------------------------------------------

wait_for_status idle 40 \
  || fm_lab_fail "the program never returned to idle (last: $(hc get --json "$ADDRESS" | jq -c '.status'))"
send_out=$(SQUAD_BASE="$LAB_BASE" SQUAD_STATE_OVERRIDE="$LAB_BASE/state" \
  SQUAD_DATA_OVERRIDE="$LAB_BASE/data" SQUAD_ROOT_OVERRIDE="$LAB_DIR" \
  "$LAB_DIR/bin/sq-send.sh" "$ID" 'lab answer one' 2>&1) || fm_lab_fail "send failed: $send_out"
send_line=$(printf '%s\n' "$send_out" | grep -E '^(Pi |sent )' | tail -1)
fm_lab_say "send: ${send_line:-confirmed (exit 0)}"
for _ in $(seq 1 30); do
  [ -s "$ANSWER_FILE" ] && break
  sleep 1
done
[ -s "$ANSWER_FILE" ] || fm_lab_fail 'the program never received the delivered text'
[ "$(cat "$ANSWER_FILE")" = 'lab answer one' ] \
  || fm_lab_fail "the program received '$(cat "$ANSWER_FILE")' instead of the sent text"
fm_lab_say "delivery: the program received '$(cat "$ANSWER_FILE")'"

# --- 6. teardown closes exactly that address ------------------------------

printf '# herdr-core lab recon\n\nThe lab task exists only to exercise the backend.\n' \
  > "$LAB_BASE/data/$ID/report.md"
printf 'decisions_reviewed=1\n' >> "$META"

teardown_out=$(SQUAD_BASE="$LAB_BASE" SQUAD_STATE_OVERRIDE="$LAB_BASE/state" \
  SQUAD_DATA_OVERRIDE="$LAB_BASE/data" SQUAD_ROOT_OVERRIDE="$LAB_DIR" \
  "$LAB_DIR/bin/sq-teardown.sh" "$ID" 2>&1) || fm_lab_fail "teardown failed: $teardown_out"
teardown_line=$(printf '%s\n' "$teardown_out" | grep -E "^teardown $ID complete" | tail -1)
fm_lab_say "teardown: ${teardown_line:-$teardown_out}"
case "$teardown_out" in
  *"teardown $ID complete"*) ;;
  *) fm_lab_fail "teardown did not report completion: $teardown_out" ;;
esac
if hc get --json "$ADDRESS" >/dev/null 2>&1; then
  fm_lab_fail "address $ADDRESS still exists after teardown"
fi
remaining=$(hc ls --all --json | jq -r '.terminals | length')
[ "$remaining" = 0 ] || fm_lab_fail "the private core still has $remaining terminals after teardown"
[ -d "$WT" ] || fm_lab_fail "the recorded worktree is gone from the pool: $WT"
# fob keeps the directory and returns it to the pool, so the lease state - not
# the path - is what proves the worktree came back.
lease_state=$(cd "$LAB_PROJECT" && fob status 2>/dev/null \
  | awk -v wt="$WT" -v home="$HOME" '{ path = $3; sub(/^~/, home, path); if (path == wt) print $2 }')
[ "$lease_state" = available ] \
  || fm_lab_fail "the worktree $WT did not return to the pool (state: ${lease_state:-unknown})"
fm_lab_say "teardown: exact address gone, private inventory empty, worktree $WT available again"

# --- 7. tripwire ----------------------------------------------------------

fm_lab_stop_private_core || fm_lab_fail 'the private core could not be stopped'
[ -S "$SOCKET" ] && fm_lab_fail 'the private socket still exists after stopping its core'

AFTER=$(fm_lab_default_unit_state) || fm_lab_fail 'the default core became unreadable'
if [ "$BEFORE" != "$AFTER" ]; then
  fm_lab_error "default-core-before=$BEFORE"
  fm_lab_error "default-core-after=$AFTER"
  fm_lab_fail 'TRIPWIRE: the commander default core changed during the lab'
fi
fm_lab_say "tripwire default-core-after=$(printf '%s' "$AFTER" | jq -c '{core, pid, live, finished, terminals}')"
fm_lab_say 'LIVE-UNCHANGED: the commander default core is byte-identical before and after'
fm_lab_say 'PASS'
