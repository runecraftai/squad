#!/usr/bin/env bash
# Fake-CLI regression coverage for the herdr-core (`hc`) session-provider adapter.
#
# Everything here runs against a fake `hc` on PATH. The fake is never allowed to
# start a core: the adapter's own socket-presence check is what licenses every
# call, so the suite binds one private unix socket to stand in for a listening
# core and asserts that a missing socket produces zero `hc` invocations.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }

# The suite binds a private unix socket to stand in for a listening core, and the
# adapter probes that socket before every `hc` call with a client that cannot
# start a core. Find an interpreter that actually runs (a broken or half-installed
# python3 on PATH is common) and put it first for both the fixture and the probe.
PY=
for candidate in python3 /usr/bin/python3 python; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  "$candidate" -c 'import socket' >/dev/null 2>&1 || continue
  PY=$candidate
  break
done
[ -n "$PY" ] || {
  echo 'skip: no working python3 (binding the private unix socket that stands in for a listening core)'
  exit 0
}

TMP_ROOT=$(fm_test_tmproot sq-backend-herdr-core-tests)
mkdir -p "$TMP_ROOT/pybin"
ln -sf "$(command -v "$PY")" "$TMP_ROOT/pybin/python3"
export SQUAD_HC_LOG="$TMP_ROOT/hc.log"
export SQUAD_HC_GET="$TMP_ROOT/get.json"
export SQUAD_HC_LIST="$TMP_ROOT/list.json"
export SQUAD_HC_SEND_KIND="$TMP_ROOT/send-kind.txt"
export SQUAD_HC_SEND_RC="$TMP_ROOT/send-rc.txt"
export SQUAD_HC_READ_TEXT="$TMP_ROOT/read.txt"
export SQUAD_HC_KEYS_LOG="$TMP_ROOT/keys.log"
export SQUAD_HC_KILL_LOG="$TMP_ROOT/kill.log"
export SQUAD_HC_GET_COUNT="$TMP_ROOT/get-count.txt"
: > "$SQUAD_HC_LOG"
: > "$SQUAD_HC_KEYS_LOG"
: > "$SQUAD_HC_KILL_LOG"
printf 'probe screen\n> ' > "$SQUAD_HC_READ_TEXT"
printf '0' > "$SQUAD_HC_SEND_RC"
: > "$SQUAD_HC_SEND_KIND"

mkdir -p "$TMP_ROOT/fakebin" "$TMP_ROOT/r/herdr-core"
export XDG_RUNTIME_DIR="$TMP_ROOT/r"
unset HC_SESSION HC_SOCKET SQUAD_HC_BIN
SOCKET="$TMP_ROOT/r/herdr-core/default.sock"

cat > "$TMP_ROOT/fakebin/hc" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
printf '%s\thc_session=%s\n' "$*" "${HC_SESSION:-}" >> "$SQUAD_HC_LOG"
json=0
for a in "$@"; do [ "$a" = --json ] && json=1; done
# Strip options so subcommand argument positions are stable.
positional=()
skip_next=0
for a in "$@"; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$a" in
    --json|--bg|--no-parent) ;;
    --if|--lines|--name|--cwd|--label|--on|--timeout|--parent|--force) skip_next=1 ;;
    -*) ;;
    *) positional+=("$a") ;;
  esac
done
cmd=${positional[0]:-}
case "$cmd" in
  connect)
    read -r line || line=
    case "${SQUAD_HC_HELLO:-ok}" in
      ok) cat "${SQUAD_HC_HELLO_FILE:-/dev/null}" ;;
      *) cat "$SQUAD_HC_HELLO_FILE" ;;
    esac
    ;;
  server)
    case "${positional[1]:-}" in
      status)
        if [ "${SQUAD_HC_STATUS_FAIL:-0}" = 1 ]; then exit 1; fi
        printf '{"core":{"id":"%s","name":"core"},"pid":1,"version":"0.1.22"}\n' "${SQUAD_HC_CORE_ID:-core-a}"
        ;;
      *) exit 1 ;;
    esac
    ;;
  schema)
    if [ "${SQUAD_HC_SCHEMA_FAIL:-0}" = 1 ]; then exit 1; fi
    if [ -n "${SQUAD_HC_SCHEMA_FILE:-}" ]; then cat "$SQUAD_HC_SCHEMA_FILE"; exit 0; fi
    exit 1
    ;;
  run)
    [ -z "${SQUAD_HC_RUN_STDERR:-}" ] || printf '%s\n' "$SQUAD_HC_RUN_STDERR" >&2
    run_address=${SQUAD_HC_NEW_ADDRESS:-t1}
    if [ "${SQUAD_HC_RUN_REGISTERS:-0}" = 1 ]; then
      jq -cn --arg address "${SQUAD_HC_RUN_REGISTER_ADDRESS:-$run_address}" --arg task "${SQUAD_HC_RUN_TASK:-probe}" \
        --arg base "${SQUAD_HC_RUN_BASE:-base}" \
        '{terminals:[{address:$address,state:"live",labels:{"squad.task":$task,"squad.base":$base}}]}' > "$SQUAD_HC_LIST"
    fi
    if [ -n "${SQUAD_HC_RUN_GET_TASK:-}" ]; then
      jq -cn --arg address "$run_address" --arg id "$SQUAD_HC_RUN_GET_TASK" \
        --arg base "${SQUAD_HC_RUN_GET_BASE:-}" --arg cwd "${SQUAD_HC_RUN_GET_CWD:-/tmp}" '
        {address:$address,state:"live",
         labels:{"squad.task":$id,"squad.base":$base},
         foreground:{argv:["bash"],cwd:$cwd,name:"bash",pid:4242},
         reported:false,status_ms:0,turn:0,title:"t"}' > "$SQUAD_HC_GET"
    fi
    if [ "${SQUAD_HC_RUN_FAIL:-0}" = 1 ]; then
      printf '{"error":{"kind":"name_taken","message":"that name is taken","hint":"pick another"}}\n' >&2
      exit 1
    fi
    printf '{"address":"%s","agent":"bash","cwd":"/tmp","name":"x","state":"live","turn":0}\n' "$run_address"
    ;;
  ls)
    # `hc ls` lists live terminals; `--all` also includes finished ones. The
    # fixture may set a distinct all-inventory; otherwise the live one doubles
    # as it.
    only_live=1
    for a in "$@"; do [ "$a" = --all ] && only_live=0; done
    if [ "$only_live" = 1 ] || [ -z "${SQUAD_HC_LIST_ALL:-}" ]; then
      cat "${SQUAD_HC_LIST:-/dev/null}"
    else
      cat "$SQUAD_HC_LIST_ALL"
    fi
    ;;
  get)
    if [ "${SQUAD_HC_GET_RC:-0}" != 0 ]; then
      printf '{"error":{"kind":"not_found","message":"no terminal","hint":"hc ls --all"}}\n' >&2
      exit "${SQUAD_HC_GET_RC}"
    fi
    if [ -n "${SQUAD_HC_GET_COUNT:-}" ]; then
      reads=$(( $(cat "$SQUAD_HC_GET_COUNT" 2>/dev/null || printf 0) + 1 ))
      printf '%s' "$reads" > "$SQUAD_HC_GET_COUNT"
      if [ -n "${SQUAD_HC_GET_FAIL_AFTER:-}" ] && [ "$reads" -gt "$SQUAD_HC_GET_FAIL_AFTER" ]; then
        printf '{"error":{"kind":"internal","message":"core hiccup","hint":"retry"}}\n' >&2
        exit 1
      fi
    fi
    cat "$SQUAD_HC_GET"
    ;;
  read)
    if [ "${SQUAD_HC_READ_FAIL:-0}" = 1 ]; then
      printf '{"error":{"kind":"internal","message":"core hiccup","hint":"retry"}}\n' >&2
      exit 1
    fi
    if [ "${SQUAD_HC_READ_MALFORMED:-0}" = 1 ]; then
      printf 'not json\n'
      exit 0
    fi
    case "${SQUAD_HC_READ_SHAPE:-screen}" in
      history) jq -cn --rawfile text "$SQUAD_HC_READ_TEXT" '{complete:true,how:"history",text:$text}' ;;
      incomplete) jq -cn --rawfile text "$SQUAD_HC_READ_TEXT" '{complete:false,how:"screen",text:$text}' ;;
      empty) printf '{"complete":true,"how":"screen","text":""}\n' ;;
      *) jq -cn --rawfile text "$SQUAD_HC_READ_TEXT" '{complete:true,how:"screen",text:$text}' ;;
    esac
    ;;
  send)
    last=${positional[${#positional[@]}-1]:-}
    if [ -n "${SQUAD_HC_SEND_FAIL_MATCH:-}" ]; then
      case "$last" in
        *"$SQUAD_HC_SEND_FAIL_MATCH"*)
          printf '{"error":{"kind":"status_mismatch","message":"refused","hint":"wait"}}\n' >&2
          exit 10
          ;;
      esac
    fi
    if [ "${SQUAD_HC_SEND_ERROR:-0}" = 1 ]; then
      printf '{"error":{"kind":"%s","message":"refused","hint":"read it"}}\n' "$(cat "$SQUAD_HC_SEND_KIND")" >&2
      exit "$(cat "$SQUAD_HC_SEND_RC")"
    fi
    # A faked `fob get` moves the terminal's foreground cwd into the leased
    # worktree, exactly as the real product reports it after the shell cds.
    if [ -n "${SQUAD_HC_LEASE:-}" ] && [ "$last" = 'fob get' ]; then
      jq --arg cwd "$SQUAD_HC_LEASE" '.foreground.cwd = $cwd' "$SQUAD_HC_GET" \
        > "$SQUAD_HC_GET.next" && mv "$SQUAD_HC_GET.next" "$SQUAD_HC_GET"
    fi
    printf '{"started":true,"status":"idle","turn":1}\n'
    ;;
  keys)
    shift_args=("${positional[@]:1}")
    printf '%s\n' "${shift_args[*]}" >> "$SQUAD_HC_KEYS_LOG"
    printf '{"status":null,"turn":0}\n'
    ;;
  kill)
    address=${positional[1]:-}
    printf 'kill %s\n' "$address" >> "$SQUAD_HC_KILL_LOG"
    if [ "${SQUAD_HC_KILL_FAIL:-0}" = 1 ]; then exit 1; fi
    out=$(jq -c '.state="finished" | .reason="killed"' "$SQUAD_HC_GET")
    if [ -n "${SQUAD_HC_KILL_SWAP:-}" ]; then cat "$SQUAD_HC_KILL_SWAP" > "$SQUAD_HC_GET"; fi
    printf '%s\n' "$out"
    ;;
  rm)
    address=${positional[1]:-}
    printf 'rm %s\n' "$address" >> "$SQUAD_HC_KILL_LOG"
    if [ "${SQUAD_HC_RM_FAIL:-0}" = 1 ]; then
      printf '{"error":{"kind":"live","message":"still running","hint":"kill it first"}}\n' >&2
      exit 1
    fi
    printf '{"removed":"%s"}\n' "$address"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/hc"
cat > "$TMP_ROOT/fakebin/fob" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${SQUAD_FAKE_FOB_LOG:?}"
case "${1:-}" in
  get) printf 'Entered worktree at %s\n' "${SQUAD_FAKE_FOB_LEASE:?}" ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$TMP_ROOT/fakebin/fob"
PATH="$TMP_ROOT/pybin:$TMP_ROOT/fakebin:$PATH"
export PATH

# --- fake core fixtures -----------------------------------------------------

hello_reply() {  # [generation] [version] [methods-json] [features-json]
  local generation=${1:-1} version=${2:-0.1.22}
  local methods=${3:-'["hello","server.status","terminal.run","terminal.get","terminal.list","terminal.read","terminal.send","terminal.keys","terminal.kill","terminal.rm","events.subscribe"]'}
  local features=${4:-'["framed","events","status"]'}
  jq -cn --argjson generation "$generation" --arg version "$version" \
    --argjson methods "$methods" --argjson features "$features" \
    '{jsonrpc:"2.0",id:1,result:{generation:$generation,version:$version,features:$features,methods:$methods}}'
}

schema_reply() {  # [method-to-drop] [param-pair-to-drop]
  local drop_method=${1:-} drop_param=${2:-}
  jq -cn --arg method "$drop_method" --arg pair "$drop_param" '
    {info:{version:"0.1.22"},
     methods:[
       {name:"terminal.run",params:[{name:"argv"},{name:"cwd"},{name:"name"},{name:"labels"},{name:"no_parent"}]},
       {name:"terminal.get",params:[{name:"terminal"}]},
       {name:"terminal.list",params:[{name:"all"},{name:"labels"}]},
       {name:"terminal.read",params:[{name:"terminal"},{name:"lines"}]},
       {name:"terminal.send",params:[{name:"terminal"},{name:"text"},{name:"if"},{name:"force"}]},
       {name:"terminal.keys",params:[{name:"terminal"},{name:"keys"}]},
       {name:"terminal.kill",params:[{name:"terminal"}]},
       {name:"terminal.rm",params:[{name:"terminal"}]},
       {name:"events.subscribe",params:[{name:"labels"},{name:"terminal"}]}
     ]}
    | if $method != "" then .methods |= map(select(.name != $method)) else . end
    | if $pair != "" then
        ($pair | split(":")) as $p
        | .methods |= map(if .name == $p[0] then .params |= map(select(.name != $p[1])) else . end)
      else . end'
}

