#!/usr/bin/env bash
# sq-secret.sh - the unit's secret broker: resolve a secret by name and hand it
# straight to its consumer.
#
# The Bitwarden CLI (`bw`) is the only store, and it speaks to whatever server
# it is already configured with, so there is no second vault, no encryption of
# our own, and no value cached on disk.
#
# Usage:
#   sq-secret.sh check
#   sq-secret.sh list
#   sq-secret.sh get <name> [--item <id-or-name>] [--for <task-id>] [--to-tty]
#   sq-secret.sh run [--for <task-id>] --with <ENVVAR>=<name> [--with ...] \
#     -- <command> [args...]
#   sq-secret.sh <command> --help
#
# Names and items
#   Logical name `foo` resolves to the Bitwarden item named `sq/foo` by
#   convention, and `--item` overrides that lookup for one `get` call.
#   A name and a task id are both [A-Za-z0-9._-]+.
#
# Session and server
#   The session is read from BW_SESSION only.
#   When it is absent, expired, or the vault is locked, the call fails closed
#   and names `bw unlock` as the remedy.
#   This script never prompts for a master password and never passes a session
#   key on a command line.
#   The server is whatever `bw` is already configured with and is reported by
#   `check`; this script never reconfigures `bw`.
#   Every `bw` call runs with --nointeraction and stdin from /dev/null, so a
#   missing session can never turn into an interactive prompt.
#
# Security invariants
#   1. A value is written only to `get` stdout, and only when stdout is not a
#      terminal or --to-tty was passed explicitly.
#   2. A value never enters an argv: `--with` carries the name, and the value
#      travels in the child's environment.
#   3. Every resolution appends one line to state/secrets-audit.log carrying its
#      ISO timestamp, logical name, backing item, task id when given, caller
#      (script name and pid), child command when run, and outcome.
#      The log never contains a value, and an unauditable resolution is refused.
#   4. Nothing is cached on disk: no temp file, no state copy, no data/ copy.
#   5. Optional scope policy lives in config/secrets-policy.json as
#      {"<task-id>": ["name", ...]}. A --for call requires that file: only names
#      listed for that task resolve, a task with no entry is denied, and a
#      missing or malformed policy is a failure rather than a bypass.
#      Without --for, resolution is allowed and audited.
#   6. Missing `bw` or `jq`, a locked session, an unknown name, and an
#      unreadable item each fail closed with their own named reason and a
#      non-zero exit.
#
# Facts
#   `check` prints one line per fact - bw, jq, server, session - and exits
#   non-zero when the backend is unusable.
#   `list` prints "<name>\t<item-id>" for every vault item named sq/*, never a
#   value.
#   `get` prints the value and nothing else.
#   `run` execs the command with each resolved value in its environment.
#
# Exit codes
#   0 success; 1 refused or failed resolution; 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
CONFIG="${SQUAD_CONFIG_OVERRIDE:-$SQUAD_BASE/config}"
POLICY="$CONFIG/secrets-policy.json"
AUDIT_LOG="$STATE/secrets-audit.log"
CALLER="$(basename -- "${BASH_SOURCE[0]}"):$$"
# Set by policy_allows when it denies, so the caller can name the reason.
POLICY_REASON=
POLICY_MESSAGE=

usage() {  # [<subcommand>]
  case "${1:-}" in
    check)
      cat <<'EOF'
Usage: sq-secret.sh check

Report whether the backend is usable, one line per fact: bw, jq, server, and
session. Never prompts and never reconfigures bw. Exits non-zero when the
backend is unusable, naming `bw unlock` when the session is the problem.
EOF
      ;;
    list)
      cat <<'EOF'
Usage: sq-secret.sh list

Print "<name>\t<item-id>" for every Bitwarden item named sq/<name>, so a caller
can see the logical names this unit knows and the item backing each one.
Names and metadata only: this never prints a value.
EOF
      ;;
    get)
      cat <<'EOF'
Usage: sq-secret.sh get <name> [--item <id-or-name>] [--for <task-id>] [--to-tty]

Resolve one logical name and write the value to stdout, and nothing else.
Refuses when stdout is a terminal unless --to-tty is passed explicitly.
--item overrides the sq/<name> lookup for this call, and --for applies the
scope policy in config/secrets-policy.json.
EOF
      ;;
    run)
      cat <<'EOF'
