#!/usr/bin/env bash
# bin/backends/herdr-core.sh - the herdr-core (`hc`) session-provider adapter.
#
# herdr-core owns terminal endpoints only. Squad and fob keep task identity,
# task state, and the isolated git worktree, exactly as on every other
# session-provider backend. A persisted target is
# `<hc-session>:<opaque-address>`; the address is never parsed, never assumed
# numeric, and never treated as an identity (design: the approved report at
# data/squad-herdr-core-adapter-recon/report.md, sections 2, 3 and 5).
#
# Behavior contract (docs/herdr-core-backend.md owns the prose, and
# docs/verification/runtime-backends.md owns the live evidence):
#
#   * NEVER START A CORE. Any `hc` call starts a core when none is running, and
#     a core started that way inherits the caller's whole environment, including
#     credentials and backend markers (report trap T1). Every call this adapter
#     makes therefore runs only after the session's socket exists AND a probe
#     that cannot start a core proves a listener answers on it: a socket file a
#     dead core left behind is not a running core. When either test fails the
#     adapter refuses and says who must start the core, and when no unix-socket
#     probe client exists it fails closed rather than risking a start.
#   * VERSION AND PROTOCOL GUARD. Before a task is created, the adapter
#     handshakes one `hello` for protocol generation 1, refuses a version below
#     the measured floor, and refuses any core whose own catalog lacks a method,
#     a parameter, or a feature this adapter calls. A named refusal, never a
#     silent degradation.
#   * ADDRESS-EXACT ONLY. Every write names one opaque address that Squad
#     created. No destructive call ever takes `--all`, never a server-global
#     verb, never a name selector and never another program's terminal. The
#     only `--all` reads are label-filtered and read-only: the failed-create
#     inventory (`hc ls --all --json --label squad.task=<id> --label
#     squad.base=<base>`), which closes nothing until that address's own labels
#     agree, and the lab's tripwire. Both inventories are scoped by the base, so
#     a second Squad base sharing the core is neither a duplicate nor a target.
#     The base value is the readable base label plus a short hash of the physical
#     base path, so two bases with the same directory name never share it.
#     The cleanup identity is the quadruple (recorded address, `squad.task=<id>`
#     label, `squad.base=<base>` label, recorded core id), checked immediately
#     before `kill` and again before `rm`. The task label alone is not unique
#     across bases, so every close requires the base label too, defaulting to
#     this base's own.
#   * A RELAUNCH RETIRES ITS OWN PREVIOUS ENDPOINT. Before a replacement is
#     created, the exact recorded address this task still owns is closed through
#     the same identity-checked path, so neither a finished husk nor a live
#     agentless shell is left unmanaged on the shared core. An endpoint that is
#     ambiguous or still runs a verified agent refuses the relaunch.
#   * Status is the program's own OSC 7501 report. `busy_state` maps it, and
#     `blocked` is a person-needed verdict, never ordinary work. A lane that
#     reports no status is supervised by polling exactly as a tmux lane is.
#   * PRESENTATION IS TWO OPTIONAL LABELS ON ONE TERMINAL AND ONE TITLE ON
#     ITS TAB. When the local config/herdr-core-space setting names a desktop
#     space, the terminal this adapter just created also carries
#     `herdr.space=<space>` and `herdr.tab=<the base-scoped name its terminal is
#     created with>`, which is what makes the app show it: a measured `hc run
#     --bg --no-parent` terminal with no pane joins that space as its own tab
#     and needs neither `--keep` nor an attach. The label names the tab's ID, so
#     a relaunch returns to the same tab; it is never the tab's visible title.
#     The title is one more write, the app's own `tab.rename` addressed to that
#     exact tab id: it sets the task id a person reads at a glance instead of
#     the bare number the app draws for an unnamed tab. An absent or unreadable
#     setting means neither is written and nothing else changes. Both writes are
#     best-effort: neither fails a spawn, the label write is a plain set
#     (repeating it leaves the same state), and both name the one address and
#     the one tab this create just returned or derived. Clearing takes the
#     labels off and gives the tab its number back; the app's own `herdr-app do
#     terminal.park --terminal <address>` is what takes the pane away, because
#     adoption is one-way on the app's side (docs/herdr-core-backend.md owns the
#     measured transcript). Placement is deliberately outside the guard below: a
#     core whose CLI lacks the label command, or an app that is not running,
#     warns and keeps the task, because a missing display preference must never
#     block real work.
#
# Sourced only through bin/sq-backend.sh's fm_backend_source, never directly.
SQUAD_BACKEND_HERDR_CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=bin/sq-transition-lib.sh
. "$SQUAD_BACKEND_HERDR_CORE_ROOT/bin/sq-transition-lib.sh"
# shellcheck source=bin/sq-composer-lib.sh
. "$SQUAD_BACKEND_HERDR_CORE_ROOT/bin/sq-composer-lib.sh"
# shellcheck source=bin/sq-timeout-lib.sh
. "$SQUAD_BACKEND_HERDR_CORE_ROOT/bin/sq-timeout-lib.sh"

# What the guard demands of a core. Each literal is one contract this adapter
# calls: a generation, an oldest measured version, the RPC methods, the features
# and the parameters. Missing any one is a named refusal.
SQUAD_BACKEND_HERDR_CORE_GENERATION=1
SQUAD_BACKEND_HERDR_CORE_VERSION_FLOOR='0.1.22'
SQUAD_BACKEND_HERDR_CORE_REQUIRED_FEATURES='status events'
SQUAD_BACKEND_HERDR_CORE_REQUIRED_METHODS='terminal.run
terminal.get
terminal.list
terminal.read
terminal.send
terminal.keys
terminal.kill
terminal.rm
events.subscribe'
SQUAD_BACKEND_HERDR_CORE_REQUIRED_PARAMS='terminal.run:no_parent,labels,cwd,name
terminal.send:if,force
events.subscribe:labels'

# Squad's own labels. The task label is the identity a destructive step checks
# before it touches an address, and the base label is how one base lists only
# its own terminals (herdr-core has no workspace or session grouping of its own).
SQUAD_BACKEND_HERDR_CORE_TASK_LABEL='squad.task'
SQUAD_BACKEND_HERDR_CORE_BASE_LABEL='squad.base'

# The desktop app's own placement label, and the local setting that names the
# space it points at. The setting is commander-private config, never inferred:
# an absent or unreadable file means this adapter writes no app state at all.
SQUAD_BACKEND_HERDR_CORE_SPACE_LABEL='herdr.space'
SQUAD_BACKEND_HERDR_CORE_TAB_LABEL='herdr.tab'
SQUAD_BACKEND_HERDR_CORE_SPACE_CONFIG='herdr-core-space'

# The desktop app's own CLI, for the one presentation value that is not a core
# label. `hc` has no tab concept at all, so a tab's visible title can only be
# written by the app that owns the tab (docs/herdr-core-backend.md owns the
# measured contract). The suite points this at its own fake so no test can ever
# reach a person's real window.
SQUAD_BACKEND_HERDR_CORE_APP_BIN='herdr-app'

# The title is written once the app has adopted the labelled terminal as its own
# tab, and that adoption arrives on the core's event stream, so a create can
# reach the write before the tab exists. Only that one answer ("no tab") is
# retried, within this bounded budget; anything else is reported at once.
# Measured on herdr-app 0.1.18 against the live app: a freshly labelled tab
# first appeared 221 ms after the label write returned, while tab.rename
# answered `no tab` in 5 ms before it. The 0.2 s intervals cover about 1.4 s,
# more than six times that measurement, so an ordinary create lands the title in
# place; the whole write also shares one TITLE_TIMEOUT deadline, so a slow app
# cannot spend the timeout once per attempt.
SQUAD_BACKEND_HERDR_CORE_TITLE_ATTEMPTS=8
SQUAD_BACKEND_HERDR_CORE_TITLE_INTERVAL='0.2'
# A create runs the title write inline, so it carries the same hard bound as the
# adapter's other external client call: an app that blocks on a missing socket,
# a stalled write, or a starting window is reported like a refusal instead of
# holding the spawn open. It is the bound for the whole write, not per attempt.
SQUAD_BACKEND_HERDR_CORE_TITLE_TIMEOUT=5

# Per-target dedupe markers for the blocked-transition producer, keyed like the
# sentry's own .stale-<key> files.
SQUAD_BACKEND_HERDR_CORE_ESCALATED_PREFIX='.herdr-core-escalated-'
SQUAD_BACKEND_HERDR_CORE_PROMPT_PREFIX='.herdr-core-prompt-'

# --- the CLI, the session, and the no-start rule ---------------------------

fm_backend_herdr_core_bin() {
  printf '%s' "${SQUAD_HC_BIN:-hc}"
}

fm_backend_herdr_core_app_bin() {
  printf '%s' "${SQUAD_HERDR_APP_BIN:-$SQUAD_BACKEND_HERDR_CORE_APP_BIN}"
}

# fm_backend_herdr_core_session: the core session this process resolves.
# `HC_SESSION` is the product's own selector; unset means the `default` core,
# which is the one the commander's desktop and phone attach to.
fm_backend_herdr_core_session() {
  printf '%s' "${HC_SESSION:-default}"
}

# fm_backend_herdr_core_socket: the socket path for <session>, honoring the
# product's own HC_SOCKET override. This is the path `hc` itself would use, so a
# present socket is the only precondition that makes an `hc` call here safe.
# `hc` has two placements: a runtime directory when `XDG_RUNTIME_DIR` is set and
# non-empty, otherwise the state directory under a per-session folder (there is
# no `/run/user/<uid>` default - a host without `XDG_RUNTIME_DIR`, such as a
# container or a bare ssh session, keeps the core only in the state directory).
fm_backend_herdr_core_socket() {  # <session>
  local session=${1:-default}
  if [ -n "${HC_SOCKET:-}" ]; then
    printf '%s' "$HC_SOCKET"
    return 0
  fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    printf '%s/herdr-core/%s.sock' "$XDG_RUNTIME_DIR" "$session"
    return 0
  fi
  printf '%s/herdr-core/%s/%s.sock' "${XDG_STATE_HOME:-${HOME:-}/.local/state}" "$session" "$session"
}

# fm_backend_herdr_core_listener_probe: is a LISTENER answering on <socket>? A
# unix-socket file proves only that something once bound the path: after an
# unclean core death the file survives while nothing accepts on it, and the next
# `hc` call would then start a core with Squad's environment. Each client here
# can only connect - none of them can start a core.
#   0  a listener accepted the connection
#   1  the connection was refused: nothing is listening
#   2  no client could decide (none installed, or the client itself cannot run)
# Every client is tried in turn, so a broken interpreter cannot masquerade as a
# dead core, and 2 is a fail-closed refusal at the caller.
SQUAD_BACKEND_HERDR_CORE_PROBE_TIMEOUT=2

fm_backend_herdr_core_probe_python() {  # <socket>
  local socket=$1 out rc=0
  out=$(python3 - "$socket" <<'PY' 2>/dev/null
import socket
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(2)
try:
    client.connect(sys.argv[1])
except OSError:
    print("refused")
    sys.exit(0)
print("listening")
PY
  ) || rc=$?
  [ "$rc" -eq 0 ] || return 2
  case "$out" in
    listening) return 0 ;;
    refused) return 1 ;;
  esac
  return 2
}