write_live_terminal() {  # [address] [label-state] [foreground-name] [status-json]
  local address=${1:-t1} state=${2:-live} name=${3:-pi}
  local status=${4:-'{"app":"pi","state":"idle"}'}
  jq -cn --arg address "$address" --arg state "$state" --arg name "$name" \
    --argjson status "$status" --arg label "${SQUAD_HC_LABEL_TASK:-probe}" \
    --arg base "${SQUAD_HC_LABEL_BASE:-base}" '
    {address:$address,state:$state,labels:{("squad.task"):$label,("squad.base"):$base},
     foreground:{argv:[$name],cwd:"/tmp/work",name:$name,pid:4242},
     status:$status,reported:($status != null),status_ms:1234,turn:0,title:"t"}' > "$SQUAD_HC_GET"
  printf '0' > "$SQUAD_HC_SEND_RC"
  : > "$SQUAD_HC_SEND_KIND"
}

write_world() {  # write a baseline hello + schema so only the case under test differs
  hello_reply > "$TMP_ROOT/hello.json"
  schema_reply > "$TMP_ROOT/schema.json"
  export SQUAD_HC_HELLO_FILE="$TMP_ROOT/hello.json"
  export SQUAD_HC_SCHEMA_FILE="$TMP_ROOT/schema.json"
  unset SQUAD_HC_HELLO SQUAD_HC_STATUS_FAIL SQUAD_HC_SCHEMA_FAIL SQUAD_HC_GET_RC
  unset SQUAD_HC_RUN_FAIL SQUAD_HC_KILL_FAIL SQUAD_HC_RM_FAIL SQUAD_HC_SEND_ERROR
  unset SQUAD_HC_KILL_SWAP SQUAD_HC_LIST_ALL
  unset SQUAD_HC_LABEL_TASK
  export SQUAD_HC_LABEL_BASE="$BASE_LABEL" SQUAD_HC_RUN_BASE="$BASE_LABEL"
  unset SQUAD_HC_READ_SHAPE
  export SQUAD_HC_CORE_ID=core-a
  printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
  write_live_terminal
}

# One private listening socket stands in for a running core: the adapter's only
# precondition for any `hc` call is that a listener answers on this path. It
# accepts and closes every connection, exactly as a real core does, so the
# adapter's probe cannot fill the accept queue over a long suite.
LISTENER_PIDS=()
bind_listener() {  # <socket>
  "$PY" - "$1" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(64)
s.settimeout(0.2)
deadline = time.time() + 300
while time.time() < deadline:
    try:
        conn, _ = s.accept()
    except OSError:
        continue
    conn.close()
PY
  LISTENER_PIDS+=("$!")
}

# A listener that answers like a live herdr-core: HTTP/0.9 - raw JSON-RPC and no
# HTTP framing - and a connection it holds open after answering.
bind_http09_core() {  # <socket>
  "$PY" - "$1" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(8)
s.settimeout(0.2)
deadline = time.time() + 60
while time.time() < deadline:
    try:
        conn, _ = s.accept()
    except OSError:
        continue
    conn.recv(4096)
    try:
        conn.sendall(b'{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"expected value at line 1 column 1"}}\n')
        time.sleep(1)
    except OSError:
        pass
    conn.close()
PY
  LISTENER_PIDS+=("$!")
}

bind_listener "$SOCKET"
restore_and_exit() { rm -rf "$TMP_ROOT"; kill "${LISTENER_PIDS[@]}" 2>/dev/null || true; rm -f "$SQUAD_HC_GET"; }
trap 'restore_and_exit' EXIT
for _ in $(seq 1 100); do [ -S "$SOCKET" ] && break; sleep 0.05; done
[ -S "$SOCKET" ] || fail 'could not bind the private stand-in core socket'

# Sourcing the dispatcher is what every production consumer does.
SQUAD_ROOT="$ROOT"
SQUAD_BASE="$TMP_ROOT/base"
SQUAD_STATE_OVERRIDE="$TMP_ROOT/base/state"
mkdir -p "$SQUAD_STATE_OVERRIDE"
export SQUAD_ROOT SQUAD_BASE SQUAD_STATE_OVERRIDE
# shellcheck source=bin/sq-backend.sh
. "$ROOT/bin/sq-backend.sh"
fm_backend_source herdr-core || fail 'the dispatcher must source the herdr-core adapter'

BASE_LABEL=$(fm_backend_herdr_core_base_name)
BASE_HASH=${BASE_LABEL##*-}
base_label_for() {  # <base-path>
  (
    SQUAD_BASE=$1
    SQUAD_ROOT=$ROOT
    fm_backend_herdr_core_base_name
  )
}

write_list_all() {  # <address> <state> <task> <base>
  jq -cn --arg address "$1" --arg state "$2" --arg task "$3" --arg base "$4" '
    {terminals:[{address:$address,state:$state,labels:{"squad.task":$task,"squad.base":$base}}]}
  ' > "$TMP_ROOT/list-all.json"
}

call_log() { cat "$SQUAD_HC_LOG"; }
reset_calls() { : > "$SQUAD_HC_LOG"; }

write_world

# --- never start a core -----------------------------------------------------

reset_calls
XDG_RUNTIME_DIR="$TMP_ROOT/empty-runtime" mkdir -p "$TMP_ROOT/empty-runtime"
no_core=$(XDG_RUNTIME_DIR="$TMP_ROOT/empty-runtime" fm_backend_herdr_core_container_ensure "$TMP_ROOT" 2>&1) && no_core_rc=0 || no_core_rc=$?
[ "$no_core_rc" -ne 0 ] || fail 'a missing core must refuse, not fall through'
assert_contains "$no_core" 'Squad never starts the core' 'the missing-core refusal names the no-start rule'
assert_contains "$no_core" 'hc server start' 'the missing-core refusal names who must start it'
[ ! -s "$SQUAD_HC_LOG" ] || fail "a missing core must produce zero hc invocations (saw: $(call_log))"

reset_calls
XDG_RUNTIME_DIR="$TMP_ROOT/empty-runtime" fm_backend_herdr_core_target_exists 'default:t1' >/dev/null 2>&1 \
  && target_missing_rc=0 || target_missing_rc=$?
[ "$target_missing_rc" -ne 0 ] || fail 'target_exists must fail when no core is listening'
[ ! -s "$SQUAD_HC_LOG" ] || fail 'target_exists must not invoke hc without a listening core'
pass 'never starts a core: no hc invocation without a listening socket'

# A socket FILE is not a core. After an unclean core death the file survives with
# nothing accepting on it, and the next `hc` call would start a core with Squad's
# environment - so the gate has to prove a listener, and a stale file must refuse
# exactly like an absent one.
mkdir -p "$TMP_ROOT/stale-runtime/herdr-core"
STALE_SOCKET="$TMP_ROOT/stale-runtime/herdr-core/default.sock"
"$PY" - "$STALE_SOCKET" <<'PY'
import socket
import sys

listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(sys.argv[1])
listener.close()
PY
[ -S "$STALE_SOCKET" ] || fail 'the stale-socket fixture must leave a socket file with no listener'
reset_calls
stale_out=$(XDG_RUNTIME_DIR="$TMP_ROOT/stale-runtime" fm_backend_herdr_core_container_ensure "$TMP_ROOT" 2>&1) && stale_rc=0 || stale_rc=$?
[ "$stale_rc" -ne 0 ] || fail 'a stale socket with nothing listening behind it must refuse'
assert_contains "$stale_out" 'Squad never starts the core' 'the stale-socket refusal names the no-start rule'
assert_contains "$stale_out" 'hc server start' 'the stale-socket refusal names who must start it'
[ ! -s "$SQUAD_HC_LOG" ] || fail "a stale socket must produce zero hc invocations (saw: $(call_log))"
reset_calls
XDG_RUNTIME_DIR="$TMP_ROOT/stale-runtime" fm_backend_herdr_core_target_exists 'default:t1' >/dev/null 2>&1 \
  && stale_target_rc=0 || stale_target_rc=$?
[ "$stale_target_rc" -ne 0 ] || fail 'target_exists must fail on a stale socket'
[ ! -s "$SQUAD_HC_LOG" ] || fail 'target_exists must not invoke hc on a stale socket'
pass 'never starts a core: a stale socket file is not a listening core'

# `hc` has two socket placements: the runtime directory when XDG_RUNTIME_DIR is
# set, and the per-session state folder when it is not. A host without a runtime
# directory - a container, a bare ssh session - keeps its core only in the state
# directory, so resolving `/run/user/<uid>` there would refuse a reachable core
# and the next `hc` call would start one with Squad's environment.
state_root="$TMP_ROOT/state-fallback"
state_socket="$state_root/herdr-core/default/default.sock"
mkdir -p "$state_root/herdr-core/default"
bind_listener "$state_socket"
for _ in $(seq 1 100); do [ -S "$state_socket" ] && break; sleep 0.05; done
[ -S "$state_socket" ] || fail 'could not bind the state-directory core fixture'
reset_calls
( unset XDG_RUNTIME_DIR HC_SOCKET; XDG_STATE_HOME="$state_root" fm_backend_herdr_core_core_present default ) \
  && state_rc=0 || state_rc=$?
[ "$state_rc" -eq 0 ] || fail 'a core in the state directory must be found when XDG_RUNTIME_DIR is unset'
[ ! -s "$SQUAD_HC_LOG" ] || fail "resolving the state-directory core must not invoke hc (saw: $(call_log))"
pass 'a core in the state directory is reachable without XDG_RUNTIME_DIR'

# The same placement when XDG_STATE_HOME is unset too: hc falls back to
# $HOME/.local/state, so the adapter must derive the identical path.
home_root="$TMP_ROOT/home-fallback"
home_socket="$home_root/.local/state/herdr-core/default/default.sock"
mkdir -p "$(dirname "$home_socket")"
bind_listener "$home_socket"
for _ in $(seq 1 100); do [ -S "$home_socket" ] && break; sleep 0.05; done
[ -S "$home_socket" ] || fail 'could not bind the home state-directory core fixture'
( unset XDG_RUNTIME_DIR XDG_STATE_HOME HC_SOCKET; HOME="$home_root" fm_backend_herdr_core_core_present default ) \
  && home_rc=0 || home_rc=$?
[ "$home_rc" -eq 0 ] || fail "a core in ~/.local/state must be found when XDG_RUNTIME_DIR and XDG_STATE_HOME are unset"
pass "a core in ~/.local/state is reachable without a runtime directory"

# And a missing state-directory core refuses at that exact path instead of a
# /run/user path no core ever used.
no_core_state="$TMP_ROOT/no-core-state"
reset_calls
no_core_out=$( ( unset XDG_RUNTIME_DIR HC_SOCKET; XDG_STATE_HOME="$no_core_state" fm_backend_herdr_core_core_present default ) 2>&1 ) \
  && no_core_state_rc=0 || no_core_state_rc=$?
[ "$no_core_state_rc" -ne 0 ] || fail 'a missing state-directory core must refuse'
assert_contains "$no_core_out" "$no_core_state/herdr-core/default/default.sock" 'the refusal names hc state-directory socket'
assert_contains "$no_core_out" 'Squad never starts the core' 'the state-directory refusal names the no-start rule'
[ ! -s "$SQUAD_HC_LOG" ] || fail "a missing state-directory core must invoke no hc (saw: $(call_log))"
pass 'no core: the state-directory socket is the path that is refused'

# curl's proof is the RESPONSE, not its exit code: hc answers in HTTP/0.9 - raw
# JSON-RPC, no HTTP framing - and holds the connection open afterwards, so real
# curl ends on its timeout with the reply already in hand. Without --http0.9 curl
# rejects that reply before it is ever shown, so the adapter must ask for 0.9.
if command -v curl >/dev/null 2>&1; then
  http09_socket="$TMP_ROOT/http09-runtime/herdr-core/default.sock"
  mkdir -p "$(dirname "$http09_socket")"
  bind_http09_core "$http09_socket"
  for _ in $(seq 1 100); do [ -S "$http09_socket" ] && break; sleep 0.05; done
  [ -S "$http09_socket" ] || fail 'could not bind the HTTP/0.9 core fixture'
  fm_backend_herdr_core_probe_curl "$http09_socket" && http09_rc=0 || http09_rc=$?
  [ "$http09_rc" -eq 0 ] || fail "real curl facing hc's HTTP/0.9 reply must prove the listener (got $http09_rc)"
  XDG_RUNTIME_DIR="$TMP_ROOT/http09-runtime" fm_backend_herdr_core_core_present default \
    || fail 'core_present must license a core whose reply arrives in HTTP/0.9'
  pass 'the curl probe recognizes a real HTTP/0.9 herdr-core reply'
else
  echo 'skip: curl not installed (the HTTP/0.9 probe fixture)'
fi

# The fallback clients exist because a working python3 is not guaranteed, so a
# curl that cannot prove a connection must fail closed: a build without
# --unix-socket, a client-local failure, or a timeout that delivered no byte is
# not a listener. The suite PATH is cut down to one fake client so python3 and nc
# cannot answer.
probe_client_bin() {  # <name> <curl-exit> -> dir
  local dir="$TMP_ROOT/probe-$1"
  mkdir -p "$dir"
  ln -sf "$(command -v bash)" "$dir/bash"
  printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$dir/curl"
  chmod +x "$dir/curl"
  printf '%s' "$dir"
}

undecided_bin=$(probe_client_bin undecided 2)
PATH="$undecided_bin" fm_backend_herdr_core_probe_curl "$STALE_SOCKET" && probe_rc=0 || probe_rc=$?
[ "$probe_rc" -eq 2 ] || fail "a curl that cannot connect must be undecidable (got $probe_rc)"
reset_calls
undecided_out=$(PATH="$undecided_bin" XDG_RUNTIME_DIR="$TMP_ROOT/stale-runtime" \
  fm_backend_herdr_core_core_present default 2>&1) && undecided_rc=0 || undecided_rc=$?
[ "$undecided_rc" -ne 0 ] || fail 'an undecidable probe client must refuse, not license hc'
assert_contains "$undecided_out" 'cannot prove a core is listening' 'the undecidable probe names why it refuses'
[ ! -s "$SQUAD_HC_LOG" ] || fail "an undecidable probe must produce zero hc invocations (saw: $(call_log))"
pass 'never starts a core: a probe client that cannot decide refuses'

# A timeout with no byte is the failure mode a real core produces only when it
# never answered, so it must not be read as a listener just because the live-core
# case also ends on curl's timeout.
timedout_bin=$(probe_client_bin timedout 28)
PATH="$timedout_bin" fm_backend_herdr_core_probe_curl "$STALE_SOCKET" && timedout_rc=0 || timedout_rc=$?
[ "$timedout_rc" -eq 2 ] || fail "a timeout that delivered no byte must be undecidable (got $timedout_rc)"
pass 'the curl probe requires a reply, not a timeout exit code'

refused_bin=$(probe_client_bin refused 7)
PATH="$refused_bin" fm_backend_herdr_core_probe_curl "$STALE_SOCKET" && refused_rc=0 || refused_rc=$?
[ "$refused_rc" -eq 1 ] || fail "curl's could-not-connect must be a refusal (got $refused_rc)"
pass 'the curl probe refuses a could-not-connect socket'

# --- the protocol guard -----------------------------------------------------

guard_fails() {  # <label> <expected-fragment> [assert no run]
  local label=$1 fragment=$2 out rc
  reset_calls
  out=$(fm_backend_herdr_core_protocol_check default 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: the guard must refuse"
  assert_contains "$out" "$fragment" "$label: the refusal names the reason"
  assert_not_contains "$out" 'Squad never starts the core' "$label: reaches the handshake, not the socket check"
  case "$(call_log)" in
    *'run '*|*'send '*|*'kill '*) fail "$label: a refused guard must not run a terminal verb" ;;
  esac
  pass "$label"
}

hello_reply 2 > "$TMP_ROOT/hello.json"
guard_fails 'guard refuses a newer protocol generation' 'requires generation 1'

printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"data":{"kind":"unsupported_generation","hint":"this core speaks generation 1"},"message":"protocol generation 2 not supported"}}' > "$TMP_ROOT/hello.json"
guard_fails 'guard relays the core own unsupported_generation hint' 'this core speaks generation 1'