Usage: sq-secret.sh run [--for <task-id>] --with <ENVVAR>=<name> [--with ...]
                        -- <command> [args...]

Resolve every name, put each value in the child's environment under the
requested variable name, and exec the command.
--with carries the name only, so the child's argv contains no value.
EOF
      ;;
    *)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
      ;;
  esac
}

fail() {  # <reason> <message>
  printf 'sq-secret: %s: %s\n' "$1" "$2" >&2
  exit 1
}

usage_fail() {  # <message>
  printf 'sq-secret: usage: %s\n' "$1" >&2
  exit 2
}

validate_name() {  # <name>
  case "$1" in
    '' | *[!A-Za-z0-9._-]*) usage_fail "invalid secret name '$1' (expected [A-Za-z0-9._-]+)" ;;
  esac
}

validate_task() {  # <task-id>
  case "$1" in
    '' | *[!A-Za-z0-9._-]*) usage_fail "invalid task id '$1' (expected [A-Za-z0-9._-]+)" ;;
  esac
}

validate_env_var() {  # <ENVVAR>
  case "$1" in
    '' | [0-9]* | *[!A-Za-z0-9_]*) usage_fail "invalid environment variable name '$1'" ;;
  esac
}

# audit_field <value>: render one bounded, single-line, quoted log field so a
# name or item containing spaces or quotes can never break the line shape.
audit_field() {
  local value=$1
  value=${value//[$'\n\r\t']/ }
  value=${value//\"/\'}
  if [ "${#value}" -gt 200 ]; then
    value="${value:0:197}..."
  fi
  printf '"%s"' "$value"
}

# audit <outcome> <name> <item> [task] [command]: append one resolution record.
# The log is created on demand with user-only permissions and is never a
# symlink; no field ever carries a value.
audit() {
  local outcome=$1 name=$2 item=$3 task=${4:-} command=${5:-} dir line
  dir=$(dirname -- "$AUDIT_LOG")
  [ -d "$dir" ] || mkdir -p -- "$dir" 2>/dev/null || return 1
  [ ! -L "$AUDIT_LOG" ] || return 1
  if [ ! -e "$AUDIT_LOG" ]; then
    (umask 077 && : >>"$AUDIT_LOG") 2>/dev/null || return 1
  fi
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) name=$(audit_field "$name") item=$(audit_field "$item")"
  [ -z "$task" ] || line="$line task=$(audit_field "$task")"
  line="$line caller=$(audit_field "$CALLER")"
  [ -z "$command" ] || line="$line command=$(audit_field "$command")"
  printf '%s outcome=%s\n' "$line" "$outcome" >>"$AUDIT_LOG"
}

require_bw() {
  command -v bw >/dev/null 2>&1 \
    || fail bw-missing "the Bitwarden CLI (bw) is not on PATH; install it with 'npm install -g @bitwarden/cli'"
}

require_jq() {
  command -v jq >/dev/null 2>&1 \
    || fail jq-missing "jq is required to read a Bitwarden item and the scope policy"
}

# bw_status_word: print bw's own status word (unlocked, locked, unauthenticated).
bw_status_word() {
  local json word
  json=$(bw status --nointeraction </dev/null 2>/dev/null) || return 1
  word=$(printf '%s' "$json" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$word" ] || return 1
  printf '%s' "$word"
}

# require_session: fail closed unless bw is present and BW_SESSION opens the
# vault. It never prompts and never guesses a session key.
require_session() {
  local word
  require_bw
  [ -n "${BW_SESSION:-}" ] \
    || fail session-missing "BW_SESSION is not set; run 'bw unlock' and export the session it prints"
  word=$(bw_status_word) \
    || fail session-unreadable "bw status could not be read; run 'bw unlock' and export the session it prints"
  [ "$word" = unlocked ] \
    || fail session-locked "the vault is $word; run 'bw unlock' and export the session it prints"
}

# policy_allows <task-id> <name>: return 0 when the task is scoped for the name.
# On denial it sets POLICY_REASON and POLICY_MESSAGE; a missing or malformed
# policy is a denial, never a bypass.
policy_allows() {
  local task=$1 name=$2
  POLICY_REASON=policy-missing
  POLICY_MESSAGE="no config/secrets-policy.json; refusing a --for scope for task '$task'"
  [ -e "$POLICY" ] || return 1
  POLICY_REASON=policy-invalid
  POLICY_MESSAGE="config/secrets-policy.json is not a readable regular file"
  { [ -f "$POLICY" ] && [ ! -L "$POLICY" ]; } || return 1
  command -v jq >/dev/null 2>&1 \
    || { POLICY_MESSAGE="jq is required to read config/secrets-policy.json"; return 1; }
  jq -e 'type == "object" and all(.[]; type == "array" and all(.[]; type == "string"))' \
    "$POLICY" >/dev/null 2>&1 \
    || { POLICY_MESSAGE="config/secrets-policy.json is not an object of name arrays"; return 1; }
  jq -e --arg task "$task" 'has($task)' "$POLICY" >/dev/null 2>&1 \
    || {
      POLICY_REASON=policy-unknown-task
      POLICY_MESSAGE="task '$task' has no entry in config/secrets-policy.json"
      return 1
    }
  jq -e --arg task "$task" --arg name "$name" '.[$task] | index($name) != null' \
    "$POLICY" >/dev/null 2>&1 \
    || {
      POLICY_REASON=policy-denied
      POLICY_MESSAGE="task '$task' is not scoped for secret '$name'"
      return 1
    }
  POLICY_REASON=
  POLICY_MESSAGE=
}

# resolve_value <name> <item> <task> <command>: print the item's password.
# The caller has already established the session with require_session.
# Every outcome is audited, and a failure to audit a successful resolution is
# itself fatal, so no value is ever emitted unaudited.
resolve_value() {
  local name=$1 item=$2 task=$3 command=$4 json value
  if ! json=$(bw get item "$item" --nointeraction </dev/null 2>/dev/null); then
    audit failed "$name" "$item" "$task" "$command"
    fail item-missing "no Bitwarden item matches '$item'"
  fi
  if ! value=$(printf '%s' "$json" | jq -r '.login.password // empty' 2>/dev/null); then
    audit failed "$name" "$item" "$task" "$command"
    fail item-unreadable "the Bitwarden item '$item' could not be read"
  fi
  if [ -z "$value" ]; then
    audit failed "$name" "$item" "$task" "$command"
    fail item-no-password "the Bitwarden item '$item' carries no usable password field"
  fi
  audit ok "$name" "$item" "$task" "$command" \
    || fail audit-unwritable "state/secrets-audit.log could not be written; refusing an unaudited resolution"
  printf '%s' "$value"
}

cmd_check() {
  local rc=0 server word
  if command -v bw >/dev/null 2>&1; then
    printf 'bw: present %s\n' "$(command -v bw)"
  else
    printf 'bw: missing (install the Bitwarden CLI: npm install -g @bitwarden/cli)\n'
    rc=1
  fi
  if command -v jq >/dev/null 2>&1; then
    printf 'jq: present %s\n' "$(command -v jq)"
  else
    printf 'jq: missing (required to read a Bitwarden item and the scope policy)\n'
    rc=1
  fi
  server=
  if command -v bw >/dev/null 2>&1; then
    server=$(bw config server --nointeraction </dev/null 2>/dev/null) || server=
  fi
  if [ -n "$server" ]; then
    printf 'server: %s\n' "$server"
  else
    printf 'server: not configured (run bw config server <url>)\n'
    rc=1
  fi
  if [ -z "${BW_SESSION:-}" ]; then
    printf 'session: missing BW_SESSION (run bw unlock and export the session it prints)\n'
    rc=1
  else
    word=
    if command -v bw >/dev/null 2>&1; then
      word=$(bw_status_word) || word=
    fi
    if [ "$word" = unlocked ]; then
      printf 'session: unlocked\n'
    else
      printf 'session: %s (run bw unlock and export the session it prints)\n' "${word:-unknown}"
      rc=1
    fi
  fi
  return "$rc"
}

cmd_list() {
  local items
  require_session
  require_jq
  items=$(bw list items --nointeraction </dev/null 2>/dev/null) \
    || fail item-listing "bw could not list the vault"
  printf '%s' "$items" | jq -r '
    .[]
    | select((.name // "") | startswith("sq/") and length > 3)
    | [.name[3:], .id]
    | @tsv
  ' | LC_ALL=C sort
}

cmd_get() {  # <name> [--item <id-or-name>] [--for <task-id>] [--to-tty]
  local name='' item='' task='' to_tty=0 value
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        usage get
        exit 0
        ;;
      --to-tty)
        to_tty=1
        shift
        ;;
      --item)
        [ "$#" -ge 2 ] || usage_fail "get --item needs an item id or name"
        item=$2
        [ -n "$item" ] || usage_fail "get --item needs an item id or name"
        shift 2
        ;;
      --for)
        [ "$#" -ge 2 ] || usage_fail "get --for needs a task id"
        task=$2
        shift 2
        ;;
      -*)
        usage_fail "unknown option for get: $1"
        ;;
      *)
        [ -z "$name" ] || usage_fail "get resolves exactly one name"
        name=$1
        shift
        ;;
    esac
  done
  [ -n "$name" ] || usage_fail "get needs a logical secret name"
  validate_name "$name"
  [ -z "$task" ] || validate_task "$task"
  [ -n "$item" ] || item="sq/$name"
  if [ -t 1 ] && [ "$to_tty" -eq 0 ]; then
    audit denied "$name" "$item" "$task" ""
    fail tty-refused "refusing to write a secret to a terminal; redirect stdout or pass --to-tty"
  fi
  require_session
  if [ -n "$task" ] && ! policy_allows "$task" "$name"; then
    audit denied "$name" "$item" "$task" ""
    fail "$POLICY_REASON" "$POLICY_MESSAGE"
  fi
  value=$(resolve_value "$name" "$item" "$task" "")
  printf '%s' "$value"
  if [ -t 1 ]; then
    printf '\n'
  fi
}