fm_backend_herdr_core_probe_curl() {  # <socket>
  local socket=$1 out rc=0
  # herdr-core answers in HTTP/0.9 - raw JSON-RPC lines with no HTTP framing - so
  # curl must be told to accept that, and a live core keeps the connection open
  # after answering, which ends curl on its timeout. The exit code therefore
  # cannot decide anything except "could not connect": the proof is the
  # RESPONSE. 7 is curl's could-not-connect: nothing is listening. Bytes from the
  # peer prove a listener. No bytes prove nothing about one - a build without
  # --unix-socket, a wrapper, an initialization or connect failure, or a timeout
  # on a socket that never answers - and reading that as a listener would let the
  # next `hc` call start a core, so it is a cannot-decide.
  out=$(curl -s --http0.9 --max-time "$SQUAD_BACKEND_HERDR_CORE_PROBE_TIMEOUT" \
    --unix-socket "$socket" http://localhost/ </dev/null 2>/dev/null) || rc=$?
  [ "$rc" -eq 7 ] && return 1
  [ -n "$out" ] && return 0
  return 2
}

fm_backend_herdr_core_probe_nc() {  # <socket>
  nc -U -z -w "$SQUAD_BACKEND_HERDR_CORE_PROBE_TIMEOUT" "$1" >/dev/null 2>&1
}

fm_backend_herdr_core_listener_probe() {  # <socket>
  local socket=$1 client rc=0
  for client in python3 curl nc; do
    command -v "$client" >/dev/null 2>&1 || continue
    case "$client" in
      python3) fm_backend_herdr_core_probe_python "$socket" || rc=$? ;;
      curl) fm_backend_herdr_core_probe_curl "$socket" || rc=$? ;;
      nc) fm_backend_herdr_core_probe_nc "$socket" || rc=$? ;;
    esac
    case "$rc" in
      0) return 0 ;;
      1) return 1 ;;
    esac
    rc=0
  done
  return 2
}

# fm_backend_herdr_core_core_present: refuse unless a core is LISTENING for
# <session>. THIS is the whole never-start-a-core rule: no other function in
# this file runs `hc` without it. A socket file that no process accepts on is
# the stale-socket case, and it refuses exactly like an absent one.
fm_backend_herdr_core_core_present() {  # <session>
  local session=${1:-default} socket rc=0
  socket=$(fm_backend_herdr_core_socket "$session")
  if [ -S "$socket" ]; then
    fm_backend_herdr_core_listener_probe "$socket" || rc=$?
    case "$rc" in
      0) return 0 ;;
      2)
        echo "error: cannot prove a core is listening for herdr-core session '$session' at $socket (no unix-socket probe client could prove it; install python3, nc or curl); Squad never starts the core, and refusing is safer than risking a start" >&2
        return 1
        ;;
    esac
  fi
  echo "error: herdr-core is not running for session '$session' (no core listening at $socket); Squad never starts the core - start Herdr or run 'hc server start' yourself" >&2
  return 1
}

# fm_backend_herdr_core_session_ok: a recorded task session must be the session
# this process resolves. An address is only meaningful inside one core's
# registry, so addressing a task through another core is refused rather than
# resolved against whatever happens to be running.
fm_backend_herdr_core_session_ok() {  # <session>
  local session=${1:-default} ambient
  ambient=$(fm_backend_herdr_core_session)
  [ "$session" = "$ambient" ] && return 0
  echo "error: recorded herdr-core session '$session' is not this process's session '$ambient'; refusing to address a different core" >&2
  return 1
}

# fm_backend_herdr_core_cli: the ONE way this adapter runs `hc`. It refuses
# without the CLI, refuses a session this process does not resolve, and refuses
# when the session's core is not listening - so no call can implicitly start a
# core with Squad's environment.
fm_backend_herdr_core_cli() {  # <session> <hc args...>
  local session=${1:-default} bin
  shift
  bin=$(fm_backend_herdr_core_bin)
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: herdr-core CLI not found: $bin" >&2
    return 1
  }
  fm_backend_herdr_core_session_ok "$session" || return 1
  fm_backend_herdr_core_core_present "$session" || return 1
  command "$bin" "$@"
}

# --- target parsing and the identity quadruple -------------------------------

fm_backend_herdr_core_parse_target() {  # <target> -> session and address globals
  local target=${1:-}
  case "$target" in *:*) ;; *) return 1 ;; esac
  SQUAD_BACKEND_HERDR_CORE_SESSION=${target%%:*}
  SQUAD_BACKEND_HERDR_CORE_ADDRESS=${target#*:}
  [ -n "$SQUAD_BACKEND_HERDR_CORE_SESSION" ] \
    && [ "$SQUAD_BACKEND_HERDR_CORE_ADDRESS" != "$target" ] \
    && fm_backend_opaque_address_valid "$SQUAD_BACKEND_HERDR_CORE_ADDRESS"
}

# fm_backend_herdr_core_task_id_of_label: the task id a cleanup label names.
# Squad's caller-facing label is `sq-<id>` on every backend; the hc label is the
# bare task id, so the two are compared through this one translation.
fm_backend_herdr_core_task_id_of_label() {  # <label>
  local label=${1:-}
  case "$label" in
    sq-*) printf '%s' "${label#sq-}" ;;
    *) printf '%s' "$label" ;;
  esac
}

