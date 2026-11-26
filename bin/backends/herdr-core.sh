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
#     makes therefore runs only after the session's socket is present. When it is
#     absent the adapter refuses and says who must start the core.
#   * VERSION AND PROTOCOL GUARD. Before a task is created, the adapter
#     handshakes one `hello` for protocol generation 1, refuses a version below
#     the measured floor, and refuses any core whose own catalog lacks a method,
#     a parameter, or a feature this adapter calls. A named refusal, never a
#     silent degradation.
#   * ADDRESS-EXACT ONLY. Every write names one opaque address that Squad
#     created. Never `--all`, never a server-global verb, never a name selector
#     and never another program's terminal. The cleanup identity is the triple
#     (recorded address, `squad.task=<id>` label, recorded core id), checked
#     immediately before `kill` and again before `rm`.
#   * Status is the program's own OSC 7501 report. `busy_state` maps it, and
#     `blocked` is a person-needed verdict, never ordinary work. A lane that
#     reports no status is supervised by polling exactly as a tmux lane is.
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

# Per-target dedupe markers for the blocked-transition producer, keyed like the
# sentry's own .stale-<key> files.
SQUAD_BACKEND_HERDR_CORE_ESCALATED_PREFIX='.herdr-core-escalated-'
SQUAD_BACKEND_HERDR_CORE_PROMPT_PREFIX='.herdr-core-prompt-'

# --- the CLI, the session, and the no-start rule ---------------------------