hello_reply 1 0.1.21 > "$TMP_ROOT/hello.json"
guard_fails 'guard refuses a version below the floor' "below this adapter's floor 0.1.22"

printf 'not json\n' > "$TMP_ROOT/hello.json"
guard_fails 'guard refuses a malformed handshake' 'handshake reply is malformed'

hello_reply 1 0.1.22 '["hello","server.status","terminal.run","terminal.get","terminal.list","terminal.read","terminal.keys","terminal.kill","terminal.rm","events.subscribe"]' > "$TMP_ROOT/hello.json"
guard_fails 'guard refuses a missing method' 'missing method terminal.send'

hello_reply 1 0.1.22 '["hello","server.status","terminal.run","terminal.get","terminal.list","terminal.read","terminal.send","terminal.keys","terminal.kill","terminal.rm","events.subscribe"]' '["framed"]' > "$TMP_ROOT/hello.json"
guard_fails 'guard refuses a missing feature' 'missing feature status'

hello_reply 1 0.1.22 '["hello","server.status","terminal.run","terminal.get","terminal.list","terminal.read","terminal.send","terminal.keys","terminal.kill","terminal.rm","events.subscribe"]' '{"status":true,"events":true}' > "$TMP_ROOT/hello.json"
guard_fails 'guard refuses a malformed feature catalog instead of assuming none' 'features list is malformed'

hello_reply 1 0.1.22 '{"terminal.run":true}' > "$TMP_ROOT/hello.json"
guard_fails 'guard refuses a malformed method catalog instead of assuming none' 'methods list is malformed'

write_world
schema_reply '' 'terminal.send:if' > "$SQUAD_HC_SCHEMA_FILE"
guard_fails 'guard refuses a missing parameter' 'terminal.send has no parameter if'

write_world
schema_reply 'events.subscribe' > "$SQUAD_HC_SCHEMA_FILE"
guard_fails 'guard refuses a missing catalog method' 'missing method events.subscribe'

write_world
SQUAD_HC_SCHEMA_FAIL=1 guard_fails 'guard refuses an unreadable catalog' 'catalog is unreadable'

write_world
SQUAD_HC_STATUS_FAIL=1 guard_fails 'guard refuses an unreadable core identity' 'core identity is unreadable'

write_world
reset_calls
guard_out=$(fm_backend_herdr_core_protocol_check default 2>&1) || fail "the guard must pass on a verified core: $guard_out"
[ "$guard_out" = core-a ] || fail "the guard must print the core id (got '$guard_out')"
pass 'guard passes a verified core and reports its id'

# Version comparison is a contract of its own.
for pair in '0.1.22 0.1.22' '0.1.23 0.1.22' '0.2.0 0.1.22' '1.0.0 0.1.22'; do
  # shellcheck disable=SC2086 # intentional word split of the two-part fixture
  set -- $pair
  fm_backend_herdr_core_version_at_least "$1" "$2" || fail "version $1 must satisfy floor $2"
done
for pair in '0.1.21 0.1.22' '0.1.9 0.1.22' '0.0.99 0.1.22'; do
  # shellcheck disable=SC2086
  set -- $pair
  if fm_backend_herdr_core_version_at_least "$1" "$2"; then fail "version $1 must NOT satisfy floor $2"; fi
done
if fm_backend_herdr_core_version_at_least 'garbage' '0.1.22'; then fail 'an unparsable version is below the floor'; fi
pass 'version floor comparison'

# --- capture, busy state, prompt summary -----------------------------------