# fm_backend_herdr_core_base_name: the `squad.base` value this base writes, and
# the value every base-scoped inventory filters on. Two bases sharing one core
# both number their tasks from 1, so the task label alone neither proves nor
# refutes ownership. Two bases can also share a directory name (the ordinary
# `squad` clone name), so the readable base label carries a short hash of the
# physical base path, exactly as the zellij and cmux titles are scoped.
fm_backend_herdr_core_base_name() {
  local raw label path hash
  raw=${SQUAD_BASE:-${SQUAD_ROOT:-squad}}
  path=$(cd "$raw" 2>/dev/null && pwd -P) || path=$raw
  label=$(printf '%s' "${path##*/}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | tr -s '-')
  label=${label#-}
  label=${label%-}
  [ -n "$label" ] || label=base
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$path" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$path" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$path" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$label" "$hash"
}

# fm_backend_herdr_core_read_core_id: one authoritative, never-cached read of
# the live core's own id, so a long-lived poller notices a restarted core.
fm_backend_herdr_core_read_core_id() {  # <session>
  local session=${1:-default} out
  out=$(fm_backend_herdr_core_cli "$session" server status --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er '.core.id | select(type == "string" and length > 0)' 2>/dev/null
}

# fm_backend_herdr_core_core_id: the live core's own id, read once per process.
# It is the third element of the cleanup identity: an address belongs to one
# core's registry, so a recorded id that no longer matches refuses every write.
fm_backend_herdr_core_core_id() {  # <session>
  local session=${1:-default} id
  if [ -n "${SQUAD_BACKEND_HERDR_CORE_CORE_ID:-}" ]; then
    printf '%s' "$SQUAD_BACKEND_HERDR_CORE_CORE_ID"
    return 0
  fi
  id=$(fm_backend_herdr_core_read_core_id "$session") || return 1
  # shellcheck disable=SC2034 # Read by later calls in the same shell.
  SQUAD_BACKEND_HERDR_CORE_CORE_ID=$id
  printf '%s' "$id"
}

# fm_backend_herdr_core_get_json: one validated `hc get` read of one exact
# address. Prints the record and returns 0; returns 3 when the core
# authoritatively has no such address, and 1 on any other failure, so an
# absent endpoint is never confused with an unreadable one.
fm_backend_herdr_core_get_json() {  # <session> <address>
  local session=${1:-default} address=$2 out rc=0
  out=$(fm_backend_herdr_core_cli "$session" get --json "$address" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 3 ] && return 3
    return 1
  fi
  printf '%s' "$out" | jq -e --arg address "$address" '
    type == "object"
    and (.address == $address)
    and ((.state // "") | type == "string" and length > 0)
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# fm_backend_herdr_core_meta_for_target: the one meta file that records
# <target>. `window` is `<session>:<address>`, and a core recycles an address as
# soon as its terminal is closed, so the address alone is not a task identity:
# two tasks can record the same window once the core recycles it. When the
# caller knows the task id, that identity decides: its own `<task-id>.meta` is
# used when it exists and records this target, and a file that exists but records
# another target refuses. When that file is absent, or no task id is known, the
# address is all there is; a single match is usable and several matches are
# ambiguous - resolving to whichever file the glob yields first would read
# another task's recorded core id and labels.
#   0  printed the one meta that owns <target>
#   1  no meta records <target>
#   2  several metas record <target> and no task id disambiguates
fm_backend_herdr_core_meta_for_target() {  # <target> [task-id]
  local target=${1:-} id=${2:-} state=${SQUAD_BACKEND_STATE_DIR:-} meta window terminal found="" ambiguous=0
  { [ -n "$target" ] && [ -n "$state" ]; } || return 1
  if [ -n "$id" ]; then
    meta=$state/$id.meta
    if [ -f "$meta" ]; then
      window=$(fm_meta_get "$meta" window)
      terminal=$(fm_meta_get "$meta" terminal)
      if [ "$window" = "$target" ] || { [ -n "$terminal" ] && [ "$terminal" = "$target" ]; }; then
        printf '%s' "$meta"
        return 0
      fi
      return 1
    fi
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(fm_meta_get "$meta" window)
    terminal=$(fm_meta_get "$meta" terminal)
    if [ "$window" = "$target" ] || { [ -n "$terminal" ] && [ "$terminal" = "$target" ]; }; then
      if [ -n "$found" ]; then
        ambiguous=1
        break
      fi
      found=$meta
    fi
  done
  [ "$ambiguous" -eq 0 ] || return 2
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# fm_backend_herdr_core_recorded_core_id: the core id recorded with the task that
# owns <target>, if this base records one. Empty (success) when the target has no
# metadata of its own, which is the ad hoc-probe case; 2 when several tasks
# recorded the address and no task id says which task this read is for.
fm_backend_herdr_core_recorded_core_id() {  # <target> [task-id]
  local target=$1 id=${2:-} meta
  meta=$(fm_backend_herdr_core_meta_for_target "$target" "$id") || return $?
  fm_meta_get "$meta" hc_core_id
}

# fm_backend_herdr_core_verify: THE identity check every write runs first. It
# parses the exact target, refuses a session this process does not resolve,
# refuses when the recorded core id no longer matches, requires the address to be
# live, and requires its `squad.task` label to be this task's. An `<expected>`
# label of `sq-<id>` selects that task; an empty one still requires a readable
# address. `<allow-finished>` is set by the cleanup path and by the presentation
# clear, because a task whose program already exited is a `finished` address
# that a close must still be able to retire, and a record whose program already
# exited can still carry the placement labels a clear must remove. It never
# licenses a create or any write other than that label removal.
# `<expected-base>` names the `squad.base` label the terminal must carry, and an
# empty one means this base's own: two bases sharing one core both number their
# tasks from 1, so the task label alone never proves ownership, and no close or
# write may reach a terminal this base did not create.
# Failure is always a refusal, and the delivery verdict needs to tell an
# authoritative absence from a local failure, so the reason is in the code:
#   1  a local failure or an identity that could not be read at all (including
#      metadata whose ownership the recorded address cannot disambiguate)
#   3  the address is authoritatively gone, or no longer live for a write
#   4  the address carries another identity (foreign, recycled or re-labelled)
#   5  a recorded core id cannot be verified against a readable live core id
fm_backend_herdr_core_verify() {  # <target> [expected-label] [allow-finished] [expected-base]
  local target=${1:-} expected=${2:-} allow_finished=${3:-} expected_base=${4:-}
  local session address json recorded live state label rc=0 expected_id meta_rc=0
  SQUAD_BACKEND_HERDR_CORE_VERIFIED_JSON=
  [ -n "$expected_base" ] || expected_base=$(fm_backend_herdr_core_base_name)
  fm_backend_herdr_core_parse_target "$target" || {
    echo "error: malformed herdr-core target '$target'; expected <session>:<address>" >&2
    return 1
  }
  expected_id=$(fm_backend_herdr_core_task_id_of_label "$expected")
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  fm_backend_herdr_core_session_ok "$session" || return 1
  recorded=$(fm_backend_herdr_core_recorded_core_id "$target" "$expected_id" 2>/dev/null) || meta_rc=$?
  if [ "$meta_rc" -eq 2 ]; then
    echo "error: herdr-core identity for $target is ambiguous (several tasks recorded this address and this write names none of them); refusing every write" >&2
    return 1
  fi
  if [ -n "$recorded" ]; then
    live=$(fm_backend_herdr_core_read_core_id "$session" 2>/dev/null || true)
    if [ -z "$live" ]; then
      echo "error: herdr-core identity for $target is unreadable (recorded core $recorded); refusing every write" >&2
      return 5
    fi
    if [ "$live" != "$recorded" ]; then
      echo "error: herdr-core identity for $target changed (recorded core $recorded, live core $live); refusing every write" >&2
      return 4
    fi
  fi
  json=$(fm_backend_herdr_core_get_json "$session" "$address") || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 3 ]; then
      echo "error: herdr-core address $address no longer exists in session '$session'" >&2
      return 3
    fi
    echo "error: herdr-core address $address is not readable in session '$session'" >&2
    return 1
  fi
  state=$(printf '%s' "$json" | jq -r '.state')
  case "$state" in
    live) ;;
    finished)
      [ "$allow_finished" = 1 ] || {
        echo "error: herdr-core address $address is finished, not live; refusing to write to it" >&2
        return 3
      }
      ;;
    *)
      echo "error: herdr-core address $address is $state, not live; refusing to write to it" >&2
      return 1
      ;;
  esac
  if [ -n "$expected" ]; then
    label=$(printf '%s' "$json" | jq -r --arg key "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL" '(.labels // {})[$key] // ""')
    if [ "$label" != "$(fm_backend_herdr_core_task_id_of_label "$expected")" ]; then
      echo "error: herdr-core address $address carries task label '${label:-none}', not '$(fm_backend_herdr_core_task_id_of_label "$expected")'; refusing to touch another task's terminal" >&2
      return 4
    fi
  fi
  label=$(printf '%s' "$json" | jq -r --arg key "$SQUAD_BACKEND_HERDR_CORE_BASE_LABEL" '(.labels // {})[$key] // ""')
  if [ "$label" != "$expected_base" ]; then
    echo "error: herdr-core address $address carries base label '${label:-none}', not '$expected_base'; refusing to touch another base's terminal" >&2
    return 4
  fi
  SQUAD_BACKEND_HERDR_CORE_VERIFIED_JSON=$json
}

# --- status projection ------------------------------------------------------

# fm_backend_herdr_core_status_json: ONE normalized read of the recorded address,
# built from a single `hc get`. Prints an object with the fields every primitive
# below needs, so no primitive re-parses the product record:
#   state     live|finished
#   reported  whether the program reports OSC 7501 status at all
#   status    idle|working|done|blocked|error, or empty when it reports none
#   kind/msg  the blocked prompt's own fields, when it carries them
#   turn, name, cwd, pid, reason, exit_code
# Returns 3 when the address is authoritatively absent, 4 when the record does
# not carry the core id, task label and base label this base recorded for
# <target>, and 5 when a recorded identity cannot be verified against a readable
# core: the live core id, or metadata ownership when several tasks recorded this
# recycled address and <task-id> names none of them.
fm_backend_herdr_core_status_json() {  # <target> [task-id]
  local target=${1:-} id=${2:-} session address json rc=0
  fm_backend_herdr_core_parse_target "$target" || return 1
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  fm_backend_herdr_core_session_ok "$session" || return 1
  # The read's own status is preserved: an absent address (3) must never look
  # like a successful read of an empty record.
  json=$(fm_backend_herdr_core_get_json "$session" "$address") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_backend_herdr_core_record_owned "$session" "$target" "$json" "$id" || rc=$?
  case "$rc" in
    0) ;;
    2) return 5 ;;
    *) return 4 ;;
  esac
  printf '%s' "$json" | jq -c '
    (if (.reported | type) == "boolean" then .reported else false end) as $reported
    | (if (.status | type) == "object" then .status else {} end) as $status
    | {
        state: .state,
        reported: $reported,
        status: (if $reported then ($status.state // "") else "" end),
        kind: ($status.kind // ""),
        msg: ($status.msg // ""),
        app: ($status.app // ""),
        status_ms: (.status_ms // 0),
        turn: (.turn // 0),
        name: (if (.foreground | type) == "object" then (.foreground.name // "") else "" end),
        cwd: (if (.foreground | type) == "object" then (.foreground.cwd // "") else "" end),
        argv0: (if (.foreground | type) == "object" then ((.foreground.argv // [])[0] // "") else "" end),
        pid: (if (.foreground | type) == "object" then (.foreground.pid // 0) else 0 end),
        title: (.title // ""),
        reason: (.reason // "")
      }'
}

# --- the version and protocol guard ----------------------------------------

# fm_backend_herdr_core_version_at_least: is <have> >= <want>, compared
# component by component on numeric dotted versions only. An unparsable version
# is below the floor, never above it.
fm_backend_herdr_core_version_at_least() {  # <have> <want>
  local have=$1 want=$2
  local -a have_parts=() want_parts=()
  printf '%s' "$have" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || return 1
  printf '%s' "$want" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || return 1
  IFS=. read -r -a have_parts <<< "$have"
  IFS=. read -r -a want_parts <<< "$want"
  local i max=${#want_parts[@]} part_have part_want
  [ "${#have_parts[@]}" -gt "$max" ] && max=${#have_parts[@]}
  for ((i = 0; i < max; i++)); do
    part_have=${have_parts[i]:-0}
    part_want=${want_parts[i]:-0}
    [ "$part_have" -gt "$part_want" ] && return 0
    [ "$part_have" -lt "$part_want" ] && return 1
  done
  return 0
}

# fm_backend_herdr_core_protocol_check: the guard. Refuses loudly, never
# degrades. In order: the CLI, the session this process resolves, a listening
# core (so the handshake cannot start one), one generation-1 handshake, the
# version floor, the required features, the required methods, the required
# parameters, and finally the core identity. On success it caches the core id.
fm_backend_herdr_core_protocol_check() {  # <session>
  local session=${1:-default} bin hello line generation version problems core_id
  local schema
  bin=$(fm_backend_herdr_core_bin)
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: herdr-core CLI not found: $bin" >&2
    return 1
  }
  fm_backend_herdr_core_session_ok "$session" || return 1
  fm_backend_herdr_core_core_present "$session" || return 1
  hello=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"hello","params":{"generation":1}}' \
    | fm_run_timed 10 "$bin" connect 2>/dev/null) || {
    echo "error: herdr-core did not answer a protocol handshake on session '$session'; refusing to drive an unverified core" >&2
    return 1
  }
  line=${hello%%$'\n'*}
  if printf '%s' "$line" | jq -e '.error.data.kind == "unsupported_generation"' >/dev/null 2>&1; then
    echo "error: herdr-core refused protocol generation $SQUAD_BACKEND_HERDR_CORE_GENERATION: $(printf '%s' "$line" | jq -r '.error.data.hint // .error.message // "no reason given"')" >&2
    return 1
  fi
  printf '%s' "$line" | jq -e '(.result | type) == "object"' >/dev/null 2>&1 || {
    echo "error: herdr-core handshake reply is malformed; refusing to drive an unverified core" >&2
    return 1
  }
  generation=$(printf '%s' "$line" | jq -r '.result.generation // ""')
  if [ "$generation" != "$SQUAD_BACKEND_HERDR_CORE_GENERATION" ]; then
    echo "error: herdr-core speaks protocol generation '${generation:-unknown}', and this adapter requires generation $SQUAD_BACKEND_HERDR_CORE_GENERATION" >&2
    return 1
  fi
  version=$(printf '%s' "$line" | jq -r '.result.version // ""')
  if ! fm_backend_herdr_core_version_at_least "$version" "$SQUAD_BACKEND_HERDR_CORE_VERSION_FLOOR"; then
    echo "error: herdr-core version '${version:-unknown}' is below this adapter's floor $SQUAD_BACKEND_HERDR_CORE_VERSION_FLOOR; upgrade hc or refuse this backend" >&2
    return 1
  fi
  printf '%s' "$line" | jq -e '(.result.features // []) | type == "array"' >/dev/null 2>&1 || {
    echo 'error: herdr-core handshake features list is malformed; refusing to drive an unverified core' >&2
    return 1
  }
  problems=$(printf '%s' "$line" | jq -r --arg required "$SQUAD_BACKEND_HERDR_CORE_REQUIRED_FEATURES" '
    (.result.features // []) as $have
    | $required | split(" ") | map(select(length > 0))
    | map(select(. as $f | ($have | index($f)) == null) | "missing feature \(.)")
    | .[]' 2>/dev/null) || {
    echo 'error: herdr-core handshake features could not be validated; refusing to drive an unverified core' >&2
    return 1
  }
  if [ -n "$problems" ]; then
    echo "error: herdr-core is missing protocol features this adapter requires: $(printf '%s' "$problems" | tr '\n' ' ' | sed 's/ *$//')" >&2
    return 1
  fi
  printf '%s' "$line" | jq -e '(.result.methods // []) | type == "array"' >/dev/null 2>&1 || {
    echo 'error: herdr-core handshake methods list is malformed; refusing to drive an unverified core' >&2
    return 1
  }
  problems=$(printf '%s' "$line" | jq -r --arg required "$SQUAD_BACKEND_HERDR_CORE_REQUIRED_METHODS" '
    (.result.methods // [] | map(if type == "object" then (.name // "") else . end)) as $have
    | $required | split("\n") | map(select(length > 0))
    | map(select(. as $m | ($have | index($m)) == null) | "missing method \(.)")
    | .[]' 2>/dev/null) || {
    echo 'error: herdr-core handshake methods could not be validated; refusing to drive an unverified core' >&2
    return 1
  }
  if [ -n "$problems" ]; then
    echo "error: herdr-core is missing methods this adapter requires: $(printf '%s' "$problems" | tr '\n' ' ' | sed 's/ *$//')" >&2
    return 1
  fi
  schema=$(fm_backend_herdr_core_cli "$session" schema --json 2>/dev/null) || {
    echo "error: herdr-core catalog is unreadable; refusing to drive an unverified core" >&2
    return 1
  }
  printf '%s' "$schema" | jq -e '(.methods | type) == "array" and (.methods | length) > 0' >/dev/null 2>&1 || {
    echo "error: herdr-core catalog is malformed; refusing to drive an unverified core" >&2
    return 1
  }
  problems=$(printf '%s' "$schema" | jq -r --arg required "$SQUAD_BACKEND_HERDR_CORE_REQUIRED_PARAMS" '
    (.methods | map({(.name): ((.params // []) | map(.name))}) | add) as $have
    | $required | split("\n") | map(select(length > 0))
    | map(split(":") as $row
          | ($have[$row[0]] // null) as $params
          | if $params == null then "missing method \($row[0])"
            else ($row[1] | split(","))[] as $p
                 | if ($params | index($p)) == null then "\($row[0]) has no parameter \($p)" else empty end
            end)
    | .[]' 2>/dev/null) || {
    echo "error: herdr-core catalog could not be validated; refusing to drive an unverified core" >&2
    return 1
  }
  if [ -n "$problems" ]; then
    echo "error: herdr-core is missing parameters this adapter requires: $(printf '%s' "$problems" | tr '\n' ' ' | sed 's/ *$//')" >&2
    return 1
  fi
  core_id=$(fm_backend_herdr_core_core_id "$session" 2>/dev/null || true)
  if [ -z "$core_id" ]; then
    echo "error: herdr-core core identity is unreadable; refusing to drive an unverified core" >&2
    return 1
  fi
  SQUAD_BACKEND_HERDR_CORE_CORE_ID=$core_id
  printf '%s' "$core_id"
}

# --- the 16 session-provider primitives -------------------------------------

fm_backend_herdr_core_capture() {  # <target> <lines> [expected-label]
  local target=${1:-} lines=${2:-0} expected=${3:-} session address out
  fm_backend_herdr_core_verify "$target" "$expected" || return 1
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  out=$(fm_backend_herdr_core_cli "$session" read --json --lines "$lines" "$address" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -jer '.text | select(type == "string")' 2>/dev/null || return 1
}

# The sentry hashes this text to expire busy claims and to compare pane
# signatures, so an incomplete screen is worse than no screen. Only the
# product's own envelope proves a complete viewport read: `complete` true and
# `how` screen over non-empty text. Every other shape - history, a partial
# read, an empty screen, a malformed record - refuses, and static-busy expiry
# simply does not run for this backend rather than hashing unproven text.
fm_backend_herdr_core_capture_rendered() {  # <target> [expected-label]
  local target=${1:-} expected=${2:-} session address out text
  fm_backend_herdr_core_verify "$target" "$expected" || return 1
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  out=$(fm_backend_herdr_core_cli "$session" read --json --lines 0 "$address" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e '
    (.complete == true)
    and (.how == "screen")
    and ((.text | type) == "string")
  ' >/dev/null 2>&1 || return 1
  text=$(printf '%s' "$out" | jq -jer '.text' 2>/dev/null) || return 1
  [ -n "${text//[[:space:]]/}" ] || return 1
  printf '%s' "$text"
}

# fm_backend_herdr_core_key_name: translate Squad's tmux-shaped key names into
# the product's own key vocabulary. An unmapped name is refused rather than
# guessed, because a wrong key in a blocked agent's terminal can answer it.
fm_backend_herdr_core_key_name() {  # <key> -> product key name
  local key=${1:-} norm
  case "$key" in
    '') return 1 ;;
    Enter|enter|Return|return|CR) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'esc' ;;
    Tab|tab) printf 'tab' ;;
    BTab|backtab) printf 'shift+tab' ;;
    Space|space) printf 'space' ;;
    BSpace|backspace|BS) printf 'backspace' ;;
    DC|Delete|delete) printf 'delete' ;;
    Up|up) printf 'up' ;;
    Down|down) printf 'down' ;;
    Left|left) printf 'left' ;;
    Right|right) printf 'right' ;;
    Home|home) printf 'home' ;;
    End|end) printf 'end' ;;
    PPage|PageUp|pageup) printf 'pageup' ;;
    NPage|PageDown|pagedown) printf 'pagedown' ;;
    C-[a-zA-Z]|c-[a-zA-Z])
      norm=${key#C-}
      norm=${norm#c-}
      printf 'ctrl+%s' "$(printf '%s' "$norm" | tr '[:upper:]' '[:lower:]')"
      ;;
    ctrl+*) printf '%s' "$key" ;;
    M-[a-zA-Z]|m-[a-zA-Z])
      norm=${key#M-}
      norm=${norm#m-}
      printf 'alt+%s' "$(printf '%s' "$norm" | tr '[:upper:]' '[:lower:]')"
      ;;
    alt+*) printf '%s' "$key" ;;
    *)
      # A single printable character is its own key name.
      case "$key" in
        ?) printf '%s' "$key" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

fm_backend_herdr_core_send_key() {  # <target> <key> [expected-label]
  local target=${1:-} key=${2:-} expected=${3:-} product_key
  fm_backend_herdr_core_verify "$target" "$expected" || return 1
  product_key=$(fm_backend_herdr_core_key_name "$key") || {
    echo "error: key '$key' has no verified herdr-core equivalent; refusing to guess" >&2
    return 1
  }
  fm_backend_herdr_core_cli "$SQUAD_BACKEND_HERDR_CORE_SESSION" keys --json \
    "$SQUAD_BACKEND_HERDR_CORE_ADDRESS" "$product_key" >/dev/null
}

# fm_backend_herdr_core_send_refusal_kind: the stable `error.kind` from a refused
# send. The product writes its error envelope on stderr; an empty result means
# the call failed for a reason it did not classify.
fm_backend_herdr_core_send_refusal_kind() {  # <stderr-file>
  local file=$1
  [ -s "$file" ] || return 0
  jq -r '.error.kind // empty' "$file" 2>/dev/null || true
}

# fm_backend_herdr_core_deliver: one paste-and-submit, mapped to Squad's delivery
# verdicts and never retried or retyped.
#   empty                the text was pasted and submitted
#   agent_blocked        the program is blocked; nothing was typed
#   not_ready            the program's own report says it is not at rest; nothing was typed
#   no_agent             the address is authoritatively finished or gone, or it is not this task's; nothing was typed
#   send-failed          a local failure before typing (an unreadable read, or an identity this process cannot verify)
#   uncertain-delivery   the call failed without a stable refusal kind, so bytes may have landed
fm_backend_herdr_core_deliver() {  # <target> <text> [expected-label]
  local target=${1:-} text=${2:-} expected=${3:-} status_json reported state kind rc=0 err_file
  # `no_agent` is a confident verdict about the core's own record, never a
  # catch-all for a failed read: a transient hiccup must surface as a local
  # failure so no caller drops a delivery expectation on it.
  fm_backend_herdr_core_verify "$target" "$expected" || rc=$?
  case "$rc" in
    0) ;;
    3|4) printf 'no_agent'; return 0 ;;
    *) printf 'send-failed'; return 0 ;;
  esac
  rc=0
  status_json=$(fm_backend_herdr_core_status_json "$target" "$(fm_backend_herdr_core_task_id_of_label "$expected")" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    3|4) printf 'no_agent'; return 0 ;;
    *) printf 'send-failed'; return 0 ;;
  esac
  reported=$(printf '%s' "$status_json" | jq -r '.reported')
  state=$(printf '%s' "$status_json" | jq -r '.status')
  err_file=$(mktemp "${TMPDIR:-/tmp}/sq-hc-send.XXXXXX") || { printf 'send-failed'; return 0; }
  if [ "$reported" = true ]; then
    # The program's own report decides how it is typed into, and the product's
    # `--if` accepts only `idle` and `working` - so `--if idle` is the gate for an
    # exactly-idle program, a `done` program (its turn finished, it is at rest and
    # accepts the next instruction) is typed plainly, and every other reported
    # state refuses without typing. Refusing on `working` keeps a steer from
    # landing mid-turn; `blocked` and `error` mean a person is needed first.
    case "$state" in
      idle)
        fm_backend_herdr_core_cli "$SQUAD_BACKEND_HERDR_CORE_SESSION" send --json --if idle \
          "$SQUAD_BACKEND_HERDR_CORE_ADDRESS" "$text" >/dev/null 2>"$err_file" && rc=0 || rc=$?
        ;;
      done)
        fm_backend_herdr_core_cli "$SQUAD_BACKEND_HERDR_CORE_SESSION" send --json \
          "$SQUAD_BACKEND_HERDR_CORE_ADDRESS" "$text" >/dev/null 2>"$err_file" && rc=0 || rc=$?
        ;;
      blocked)
        rm -f "$err_file"
        printf 'agent_blocked'
        return 0
        ;;
      *)
        rm -f "$err_file"
        printf 'not_ready'
        return 0
        ;;
    esac
  else
    # A silent program has no status to test, so `--if idle` would refuse for the
    # ordinary reason "reports nothing". Its composer is the only readable signal,
    # and only POSITIVE evidence of unsent text is a refusal: an `unknown`
    # composer (a plain shell prompt, an unreadable row) carries no such evidence,
    # so the text is typed exactly as it is on the tmux path, once.
    if [ "$(fm_backend_herdr_core_composer_state "$target")" = pending ]; then
      rm -f "$err_file"
      printf 'not_ready'
      return 0
    fi
    fm_backend_herdr_core_cli "$SQUAD_BACKEND_HERDR_CORE_SESSION" send --json \
      "$SQUAD_BACKEND_HERDR_CORE_ADDRESS" "$text" >/dev/null 2>"$err_file" && rc=0 || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f "$err_file"
    printf 'empty'
    return 0
  fi
  kind=$(fm_backend_herdr_core_send_refusal_kind "$err_file")
  rm -f "$err_file"
  case "$kind" in
    blocked) printf 'agent_blocked' ;;
    status_mismatch) printf 'not_ready' ;;
    finished|not_found) printf 'no_agent' ;;
    *) printf 'uncertain-delivery' ;;
  esac
}