cmd_run() {  # [--for <task-id>] --with <ENVVAR>=<name> ... -- <command> [args...]
  local task='' command_string='' value i
  local -a vars=() names=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        usage run
        exit 0
        ;;
      --for)
        [ "$#" -ge 2 ] || usage_fail "run --for needs a task id"
        task=$2
        shift 2
        ;;
      --with)
        [ "$#" -ge 2 ] || usage_fail "run --with needs <ENVVAR>=<name>"
        case "$2" in
          *=*) ;;
          *) usage_fail "run --with needs <ENVVAR>=<name>, got '$2'" ;;
        esac
        validate_env_var "${2%%=*}"
        validate_name "${2#*=}"
        vars+=("${2%%=*}")
        names+=("${2#*=}")
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage_fail "unknown option for run: $1"
        ;;
      *)
        usage_fail "run needs '--' before the command"
        ;;
    esac
  done
  [ "$#" -gt 0 ] || usage_fail "run needs a command after '--'"
  [ "${#vars[@]}" -gt 0 ] || usage_fail "run needs at least one --with <ENVVAR>=<name>"
  [ -z "$task" ] || validate_task "$task"
  command_string="$*"
  require_session
  # Deny the whole call before resolving anything, so a scope failure never
  # leaves a partially resolved command.
  if [ -n "$task" ]; then
    for i in "${!names[@]}"; do
      if ! policy_allows "$task" "${names[$i]}"; then
        audit denied "${names[$i]}" "sq/${names[$i]}" "$task" "$command_string"
        fail "$POLICY_REASON" "$POLICY_MESSAGE"
      fi
    done
  fi
  for i in "${!vars[@]}"; do
    value=$(resolve_value "${names[$i]}" "sq/${names[$i]}" "$task" "$command_string")
    export "${vars[$i]}=${value}"
  done
  exec "$@"
}

[ "$#" -gt 0 ] || {
  usage >&2
  exit 2
}

subcommand=$1
shift
case "$subcommand" in
  check | list)
    case "${1:-}" in
      --help | -h)
        usage "$subcommand"
        exit 0
        ;;
      '') ;;
      *) usage_fail "$subcommand takes no arguments" ;;
    esac
    if [ "$subcommand" = check ]; then
      cmd_check
    else
      cmd_list
    fi
    ;;
  get) cmd_get "$@" ;;
  run) cmd_run "$@" ;;
  --help | -h | help) usage ;;
  *)
    printf 'sq-secret: usage: unknown command %s\n' "$subcommand" >&2
    exit 2
    ;;
esac