write_world
write_live_terminal t1 live pi '{"app":"pi","state":"working"}'
fm_backend_herdr_core_busy_state 'default:t1' | grep -qx busy || fail 'a working report is busy'
[ "$(fm_backend_herdr_core_capture 'default:t1' 10 'sq-probe')" = 'probe screen
> ' ] || fail 'capture returns the program text'

# The sentry hashes the rendered read to expire busy claims, so only the product's
# own complete-screen envelope is accepted. A history read, a partial read, an
# empty screen, and a failed or malformed read all refuse, and static-busy expiry
# simply does not run rather than hashing unproven text.
rendered=$(fm_backend_capture_rendered herdr-core 'default:t1' 'sq-probe') \
  || fail 'a complete screen read must be accepted'
[ "$rendered" = 'probe screen
> ' ] || fail "a complete screen read returns the program text (got '$rendered')"
for shape in history incomplete empty; do
  out=$(SQUAD_HC_READ_SHAPE=$shape fm_backend_capture_rendered herdr-core 'default:t1' 'sq-probe' 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a $shape rendered read must refuse"
  [ -z "$out" ] || fail "a $shape rendered read must print nothing (got '$out')"
done

# A failed or malformed read must surface as a failure, never as a successful
# empty screen: the sentry would otherwise hash "" as a static pane and start a
# wedge timer on no data.
reset_calls
out=$(SQUAD_HC_READ_FAIL=1 fm_backend_capture herdr-core 'default:t1' 10 'sq-probe' 2>/dev/null) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a failed hc read must not report a successful capture'
[ -z "$out" ] || fail "a failed hc read must not print an empty screen (got '$out')"
out=$(SQUAD_HC_READ_MALFORMED=1 fm_backend_capture_rendered herdr-core 'default:t1' 'sq-probe' 2>/dev/null) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a malformed hc read must not report a successful rendered capture'
[ -z "$out" ] || fail "a malformed hc read must not print an empty screen (got '$out')"
pass 'capture and busy state come from the program report'

write_live_terminal t1 live pi '{"app":"pi","state":"blocked","kind":"permission","msg":"Allow rm?"}'
[ "$(fm_backend_herdr_core_busy_state 'default:t1')" = blocked ] || fail 'a blocked report is blocked'
summary=$(fm_backend_herdr_core_prompt_summary 'default:t1')
[ "$summary" = 'permission: Allow rm?' ] || fail "prompt summary must carry kind and message (got '$summary')"

write_live_terminal t1 live bash 'null'
SQUAD_HC_LABEL_TASK=probe write_live_terminal t1 live bash 'null'
[ "$(fm_backend_herdr_core_busy_state 'default:t1')" = unknown ] || fail 'a silent program is unknown, never idle'
[ -z "$(fm_backend_herdr_core_prompt_summary 'default:t1')" ] || fail 'a silent program has no prompt summary'
pass 'silent lanes stay unknown and carry no prompt'

# A restarted core recycles addresses, and a retired task's address can belong
# to a stranger: the one read every status consumer uses checks the recorded
# core id and the terminal's own task label before projecting any state.
write_world
fm_write_meta "$SQUAD_STATE_OVERRIDE/status.meta" \
  "window=default:t1" "endpoint_task_id=status" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-old"
SQUAD_HC_LABEL_TASK=status write_live_terminal t1 live pi '{"app":"pi","state":"blocked","kind":"permission","msg":"Allow rm?"}'
[ "$(fm_backend_herdr_core_busy_state 'default:t1')" = unknown ] \
  || fail 'a record from a different core must not report a busy verdict'
[ -z "$(fm_backend_herdr_core_prompt_summary 'default:t1')" ] \
  || fail 'a record from a different core must not report a prompt'
[ "$(fm_backend_herdr_core_agent_state 'default:t1')" = missing ] \
  || fail 'a record from a different core is not this task endpoint'
mkdir -p "$TMP_ROOT/status-state"
out=$(fm_backend_herdr_core_poll_transition "$TMP_ROOT/status-state" default 'default:t1') && rc=0 || rc=$?
[ "$rc" -eq 2 ] || fail "a record from a different core must not wake the sentry (rc=$rc)"

fm_write_meta "$SQUAD_STATE_OVERRIDE/status.meta" \
  "window=default:t1" "endpoint_task_id=status" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-a"
SQUAD_HC_LABEL_TASK=stranger write_live_terminal t1 live pi '{"app":"pi","state":"blocked","kind":"permission","msg":"Allow rm?"}'
[ "$(fm_backend_herdr_core_busy_state 'default:t1')" = unknown ] \
  || fail 'a stranger task label must not report a busy verdict'
[ "$(fm_backend_herdr_core_agent_state 'default:t1')" = missing ] \
  || fail 'a stranger task label is not this task endpoint'
out=$(fm_backend_herdr_core_poll_transition "$TMP_ROOT/status-state" default 'default:t1') && rc=0 || rc=$?
[ "$rc" -eq 2 ] || fail "a stranger task label must not wake the sentry (rc=$rc)"

# A recorded core id the live core cannot confirm is an UNVERIFIABLE identity,
# not an absent endpoint: reporting `missing` here would authorise a replacement
# endpoint or supervisor for a task whose terminal may still be running.
export SQUAD_HC_STATUS_FAIL=1
[ "$(fm_backend_herdr_core_agent_state 'default:t1')" = unreadable ] \
  || fail 'an unreadable live core id must not read as an absent endpoint'
[ "$(fm_backend_agent_alive herdr-core 'default:t1')" = unknown ] \
  || fail 'an unverifiable identity must not report the agent as dead'
[ "$(fm_backend_herdr_core_busy_state 'default:t1')" = unknown ] \
  || fail 'an unreadable core id must not report a busy verdict'
unset SQUAD_HC_STATUS_FAIL
# The status read is the only label authority: it proves the recorded core id
# and the task label together, so a redundant second read that fails must never
# turn a verified live endpoint into an absent one.
SQUAD_HC_LABEL_TASK=status write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
: > "$SQUAD_HC_GET_COUNT"
verdict=$(SQUAD_HC_GET_FAIL_AFTER=1 fm_backend_herdr_core_agent_state 'default:t1' 2>/dev/null)
unset SQUAD_HC_GET_FAIL_AFTER
[ "$verdict" = alive ] \
  || fail "a failed duplicate label read must not report a live endpoint as $verdict"
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'status reads are bound to the recorded core id and task label'

# endpoint_task_id= is the bare task id even when the id itself begins with
# sq-, which docs/configuration.md supports: the identity check must not strip
# that prefix a second time, or every status consumer and delivery refuses a
# correctly recorded task.
write_world
fm_write_meta "$SQUAD_STATE_OVERRIDE/sq-demo.meta" \
  "window=default:t1" "endpoint_task_id=sq-demo" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-a"
SQUAD_HC_LABEL_TASK=sq-demo write_live_terminal t1 live pi '{"app":"pi","state":"blocked","kind":"permission","msg":"Allow rm?"}'
[ "$(fm_backend_herdr_core_busy_state 'default:t1')" = blocked ] \
  || fail 'an sq-prefixed task id must still report its busy verdict'
[ "$(fm_backend_herdr_core_agent_state 'default:t1')" = alive ] \
  || fail 'an sq-prefixed task id must still report its live agent'
fm_backend_herdr_core_target_exists 'default:t1' 'sq-sq-demo' \
  || fail 'an sq-prefixed task id is still this task exact endpoint'
[ "$(fm_backend_herdr_core_capture 'default:t1' 10 'sq-sq-demo')" = 'probe screen
> ' ] \
  || fail 'an sq-prefixed task id must still capture its own screen'
SQUAD_HC_LABEL_TASK=sq-demo write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
fm_backend_herdr_core_send_text_line 'default:t1' 'hello' 'sq-sq-demo' \
  || fail 'an sq-prefixed task id must still accept a delivery'
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'an sq-prefixed task id keeps its bare recorded identity'

# composer_state: only a bordered row, or a bare AGENT glyph, is a composer.
write_world
printf '│ ❯ │\n' > "$SQUAD_HC_READ_TEXT"
write_live_terminal t1 live bash 'null'
[ "$(fm_backend_herdr_core_composer_state 'default:t1')" = empty ] \
  || fail 'an empty bordered composer is empty'
printf '│ hello │\n' > "$SQUAD_HC_READ_TEXT"
[ "$(fm_backend_herdr_core_composer_state 'default:t1')" = pending ] \
  || fail 'typed text in a bordered composer is pending'
printf '│ > │\n' > "$SQUAD_HC_READ_TEXT"
[ "$(fm_backend_herdr_core_composer_state 'default:t1')" = empty ] \
  || fail 'a shell prompt inside a composer box is its own empty composer'
printf '> \n' > "$SQUAD_HC_READ_TEXT"
[ "$(fm_backend_herdr_core_composer_state 'default:t1')" = unknown ] \
  || fail 'a bare shell prompt is never a safe injection target'
printf '❯ \n' > "$SQUAD_HC_READ_TEXT"
[ "$(fm_backend_herdr_core_composer_state 'default:t1')" = empty ] \
  || fail 'a bare agent glyph is an empty agent composer'
printf 'probe screen\n> ' > "$SQUAD_HC_READ_TEXT"
pass 'the composer classifier keeps the prompt glyph it must judge'

# --- delivery verdicts -----------------------------------------------------

verdict_send() { fm_backend_herdr_core_send_text_submit "${1:-default:t1}" 'hello' 3 0.1 0 "${2:-sq-probe}"; }

write_world
[ "$(verdict_send)" = empty ] || fail 'a successful send is a confirmed delivery'

printf 'blocked' > "$SQUAD_HC_SEND_KIND"; printf '9' > "$SQUAD_HC_SEND_RC"; export SQUAD_HC_SEND_ERROR=1
[ "$(verdict_send)" = agent_blocked ] || fail 'a blocked refusal is agent_blocked'

printf 'status_mismatch' > "$SQUAD_HC_SEND_KIND"; printf '10' > "$SQUAD_HC_SEND_RC"
[ "$(verdict_send)" = not_ready ] || fail 'a status mismatch refusal is not_ready'

printf 'finished' > "$SQUAD_HC_SEND_KIND"; printf '11' > "$SQUAD_HC_SEND_RC"
[ "$(verdict_send)" = no_agent ] || fail 'a finished refusal is no_agent'

printf 'not_found' > "$SQUAD_HC_SEND_KIND"; printf '3' > "$SQUAD_HC_SEND_RC"
[ "$(verdict_send)" = no_agent ] || fail 'a gone address refusal is no_agent'

printf 'weird' > "$SQUAD_HC_SEND_KIND"; printf '1' > "$SQUAD_HC_SEND_RC"
[ "$(verdict_send)" = uncertain-delivery ] || fail 'an unclassified failure is uncertain-delivery, never retried'
unset SQUAD_HC_SEND_ERROR
pass 'delivery verdicts map every refusal kind'

# The program's own reported state decides how it is typed into. `--if` accepts
# only idle|working, so an exactly-idle program is gated by `--if idle`, a
# `done` program (its turn finished, it is at rest) is sent plainly, and any
# other reported state refuses before typing.
write_world
write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
reset_calls
[ "$(verdict_send)" = empty ] || fail 'an idle program accepts a delivery'
case "$(call_log)" in
  *'send --json --if idle'*) ;;
  *) fail "an idle program must be gated by --if idle (saw: $(call_log))" ;;
esac

write_live_terminal t1 live pi '{"app":"pi","state":"done"}'
reset_calls
[ "$(verdict_send)" = empty ] || fail 'a done program is at rest and accepts a delivery'
send_line=$(grep -F 'send ' "$SQUAD_HC_LOG" | tail -1)
case "$send_line" in
  *'--if'*) fail "a done program must be sent without --if, which cannot express done (saw: $send_line)" ;;
esac

write_live_terminal t1 live pi '{"app":"pi","state":"working"}'
reset_calls
[ "$(verdict_send)" = not_ready ] || fail 'a working program must refuse a delivery'
case "$(call_log)" in *'send '*) fail 'a working program must not be sent into' ;; esac

write_live_terminal t1 live pi '{"app":"pi","state":"error"}'
reset_calls
[ "$(verdict_send)" = not_ready ] || fail 'an erroring program must refuse a delivery'
case "$(call_log)" in *'send '*) fail 'an erroring program must not be sent into' ;; esac

write_world
[ "$(fm_backend_herdr_core_busy_state 'default:t1')" = idle ] || fail 'busy_state keeps reporting done as idle'
write_world
pass 'delivery gates on the reported state, and done is sent plainly'

# A failed read, or an identity this process cannot verify, is a local failure
# before anything was typed, never a confident absence: a caller that treats
# no_agent as authoritative would otherwise drop its delivery record on a core
# hiccup, while an authoritative "gone" still must read as no_agent.
write_world
fm_write_meta "$SQUAD_STATE_OVERRIDE/verdict.meta" \
  "window=default:t1" "endpoint_task_id=probe" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-a"
reset_calls
verdict=$(SQUAD_HC_STATUS_FAIL=1 fm_backend_herdr_core_send_text_submit 'default:t1' 'hello' 3 0.1 0 'sq-probe' 2>/dev/null)
[ "$verdict" = send-failed ] || fail "an unverifiable core identity is a local failure, not $verdict"
case "$(call_log)" in *'send '*) fail 'an unverifiable core identity must not send' ;; esac

reset_calls
verdict=$(SQUAD_HC_GET_RC=1 fm_backend_herdr_core_send_text_submit 'default:t1' 'hello' 3 0.1 0 'sq-probe' 2>/dev/null)
[ "$verdict" = send-failed ] || fail "an unreadable status read is a local failure, not $verdict"
case "$(call_log)" in *'send '*) fail 'an unreadable status read must not send' ;; esac

reset_calls
verdict=$(SQUAD_HC_GET_RC=3 fm_backend_herdr_core_send_text_submit 'default:t1' 'hello' 3 0.1 0 'sq-probe' 2>/dev/null)
[ "$verdict" = no_agent ] || fail "an authoritatively gone address is no_agent, not $verdict"
case "$(call_log)" in *'send '*) fail 'a gone address must not send' ;; esac

rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'a failed read is a local send failure, never a confident absence'

# A mismatched task label is refused before anything is typed.
write_world
reset_calls
out=$(fm_backend_herdr_core_send_text_line 'default:t1' 'hello' 'sq-other' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a foreign label must refuse delivery'
assert_contains "$out" 'refusing to touch another task' 'the label refusal names the reason'
case "$(call_log)" in *'send '*) fail 'a refused label must not send' ;; esac
pass 'a mismatched squad.task label refuses before typing'

# --- the identity triple ---------------------------------------------------