fm_backend_herdr_core_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  # The product pastes text and presses Enter in one call and owns its own
  # draft/settle behavior, so the composer-retry arguments Squad's tmux path
  # takes have no counterpart here: one attempt, no retype.
  fm_backend_herdr_core_deliver "${1:-}" "${2:-}" "${6:-}"
}

fm_backend_herdr_core_send_text_line() {  # <target> <text> [expected-label]
  local target=${1:-} text=${2:-} expected=${3:-} verdict
  verdict=$(fm_backend_herdr_core_deliver "$target" "$text" "$expected")
  [ "$verdict" = empty ] && return 0
  echo "error: herdr-core did not submit the line to $target (verdict=$verdict)" >&2
  return 1
}

fm_backend_herdr_core_container_ensure() {  # <project-cwd> -> session, after the full guard
  local session
  session=$(fm_backend_herdr_core_session)
  [ -n "$session" ] || { echo 'error: herdr-core session is empty' >&2; return 1; }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=herdr-core selected but 'jq' is not installed (required to parse herdr-core JSON output)" >&2
    return 1
  }
  # There is no session, workspace or window to ensure: the core is the
  # commander's already-running one, and a base's grouping is its label. This
  # call is a read-only presence and contract check that must pass before any
  # task terminal exists.
  fm_backend_herdr_core_protocol_check "$session" >/dev/null || return 1
  printf '%s' "$session"
}