fm_backend_herdr_core_bin() {
  printf '%s' "${SQUAD_HC_BIN:-hc}"
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
fm_backend_herdr_core_socket() {  # <session>
  local session=${1:-default}
  if [ -n "${HC_SOCKET:-}" ]; then
    printf '%s' "$HC_SOCKET"
    return 0
  fi
  printf '%s/herdr-core/%s.sock' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" "$session"
}

# fm_backend_herdr_core_core_present: refuse unless a core is listening for
# <session>. THIS is the whole never-start-a-core rule: no other function in
# this file runs `hc` without it.
fm_backend_herdr_core_core_present() {  # <session>
  local session=${1:-default} socket
  socket=$(fm_backend_herdr_core_socket "$session")
  [ -S "$socket" ] && return 0
  echo "error: herdr-core is not running for session '$session' (no core socket at $socket); Squad never starts the core - start Herdr or run 'hc server start' yourself" >&2
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

# --- target parsing and the identity triple --------------------------------

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

# fm_backend_herdr_core_recorded_core_id: the core id recorded with the task that
# owns <target>, if this base records one. Empty (success) when the target has no
# metadata of its own, which is the ad hoc-probe case.
fm_backend_herdr_core_recorded_core_id() {  # <target>
  local target=$1 meta
  meta=$(fm_backend_meta_for_window "$target" "${SQUAD_BACKEND_STATE_DIR:-}" 2>/dev/null) || return 0
  fm_meta_get "$meta" hc_core_id
}

# fm_backend_herdr_core_verify: THE identity check every write runs first. It
# parses the exact target, refuses a session this process does not resolve,
# refuses when the recorded core id no longer matches, requires the address to be
# live, and requires its `squad.task` label to be this task's. An `<expected>`
# label of `sq-<id>` selects that task; an empty one still requires a readable
# address. `<allow-finished>` is set only by the cleanup path, because a task
# whose program already exited is a `finished` address that a close must still
# be able to retire - it never licenses a write of any other kind.
fm_backend_herdr_core_verify() {  # <target> [expected-label] [allow-finished]
  local target=${1:-} expected=${2:-} allow_finished=${3:-} session address json recorded live state label
  fm_backend_herdr_core_parse_target "$target" || {
    echo "error: malformed herdr-core target '$target'; expected <session>:<address>" >&2
    return 1
  }
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  fm_backend_herdr_core_session_ok "$session" || return 1
  recorded=$(fm_backend_herdr_core_recorded_core_id "$target" 2>/dev/null || true)
  if [ -n "$recorded" ]; then
    live=$(fm_backend_herdr_core_read_core_id "$session" 2>/dev/null || true)
    if [ -z "$live" ] || [ "$live" != "$recorded" ]; then
      echo "error: herdr-core identity for $target changed (recorded core ${recorded:-unreadable}, live core ${live:-unreadable}); refusing every write" >&2
      return 1
    fi
  fi
  if ! json=$(fm_backend_herdr_core_get_json "$session" "$address"); then
    echo "error: herdr-core address $address is not readable in session '$session'" >&2
    return 1
  fi
  state=$(printf '%s' "$json" | jq -r '.state')
  case "$state" in
    live) ;;
    finished)
      [ "$allow_finished" = 1 ] || {
        echo "error: herdr-core address $address is finished, not live; refusing to write to it" >&2
        return 1
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
      return 1
    fi
  fi
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
# not carry the core id and task label this base recorded for <target>, and 5
# when a recorded core id cannot be verified against a readable live core id.
fm_backend_herdr_core_status_json() {  # <target>
  local target=${1:-} session address json rc=0
  fm_backend_herdr_core_parse_target "$target" || return 1
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  fm_backend_herdr_core_session_ok "$session" || return 1
  # The read's own status is preserved: an absent address (3) must never look
  # like a successful read of an empty record.
  json=$(fm_backend_herdr_core_get_json "$session" "$address") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_backend_herdr_core_record_owned "$session" "$target" "$json" || rc=$?
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

fm_backend_herdr_core_capture_rendered() {  # <target> [expected-label]
  fm_backend_herdr_core_capture "${1:-}" 0 "${2:-}"
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
#   not_ready            the program declined because its status was not idle; nothing was typed
#   no_agent             the address has finished or is gone; nothing was typed
#   uncertain-delivery   the call failed without a stable refusal kind, so bytes may have landed
fm_backend_herdr_core_deliver() {  # <target> <text> [expected-label]
  local target=${1:-} text=${2:-} expected=${3:-} status_json reported kind rc err_file
  fm_backend_herdr_core_verify "$target" "$expected" || { printf 'no_agent'; return 0; }
  status_json=$(fm_backend_herdr_core_status_json "$target" 2>/dev/null) || { printf 'no_agent'; return 0; }
  reported=$(printf '%s' "$status_json" | jq -r '.reported')
  err_file=$(mktemp "${TMPDIR:-/tmp}/sq-hc-send.XXXXXX") || { printf 'send-failed'; return 0; }
  if [ "$reported" = true ]; then
    # A reporting program's own status is the readiness contract: `--if idle`
    # makes the product itself refuse rather than typing over a running turn or
    # into a blocked dialog, and nothing is typed on that refusal.
    fm_backend_herdr_core_cli "$SQUAD_BACKEND_HERDR_CORE_SESSION" send --json --if idle \
      "$SQUAD_BACKEND_HERDR_CORE_ADDRESS" "$text" >/dev/null 2>"$err_file" && rc=0 || rc=$?
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
# a-z 0-9 - _. A longer task id is truncated and disambiguated by a hash of the
# full id, so two long ids can never collide on one name.
fm_backend_herdr_core_name_for_task() {  # <task-id>
  local id=${1:-} slug prefix=sq- suffix full
  slug=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
  slug=${slug#-}
  [ -n "$slug" ] || slug=task
  # A task id that already carries Squad's own `sq-` prefix is not prefixed twice.
  case "$slug" in sq-*) prefix='' ;; esac
  full="$prefix$slug"
  if [ "${#full}" -le 32 ]; then
    printf '%s' "$full"
    return 0
  fi
  if command -v md5 >/dev/null 2>&1; then
    suffix=$(printf '%s' "$id" | md5 -q | cut -c1-6)
  else
    suffix=$(printf '%s' "$id" | md5sum | cut -c1-6)
  fi
  printf '%s-%s' "$(printf '%s' "$full" | cut -c1-25)" "$suffix"
}

fm_backend_herdr_core_create_task() {  # <session> <task-label> <cwd> -> address
  local session=${1:-} label=${2:-} cwd=${3:-} task_id base name out address duplicate
  [ -n "$label" ] || { echo 'error: herdr-core create_task needs a task label' >&2; return 1; }
  [ -n "$cwd" ] && [ -d "$cwd" ] || { echo "error: herdr-core create_task needs an existing directory, got '$cwd'" >&2; return 1; }
  task_id=$(fm_backend_herdr_core_task_id_of_label "$label")
  base=$(basename "${SQUAD_BASE:-${SQUAD_ROOT:-squad}}")
  name=$(fm_backend_herdr_core_name_for_task "$task_id")
  # Refuse a second live terminal for the same task label: a duplicate endpoint
  # would split one task across two terminals.
  out=$(fm_backend_herdr_core_cli "$session" ls --json --label "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL=$task_id" 2>/dev/null) || {
    echo "error: cannot read the herdr-core inventory for session '$session'" >&2
    return 1
  }
  duplicate=$(printf '%s' "$out" | jq -r '[.terminals[]?] | length' 2>/dev/null) || duplicate=unknown
  if [ "$duplicate" != 0 ]; then
    echo "error: a live herdr-core terminal already carries $SQUAD_BACKEND_HERDR_CORE_TASK_LABEL=$task_id ($duplicate found); refusing a duplicate endpoint" >&2
    return 1
  fi
  out=$(fm_backend_herdr_core_cli "$session" run --bg --json --no-parent \
    --name "$name" --cwd "$cwd" \
    --label "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL=$task_id" \
    --label "$SQUAD_BACKEND_HERDR_CORE_BASE_LABEL=$base" 2>&1) || {
    echo "error: herdr-core refused to create the terminal for $label: ${out:-no reason given}" >&2
    return 1
  }
  address=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null) || address=
  if ! fm_backend_opaque_address_valid "$address"; then
    echo "error: herdr-core returned no usable opaque address for $label" >&2
    return 1
  fi
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
fm_backend_herdr_core_agent_state() {  # <target>
  local target=${1:-} status_json state rc=0
  status_json=$(fm_backend_herdr_core_status_json "$target" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      3|4) printf 'missing' ;;
      5) printf 'unreadable' ;;
      *)
        if [ -n "$(fm_backend_herdr_core_recorded_core_id "$target" 2>/dev/null || true)" ]; then
          printf 'unreadable'
        else
          printf 'missing'
        fi
        ;;
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
fm_backend_herdr_core_recorded_task_id_for_target() {  # <target>
  local target=${1:-} meta
  meta=$(fm_backend_meta_for_window "$target" "${SQUAD_BACKEND_STATE_DIR:-}" 2>/dev/null) || return 0
  fm_meta_get "$meta" endpoint_task_id
}

# fm_backend_herdr_core_record_owned: does one read of <target> carry the two
# identities this base recorded for it? A recycled address in a restarted core,
# or an address another task now owns, has lost one of them, so a status
# consumer must refuse the record instead of projecting a stranger's state onto
# the task that recorded the address. A recorded core id that cannot be read is
# not a mismatch: it is an unverifiable identity, which callers must never
# confuse with an authoritatively absent endpoint.
#   0  both recorded identities are present and agree
#   1  an identity belongs to something else (foreign, recycled, or re-labelled)
#   2  a core id is recorded and the live core id cannot be read
fm_backend_herdr_core_record_owned() {  # <session> <target> <json>
  local session=${1:-default} target=${2:-} json=${3:-} recorded live recorded_id label rc=0
  recorded=$(fm_backend_herdr_core_recorded_core_id "$target" 2>/dev/null || true)
  if [ -n "$recorded" ]; then
    live=$(fm_backend_herdr_core_read_core_id "$session" 2>/dev/null) || rc=$?
    [ "$rc" -eq 0 ] && [ -n "$live" ] || return 2
    [ "$live" = "$recorded" ] || return 1
  fi
  recorded_id=$(fm_backend_herdr_core_recorded_task_id_for_target "$target" 2>/dev/null || true)
  if [ -n "$recorded_id" ]; then
    label=$(printf '%s' "$json" | jq -r --arg key "$SQUAD_BACKEND_HERDR_CORE_TASK_LABEL" '(.labels // {})[$key] // ""')
    [ "$label" = "$recorded_id" ] || return 1
  fi
  return 0
}

# fm_backend_herdr_core_kill: close ONE exact address after the identity triple,
# and confirm both destructive steps. Never `--all`, never a name, never a
# server-global verb, and never an address whose label or core id does not match.
# Refuses (nonzero) whenever the exact close cannot be confirmed, so a caller
# that preserves metadata on refusal keeps a retryable record.
fm_backend_herdr_core_kill() {  # <target> [unused] [expected-label]
  local target=${1:-} expected=${3:-} session address out state removed
  # A task whose program already exited is a finished address; the close still
  # has to retire it, so finished is accepted here and nowhere else.
  fm_backend_herdr_core_verify "$target" "$expected" 1 || return 1
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
  fm_backend_herdr_core_verify "$target" "$expected" 1 || return 1
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

# fm_backend_herdr_core_task_closed: teardown's confirmation that the exact
# terminal this task opened is gone. Only an authoritative "no such address"
# counts; a foreign terminal at that address, or an unreadable core, refuses.
fm_backend_herdr_core_task_closed() {  # <target> <task-id>
  local target=${1:-} id=${2:-} session address rc=0
  if ! fm_backend_herdr_core_parse_target "$target"; then
    echo "error: malformed herdr-core target '$target'; cannot confirm the close" >&2
    return 1
  fi
  session=$SQUAD_BACKEND_HERDR_CORE_SESSION
  address=$SQUAD_BACKEND_HERDR_CORE_ADDRESS
  fm_backend_herdr_core_session_ok "$session" || return 1
  fm_backend_herdr_core_get_json "$session" "$address" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    3) return 0 ;;
    *)
      echo "error: herdr-core address $address for task $id could not be read in session '$session' (unreachable core or an inconsistent record); cannot confirm the close" >&2
      return 1
      ;;
  esac
  echo "error: herdr-core address $address for task $id is still present; refusing to retire its records" >&2
  return 1
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
  fm_backend_herdr_core_record_owned "$session" "$target" "$json" || return 1
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
