#!/usr/bin/env bash
# Resolve and verify one registered Claude account's isolated CLAUDE_CONFIG_DIR.
#
# config/claude-accounts is a local, gitignored registry mapping short labels
# to absolute CLAUDE_CONFIG_DIR paths, one already-authenticated Claude
# account each. It exists so bin/sq-spawn.sh's --account selector can move a
# harness=claude operator onto a different account than Squad's own ambient
# one when the active account hits its session limit - registering an
# account (running `claude auth login` against its config dir) remains the
# commander's own action; this script only ever reads.
#
# Registry format (docs/configuration.md "Claude account selection" is the
# schema owner): one non-comment, non-blank line per account,
# "<label> <absolute-CLAUDE_CONFIG_DIR-path>", whitespace-separated. '#'
# starts a comment. A malformed line (wrong token count, a relative path, or a
# label reused on a later line) is refused rather than guessed around.
#
# Usage:
#   sq-claude-account.sh list
#       Print "<label> <dir>" for every registered account, one per line.
#       Prints nothing (exit 0) when the registry is absent or empty.
#   sq-claude-account.sh resolve <label>
#       Print the registered absolute dir for <label>, or fail with the known
#       label list when the registry is absent or <label> is not registered.
#   sq-claude-account.sh verify <label>
#       Resolve <label>, then run a bounded, read-only
#       `claude auth status --json` under that CLAUDE_CONFIG_DIR. On success
#       (a live claude CLI, a clean exit, and a JSON loggedIn:true field - two
#       independent structural signals from the one vendor command, neither
#       alone trusted) print the resolved dir and exit 0. On any other
#       outcome - unregistered label, missing claude CLI, a bound timeout, or
#       a config dir that is not logged in - print an actionable refusal to
#       stderr and exit 1. Never runs `claude auth login`, `claude auth
#       logout`, or any other mutating or interactive claude command.
#
# Environment:
#   SQUAD_CLAUDE_ACCOUNT_VERIFY_TIMEOUT   hard bound in seconds for the
#       `claude auth status` call (default 20); a non-positive or
#       non-numeric value falls back to the default (bin/sq-timeout-lib.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
CONFIG="${SQUAD_CONFIG_OVERRIDE:-$SQUAD_BASE/config}"
REGISTRY="$CONFIG/claude-accounts"

# shellcheck source=bin/sq-timeout-lib.sh
. "$SCRIPT_DIR/sq-timeout-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

# registry_lines: print "<label> <dir>" for every valid registry line, or fail
# on the first malformed or duplicate line naming it by number. Prints nothing
# and succeeds when the registry is absent.
registry_lines() {
  local line n=0 label dir seen=$'\n'
  [ -f "$REGISTRY" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
    set -- $line
    if [ "$#" -ne 2 ]; then
      echo "error: config/claude-accounts:$n: expected '<label> <config-dir>', got '$line'" >&2
      return 1
    fi
    label=$1
    dir=$2
    case "$dir" in
      /*) : ;;
      *)
        echo "error: config/claude-accounts:$n: config dir must be an absolute path, got '$dir'" >&2
        return 1
        ;;
    esac
    case "$seen" in
      *$'\n'"$label"$'\n'*)
        echo "error: config/claude-accounts:$n: duplicate account label '$label'" >&2
        return 1
        ;;
    esac
    seen="$seen$label"$'\n'
    printf '%s %s\n' "$label" "$dir"
  done < "$REGISTRY"
}

cmd_list() {
  registry_lines
}

# known_labels: comma-separated label list from an already-validated
# registry_lines snapshot, for actionable error messages.
known_labels() {
  local snapshot=$1 line known=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    known="${known:+$known, }${line%% *}"
  done <<EOF
$snapshot
EOF
  printf '%s\n' "${known:-none registered}"
}

cmd_resolve() {
  local want=$1 snapshot line label dir
  if [ ! -f "$REGISTRY" ]; then
    echo "error: no Claude accounts are registered; create config/claude-accounts (see docs/configuration.md \"Claude account selection\")" >&2
    return 1
  fi
  snapshot=$(registry_lines) || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    label=${line%% *}
    dir=${line#* }
    if [ "$label" = "$want" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done <<EOF
$snapshot
EOF
  echo "error: unknown Claude account '$want'; registered accounts: $(known_labels "$snapshot")" >&2
  return 1
}

cmd_verify() {
  local label=$1 dir out rc timeout_s
  dir=$(cmd_resolve "$label") || return 1
  if ! command -v claude >/dev/null 2>&1; then
    echo "error: claude executable not found on PATH; cannot verify Claude account '$label'" >&2
    return 1
  fi
  timeout_s=${SQUAD_CLAUDE_ACCOUNT_VERIFY_TIMEOUT:-20}
  case "$timeout_s" in
    ''|*[!0-9]*|0*) timeout_s=20 ;;
  esac
  rc=0
  out=$(CLAUDE_CONFIG_DIR="$dir" fm_run_timed "$timeout_s" claude auth status --json 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "error: Claude account '$label' at $dir: 'claude auth status' timed out after ${timeout_s}s" >&2
    return 1
  fi
  # Two independent structural signals from the one vendor JSON command -
  # the clean exit and the parsed loggedIn field - so neither alone is
  # trusted as the verdict (squad-coding-guidelines "Harness-dependent checks").
  case "$out" in
    *'"loggedIn": true'*|*'"loggedIn":true'*)
      if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$dir"
        return 0
      fi
      ;;
  esac
  echo "error: Claude account '$label' at $dir is not logged in (claude auth status exit=$rc). Registering an account is the commander's own action: log in with CLAUDE_CONFIG_DIR=$dir claude auth login, then retry." >&2
  return 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  list)
    [ "$#" -eq 1 ] || { echo "usage: sq-claude-account.sh list" >&2; exit 2; }
    cmd_list
    ;;
  resolve)
    [ "$#" -eq 2 ] || { echo "usage: sq-claude-account.sh resolve <label>" >&2; exit 2; }
    cmd_resolve "$2"
    ;;
  verify)
    [ "$#" -eq 2 ] || { echo "usage: sq-claude-account.sh verify <label>" >&2; exit 2; }
    cmd_verify "$2"
    ;;
  *) usage >&2; exit 2 ;;
esac