# fm_backend_herdr_core_name_for_task: the product's own terminal name, which is
# unique only among live terminals and limited to 32 characters of
# a-z 0-9 - _. The product's registry is core-global while every base numbers its
# tasks from the same start, so the name is scoped by the base identity as well
# as the task id: `sq-<base-hash>-<id>`. The plain form is used only when the id
# is already its own slug and the whole name fits; every other id - a longer one,
# or one whose slug differs from it - is truncated and disambiguated by a hash of
# the full id, so `demo` and `sq-demo` cannot claim one name and two bases'
# task `1` cannot either.
fm_backend_herdr_core_name_for_task() {  # <task-id>
  local id=${1:-} slug base hash suffix full
  base=$(fm_backend_herdr_core_base_name)
  hash=${base##*-}
  slug=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
  slug=${slug#-}
  [ -n "$slug" ] || slug=task
  full="sq-$hash-$slug"
  if [ "$slug" = "$id" ] && [ "${#full}" -le 32 ]; then
    printf '%s' "$full"
    return 0
  fi
  if command -v md5 >/dev/null 2>&1; then
    suffix=$(printf '%s' "$id" | md5 -q | cut -c1-6)
  else
    suffix=$(printf '%s' "$id" | md5sum | cut -c1-6)
  fi
  if [ "${#slug}" -gt 13 ]; then
    slug=$(printf '%s' "$slug" | cut -c1-13)
  fi
  printf 'sq-%s-%s-%s' "$hash" "$slug" "$suffix"
}

# fm_backend_herdr_core_labeled_addresses: every address in <session> whose own
# `squad.task` label is exactly <task-id> and whose `squad.base` label is this
# base, live or already finished. The base scope is what keeps a second Squad
# base on the same core out of this base's inventory: both bases number their
# tasks from 1, so the task label alone is not unique across the core.
# `hc ls` without `--all` lists live terminals only, and the create failure this
# inventory recovers can already have run to completion, so the read asks for
# finished terminals too; it is read-only and never authorizes anything on its
# own. The product's `--label` filter is re-checked locally, because this list
# authorizes closing a terminal that may have just been created and never
# recorded.
fm_backend_herdr_core_labeled_addresses() {  # <session> <task-id>
  local session=${1:-default} task_id=${2:-} base out
  [ -n "$task_id" ] || return 1
  base=$(fm_backend_herdr_core_base_name)
  out=$(fm_backend_herdr_core_cli "$session" ls --all --json \
    --label "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL=$task_id" \
    --label "$SQUAD_BACKEND_HERDR_CORE_BASE_LABEL=$base" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r \
    --arg task_key "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL" \
    --arg base_key "$SQUAD_BACKEND_HERDR_CORE_BASE_LABEL" \
    --arg id "$task_id" --arg base "$base" '
    (.terminals // [])
    | map(select(((.labels // {})[$task_key] // "") == $id))
    | map(select(((.labels // {})[$base_key] // "") == $base))
    | .[]
    | .address // empty
  ' 2>/dev/null
}

# fm_backend_herdr_core_close_created: recover a create that failed or returned an
# unreadable address. The product documents that a failed `hc run` may still have
# run the program, so the adapter resolves the terminal it may just have made by
# its task label scoped to this base, and closes exactly that address. Nothing
# else is touched, and a close that cannot be confirmed names the exact address to
# retire by hand.
fm_backend_herdr_core_close_created() {  # <session> <task-id>
  local session=${1:-default} task_id=${2:-} addresses address base
  base=$(fm_backend_herdr_core_base_name)
  addresses=$(fm_backend_herdr_core_labeled_addresses "$session" "$task_id") || {
    echo "warning: could not read the herdr-core inventory to recover a failed create for task $task_id in session '$session'; check 'HC_SESSION=$session hc ls --all --label $SQUAD_BACKEND_HERDR_CORE_TASK_LABEL=$task_id --label $SQUAD_BACKEND_HERDR_CORE_BASE_LABEL=$base' and close that exact address by hand" >&2
    return 0
  }
  [ -n "$addresses" ] || return 0
  while IFS= read -r address; do
    [ -n "$address" ] || continue
    # The expected labels are Squad's caller-facing form of the labels already
    # filtered above, so the close re-checks the terminal's own task AND base
    # labels before both `kill` and `rm` and never retires an address the core
    # has recycled in between.
    fm_backend_herdr_core_kill "$session:$address" '' "sq-$task_id" "$base" >/dev/null 2>&1 && continue
    echo "warning: could not close the herdr-core terminal $session:$address created for task $task_id; close that exact address by hand: HC_SESSION=$session hc kill $address; HC_SESSION=$session hc rm $address" >&2
  done <<EOF
$addresses
EOF
}

# --- presentation: one optional desktop-app placement label ------------------

# fm_backend_herdr_core_presentation_space: the desktop space this base's task
# terminals belong to, or empty when the person configured none. It is a single
# positive identifier read fresh from the effective config dir's
# config/herdr-core-space, using the first-non-empty-line, whitespace-stripped
# convention the other scalar config items already use (config/backend,
# config/crew-harness).
# Nothing is inferred: an absent, unreadable, or blank file answers empty, and an
# empty answer means this adapter writes no app state at all.
# The id is local to this machine's app, exactly as the product's own labels are;
# an id the app does not know becomes a new space with the app's own name.
# Only the space id is configured. The tab id comes from the task's own identity
# (see fm_backend_herdr_core_tab_for_task), so nothing else in the person's app
# state is touched and no tab is guessed.
#
# Note the product's own consequence of adopting a terminal into a space: the
# core keeps it, so a terminal lost with the core comes back as a shell in its
# last folder instead of disappearing (docs/herdr-core-backend.md).
fm_backend_herdr_core_presentation_space() {
  local base=${SQUAD_BASE:-${SQUAD_ROOT:-}} config_dir file line value
  config_dir=${SQUAD_CONFIG_OVERRIDE:-${base:+$base/config}}
  [ -n "$config_dir" ] || return 0
  file=$config_dir/$SQUAD_BACKEND_HERDR_CORE_SPACE_CONFIG
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    value=$(printf '%s' "$line" | tr -d '[:space:]') || value=
    [ -n "$value" ] || continue
    printf '%s' "$value"
    return 0
  done < "$file"
  return 0
}

# fm_backend_herdr_core_tab_for_task: the app tab this task's terminal belongs
# to. The tab id is the task's own derived identity - the same base-scoped,
# collision-safe value the terminal is named with - so one mission owns one tab
# and a relaunch returns to that tab instead of stacking a second one. The id is
# app-local, so nothing is configured for it and nothing is guessed: two bases
# and two tasks never share one.
# This is the tab's IDENTITY. It is not what the tab shows: the app draws a tab
# by its title, and an untouched tab shows its number.
fm_backend_herdr_core_tab_for_task() {  # <task-id> -> app tab id
  fm_backend_herdr_core_name_for_task "${1:-}"
}

# fm_backend_herdr_core_tab_title_for_task: what this task's tab reads as. The
# task id is already the readable mission name (`robotyard-skeleton-complete`),
# so it is used whole; the base-scoped, hashed tab id above
# (`sq-f8f4d208-scaffold-dete-24b281`) identifies the tab but is unreadable.
# Measured on herdr-app 0.1.18, `tab.rename` keeps a 300-character name
# unchanged, so the app forces no truncation and this derives none: the title
# stays a pure function of the task id, so a relaunch of the same task writes the
# same title on the same tab.
fm_backend_herdr_core_tab_title_for_task() {  # <task-id> -> tab title
  printf '%s' "${1:-}"
}

# fm_backend_herdr_core_record_label: one label's value on an already-read
# terminal record, or empty when the record carries none. Reading from a record
# the identity check returned, rather than the terminal again, is what keeps a
# recycled address from swapping one terminal's labels for another's between two
# reads.
fm_backend_herdr_core_record_label() {  # <record-json> <label-key>
  local value
  value=$(printf '%s' "${1:-}" | jq -r --arg key "${2:-}" \
    '(.labels // {})[$key] // ""' 2>/dev/null) || value=
  printf '%s' "$value"
}

# fm_backend_herdr_core_presentation_tab_of: the app tab id recorded on ONE
# exact terminal's own `herdr.tab` label, or empty when it carries none. A caller
# resolves the tab it titled from the label this adapter wrote, never by
# position and never from whichever tab is selected.
# <record> is that terminal as the caller already read it. A caller that has one
# passes it, and its labels come from that one read; reading the terminal again
# here could return a different terminal once the core has recycled the address.
#   0  printed the label's value (possibly empty)
#   1  the terminal could not be read
fm_backend_herdr_core_presentation_tab_of() {  # <session> <address> [<record>]
  local session=${1:-default} address=${2:-} record=${3:-}
  [ -n "$address" ] || return 1
  if [ -z "$record" ]; then
    record=$(fm_backend_herdr_core_get_json "$session" "$address" 2>/dev/null) || return 1
  fi
  fm_backend_herdr_core_record_label "$record" "$SQUAD_BACKEND_HERDR_CORE_TAB_LABEL"
}

# fm_backend_herdr_core_rename_tab: write the visible title of ONE desktop tab,
# addressed by that tab's own id and nothing else - never a position, never
# "the active tab" - so the person's own working tab can never be reached here.
# An empty <title> gives the tab its number back, which is the product's own
# spelling of "unnamed".
# The title is the app's own state, not a core label: the capture found the app
# keeping it in the machine's core doc, keyed by that same tab id. That the app
# restores it from there on relaunch, and that every client of that core shows
# it, is the product's documented behavior, not something measured here.
# Best-effort by contract, exactly like the label write: a missing app, a
# refusal, or a failed write warns on stderr and returns nonzero for a caller
# that cares; no caller may turn it into a spawn failure.
# A missing app is "there is nothing in this app to title": no title exists and
# none was ever written, so a caller undoing its own work may still finish. The
# app's own `no tab` answer is also nothing to undo on a clear, and it is final
# there: nothing can make an id the app does not hold appear, so a clear never
# waits. On a set, that answer is the app not having adopted the labelled
# terminal yet, so it is retried; a budget that exhausts it is reported as a
# failed title, because the tab may still appear just after it and the warning
# names the by-hand rename. Every other refusal is final.
# The reason an attempt failed is read from the app's own error record, on
# stdout or on stderr: either stream carries the product's refusal, and the
# `no tab` answer must be recognised on whichever one the build writes.
#   0  the tab carries the title
#   1  the app refused an existing tab or answered an error; already reported. A
#      set that exhausts its retries also lands here, because the mission tab is
#      still at its number and the warning names the by-hand rename
#   2  nothing in this app to title: not installed, or no such tab on a clear;
#      reported
fm_backend_herdr_core_rename_tab() {  # <tab-id> <title> [<terminal-context>]
  local tab=${1:-} title=${2:-} context=${3:-} bin attempt=1 out err reason act hand rc=0
  local nothing=0 ok=0 err_file='' deadline bound
  [ -n "$tab" ] || return 1
  bin=$(fm_backend_herdr_core_app_bin)
  if [ -n "$title" ]; then
    act="set the desktop tab title of the herdr-core terminal ${context:-$tab} (tab '$tab') to '$title'"
    hand="$bin do tab.rename --id $tab --name \"$title\""
  else
    act="clear the desktop tab title of the herdr-core terminal ${context:-$tab} (tab '$tab')"
    hand="$bin do tab.rename --id $tab --name \"\""
  fi
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "warning: could not $act: '$bin' is not installed; there is no such tab in the app, so nothing is left to undo" >&2
    return 2
  fi
  err_file=$(mktemp "${TMPDIR:-/tmp}/sq-hc-title.XXXXXX") || err_file=
  # One deadline for the whole write, not one per attempt: the retry budget
  # bounds elapsed time as well as the number of answers, so an app that keeps
  # answering `no tab` slowly cannot hold the spawn for attempt-count times the
  # per-call bound.
  deadline=$((SECONDS + SQUAD_BACKEND_HERDR_CORE_TITLE_TIMEOUT))
  while :; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      if [ -n "$reason" ]; then
        reason="gave up after ${SQUAD_BACKEND_HERDR_CORE_TITLE_TIMEOUT}s (last answer: $reason)"
      else
        reason="the app did not answer within ${SQUAD_BACKEND_HERDR_CORE_TITLE_TIMEOUT}s"
      fi
      break
    fi
    bound=$((deadline - SECONDS))
    rc=0
    if [ -n "$err_file" ]; then
      out=$(fm_run_timed "$bound" \
        "$bin" 'do' tab.rename --id "$tab" --name "$title" 2>"$err_file") || rc=$?
      err=$(cat "$err_file" 2>/dev/null) || err=
    else
      out=$(fm_run_timed "$bound" \
        "$bin" 'do' tab.rename --id "$tab" --name "$title" 2>/dev/null) || rc=$?
      err=
    fi
    # A bound that expired is final: the app is holding the call, not that one
    # tab's adoption, and waiting longer only holds the spawn open.
    if [ "$rc" -eq 124 ]; then
      reason="the app did not answer within ${bound}s"
      break
    fi
    # The product's own refusal record is the authority on whether the tab is
    # still unknown, not the status alone: a build that prints that record and
    # exits zero must still take the adoption retry instead of reporting a
    # titled tab that never got its title.
    reason=$(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null) || reason=
    if [ -z "$reason" ] && [ -n "$err" ]; then
      reason=$(printf '%s' "$err" | jq -r '.error // empty' 2>/dev/null) || reason=
    fi
    if [ -z "$reason" ] && [ "$rc" -eq 0 ]; then
      ok=1
      break
    fi
    if [ -z "$reason" ] && [ -n "$err" ]; then
      reason=$(printf '%s\n' "$err" | head -n 1 | tr -d '\r')
    fi
    reason=${reason:-no reason given}
    # Only an unknown tab is worth another try: it is the app saying it has not
    # adopted the labelled terminal yet. Every other answer is final.
    case "$reason" in
      no\ tab*) ;;
      *) break ;;
    esac
    # Nothing can make an id the app does not hold appear on a clear, so that
    # answer is final there and the labels go without waiting.
    if [ -z "$title" ]; then
      nothing=1
      break
    fi
    if [ "$attempt" -ge "$SQUAD_BACKEND_HERDR_CORE_TITLE_ATTEMPTS" ]; then
      nothing=1
      break
    fi
    attempt=$((attempt + 1))
    sleep "$SQUAD_BACKEND_HERDR_CORE_TITLE_INTERVAL"
  done
  if [ -n "$err_file" ]; then rm -f "$err_file" 2>/dev/null || :; fi
  [ "$ok" -eq 0 ] || return 0
  if [ "$nothing" -ne 0 ] && [ -n "$title" ]; then
    echo "warning: could not $act (reason: $reason); the tab may still appear later, but the task is unaffected. Set it by hand with: $hand" >&2
    return 1
  fi
  if [ "$nothing" -ne 0 ]; then
    echo "warning: could not $act (reason: $reason); there is no such tab in the app, so nothing is left to undo" >&2
    return 2
  fi
  echo "warning: could not $act (reason: $reason); the task is unaffected. Set it by hand with: $hand" >&2
  return 1
}

# fm_backend_herdr_core_apply_presentation_space: place ONE terminal in the
# configured space, as its own tab, and give that tab a readable title. Two
# labels and one title, all resolved from this create's own address and its own
# derived tab id, so none of them can reach another terminal, another tab, or
# the person's own working tab.
# Idempotent by the product's own semantics - writing the same pair again leaves
# exactly one value each, and renaming a tab to the title it already has leaves
# it named - and best-effort by contract: a refused or failed write warns on
# stderr and returns nonzero for a caller that cares, and no caller may turn it
# into a spawn failure.
#   0  the labels and the title are in place, or nothing is configured
#   1  a configured label write failed; already reported
#   2  the labels are in place but the app is not installed; already reported. A
#      configured title that exhausts its retries returns 1, not 2, because the
#      tab may still appear and the warning names the by-hand rename
fm_backend_herdr_core_apply_presentation_space() {  # <session> <address> <task-id>
  local session=${1:-default} address=${2:-} task_id=${3:-} space tab title err_file reason rc=0
  [ -n "$address" ] || return 1
  space=$(fm_backend_herdr_core_presentation_space)
  [ -n "$space" ] || return 0
  tab=$(fm_backend_herdr_core_tab_for_task "$task_id")
  err_file=$(mktemp "${TMPDIR:-/tmp}/sq-hc-label.XXXXXX") || err_file=
  if [ -n "$err_file" ]; then
    fm_backend_herdr_core_cli "$session" label "$address" \
      "$SQUAD_BACKEND_HERDR_CORE_SPACE_LABEL=$space" \
      "$SQUAD_BACKEND_HERDR_CORE_TAB_LABEL=$tab" >/dev/null 2>"$err_file" || rc=$?
    reason=$(head -n 1 "$err_file" 2>/dev/null | tr -d '\r')
    rm -f "$err_file"
  else
    fm_backend_herdr_core_cli "$session" label "$address" \
      "$SQUAD_BACKEND_HERDR_CORE_SPACE_LABEL=$space" \
      "$SQUAD_BACKEND_HERDR_CORE_TAB_LABEL=$tab" >/dev/null 2>&1 || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "warning: could not place herdr-core terminal $session:$address in the configured desktop space '$space'; the task is unaffected and stays in 'hc ls' (reason: ${reason:-no reason given}). Set it by hand with: HC_SESSION=$session hc label $address $SQUAD_BACKEND_HERDR_CORE_SPACE_LABEL=$space $SQUAD_BACKEND_HERDR_CORE_TAB_LABEL=$tab" >&2
    # Without the labels the app has no tab for this terminal to name.
    return 1
  fi
  title=$(fm_backend_herdr_core_tab_title_for_task "$task_id")
  fm_backend_herdr_core_rename_tab "$tab" "$title" "$session:$address"
}

# fm_backend_herdr_core_clear_presentation_space: the adapter's half of the
# reversal. It clears both placement labels from ONE exact terminal, after the
# same identity check every other write runs (this base's `squad.base` label,
# plus this task's `squad.task` label when one is named), and it never removes,
# kills, or relabels a terminal - the address keeps running exactly as it was.
# It also gives back the tab's own number, which is the one title this adapter
# set: the tab and the task label are both read from the one record the identity
# check returned, so the removal sees a consistent terminal even when the
# address is recycled right after that read. The `herdr.tab` value must be the
# tab id this adapter derives from that same record's `squad.task` label - with
# or without a named task - or the clear refuses; a terminal that carries no
# such label titles nothing. The title goes back before the labels, so an app
# that refuses to rename the tab it holds leaves the label that names the tab in
# place and the whole removal is re-runnable. An app that is not installed, or
# that answers `no tab` for an id it does not hold, has no title left to clear:
# that answer is reported and the labels are still removed, so the removal always
# finishes for the core.
# A recorded core id and session that no longer agree refuse, so a recycled
# address is never cleared. A finished terminal is accepted, because a record
# whose program already exited can still carry the labels.
# Clearing the labels alone does NOT take the pane off the person's screen: the
# app binds an adopted terminal one way and keeps it
# (docs/herdr-core-backend.md owns the measured transcript), so the documented
# reversal pairs this with `herdr-app do terminal.park --terminal <address>`.
#   0  both labels are cleared on that terminal, and its tab carries no title or
#      the app holds no such tab
#   1  refused: a foreign, unreadable or unverifiable identity, or a write the
#      app or the core refused
fm_backend_herdr_core_clear_presentation_space() {  # <target> [expected-label]
  local target=${1:-} expected=${2:-} session address tab own_task own_tab rc=0
  fm_backend_herdr_core_verify "$target" "$expected" 1 || return 1
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  # Resolve the tab from the record the identity check just validated, before
  # its label is gone, so the removal can never act on a terminal other than the
  # one it checked.
  tab=$(fm_backend_herdr_core_presentation_tab_of \
    "$session" "$address" "$SQUAD_BACKEND_HERDR_CORE_VERIFIED_JSON")
  own_task=$(fm_backend_herdr_core_record_label \
    "$SQUAD_BACKEND_HERDR_CORE_VERIFIED_JSON" "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL")
  # The tab id must be the one this adapter derives from the terminal's own task
  # label, whether or not the caller named a task. Anything else is another
  # tab, which no clear may rename.
  if [ -n "$tab" ]; then
    if [ -z "$own_task" ]; then
      echo "error: herdr-core terminal $address carries $SQUAD_BACKEND_HERDR_CORE_TAB_LABEL '${tab}' but no $SQUAD_BACKEND_HERDR_CORE_TASK_LABEL to derive its own tab from; refusing to rename a tab this task did not create" >&2
      return 1
    fi
    own_tab=$(fm_backend_herdr_core_tab_for_task "$own_task")
    if [ "$tab" != "$own_tab" ]; then
      echo "error: herdr-core terminal $address carries $SQUAD_BACKEND_HERDR_CORE_TAB_LABEL '${tab}', not its own task's '$own_tab'; refusing to rename a tab this task did not create" >&2
      return 1
    fi
  fi
  # The title goes first: while it is still there the label above still names
  # this one tab, so a refused rename leaves the removal re-runnable instead of
  # stranding a title no later run can find. Only "nothing in the app to title"
  # may continue to the labels, because then no title was left behind.
  if [ -n "$tab" ]; then
    fm_backend_herdr_core_rename_tab "$tab" '' "$session:$address" || rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || return 1
  fi
  fm_backend_herdr_core_cli "$session" label "$address" \
    "$SQUAD_BACKEND_HERDR_CORE_SPACE_LABEL=" \
    "$SQUAD_BACKEND_HERDR_CORE_TAB_LABEL=" >/dev/null || {
    echo "error: herdr-core refused to clear the presentation labels on $address in session '$session'" >&2
    return 1
  }
  return 0
}

fm_backend_herdr_core_create_task() {  # <session> <task-label> <cwd> -> address
  local session=${1:-} label=${2:-} cwd=${3:-} task_id base name out address duplicate err_file reason
  [ -n "$label" ] || { echo 'error: herdr-core create_task needs a task label' >&2; return 1; }
  [ -n "$cwd" ] && [ -d "$cwd" ] || { echo "error: herdr-core create_task needs an existing directory, got '$cwd'" >&2; return 1; }
  task_id=$(fm_backend_herdr_core_task_id_of_label "$label")
  base=$(fm_backend_herdr_core_base_name)
  name=$(fm_backend_herdr_core_name_for_task "$task_id")
  # Refuse a second live terminal for this base's task label: a duplicate endpoint
  # would split one task across two terminals. Another base's terminal with the
  # same id is not a duplicate of this task.
  out=$(fm_backend_herdr_core_cli "$session" ls --json \
    --label "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL=$task_id" \
    --label "$SQUAD_BACKEND_HERDR_CORE_BASE_LABEL=$base" 2>/dev/null) || {
    echo "error: cannot read the herdr-core inventory for session '$session'" >&2
    return 1
  }
  duplicate=$(printf '%s' "$out" | jq -r \
    --arg task_key "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL" \
    --arg base_key "$SQUAD_BACKEND_HERDR_CORE_BASE_LABEL" \
    --arg id "$task_id" --arg base "$base" '
    [.terminals[]?
     | select(((.labels // {})[$task_key] // "") == $id)
     | select(((.labels // {})[$base_key] // "") == $base)] | length
  ' 2>/dev/null) || duplicate=unknown
  if [ "$duplicate" != 0 ]; then
    echo "error: a live herdr-core terminal already carries $SQUAD_BACKEND_HERDR_CORE_TASK_LABEL=$task_id in base '$base' ($duplicate found); refusing a duplicate endpoint" >&2
    return 1
  fi
  # stdout carries only the product's JSON record and stderr only its message, so
  # an informational notice on an otherwise successful create cannot make the
  # address unreadable.
  err_file=$(mktemp "${TMPDIR:-/tmp}/sq-hc-run.XXXXXX") || {
    echo "error: cannot create a temporary file for the herdr-core create error envelope" >&2
    return 1
  }
  if ! out=$(fm_backend_herdr_core_cli "$session" run --bg --json --no-parent \
    --name "$name" --cwd "$cwd" \
    --label "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL=$task_id" \
    --label "$SQUAD_BACKEND_HERDR_CORE_BASE_LABEL=$base" 2>"$err_file"); then
    reason=$(tr '\n\r' '  ' < "$err_file" 2>/dev/null || true)
    rm -f "$err_file"
    fm_backend_herdr_core_close_created "$session" "$task_id"
    echo "error: herdr-core refused to create the terminal for $label: ${reason:-no reason given}" >&2
    return 1
  fi
  rm -f "$err_file"
  address=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null) || address=
  if ! fm_backend_opaque_address_valid "$address"; then
    fm_backend_herdr_core_close_created "$session" "$task_id"
    echo "error: herdr-core returned no usable opaque address for $label" >&2
    return 1
  fi
  # Presentation comes after the terminal exists and carries its own two Squad
  # labels, so the placement labels and the tab title can only ever land on the
  # terminal and the tab this create just returned. It is best-effort by
  # contract: a failed write is reported and the spawn keeps its endpoint.
  fm_backend_herdr_core_apply_presentation_space "$session" "$address" "$task_id" || true
  printf '%s' "$address"
}

fm_backend_herdr_core_current_path() {  # <target>
  local status_json
  status_json=$(fm_backend_herdr_core_status_json "${1:-}" 2>/dev/null) || return 0
  printf '%s' "$status_json" | jq -r '.cwd // empty'
}

# fm_backend_herdr_core_classify_process_name: the shared process-name
# vocabulary (`agent` for a verified harness, `shell` for an idle interactive
# shell, `other` for anything else), reusing the tmux adapter's single owner so
# the two backends cannot disagree about what a name means.
fm_backend_herdr_core_classify_process_name() {  # <path> [argv0]
  fm_backend_source tmux >/dev/null 2>&1 || return 1
  fm_backend_tmux_classify_process_name "${1:-}" "${2:-}"
}

# fm_backend_herdr_core_agent_state: the recovery-grade verdict.
#   missing    the address is authoritatively absent, or it is not this task's
#   dead       the address exists but confidently has no agent (finished, or a
#              live shell where an agent used to be)
#   alive      a verified harness is the foreground program
#   ambiguous  the address is live but its program cannot be attributed
#   unreadable a read failed or contradicted itself
fm_backend_herdr_core_agent_state() {  # <target> [task-id]
  local target=${1:-} id=${2:-} status_json state rc=0
  status_json=$(fm_backend_herdr_core_status_json "$target" "$id" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      3|4) printf 'missing' ;;
      *) printf 'unreadable' ;;
    esac
    return 0
  fi
  state=$(printf '%s' "$status_json" | jq -r '.state')
  if [ "$state" = finished ]; then
    printf 'dead'
    return 0
  fi
  if [ "$state" != live ]; then
    printf 'ambiguous'
    return 0
  fi
  case "$(fm_backend_herdr_core_classify_process_name \
    "$(printf '%s' "$status_json" | jq -r '.name')" \
    "$(printf '%s' "$status_json" | jq -r '.argv0')" 2>/dev/null || true)" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# fm_backend_herdr_core_recorded_task_id_for_target: the bare herdr-core task id
# this base recorded for <target> (the terminal's own `squad.task` value), or
# empty for a target no task owns. Unlike a caller-facing label it carries no
# `sq-` prefix, so it must never be passed through the label translation.
fm_backend_herdr_core_recorded_task_id_for_target() {  # <target> [task-id]
  local target=${1:-} id=${2:-} meta
  meta=$(fm_backend_herdr_core_meta_for_target "$target" "$id") || return $?
  fm_meta_get "$meta" endpoint_task_id
}

# fm_backend_herdr_core_record_owned: does one read of <target> carry the
# identities this base recorded for it? A recycled address in a restarted core,
# an address another task now owns, or another base's terminal at that address
# has lost one of them, so a status consumer must refuse the record instead of
# projecting a stranger's state onto the task that recorded the address. A
# recorded core id that cannot be read is not a mismatch: it is an unverifiable
# identity, which callers must never confuse with an authoritatively absent
# endpoint.
#   0  the recorded identities are present and agree
#   1  an identity belongs to something else (foreign, recycled, or re-labelled)
#   2  a recorded identity cannot be verified: several tasks recorded the address
#      and the caller named none, or the live core id cannot be read
# The optional <task-id> is the task the caller is asking about. Without it the
# recorded address decides, and an address several tasks recorded is refused
# rather than resolved to another task's core id and labels.
fm_backend_herdr_core_record_owned() {  # <session> <target> <json> [task-id]
  local session=${1:-default} target=${2:-} json=${3:-} id=${4:-}
  local recorded live recorded_id label base rc=0 meta_rc=0
  recorded=$(fm_backend_herdr_core_recorded_core_id "$target" "$id" 2>/dev/null) || meta_rc=$?
  [ "$meta_rc" -ne 2 ] || return 2
  if [ -n "$recorded" ]; then
    live=$(fm_backend_herdr_core_read_core_id "$session" 2>/dev/null) || rc=$?
    [ "$rc" -eq 0 ] && [ -n "$live" ] || return 2
    [ "$live" = "$recorded" ] || return 1
  fi
  meta_rc=0
  recorded_id=$(fm_backend_herdr_core_recorded_task_id_for_target "$target" "$id" 2>/dev/null) || meta_rc=$?
  [ "$meta_rc" -ne 2 ] || return 2
  if [ -n "$recorded_id" ]; then
    label=$(printf '%s' "$json" | jq -r --arg key "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL" '(.labels // {})[$key] // ""')
    [ "$label" = "$recorded_id" ] || return 1
  fi
  base=$(printf '%s' "$json" | jq -r --arg key "$SQUAD_BACKEND_HERDR_CORE_BASE_LABEL" '(.labels // {})[$key] // ""')
  [ "$base" = "$(fm_backend_herdr_core_base_name)" ] || return 1
  return 0
}

# fm_backend_herdr_core_endpoint_ownership: ONE read of a recorded endpoint,
# classified by whether it still exists and is still the one this base recorded.
# A core recycles an address as soon as its terminal is closed, so a readable
# record at the recorded address is no proof that this task's endpoint is still
# there: the identities on the record itself decide. Prints exactly one word:
#   absent      the core authoritatively has no such address
#   foreign     the address is readable but carries another task's or another
#               base's labels, or another core id: this task's endpoint is gone
#   ours        the record carries the identities this base recorded
#   unreadable  the target, the session, the address, the core, or a recorded
#               core id could not be read or verified
# Only `unreadable` is a refusal: the other three are facts a caller may act on,
# and classifying a stranger's terminal as this task's would either close it or
# wedge the task's cleanup forever.
fm_backend_herdr_core_endpoint_ownership() {  # <target> [task-id]
  local target=${1:-} id=${2:-} session address json rc=0
  if ! fm_backend_herdr_core_parse_target "$target"; then
    printf 'unreadable'
    return 0
  fi
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  if ! fm_backend_herdr_core_session_ok "$session"; then
    printf 'unreadable'
    return 0
  fi
  json=$(fm_backend_herdr_core_get_json "$session" "$address") || rc=$?
  case "$rc" in
    0) ;;
    3) printf 'absent'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  fm_backend_herdr_core_record_owned "$session" "$target" "$json" "$id" || rc=$?
  case "$rc" in
    0) printf 'ours' ;;
    1) printf 'foreign' ;;
    *) printf 'unreadable' ;;
  esac
  return 0
}

# fm_backend_herdr_core_kill: close ONE exact address after the identity
# quadruple, and confirm both destructive steps. This close never takes `--all`,
# never a name, never a server-global verb, and never an address whose labels or
# core id do not match. The fourth argument names the terminal's required
# `squad.base` label and defaults to this base's own: a recorded-address close
# and the failed-create recovery both need it, because the task label is not
# unique across bases.
# Refuses (nonzero) whenever the exact close cannot be confirmed, so a caller
# that preserves metadata on refusal keeps a retryable record.
fm_backend_herdr_core_kill() {  # <target> [unused] [expected-label] [expected-base]
  local target=${1:-} expected=${3:-} expected_base=${4:-} session address out state removed
  # A task whose program already exited is a finished address; the close still
  # has to retire it, so finished is accepted here and nowhere else.
  fm_backend_herdr_core_verify "$target" "$expected" 1 "$expected_base" || return 1
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  out=$(fm_backend_herdr_core_cli "$session" kill --json "$address" 2>/dev/null) || {
    echo "error: herdr-core refused to kill $address in session '$session'" >&2
    return 1
  }
  state=$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null) || state=
  if [ "$state" != finished ]; then
    echo "error: herdr-core did not confirm $address finished after kill (state='${state:-unknown}')" >&2
    return 1
  fi
  # The second destructive step checks the same identity again: another actor can
  # remove the finished address and the core can recycle it for a new terminal
  # between the close and the removal.
  fm_backend_herdr_core_verify "$target" "$expected" 1 "$expected_base" || return 1
  if ! out=$(fm_backend_herdr_core_cli "$session" rm --json "$address" 2>/dev/null); then
    echo "error: herdr-core refused to remove the finished terminal $address in session '$session'" >&2
    return 1
  fi
  removed=$(printf '%s' "$out" | jq -r '.removed // empty' 2>/dev/null) || removed=
  if [ "$removed" != "$address" ]; then
    echo "error: herdr-core did not confirm removal of $address (removed='${removed:-none}')" >&2
    return 1
  fi
}

# fm_backend_herdr_core_retire_endpoint: retire a task's PREVIOUS exact endpoint
# before a relaunch creates its replacement. A task whose harness exited normally
# leaves a live, agentless shell; a core restart leaves a `finished` record. Both
# still carry this task's labels, so without this step the replacement is refused
# as a duplicate (live shell) or the husk is left unmanaged on the shared core
# (finished). The close is the same identity-checked one teardown uses, and an
# address the core authoritatively no longer has, or one that now carries a
# terminal this task does not own, is already retired.
#
#   0  the recorded address is gone, or was closed and confirmed
#   1  the address is still this task's but could not be closed: the relaunch
#      refuses
fm_backend_herdr_core_retire_endpoint() {  # <target> <expected-label>
  local target=${1:-} expected=${2:-} session address state ownership
  fm_backend_herdr_core_parse_target "$target" || {
    echo "error: malformed herdr-core target '$target'; cannot retire the previous endpoint" >&2
    return 1
  }
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  fm_backend_herdr_core_session_ok "$session" || return 1
  # An address the core authoritatively lacks, or one that now carries another
  # task's or base's terminal, means this task's previous endpoint is already
  # gone: there is nothing to retire and nothing this base may touch, so the
  # relaunch creates its replacement instead of killing a stranger's terminal.
  ownership=$(fm_backend_herdr_core_endpoint_ownership "$target" "$(fm_backend_herdr_core_task_id_of_label "${expected:-}")")
  case "$ownership" in
    absent|foreign) return 0 ;;
    ours) ;;
    *)
      echo "error: the previous herdr-core endpoint $target for $expected could not be read in session '$session'; refusing to create a replacement beside an endpoint this process cannot verify" >&2
      return 1
      ;;
  esac
  # Only an endpoint confidently without an agent is retired here. A read that is
  # ambiguous or unreadable, or that still sees a live agent, refuses: a relaunch
  # must never kill a program that may still be working.
  state=$(fm_backend_herdr_core_agent_state "$target" "$(fm_backend_herdr_core_task_id_of_label "${expected:-}")" 2>/dev/null || printf 'unreadable')
  case "$state" in
    dead|missing) ;;
    *)
      echo "error: the previous herdr-core endpoint $target for $expected is $state; refusing to retire an endpoint that may still be running a program" >&2
      return 1
      ;;
  esac
  fm_backend_herdr_core_kill "$target" '' "$expected" || {
    echo "error: the previous herdr-core endpoint $target for $expected could not be closed; refusing to create a replacement" >&2
    return 1
  }
}

# fm_backend_herdr_core_task_closed: teardown's confirmation that the exact
# terminal this task opened is gone. The endpoint is gone when the core
# authoritatively lacks the address, and it is also gone when the address is
# readable but carries another task's or base's labels, or another core id: the
# core recycled the address, so nothing this task created is left there and its
# records may be retired without touching the stranger's terminal. A record that
# still carries this task's and this base's labels refuses, and so does an
# unreadable core or a record whose identity cannot be verified - a transient
# failure is never mistaken for a completed cleanup.
fm_backend_herdr_core_task_closed() {  # <target> <task-id>
  local target=${1:-} id=${2:-} session address ownership
  if ! fm_backend_herdr_core_parse_target "$target"; then
    echo "error: malformed herdr-core target '$target'; cannot confirm the close" >&2
    return 1
  fi
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  fm_backend_herdr_core_session_ok "$session" || return 1
  ownership=$(fm_backend_herdr_core_endpoint_ownership "$target" "$id")
  case "$ownership" in
    absent) return 0 ;;
    foreign)
      echo "note: herdr-core address $address now carries a terminal this task does not own (another task, base, or core id); task $id has no endpoint there, so its records are retired and that terminal is left untouched" >&2
      return 0
      ;;
    ours)
      echo "error: herdr-core address $address for task $id is still present with this task's own labels; refusing to retire its records" >&2
      return 1
      ;;
    *)
      echo "error: herdr-core address $address for task $id could not be read in session '$session' (unreachable core, unreadable record, or an identity this process cannot verify); cannot confirm the close" >&2
      return 1
      ;;
  esac
}

# --- the extra dispatcher operations ---------------------------------------

# fm_backend_herdr_core_busy_state: the program's own report, mapped to Squad's
# busy vocabulary. `working` is busy; `blocked` and `error` both mean a person is
# needed; `idle` and `done` are idle; a silent or unreadable program is unknown,
# which is the cue for the harness-scoped fallback the other backends use.
fm_backend_herdr_core_busy_state() {  # <target>
  local status_json reported state
  status_json=$(fm_backend_herdr_core_status_json "${1:-}" 2>/dev/null) || { printf 'unknown'; return 0; }
  reported=$(printf '%s' "$status_json" | jq -r '.reported')
  [ "$reported" = true ] || { printf 'unknown'; return 0; }
  state=$(printf '%s' "$status_json" | jq -r '.status')
  case "$state" in
    working) printf 'busy' ;;
    blocked|error) printf 'blocked' ;;
    idle|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_core_prompt_summary: one bounded line naming what a blocked
# program is waiting on, from the fields the program itself wrote. The text is
# another program's data and must never break the caller's one-line contract.
fm_backend_herdr_core_prompt_summary() {  # <target>
  local status_json state kind msg line
  status_json=$(fm_backend_herdr_core_status_json "${1:-}" 2>/dev/null) || return 0
  [ "$(printf '%s' "$status_json" | jq -r '.reported')" = true ] || return 0
  state=$(printf '%s' "$status_json" | jq -r '.status')
  case "$state" in blocked|error) ;; *) return 0 ;; esac
  kind=$(printf '%s' "$status_json" | jq -r '.kind // empty')
  msg=$(printf '%s' "$status_json" | jq -r '.msg // empty')
  [ -n "$kind" ] || kind=$state
  line=$(printf '%s' "$msg" | tr '\n\r\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//' | cut -c1-160)
  if [ -n "$line" ]; then
    printf '%s: %s' "$kind" "$line"
  else
    printf '%s (no message reported)' "$kind"
  fi
}