write_world
reset_calls
: > "$SQUAD_HC_KILL_LOG"
out=$(fm_backend_herdr_core_kill 'default:t1' '' 'sq-other' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'kill must refuse a foreign label'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail 'a refused label must never reach kill or rm'

write_world
reset_calls
: > "$SQUAD_HC_KILL_LOG"
out=$(fm_backend_herdr_core_kill 'default:t1' '' 'sq-probe' 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "kill must succeed on a matching triple: $out"
assert_grep 'kill t1' "$SQUAD_HC_KILL_LOG" 'kill names the exact address'
assert_grep 'rm t1' "$SQUAD_HC_KILL_LOG" 'rm names the exact address'
pass 'kill and rm run only on the exact address'

# A recorded core id that no longer matches refuses every write.
write_world
fm_write_meta "$SQUAD_STATE_OVERRIDE/target.meta" \
  "window=default:t1" "endpoint_task_id=target" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-old"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
out=$(fm_backend_herdr_core_kill 'default:t1' '' 'sq-target' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a recorded core id that no longer matches must refuse'
assert_contains "$out" 'recorded core core-old' 'the core-id refusal names both ids'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail 'a core-id mismatch must never reach kill or rm'

# The address is also refused once it is no longer live.
write_world
SQUAD_HC_LABEL_TASK=target write_live_terminal t1 finished pi 'null'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
SQUAD_HC_LABEL_TASK=target write_live_terminal t1 finished pi 'null'
fm_write_meta "$SQUAD_STATE_OVERRIDE/target.meta" \
  "window=default:t1" "endpoint_task_id=target" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-a"
# A finished address still has to be retirable: a task whose program exited on
# its own must not be stuck forever in the registry.
out=$(fm_backend_herdr_core_kill 'default:t1' '' 'sq-target' 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "a finished address must still be closed by its exact identity: $out"
assert_grep 'rm t1' "$SQUAD_HC_KILL_LOG" 'the finished address is removed'
# The same allowance never licenses a write of another kind.
SQUAD_HC_LABEL_TASK=target write_live_terminal t1 finished pi 'null'
if fm_backend_herdr_core_send_text_line 'default:t1' 'hello' 'sq-target' >/dev/null 2>&1; then
  fail 'a finished address must refuse delivery'
fi
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'the cleanup identity is address, task label and core id'

# The identity is re-checked immediately before `rm`: if the finished address is
# retired and recycled by another actor between the close and the removal, the
# stranger that now owns it must survive.
write_world
fm_write_meta "$SQUAD_STATE_OVERRIDE/target.meta" \
  "window=default:t1" "endpoint_task_id=target" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-a"
SQUAD_HC_LABEL_TASK=target write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
cp "$SQUAD_HC_GET" "$TMP_ROOT/owner-record.json"
SQUAD_HC_LABEL_TASK=stranger write_live_terminal t1 finished pi 'null'
cp "$SQUAD_HC_GET" "$TMP_ROOT/stranger-record.json"
cp "$TMP_ROOT/owner-record.json" "$SQUAD_HC_GET"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
out=$(SQUAD_HC_KILL_SWAP="$TMP_ROOT/stranger-record.json" \
  fm_backend_herdr_core_kill 'default:t1' '' 'sq-target' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a recycled address must refuse the removal'
assert_contains "$out" 'refusing to touch another task' 'the second check names the foreign label'
assert_grep 'kill t1' "$SQUAD_HC_KILL_LOG" 'the close itself ran on the exact address'
case "$(cat "$SQUAD_HC_KILL_LOG")" in
  *'rm t1'*) fail 'a recycled address must never be removed' ;;
esac
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta "$TMP_ROOT/owner-record.json" "$TMP_ROOT/stranger-record.json"
write_world
pass 'the identity is checked again before rm'

# The failed-create recovery closes an address that has no task record behind it,
# so its close also re-checks the terminal's own squad.base label: another base's
# terminal is never closed even when this base's task id happens to match.
write_world
reset_calls
: > "$SQUAD_HC_KILL_LOG"
out=$(fm_backend_herdr_core_kill 'default:t1' '' 'sq-probe' other 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a close must refuse another base's terminal"
assert_contains "$out" "refusing to touch another base's terminal" 'the base refusal names the reason'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail 'a base-label mismatch must never reach kill or rm'
fm_backend_herdr_core_kill 'default:t1' '' 'sq-probe' "$BASE_LABEL" >/dev/null 2>&1 \
  || fail "a close must accept this base's own terminal"
write_world
pass 'a close checks the squad.base label it was scoped by'

# Two bases can share the ordinary `squad` directory name, so the base label
# itself must distinguish them: otherwise this base's failed-create recovery
# could close the other base's terminal for the same task id.
mkdir -p "$TMP_ROOT/one/squad" "$TMP_ROOT/two/squad"
label_one=$(base_label_for "$TMP_ROOT/one/squad")
label_two=$(base_label_for "$TMP_ROOT/two/squad")
[ "$label_one" != "$label_two" ] \
  || fail "two bases with the same directory name must get different labels (got '$label_one')"
[ "$label_one" = "$(base_label_for "$TMP_ROOT/one/squad")" ] \
  || fail 'a base label must be stable for one base path'
# The persisted base label is the documented `<base-directory>-<short-hash>`,
# one separator and nothing else: an extra separator is a different identity than
# the one this base both writes onto its terminals and filters its inventories by.
assert_base_label_shape() {  # <expected-directory-name> <label>
  case "$2" in *[!a-z0-9_-]*) fail "a base label may only use a-z 0-9 - _ (got '$2')" ;; esac
  [ "$2" = "$1-${2##*-}" ] \
    || fail "a base label must be <base-directory>-<hash> with exactly one separator (got '$2')"
}
assert_base_label_shape base "$BASE_LABEL"
assert_base_label_shape squad "$label_one"
assert_base_label_shape squad "$label_two"
write_world
write_list_all t5 finished probe "$label_two"
cp "$TMP_ROOT/list-all.json" "$TMP_ROOT/other-base-inventory.json"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
( SQUAD_BASE="$TMP_ROOT/one/squad" SQUAD_HC_LIST_ALL="$TMP_ROOT/other-base-inventory.json" \
    fm_backend_herdr_core_close_created default probe ) >/dev/null 2>&1
[ ! -s "$SQUAD_HC_KILL_LOG" ] \
  || fail "a base must never close another base's terminal at the same task id (saw: $(cat "$SQUAD_HC_KILL_LOG"))"
rm -f "$TMP_ROOT/other-base-inventory.json"
write_world
pass 'the base label is unique per base path and scopes the recovery close'

# The base label is part of the identity on EVERY recorded-address close and read,
# not only the failed-create recovery. Bases A and B share one core and both have
# task `1`; A's recorded address `t1` is lost, the core recycles it for B's task
# `1`, and A's teardown then reads a live terminal carrying `squad.task=1` and A's
# recorded core id. It must still refuse, because the terminal's `squad.base` is
# B's - closing it would destroy a terminal this base never created.
write_world
fm_write_meta "$SQUAD_STATE_OVERRIDE/recycled.meta" \
  "window=default:t1" "endpoint_task_id=recycled" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-a"
( SQUAD_HC_LABEL_TASK=recycled SQUAD_HC_LABEL_BASE="$label_two" \
    write_live_terminal t1 live pi '{"app":"pi","state":"idle"}' )
reset_calls
: > "$SQUAD_HC_KILL_LOG"
out=$(fm_backend_herdr_core_kill 'default:t1' '' 'sq-recycled' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a recorded-address close must refuse another base's terminal at the recycled address"
assert_contains "$out" "refusing to touch another base's terminal" 'the recorded-address base refusal names the reason'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail "another base's terminal must never reach kill or rm"
fm_backend_herdr_core_status_json 'default:t1' >/dev/null 2>&1 && status_rc=0 || status_rc=$?
[ "$status_rc" -eq 4 ] || fail "a status read must refuse another base's terminal (rc=$status_rc)"
[ "$(fm_backend_herdr_core_agent_state 'default:t1')" = missing ] \
  || fail "another base's terminal is not this task's"
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'every recorded-address close and read requires the squad.base label'

# A core recycles an address as soon as its terminal is closed, so two tasks can
# record the same `<session>:<address>` window. The recorded identity therefore
# comes from the task's own `<task-id>.meta`, never from whichever meta the
# address glob yields first: task `alpha` recorded `default:t1` against an older
# core, the address was recycled, and task `beta` now records that same window
# against the live core. Reading alpha's ids for beta would refuse every write,
# drop deliveries and retire a live task's records as "foreign".
write_world
twin_meta() {  # <id> <core-id>
  fm_write_meta "$SQUAD_STATE_OVERRIDE/$1.meta" \
    "window=default:t1" "endpoint_task_id=$1" "worktree=$TMP_ROOT" \
    "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
    "hc_session=default" "hc_address=t1" "hc_core_id=$2"
}
twin_meta alpha core-old
twin_meta beta core-a
SQUAD_HC_LABEL_TASK=beta write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
[ "$(fm_backend_herdr_core_recorded_core_id 'default:t1' beta)" = core-a ] \
  || fail "a task's recorded core id must come from its own metadata"
[ "$(fm_backend_herdr_core_recorded_task_id_for_target 'default:t1' beta)" = beta ] \
  || fail "a task's recorded task id must come from its own metadata"
fm_backend_herdr_core_target_exists 'default:t1' 'sq-beta' \
  || fail 'a live task is present through its own recorded identity even when a recycled address is shared'
[ "$(fm_backend_herdr_core_agent_state 'default:t1' beta)" = alive ] \
  || fail 'a live task is alive through its own recorded identity'
out=$(fm_backend_herdr_core_task_closed 'default:t1' beta 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a live task must refuse to retire the records of the endpoint it still owns'
assert_contains "$out" 'still present' 'the live owner still owns its recorded address'
# A read that names no task cannot tell the two recorded owners apart, so it
# refuses as unverifiable instead of projecting one task's state onto the other.
fm_backend_herdr_core_recorded_core_id 'default:t1' >/dev/null 2>&1 && ambiguous_rc=0 || ambiguous_rc=$?
[ "$ambiguous_rc" -eq 2 ] || fail "an address two tasks recorded without a task id must be ambiguous (rc=$ambiguous_rc)"
fm_backend_herdr_core_status_json 'default:t1' >/dev/null 2>&1 && ambiguous_status_rc=0 || ambiguous_status_rc=$?
[ "$ambiguous_status_rc" -eq 5 ] \
  || fail "an ambiguous recorded identity must be unverifiable, not another task's state (rc=$ambiguous_status_rc)"
[ "$(fm_backend_herdr_core_agent_state 'default:t1')" = unreadable ] \
  || fail "an ambiguous recorded identity must not resolve to one task's state"
[ "$(fm_backend_herdr_core_endpoint_ownership 'default:t1' beta)" = ours ] \
  || fail 'the task that records the address owns it'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
fm_backend_herdr_core_kill 'default:t1' '' 'sq-beta' \
  || fail 'the task whose metadata records the live address must be able to close it'
assert_grep 'kill t1' "$SQUAD_HC_KILL_LOG" 'the live owner closes its own recorded address'
assert_grep 'rm t1' "$SQUAD_HC_KILL_LOG" 'the live owner removes its own recorded address'
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'a recycled window is resolved by the task own metadata, and ambiguity refuses'

# --- retiring a previous endpoint before a relaunch ------------------------

relaunch_meta() {  # <id> <address>
  fm_write_meta "$SQUAD_STATE_OVERRIDE/$1.meta" \
    "window=default:$2" "endpoint_task_id=$1" "worktree=$TMP_ROOT" \
    "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
    "hc_session=default" "hc_address=$2" "hc_core_id=core-a"
}

# A core restart leaves the task's own terminal as a finished husk. The relaunch
# must retire exactly that address, or it accumulates unmanaged terminals.
write_world
relaunch_meta relaunch t1
SQUAD_HC_LABEL_TASK=relaunch write_live_terminal t1 finished pi 'null'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
fm_backend_herdr_core_retire_endpoint 'default:t1' 'sq-relaunch' \
  || fail 'a finished previous endpoint must be retired before the relaunch'
assert_grep 'kill t1' "$SQUAD_HC_KILL_LOG" 'the finished husk is closed'
assert_grep 'rm t1' "$SQUAD_HC_KILL_LOG" 'the finished husk is removed'

# A harness that exits on its own leaves a live but agentless shell, which would
# otherwise refuse the replacement as a duplicate endpoint.
SQUAD_HC_LABEL_TASK=relaunch write_live_terminal t1 live bash 'null'
[ "$(fm_backend_herdr_core_agent_state 'default:t1')" = dead ] \
  || fail 'a live agentless shell is the dead state a relaunch proceeds from'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
fm_backend_herdr_core_retire_endpoint 'default:t1' 'sq-relaunch' \
  || fail 'a live agentless previous endpoint must be retired before the relaunch'
assert_grep 'kill t1' "$SQUAD_HC_KILL_LOG" 'the agentless shell is closed'
assert_grep 'rm t1' "$SQUAD_HC_KILL_LOG" 'the agentless shell is removed'

# An address the core authoritatively no longer has is already retired.
reset_calls
: > "$SQUAD_HC_KILL_LOG"
SQUAD_HC_GET_RC=3 fm_backend_herdr_core_retire_endpoint 'default:t1' 'sq-relaunch' \
  || fail 'an absent previous endpoint is already retired'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail 'an absent previous endpoint must not be closed'

# An address whose terminal now belongs to another task is no longer this task's
# previous endpoint at all: the relaunch proceeds and the stranger's terminal is
# never closed.
SQUAD_HC_LABEL_TASK=other write_live_terminal t1 live bash 'null'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
fm_backend_herdr_core_retire_endpoint 'default:t1' 'sq-relaunch' \
  || fail 'a previous endpoint that another task now owns is already retired'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail "another task's terminal must never be closed"

# A core restart moves the address into a new registry, so the live terminal at
# the recorded address is not the one this task created either.
SQUAD_HC_LABEL_TASK=relaunch write_live_terminal t1 live bash 'null'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
SQUAD_HC_CORE_ID=core-b fm_backend_herdr_core_retire_endpoint 'default:t1' 'sq-relaunch' \
  || fail 'an endpoint recorded against another core is already retired'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail "the new core's terminal must never be closed"
SQUAD_HC_CORE_ID=core-a

# A previous endpoint that still runs a verified agent is never killed by a
# relaunch, even when the caller asks: only a confidently agentless endpoint is
# retired.
SQUAD_HC_LABEL_TASK=relaunch write_live_terminal t1 live pi '{"app":"pi","state":"working"}'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
out=$(fm_backend_herdr_core_retire_endpoint 'default:t1' 'sq-relaunch' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a previous endpoint with a live agent must refuse the relaunch'
assert_contains "$out" 'may still be running a program' 'the refusal says the endpoint may still be running'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail 'a live agent must never be killed by a relaunch'
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'a relaunch retires its own previous endpoint and refuses a foreign one'

# teardown's confirmation reads the address once and classifies it: an address
# the core no longer has is closed, an address that still carries this task's own
# labels refuses, and an address whose terminal now belongs to another task, base
# or core is this task's endpoint being gone - teardown proceeds there and the
# stranger's terminal is never called "still present" nor touched. An unreadable
# core or an unverifiable identity still refuses, so a transient failure is never
# mistaken for a completed cleanup.
write_world
SQUAD_HC_GET_RC=3 fm_backend_herdr_core_task_closed 'default:t1' probe \
  || fail 'an absent address counts as closed'
out=$(fm_backend_herdr_core_task_closed 'default:t1' probe 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a still-present address must refuse the close'
assert_contains "$out" 'still present' 'the close refusal says the address is still there'
out=$(SQUAD_HC_GET_RC=1 fm_backend_herdr_core_task_closed 'default:t1' probe 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'an unreadable address must refuse the close'
assert_contains "$out" 'could not be read' 'an unreachable core is not reported as a present address'
assert_not_contains "$out" 'still present' 'an unreachable core must not claim the address is still there'

fm_write_meta "$SQUAD_STATE_OVERRIDE/recycled.meta" \
  "window=default:t1" "endpoint_task_id=probe" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-a"
( SQUAD_HC_LABEL_TASK=stranger write_live_terminal t1 live pi '{"app":"pi","state":"idle"}' )
reset_calls
: > "$SQUAD_HC_KILL_LOG"
out=$(fm_backend_herdr_core_task_closed 'default:t1' probe 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "an address recycled for another task's terminal is this task's endpoint being gone: $out"
assert_contains "$out" 'does not own' 'the recycled-address note names the ownership, not a still-present terminal'
assert_not_contains "$out" 'still present' "a stranger's terminal must never be called still present"
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail "teardown's confirmation must never close the stranger's terminal"

( SQUAD_HC_LABEL_TASK=probe SQUAD_HC_LABEL_BASE="$label_two" \
    write_live_terminal t1 live pi '{"app":"pi","state":"idle"}' )
reset_calls
out=$(fm_backend_herdr_core_task_closed 'default:t1' probe 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "an address recycled for another base's terminal is this task's endpoint being gone: $out"
assert_not_contains "$out" 'still present' "another base's terminal must never be called still present"

SQUAD_HC_LABEL_TASK=probe write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
SQUAD_HC_CORE_ID=core-b fm_backend_herdr_core_task_closed 'default:t1' probe >/dev/null 2>&1 \
  || fail 'a terminal in another core registry is this task endpoint being gone'
SQUAD_HC_CORE_ID=core-a
out=$(SQUAD_HC_STATUS_FAIL=1 fm_backend_herdr_core_task_closed 'default:t1' probe 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a recorded core id that cannot be verified must refuse the close'
assert_contains "$out" 'could not be read' 'an unverifiable core id is not reported as a present address'
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'teardown confirmation classifies absent, ours, foreign and unreadable'

# A recorded session other than this process die is refused, not resolved.
write_world
reset_calls
out=$(fm_backend_herdr_core_target_exists 'other:t1' 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a foreign recorded session must refuse'
case "$(call_log)" in *'get '*) fail 'a foreign session must not be addressed' ;; esac
pass 'a recorded session this process does not resolve is refused'

# --- agent state ----------------------------------------------------------

write_world
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
assert_contains "$(fm_backend_herdr_core_agent_state 'default:t1')" 'alive' 'a live harness is alive'
write_live_terminal t1 live bash 'null'
assert_contains "$(fm_backend_herdr_core_agent_state 'default:t1')" 'dead' 'a live shell is dead'
write_live_terminal t1 finished pi 'null'
assert_contains "$(fm_backend_herdr_core_agent_state 'default:t1')" 'dead' 'a finished terminal is dead'
SQUAD_HC_GET_RC=3 export SQUAD_HC_GET_RC
assert_contains "$(fm_backend_herdr_core_agent_state 'default:t1')" 'missing' 'an absent address is missing'
# An ad hoc address records no metadata, so the read itself is the only verdict
# authority: a failed read is unverifiable, never an authoritative absence.
SQUAD_HC_GET_RC=1 export SQUAD_HC_GET_RC
assert_contains "$(fm_backend_herdr_core_agent_state 'default:t1')" 'unreadable' 'a failed ad hoc read is unreadable'
[ "$(fm_backend_agent_alive herdr-core 'default:t1')" = unknown ] \
  || fail 'an unreadable ad hoc read must not report the agent as dead'
assert_contains "$(fm_backend_herdr_core_agent_state 'nocolon')" 'unreadable' 'a malformed target is unreadable'
SQUAD_HC_GET_RC=0 export SQUAD_HC_GET_RC
# A live address carrying another task's label is not THIS task's endpoint.
fm_write_meta "$SQUAD_STATE_OVERRIDE/target.meta" \
  "window=default:t1" "endpoint_task_id=target" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t1" "hc_core_id=core-a"
SQUAD_HC_LABEL_TASK=other write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
assert_contains "$(fm_backend_herdr_core_agent_state 'default:t1')" 'missing' 'a foreign label is missing for this task'
rm -f "$SQUAD_STATE_OVERRIDE"/*.meta
write_world
pass 'agent state separates alive, dead, missing and unreadable'

# --- key names ------------------------------------------------------------

case "$(fm_backend_herdr_core_key_name C-u)" in ctrl+u) ;; *) fail 'C-u maps to ctrl+u' ;; esac
case "$(fm_backend_herdr_core_key_name Enter)" in enter) ;; *) fail 'Enter maps to enter' ;; esac
case "$(fm_backend_herdr_core_key_name Escape)" in esc) ;; *) fail 'Escape maps to esc' ;; esac
case "$(fm_backend_herdr_core_key_name M-x)" in alt+x) ;; *) fail 'M-x maps to alt+x' ;; esac
if fm_backend_herdr_core_key_name 'XF86AudioMute' >/dev/null 2>&1; then
  fail 'an unmapped key must refuse rather than guess'
fi
write_world
fm_backend_herdr_core_send_key 'default:t1' 'C-c' '' || fail 'a mapped key send must succeed'
assert_grep 't1 ctrl+c' "$SQUAD_HC_KEYS_LOG" 'the key reaches the exact address in the product vocabulary'
pass 'key names are translated, and an unmapped key refuses'

# --- create_task ----------------------------------------------------------

write_world
export SQUAD_HC_NEW_ADDRESS=t7
address=$(fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT") || fail 'create_task must succeed'
[ "$address" = t7 ] || fail "create_task returns the opaque address (got '$address')"
run_line=$(grep -F 'run --bg' "$SQUAD_HC_LOG" | tail -1)
assert_contains "$run_line" '--no-parent' 'create_task always passes --no-parent'
assert_contains "$run_line" '--label squad.task=probe' 'create_task labels the task'
assert_contains "$run_line" '--label squad.base=' 'create_task labels the base'
assert_contains "$run_line" "--cwd $TMP_ROOT" 'create_task passes the recorded worktree as cwd'

write_list_all t9 live probe "$BASE_LABEL"
cp "$TMP_ROOT/list-all.json" "$SQUAD_HC_LIST"
reset_calls
out=$(fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'create_task must refuse a duplicate live task label'
assert_contains "$out" 'refusing a duplicate endpoint' 'the duplicate refusal names the reason'
case "$(call_log)" in *'run '* ) fail 'a duplicate refusal must not create a terminal' ;; esac

# Another Squad base on the same core numbers its tasks from 1 too, so a
# terminal carrying this task id under a different squad.base is not this base's
# duplicate and must not block the spawn.
write_list_all t9 live probe other
cp "$TMP_ROOT/list-all.json" "$SQUAD_HC_LIST"
address=$(SQUAD_HC_NEW_ADDRESS=t8 fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT") \
  || fail "another base's terminal with the same task id is not this base's duplicate"
[ "$address" = t8 ] || fail "create_task returns the new opaque address (got '$address')"

printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
out=$(fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT/missing" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'create_task must refuse a missing directory'

export SQUAD_HC_NEW_ADDRESS=.t7
out=$(fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'create_task must refuse an address the adapter cannot address'
assert_contains "$out" 'usable opaque address' 'the unusable-address refusal names the reason'
unset SQUAD_HC_NEW_ADDRESS

# A create that succeeds while the product also writes a notice on stderr still
# yields its address: only stdout is parsed as JSON.
reset_calls
: > "$SQUAD_HC_KILL_LOG"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
address=$(SQUAD_HC_NEW_ADDRESS=t7 SQUAD_HC_RUN_STDERR='notice: registry compacted' \
  fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT") \
  || fail 'a stderr notice must not hide a successful create'
[ "$address" = t7 ] || fail "a create with a stderr notice still returns its address (got '$address')"
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail 'a successful create must not close anything'

# The product documents that a failed `hc run` may still have run the program, so
# the terminal it created is resolved by its unique task label and closed exactly.
SQUAD_HC_LABEL_TASK=probe write_live_terminal t7 live pi '{"app":"pi","state":"idle"}'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
out=$(SQUAD_HC_RUN_FAIL=1 SQUAD_HC_RUN_REGISTERS=1 SQUAD_HC_NEW_ADDRESS=t7 \
  fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a failed hc run must refuse'
assert_contains "$out" 'that name is taken' 'the create refusal relays the product message'
assert_grep 'kill t7' "$SQUAD_HC_KILL_LOG" 'the unrecorded terminal is closed by its exact address'
assert_grep 'rm t7' "$SQUAD_HC_KILL_LOG" 'the unrecorded terminal is removed by its exact address'

# The same recovery runs when the create output carries no usable address: the
# inventory, not the unreadable output, names what has to be closed.
SQUAD_HC_LABEL_TASK=probe write_live_terminal t7 live pi '{"app":"pi","state":"idle"}'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
out=$(SQUAD_HC_RUN_REGISTERS=1 SQUAD_HC_RUN_REGISTER_ADDRESS=t7 SQUAD_HC_NEW_ADDRESS=.t7 \
  fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'an unusable reported address must refuse'
assert_contains "$out" 'usable opaque address' 'the unusable-address refusal names the reason'
assert_grep 'kill t7' "$SQUAD_HC_KILL_LOG" 'the terminal an unusable address hid is closed by the address the inventory reports'

# The failed create may already have run to completion, so a terminal that is
# already `finished` is invisible to a live-only listing but is still recovered
# by the same exact close.
SQUAD_HC_LABEL_TASK=probe write_live_terminal t7 finished pi 'null'
write_list_all t7 finished probe "$BASE_LABEL"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
out=$(SQUAD_HC_LIST_ALL="$TMP_ROOT/list-all.json" SQUAD_HC_NEW_ADDRESS=.t7 \
  fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'an unusable reported address must refuse'
assert_contains "$out" 'usable opaque address' 'the unusable-address refusal names the reason'
assert_grep 'kill t7' "$SQUAD_HC_KILL_LOG" 'a finished unrecorded terminal is closed too'
assert_grep 'rm t7' "$SQUAD_HC_KILL_LOG" 'a finished unrecorded terminal is removed too'

# The recovery inventory is base-scoped: a second base's terminal that happens to
# carry this task id is not this base's create and must never be closed.
write_list_all t8 finished probe other
reset_calls
: > "$SQUAD_HC_KILL_LOG"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
out=$(SQUAD_HC_LIST_ALL="$TMP_ROOT/list-all.json" SQUAD_HC_NEW_ADDRESS=.t8 \
  fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'an unusable reported address must refuse'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail "another base's terminal must never be closed by this base's recovery (saw: $(cat "$SQUAD_HC_KILL_LOG"))"
write_list_all t7 finished probe "$BASE_LABEL"

# The address the inventory names is re-checked against its own task label, so a
# core that recycled that address between the listing and the close leaves the
# stranger alone and reports the address to retire by hand.
SQUAD_HC_LABEL_TASK=stranger write_live_terminal t7 finished pi 'null'
reset_calls
: > "$SQUAD_HC_KILL_LOG"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
out=$(SQUAD_HC_LIST_ALL="$TMP_ROOT/list-all.json" SQUAD_HC_NEW_ADDRESS=.t7 \
  fm_backend_herdr_core_create_task default 'sq-probe' "$TMP_ROOT" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'an unusable reported address must refuse'
assert_contains "$out" 'could not close the herdr-core terminal' 'an unclosable recycled address is reported, not swallowed'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail 'a recycled address carrying another task label must never be closed'
rm -f "$TMP_ROOT/list-all.json"

short_name=$(fm_backend_herdr_core_name_for_task 'short-id')
[ "$short_name" = "sq-$BASE_HASH-short-id" ] \
  || fail "a clean short task id is named directly under its base (got '$short_name')"
# The product's name registry is core-global while every base numbers its tasks
# from the same start, so the name carries the base identity too: bases A and B
# both spawning task `1` must not both ask for `sq-1` and collide on name_taken.
name_one=$( ( SQUAD_BASE="$TMP_ROOT/one/squad"; fm_backend_herdr_core_name_for_task '1' ) )
name_two=$( ( SQUAD_BASE="$TMP_ROOT/two/squad"; fm_backend_herdr_core_name_for_task '1' ) )
[ "$name_one" != "$name_two" ] \
  || fail "the same task id in two bases must get different terminal names (got '$name_one')"
for name in "$name_one" "$name_two"; do
  [ "${#name}" -le 32 ] || fail "a base-scoped name must fit the 32-character limit (got '$name')"
  case "$name" in *[!a-z0-9_-]*) fail "a name may only use a-z 0-9 - _ (got '$name')" ;; esac
done
# The id shapes `demo` and `sq-demo` both exist, so a name built by stripping the
# prefix is not injective: the id's own slug is kept, so the two ids get two
# distinct names instead of both claiming `sq-demo`.
plain_name=$(fm_backend_herdr_core_name_for_task 'demo')
prefixed_name=$(fm_backend_herdr_core_name_for_task 'sq-demo')
[ "$plain_name" != "$prefixed_name" ] || fail "the ids demo and sq-demo must not share one terminal name (got '$plain_name')"
for name in "$plain_name" "$prefixed_name"; do
  [ "${#name}" -le 32 ] || fail "a task name must fit the 32-character limit (got '$name')"
  case "$name" in *[!a-z0-9_-]*) fail "a name may only use a-z 0-9 - _ (got '$name')" ;; esac
done
long_name=$(fm_backend_herdr_core_name_for_task 'a-very-long-task-id-that-exceeds-the-limit')
[ "${#long_name}" -le 32 ] || fail "a long task id must fit the 32-character name limit (got '$long_name')"
other_name=$(fm_backend_herdr_core_name_for_task 'a-very-long-task-id-that-exceeds-the-limi')
[ "$long_name" != "$other_name" ] || fail 'two long task ids must not share one name'
case "$long_name" in *[!a-z0-9_-]*) fail "a name may only use a-z 0-9 - _ (got '$long_name')" ;; esac
pass 'create_task is exact, labelled, duplicate-safe and name-limited'

# --- transition producer --------------------------------------------------

STATE_DIR="$TMP_ROOT/transition-state"
mkdir -p "$STATE_DIR"
WINDOW='default:t1'
write_world
write_live_terminal t1 live pi '{"app":"pi","state":"blocked","kind":"permission","msg":"Allow rm?"}'
record=$(fm_backend_herdr_core_poll_transition "$STATE_DIR" default "$WINDOW") || fail 'a blocked report must produce a record'
assert_contains "$record" 'blocked' 'the record is a blocked edge'
fm_backend_herdr_core_commit_transition "$STATE_DIR" default "$record"
out=$(fm_backend_herdr_core_poll_transition "$STATE_DIR" default "$WINDOW") && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "the same prompt must not wake twice (rc=$rc)"
write_live_terminal t1 live pi '{"app":"pi","state":"blocked","kind":"question","msg":"Pick 1 or 2"}'
record=$(fm_backend_herdr_core_poll_transition "$STATE_DIR" default "$WINDOW") \
  || fail 'a changed prompt must wake again even while blocked'
assert_contains "$record" 'blocked' 'the changed prompt is a fresh blocked edge'
fm_backend_herdr_core_commit_transition "$STATE_DIR" default "$record"
write_live_terminal t1 live pi '{"app":"pi","state":"idle"}'
out=$(fm_backend_herdr_core_poll_transition "$STATE_DIR" default "$WINDOW") && rc=0 || rc=$?
[ "$rc" -eq 2 ] || fail "an idle report falls through to the ordinary poll (rc=$rc)"
write_live_terminal t1 live pi '{"app":"pi","state":"blocked","kind":"permission","msg":"Allow rm?"}'
record=$(fm_backend_herdr_core_poll_transition "$STATE_DIR" default "$WINDOW") \
  || fail 'a non-blocked edge must clear the dedupe so the next block wakes again'
fm_backend_herdr_core_clear_transition "$STATE_DIR" "$WINDOW"
[ -z "$(find "$STATE_DIR" -name '.herdr-core-*' -print -quit)" ] || fail 'clear_transition removes both markers'
pass 'the poll producer dedupes one prompt and wakes again on a new one'

# --- endpoint metadata validation ----------------------------------------

meta="$SQUAD_STATE_OVERRIDE/meta.meta"
fm_write_meta "$meta" \
  "window=default:t5" "endpoint_task_id=meta" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t5" "hc_core_id=core-a"
fm_backend_validate_task_endpoint "$meta" meta || fail 'a complete herdr-core record validates'
[ "$SQUAD_BACKEND_VALIDATED_TARGET" = 'default:t5' ] || fail 'validation reports the recorded target'
[ "$SQUAD_BACKEND_VALIDATED_BACKEND" = herdr-core ] || fail 'validation reports the recorded backend'

fm_write_meta "$meta" \
  "window=default:t5" "endpoint_task_id=meta" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t6" "hc_core_id=core-a"
out=$(fm_backend_validate_task_endpoint "$meta" meta 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'an address that does not match window= must be refused'
assert_contains "$out" 'malformed or inconsistent' 'the mismatch refusal names the shape'

fm_write_meta "$meta" \
  "window=default:.t5" "endpoint_task_id=meta" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=.t5" "hc_core_id=core-a"
out=$(fm_backend_validate_task_endpoint "$meta" meta 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'an address the adapter cannot address must be refused'
assert_contains "$out" 'malformed or inconsistent' 'the unusable-address refusal names the shape'

fm_write_meta "$meta" \
  "window=default:t5" "endpoint_task_id=meta" "worktree=$TMP_ROOT" \
  "project=$TMP_ROOT" "harness=pi" "kind=strike" "backend=herdr-core" \
  "hc_session=default" "hc_address=t5"
out=$(fm_backend_validate_task_endpoint "$meta" meta 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail 'a record without a core id must be refused'
rm -f "$meta"
pass 'herdr-core endpoint metadata requires the full triple'

# --- the no-start rule across every primitive ----------------------------

reset_calls
for primitive in \
  'fm_backend_herdr_core_capture default:t1 5' \
  'fm_backend_herdr_core_busy_state default:t1' \
  'fm_backend_herdr_core_target_exists default:t1' \
  'fm_backend_herdr_core_agent_state default:t1' \
  'fm_backend_herdr_core_send_text_line default:t1 hi'; do
  # shellcheck disable=SC2086 # each fixture is a deliberate argv split
  ( XDG_RUNTIME_DIR="$TMP_ROOT/empty-runtime" $primitive ) >/dev/null 2>&1 && rc=0 || rc=$?
  case "${primitive%% *} $primitive" in
    # The verdict primitives always answer with a verdict rather than a status;
    # what matters is that they answer "not there" and never reach the CLI.
    *busy_state*) : ;;
    *agent_state*) : ;;
    *) [ "$rc" -ne 0 ] || fail "primitive '$primitive' must fail without a listening core" ;;
  esac
done
verdict=$( XDG_RUNTIME_DIR="$TMP_ROOT/empty-runtime" fm_backend_herdr_core_busy_state 'default:t1' )
[ "$verdict" = unknown ] || fail "busy state without a core is unknown (got '$verdict')"
verdict=$( XDG_RUNTIME_DIR="$TMP_ROOT/empty-runtime" fm_backend_herdr_core_agent_state 'default:t1' )
# No core listening is an unverifiable read, not an absent endpoint: `missing`
# would let a caller replace an endpoint this process cannot see.
[ "$verdict" = unreadable ] \
  || fail "agent state without a core must be unreadable (got '$verdict')"
[ ! -s "$SQUAD_HC_LOG" ] || fail "no primitive may invoke hc without a listening core (saw: $(call_log))"
pass 'no primitive invokes hc without a listening core'

# --- the lab tripwire never starts the ambient core -----------------------
# The lab's tripwire reads the commander's default core before and after the
# run. A socket file left behind by a dead core is not a running core, so the
# next `hc` call would start one with the lab's environment; the tripwire must
# refuse through the adapter's listener probe instead of trusting the socket.
stale_runtime="$TMP_ROOT/lab-stale-runtime"
mkdir -p "$stale_runtime/herdr-core" "$TMP_ROOT/lab-project"
"$PY" - "$stale_runtime/herdr-core/default.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.close()
PY
[ -S "$stale_runtime/herdr-core/default.sock" ] || fail 'could not create the stale default-core socket fixture'
reset_calls
lab_out=$(SQUAD_HC_LAB=1 SQUAD_HC_LAB_PROJECT="$TMP_ROOT/lab-project" XDG_RUNTIME_DIR="$stale_runtime" \
  "$ROOT/bin/sq-herdr-core-lab.sh" 2>&1) && lab_rc=0 || lab_rc=$?
[ "$lab_rc" -ne 0 ] || fail 'the lab must refuse a stale default-core socket'
[ ! -s "$SQUAD_HC_LOG" ] || fail "the lab tripwire invoked hc on a socket with no listener (saw: $(call_log))"
assert_contains "$lab_out" 'no listener answers' 'the lab names the stale-socket refusal'
pass 'the lab tripwire refuses a stale default-core socket without invoking hc'

# --- the launch delivery owns the terminal it created ---------------------
# The task endpoint is created and recorded before the launch line is delivered,
# so the abort cleanup must stay armed through that delivery. A refused launch has
# to close the exact address it created instead of exiting with a live labelled
# terminal behind a published record and no exec_state=running to retry from.

spawn_case() {  # <name> <id> [extra-setup-fn] -> "case-dir"
  local name=$1 id=$2 dir proj wt base
  dir="$TMP_ROOT/spawn-$name"
  proj="$dir/project"
  wt="$dir/wt"
  base="$dir/mybase"
  mkdir -p "$base/data/$id" "$base/state" "$base/config" "$base/projects" "$proj"
  printf 'bash\n' > "$base/config/crew-harness"
  printf '# brief\n\nraw launch probe for %s\n\nReport status by appending one line:\n\n    echo "{state}: {note}" >> %s/%s.status\n' \
    "$id" "$base/state" "$id" > "$base/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s|%s\n' "$dir" "$base" "$proj" "$wt" "$id"
}

run_spawn_case() {  # <case-record> <launch-command>
  local dir base proj wt id
  IFS='|' read -r dir base proj wt id <<EOF
$1
EOF
  SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$base" \
    SQUAD_STATE_OVERRIDE="$base/state" SQUAD_DATA_OVERRIDE="$base/data" \
    SQUAD_PROJECTS_OVERRIDE="$base/projects" SQUAD_CONFIG_OVERRIDE="$base/config" \
    XDG_RUNTIME_DIR="$TMP_ROOT/r" SQUAD_SPAWN_NO_GUARD=1 \
    SQUAD_FAKE_FOB_LOG="$dir/fob.log" SQUAD_FAKE_FOB_LEASE="$wt" \
    SQUAD_HC_LEASE="$wt" \
    "$ROOT/bin/sq-spawn.sh" "$id" "$proj" "$2" --backend herdr-core --recon 2>&1
}

# The terminal the spawn creates is address t2, carrying this task's own labels;
# a silent program keeps delivery on the composer path the spawn uses.
seed_spawn_terminal() {  # <case-record>
  local dir base proj wt id
  IFS='|' read -r dir base proj wt id <<EOF
$1
EOF
  jq -cn --arg address t2 --arg id "$id" --arg base "$(base_label_for "$base")" --arg cwd "$proj" '
    {address:$address,state:"live",
     labels:{"squad.task":$id,"squad.base":$base},
     foreground:{argv:["bash"],cwd:$cwd,name:"bash",pid:4242},
     reported:false,status_ms:0,turn:0,title:"t"}' > "$SQUAD_HC_GET"
  printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
}

case_record=$(spawn_case launch-refused spawn-launch-refused)
seed_spawn_terminal "$case_record"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
spawn_out=$(SQUAD_HC_SEND_FAIL_MATCH='LAUNCH-REFUSED-MARKER' \
  SQUAD_HC_NEW_ADDRESS=t2 run_spawn_case "$case_record" 'bash -c LAUNCH-REFUSED-MARKER') && spawn_rc=0 || spawn_rc=$?
[ "$spawn_rc" -ne 0 ] || fail 'a refused launch delivery must fail the spawn'
assert_contains "$spawn_out" 'did not submit the line' 'the failed launch names the refused delivery'
assert_grep 'kill t2' "$SQUAD_HC_KILL_LOG" 'a refused launch must close the terminal it created'
assert_grep 'rm t2' "$SQUAD_HC_KILL_LOG" 'a refused launch must remove the terminal it created'
pass 'a refused launch delivery closes the exact terminal the spawn created'

case_record=$(spawn_case launch-delivered spawn-launch-delivered)
seed_spawn_terminal "$case_record"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
spawn_out=$(SQUAD_HC_NEW_ADDRESS=t2 run_spawn_case "$case_record" 'bash -c LAUNCH-DELIVERED-MARKER') && spawn_rc=0 || spawn_rc=$?
[ "$spawn_rc" -eq 0 ] || fail "a delivered launch must spawn cleanly: $spawn_out"
assert_contains "$spawn_out" 'spawned spawn-launch-delivered' 'a delivered launch reports the spawn'
[ ! -s "$SQUAD_HC_KILL_LOG" ] || fail 'a delivered launch must not close its own terminal'
case "$(call_log)" in
  *'LAUNCH-DELIVERED-MARKER'*) ;;
  *) fail 'the launch command must be delivered through hc send' ;;
esac
pass 'a delivered launch leaves its terminal in place'

# Codex must run with --no-daemon under herdr-core, or the commands it runs
# execute outside hc's terminal and disappear from its record. The flag is this
# backend's alone: the same harness on tmux keeps its original launch line.
codex_record=$(spawn_case codex spawn-codex)
seed_spawn_terminal "$codex_record"
reset_calls
spawn_out=$(SQUAD_HC_NEW_ADDRESS=t2 run_spawn_case "$codex_record" codex) && spawn_rc=0 || spawn_rc=$?
[ "$spawn_rc" -eq 0 ] || fail "a codex launch on herdr-core must spawn cleanly: $spawn_out"
case "$(call_log)" in
  *'codex --no-daemon '*) ;;
  *) fail "codex on herdr-core must be delivered with --no-daemon (log: $(call_log))" ;;
esac
pass 'codex on herdr-core launches with --no-daemon'

# A relaunch retires the endpoint the task still records before it creates the
# replacement, so a finished husk does not accumulate and a live agentless shell
# does not refuse the new terminal as a duplicate.
relaunch_record=$(spawn_case relaunch spawn-relaunch)
IFS='|' read -r _ relaunch_base relaunch_proj relaunch_wt relaunch_id <<EOF
$relaunch_record
EOF
jq -cn --arg address t2 --arg id "$relaunch_id" --arg base "$(base_label_for "$relaunch_base")" '
  {address:$address,state:"finished",
   labels:{"squad.task":$id,"squad.base":$base},
   reported:false,status_ms:0,turn:0,title:"t",reason:"exited"}' > "$SQUAD_HC_GET"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
fm_write_meta "$relaunch_base/state/$relaunch_id.meta" \
  "window=default:t2" "endpoint_task_id=$relaunch_id" "worktree=$relaunch_wt" \
  "project=$relaunch_proj" "harness=bash" "kind=recon" "backend=herdr-core" \
  "hc_session=default" "hc_address=t2" "hc_core_id=core-a"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
spawn_out=$(SQUAD_HC_NEW_ADDRESS=t3 \
  SQUAD_HC_RUN_GET_TASK="$relaunch_id" SQUAD_HC_RUN_GET_BASE="$(base_label_for "$relaunch_base")" \
  SQUAD_HC_RUN_GET_CWD="$relaunch_proj" \
  run_spawn_case "$relaunch_record" 'bash -c RELAUNCH-MARKER') && spawn_rc=0 || spawn_rc=$?
[ "$spawn_rc" -eq 0 ] || fail "a relaunch over a retired endpoint must spawn cleanly: $spawn_out"
assert_grep 'kill t2' "$SQUAD_HC_KILL_LOG" 'the relaunch retires the finished previous endpoint'
assert_grep 'rm t2' "$SQUAD_HC_KILL_LOG" 'the relaunch removes the finished previous endpoint'
assert_grep 'hc_address=t3' "$relaunch_base/state/$relaunch_id.meta" 'the relaunch records the replacement address'
case "$(cat "$SQUAD_HC_KILL_LOG")" in
  *'t3'*) fail 'the relaunch must not close the replacement it just created' ;;
esac
pass 'a relaunch retires its previous endpoint before creating the replacement'

# --- a cross-backend relaunch retires the old herdr-core endpoint ---------
# The relaunch guard allows an explicit --backend switch, so the shared relaunch
# path retires the OLD recorded endpoint through its own backend before the new
# arm creates anything. Relaunching a dead herdr-core task onto tmux must close
# exactly the recorded address and create no herdr-core replacement.

cat > "$TMP_ROOT/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${SQUAD_FAKE_TMUX_LOG:?}"
case "${1:-}" in
  new-window) printf '%%7\n' ;;
  list-windows) : ;;
  send-keys)
    for a in "$@"; do
      if [ "$a" = 'fob get' ]; then
        printf '%s\n' "${SQUAD_FAKE_TMUX_WORKTREE:?}" > "${SQUAD_FAKE_TMUX_CWD:?}"
      fi
    done
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        '#S') printf 'Squad\n'; exit 0 ;;
        '#{pane_current_path}') cat "${SQUAD_FAKE_TMUX_CWD:?}"; exit 0 ;;
        '#{pane_current_command}') printf 'bash\n'; exit 0 ;;
      esac
    done
    ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$TMP_ROOT/fakebin/tmux"

run_cross_backend_spawn_case() {  # <case-record> <launch-command>
  local dir base proj wt id
  IFS='|' read -r dir base proj wt id <<EOF
$1
EOF
  SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$base" \
    SQUAD_STATE_OVERRIDE="$base/state" SQUAD_DATA_OVERRIDE="$base/data" \
    SQUAD_PROJECTS_OVERRIDE="$base/projects" SQUAD_CONFIG_OVERRIDE="$base/config" \
    XDG_RUNTIME_DIR="$TMP_ROOT/r" SQUAD_SPAWN_NO_GUARD=1 \
    SQUAD_FAKE_TMUX_LOG="$dir/tmux.log" \
    SQUAD_FAKE_TMUX_CWD="$dir/tmux-cwd" \
    SQUAD_FAKE_TMUX_WORKTREE="$wt" \
    "$ROOT/bin/sq-spawn.sh" "$id" "$proj" "$2" --backend tmux --recon 2>&1
}

cross_record=$(spawn_case cross-backend cross-backend-relaunch)
IFS='|' read -r cross_dir cross_base cross_proj cross_wt cross_id <<EOF
$cross_record
EOF
printf '%s\n' "$cross_proj" > "$cross_dir/tmux-cwd"
jq -cn --arg address t2 --arg id "$cross_id" --arg base "$(base_label_for "$cross_base")" '
  {address:$address,state:"live",
   labels:{"squad.task":$id,"squad.base":$base},
   foreground:{argv:["bash"],cwd:"/tmp/work",name:"bash",pid:4242},
   reported:false,status_ms:0,turn:0,title:"t"}' > "$SQUAD_HC_GET"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
fm_write_meta "$cross_base/state/$cross_id.meta" \
  "window=default:t2" "endpoint_task_id=$cross_id" "worktree=$cross_wt" \
  "project=$cross_proj" "harness=bash" "kind=recon" "backend=herdr-core" \
  "hc_session=default" "hc_address=t2" "hc_core_id=core-a"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
spawn_out=$(run_cross_backend_spawn_case "$cross_record" 'bash -c CROSS-BACKEND-MARKER') && spawn_rc=0 || spawn_rc=$?
[ "$spawn_rc" -eq 0 ] || fail "a cross-backend relaunch over a dead endpoint must spawn cleanly: $spawn_out"
[ "$(cat "$SQUAD_HC_KILL_LOG")" = "kill t2
rm t2" ] \
  || fail "the cross-backend relaunch must close exactly the recorded herdr-core address (log: $(cat "$SQUAD_HC_KILL_LOG"))"
case "$(call_log)" in
  *'run '*) fail 'a cross-backend relaunch must not create a herdr-core replacement' ;;
esac
[ -z "$(sed -n 's/^hc_address=//p' "$cross_base/state/$cross_id.meta")" ] \
  || fail 'the tmux relaunch must not keep a herdr-core address in the replacement record'
assert_grep 'CROSS-BACKEND-MARKER' "$cross_dir/tmux.log" 'the replacement launch goes to the new backend'
pass 'a cross-backend relaunch retires the recorded herdr-core endpoint'

# The codex --no-daemon flag is herdr-core's alone: the same harness launched on
# tmux keeps its original line, so the exception cannot leak onto another backend.
codex_tmux_record=$(spawn_case codex-tmux spawn-codex-tmux)
IFS='|' read -r codex_tmux_dir _ codex_tmux_proj _ _ <<EOF
$codex_tmux_record
EOF
printf '%s\n' "$codex_tmux_proj" > "$codex_tmux_dir/tmux-cwd"
codex_tmux_out=$(run_cross_backend_spawn_case "$codex_tmux_record" codex) && spawn_rc=0 || spawn_rc=$?
[ "$spawn_rc" -eq 0 ] || fail "a codex launch on tmux must spawn cleanly: $codex_tmux_out"
assert_grep 'codex ' "$codex_tmux_dir/tmux.log" 'the codex launch goes to the tmux backend'
case "$(cat "$codex_tmux_dir/tmux.log")" in
  *'--no-daemon'*) fail '--no-daemon must not leak onto another backend' ;;
esac
pass 'codex on tmux keeps its original launch without --no-daemon'

# --- a refused relaunch leaves the recorded endpoint alone ----------------
# Retirement is destructive, so it must run only after every relaunch refusal
# has been cleared. A released task over a dead herdr-core endpoint is refused,
# and the terminal it still records must survive that refusal.

refused_record=$(spawn_case relaunch-refused-rel released-husk)
IFS='|' read -r refused_dir refused_base refused_proj refused_wt refused_id <<EOF
$refused_record
EOF
printf '%s\n' "$refused_proj" > "$refused_dir/tmux-cwd"
jq -cn --arg address t2 --arg id "$refused_id" --arg base "$(base_label_for "$refused_base")" '
  {address:$address,state:"finished",
   labels:{"squad.task":$id,"squad.base":$base},
   reported:false,status_ms:0,turn:0,title:"t",reason:"exited"}' > "$SQUAD_HC_GET"
printf '{"terminals":[]}\n' > "$SQUAD_HC_LIST"
fm_write_meta "$refused_base/state/$refused_id.meta" \
  "window=default:t2" "endpoint_task_id=$refused_id" "worktree=$refused_wt" \
  "project=$refused_proj" "harness=bash" "kind=recon" "backend=herdr-core" \
  "hc_session=default" "hc_address=t2" "hc_core_id=core-a"
printf 'exec_state=released\n' > "$refused_base/state/$refused_id.exec"
reset_calls
: > "$SQUAD_HC_KILL_LOG"
spawn_out=$(run_cross_backend_spawn_case "$refused_record" 'bash -c RELEASED-REFUSED-MARKER') && spawn_rc=0 || spawn_rc=$?
[ "$spawn_rc" -ne 0 ] || fail 'a released task must still refuse a relaunch'
assert_contains "$spawn_out" "task $refused_id is released; refusing relaunch" 'the refused relaunch names the release'
[ ! -s "$SQUAD_HC_KILL_LOG" ] \
  || fail "a refused relaunch must leave the recorded endpoint alone (log: $(cat "$SQUAD_HC_KILL_LOG"))"
assert_grep "hc_address=t2" "$refused_base/state/$refused_id.meta" 'a refused relaunch keeps the recorded address'
pass 'a refused relaunch leaves the recorded herdr-core endpoint in place'

# --- forced XO cleanup closes a herdr-core child as the child base --------
# A child spawned inside an XO home records SQUAD_BASE=$home, so its terminal
# carries that home's base label. Forced teardown must verify the close as the
# child base (not the parent's) and may retire the child record only once the
# exact address is gone; otherwise a live terminal is left on the shared core.

test_forced_XO_teardown_closes_herdr_core_child_as_its_home() {
  local dir state data config home project fakebin out status child_label
  dir="$TMP_ROOT/teardown-herdr-core-XO-child"
  state="$dir/state" data="$dir/data" config="$dir/config"
  home="$dir/XO-home" project="$dir/project" fakebin="$dir/fakebin"
  mkdir -p "$state" "$data" "$config" "$home/state" "$home/data" "$home/config" \
    "$home/projects" "$project" "$fakebin"
  printf 'smhc\n' > "$home/.sq-xo-home"
  fm_write_meta "$state/smhc.meta" \
    "window=Squad:sq-smhc" "endpoint_task_id=smhc" "backend=tmux" \
    "worktree=$home" "project=$home" "kind=xo" "mode=xo" "home=$home"
  fm_write_meta "$home/state/childhc.meta" \
    "window=default:t7" "endpoint_task_id=childhc" "backend=herdr-core" \
    "hc_session=default" "hc_address=t7" "hc_core_id=core-a" \
    "worktree=$dir/missing-child-worktree" "project=$project" "kind=strike"
  child_label=$(base_label_for "$home")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  unset SQUAD_HC_GET_RC SQUAD_HC_GET_COUNT SQUAD_HC_GET_FAIL_AFTER \
    SQUAD_HC_KILL_FAIL SQUAD_HC_RM_FAIL
  jq -cn --arg id childhc --arg base "$child_label" '
    {address:"t7",state:"live",labels:{"squad.task":$id,"squad.base":$base},
     foreground:{argv:["bash"],cwd:"/tmp",name:"bash",pid:4242},
     reported:false,status_ms:0,turn:0,title:"t"}' > "$SQUAD_HC_GET"
  jq -c '.state="finished" | .reason="killed"' "$SQUAD_HC_GET" > "$dir/kill-swap.json"
  : > "$SQUAD_HC_KILL_LOG"
  out=$( PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_DATA_OVERRIDE="$data" \
    SQUAD_CONFIG_OVERRIDE="$config" SQUAD_ROOT_OVERRIDE="$ROOT" \
    XDG_RUNTIME_DIR="$TMP_ROOT/r" SQUAD_HC_KILL_SWAP="$dir/kill-swap.json" \
    "$ROOT/bin/sq-teardown.sh" smhc --force 2>&1 ) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "sq-teardown should force-retire an XO with a herdr-core child: $out"
  assert_grep 'kill t7' "$SQUAD_HC_KILL_LOG" 'forced XO cleanup must close the herdr-core child address'
  assert_grep 'rm t7' "$SQUAD_HC_KILL_LOG" 'forced XO cleanup must remove the herdr-core child address'
  [ ! -e "$home/state/childhc.meta" ] || fail 'forced XO cleanup must retire the closed child record'
  pass 'forced XO teardown closes a herdr-core child as the child home base'
}

test_forced_XO_teardown_closes_herdr_core_child_as_its_home

printf 'ok - herdr-core adapter contract\n'