# fm_backend_herdr_core_composer_state: empty|pending|pending-unproven|unknown.
# A reporting program's `--if idle` replaces this question entirely, so it
# reports unknown there - the truthful answer, not a guess. A silent program has
# no status, so its composer row is the only readable readiness signal, read the
# same way the other adapters read a bordered composer and classified by the
# shared owner in bin/sq-composer-lib.sh.
fm_backend_herdr_core_composer_state() {  # <target>
  local status_json cap line trimmed content="" bordered=0 found=0
  status_json=$(fm_backend_herdr_core_status_json "${1:-}" 2>/dev/null) || { printf 'unknown'; return 0; }
  [ "$(printf '%s' "$status_json" | jq -r '.reported')" = true ] && { printf 'unknown'; return 0; }
  cap=$(fm_backend_herdr_core_capture "${1:-}" 24 2>/dev/null) || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [ -n "$trimmed" ] || continue
    # A bordered row is a genuine composer container even when it holds only the
    # harness's own prompt glyph. A bare row is a candidate only for an AGENT
    # prompt glyph: a bare shell prompt is never a safe injection target, and the
    # shared classifier below makes that distinction, so the glyph stays in the
    # content it judges.
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
      '>'*|'❯'*|'›'*|'⟩'*) bordered=0 ;;
      *) continue ;;
    esac
    content=$trimmed
    found=1
  done <<EOF
$cap
EOF
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  content=${content//│/}
  content=${content//┃/}
  content=${content//|/}
  content=${content#"${content%%[![:space:]]*}"}
  content=${content%"${content##*[![:space:]]}"}
  fm_composer_classify_content "$bordered" "$content"
}

fm_backend_herdr_core_target_exists() {  # <target> [expected-label]
  local target=${1:-} expected=${2:-} session address json state label
  fm_backend_herdr_core_parse_target "$target" || return 1
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  fm_backend_herdr_core_session_ok "$session" 2>/dev/null || return 1
  json=$(fm_backend_herdr_core_get_json "$session" "$address" 2>/dev/null) || return 1
  fm_backend_herdr_core_record_owned "$session" "$target" "$json" \
    "$(fm_backend_herdr_core_task_id_of_label "$expected")" || return 1
  state=$(printf '%s' "$json" | jq -r '.state')
  [ "$state" = live ] || return 1
  if [ -n "$expected" ]; then
    label=$(printf '%s' "$json" | jq -r --arg key "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL" '(.labels // {})[$key] // ""')
    [ "$label" = "$(fm_backend_herdr_core_task_id_of_label "$expected")" ] || return 1
  fi
}

# --- the blocked-transition poll producer (S1) -----------------------------
# The event-wait splice is not used by this backend yet (S2 adds the native
# stream), so a supervised herdr-core window is reconciled on the sentry's
# ordinary poll: one read per cycle, normalized into the shared record, routed
# through the shared policy table, and deduped per target by the prompt identity.
# The identity is the program's own `kind` + `msg`, not `status_ms`: measured
# live, two consecutive prompts arrived with the SAME status_ms.

fm_backend_herdr_core_normalize_status() {  # <busy-verdict>
  case "$1" in
    busy) printf 'working' ;;
    blocked) printf 'blocked' ;;
    idle) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_core_marker() {  # <state-dir> <prefix> <window>
  local state=$1 prefix=$2 window=$3 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s/%s%s' "$state" "$prefix" "$key"
}

fm_backend_herdr_core_prompt_hash() {  # <target>
  local status_json identity
  status_json=$(fm_backend_herdr_core_status_json "${1:-}" 2>/dev/null) || return 1
  [ "$(printf '%s' "$status_json" | jq -r '.reported')" = true ] || return 1
  identity=$(printf '%s' "$status_json" | jq -r '((.status // "") + "\n" + (.kind // "") + "\n" + (.msg // ""))')
  [ -n "$identity" ] || return 1
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$identity" | md5 -q
  else
    printf '%s' "$identity" | md5sum | cut -d' ' -f1
  fi
}

fm_backend_herdr_core_commit_transition() {  # <state-dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  : > "$(fm_backend_herdr_core_marker "$state" "$SQUAD_BACKEND_HERDR_CORE_ESCALATED_PREFIX" "$session:$pane_id")"
}

fm_backend_herdr_core_clear_transition() {  # <state-dir> <window>
  local state=$1 window=$2
  [ -n "$window" ] || return 0
  rm -f "$(fm_backend_herdr_core_marker "$state" "$SQUAD_BACKEND_HERDR_CORE_ESCALATED_PREFIX" "$window")" 2>/dev/null || true
  rm -f "$(fm_backend_herdr_core_marker "$state" "$SQUAD_BACKEND_HERDR_CORE_PROMPT_PREFIX" "$window")" 2>/dev/null || true
}

# fm_backend_herdr_core_poll_transition: the same contract the TUIOS and Orca
# producers implement.
#   0  a fresh actionable (blocked) record is printed for the caller to hand up
#   1  still blocked but already escalated for this exact prompt
#   2  not currently blocked, or no report at all: the ordinary poll path runs
#   3  previously escalated, current read ambiguous: never reclassified as stale
fm_backend_herdr_core_poll_transition() {  # <state-dir> <session> <window>
  local state=$1 session=$2 window=$3 native status action marker stored prompt_hash hit
  native=$(fm_backend_herdr_core_busy_state "$window" 2>/dev/null) || native=unknown
  status=$(fm_backend_herdr_core_normalize_status "$native")
  action=$(fm_transition_policy "$status")
  if [ "$action" != actionable ]; then
    if [ "$action" = fallback ]; then
      [ -e "$(fm_backend_herdr_core_marker "$state" "$SQUAD_BACKEND_HERDR_CORE_ESCALATED_PREFIX" "$window")" ] && return 3
      return 2
    fi
    fm_backend_herdr_core_clear_transition "$state" "$window"
    return 2
  fi
  marker=$(fm_backend_herdr_core_marker "$state" "$SQUAD_BACKEND_HERDR_CORE_PROMPT_PREFIX" "$window")
  stored=$(cat "$marker" 2>/dev/null || true)
  if prompt_hash=$(fm_backend_herdr_core_prompt_hash "$window" 2>/dev/null); then
    if [ -n "$stored" ] && [ "$stored" != "$prompt_hash" ]; then
      rm -f "$(fm_backend_herdr_core_marker "$state" "$SQUAD_BACKEND_HERDR_CORE_ESCALATED_PREFIX" "$window")" 2>/dev/null || true
    fi
    printf '%s' "$prompt_hash" > "$marker"
  fi
  hit=$(fm_transition_record "${window#*:}" "" "" blocked "" \
    | fm_backend_herdr_core_apply_transition "$state" "$session") || return 1
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

# fm_backend_herdr_core_apply_transition: route one record through the shared
# policy table. Prints it only on a fresh actionable edge with no marker yet.
fm_backend_herdr_core_apply_transition() {  # <state-dir> <session> (record on stdin)
  local state=$1 session=$2 record pane_id to action
  IFS= read -r record || [ -n "$record" ] || return 1
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  if [ "$action" = actionable ] \
    && [ ! -e "$(fm_backend_herdr_core_marker "$state" "$SQUAD_BACKEND_HERDR_CORE_ESCALATED_PREFIX" "$session:$pane_id")" ]; then
    printf '%s' "$record"
    return 0
  fi
  return 1
}
