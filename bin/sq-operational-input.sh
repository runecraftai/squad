#!/usr/bin/env bash
# sq-operational-input.sh - canonical Squad operational-input protocol.
#
# This file is both a source-safe shell library and the cross-language CLI used
# by JavaScript and TypeScript integrations. It is the single owner of current
# construction, current parsing, and narrow pre-protocol transcript parsing.
#
# Current generic wire form:
#   U+2063 SQUAD_OP: v1 <kind>: <body>
#
# The landed U+2063 + "SQUAD_OP: " prefix is permanent compatibility.
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose. The established from-squad routing
# marker remains a current compatibility carrier because already-running
# XOs have its leading label in their charter context.
#
# CLI:
#   sq-operational-input.sh encode <kind>  # body on stdin, encoded input stdout
#   sq-operational-input.sh kind           # current input on stdin, kind stdout
#   sq-operational-input.sh classify       # current or legacy input on stdin
#   sq-operational-input.sh body           # current generic input on stdin
#   sq-operational-input.sh --help
#
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2. Bash 3.2 compatible.

SQUAD_OPERATIONAL_MARK=$'\xE2\x81\xA3'
SQUAD_OPERATIONAL_PREFIX="${SQUAD_OPERATIONAL_MARK}SQUAD_OP: "
SQUAD_OPERATIONAL_VERSION=v1
SQUAD_OPERATIONAL_HEADER_PREFIX="${SQUAD_OPERATIONAL_PREFIX}${SQUAD_OPERATIONAL_VERSION} "
SQUAD_OPERATIONAL_KINDS='session-start sentry turn-end-guard away-supervisor launch-brief handoff-request'

# Compatibility name retained for the away-mode owner and its tests.
# shellcheck disable=SC2034 # Public source-library variable used by callers.
SQUAD_INJECT_MARK=$SQUAD_OPERATIONAL_MARK

# The from-squad carrier stays byte-compatible with live XO charter
# context while this owner supplies its construction and structural kind.
SQUAD_FROMFIRST_LABEL='[sq-from-squad]'
SQUAD_FROMFIRST_SEPARATOR=$SQUAD_OPERATIONAL_MARK
SQUAD_FROMFIRST_MARK="${SQUAD_FROMFIRST_LABEL}${SQUAD_FROMFIRST_SEPARATOR}"

fm_operational_kind_is_current() {  # <kind>
  case " $SQUAD_OPERATIONAL_KINDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

fm_operational_input_encode() {  # <generic-kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  fm_operational_kind_is_current "$kind" || return 2
  [ -n "$body" ] || return 2
  printf -v "$result_var" '%s%s: %s' "$SQUAD_OPERATIONAL_HEADER_PREFIX" "$kind" "$body"
}

fm_operational_input_construct() {  # <kind> <body> <result-var>
  local kind=${1-} body=${2-} result_var=${3-}
  [ -n "$result_var" ] && [ -n "$body" ] || return 2
  if [ "$kind" = from-squad ]; then
    fm_message_mark_from_Squad "$body" "$result_var"
    return
  fi
  fm_operational_input_encode "$kind" "$body" "$result_var"
}

fm_operational_generic_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} remainder parsed_kind body
  [ -n "$result_var" ] || return 2
  case "$message" in
    "$SQUAD_OPERATIONAL_HEADER_PREFIX"*': '?*) ;;
    *) return 1 ;;
  esac
  remainder=${message#"$SQUAD_OPERATIONAL_HEADER_PREFIX"}
  parsed_kind=${remainder%%': '*}
  fm_operational_kind_is_current "$parsed_kind" || return 1
  body=${remainder#"${parsed_kind}: "}
  [ "$body" != "$remainder" ] && [ -n "$body" ] || return 1
  printf -v "$result_var" '%s' "$parsed_kind"
}

fm_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-} current_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    printf -v "$result_var" '%s' "$current_kind"
    return 0
  fi
  case "$message" in
    "$SQUAD_FROMFIRST_MARK"?*)
      printf -v "$result_var" '%s' from-squad
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_body() {  # <current-message> <result-var>
  local message=${1-} result_var=${2-} current_kind parsed_body
  [ -n "$result_var" ] || return 2
  if fm_operational_generic_kind "$message" current_kind; then
    parsed_body=${message#"${SQUAD_OPERATIONAL_HEADER_PREFIX}${current_kind}: "}
    printf -v "$result_var" '%s' "$parsed_body"
    return 0
  fi
  case "$message" in
    "$SQUAD_FROMFIRST_MARK"?*)
      parsed_body=${message#"$SQUAD_FROMFIRST_MARK"}
      printf -v "$result_var" '%s' "$parsed_body"
      return 0
      ;;
  esac
  return 1
}

# Historical payload literals are intentionally isolated below this line.
# They exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests.
# shellcheck disable=SC2016 # Backticks are literal historical prompt markup.
SQUAD_LEGACY_SESSIONSTART='Run `bin/sq-session-start.sh` now, exactly once, before executing any other instructions.'
SQUAD_LEGACY_WATCHER_PREFIX='SQUAD WATCHER WAKE: '
SQUAD_LEGACY_WATCHER_SUFFIX=$'\n\nRun bin/sq-stand-to-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.'
SQUAD_LEGACY_TURNEND_PREFIX=$'TURN WOULD END BLIND - supervision is off. The sentry cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n'
SQUAD_LEGACY_AWAY_PREFIX="${SQUAD_OPERATIONAL_MARK}Supervisor escalate ("

fm_legacy_operational_input_kind() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2

  # PR 899 landed an untyped SQUAD_OP prefix. Its subtype cannot be
  # recovered without body prose, so it is explicitly generic.
  case "$message" in
    "$SQUAD_OPERATIONAL_PREFIX"?*)
      printf -v "$result_var" '%s' legacy-operational
      return 0
      ;;
  esac

  if [ "$message" = "$SQUAD_LEGACY_SESSIONSTART" ]; then
    printf -v "$result_var" '%s' session-start
    return 0
  fi
  case "$message" in
    "$SQUAD_LEGACY_AWAY_PREFIX"*)
      printf -v "$result_var" '%s' away-supervisor
      return 0
      ;;
    "$SQUAD_LEGACY_WATCHER_PREFIX"*"$SQUAD_LEGACY_WATCHER_SUFFIX")
      [ "${#message}" -gt "$(( ${#SQUAD_LEGACY_WATCHER_PREFIX} + ${#SQUAD_LEGACY_WATCHER_SUFFIX} ))" ] || return 1
      printf -v "$result_var" '%s' sentry
      return 0
      ;;
    "$SQUAD_LEGACY_TURNEND_PREFIX"?*)
      printf -v "$result_var" '%s' turn-end-guard
      return 0
      ;;
  esac
  return 1
}

fm_operational_input_classify() {  # <message> <result-var>
  local message=${1-} result_var=${2-} classified_kind
  [ -n "$result_var" ] || return 2
  if fm_operational_input_kind "$message" classified_kind ||
     fm_legacy_operational_input_kind "$message" classified_kind; then
    printf -v "$result_var" '%s' "$classified_kind"
    return 0
  fi
  return 1
}

fm_message_from_Squad() {  # <message>
  local kind
  fm_operational_input_kind "${1-}" kind && [ "$kind" = from-squad ]
}

fm_message_mark_from_Squad() {  # <message> <result-var>
  local message=${1-} result_var=${2-} transformed
  [ -n "$result_var" ] || return 2
  if fm_message_from_Squad "$message"; then
    transformed=$message
  else
    transformed="${SQUAD_FROMFIRST_MARK}${message}"
  fi
  printf -v "$result_var" '%s' "$transformed"
}

fm_operational_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

fm_operational_usage() {
  cat <<'EOF'
Usage:
  bin/sq-operational-input.sh encode <kind>  # body on stdin
  bin/sq-operational-input.sh kind           # current input on stdin
  bin/sq-operational-input.sh classify       # current or legacy input on stdin
  bin/sq-operational-input.sh body           # current input on stdin

Current construction kinds:
  session-start sentry turn-end-guard away-supervisor from-squad launch-brief handoff-request

The from-squad kind uses its established live-charter-compatible carrier.
EOF
}

fm_operational_main() {
  local command=${1-} argument=${2-} input output
  case "$command" in
    -h|--help|help)
      fm_operational_usage
      ;;
    encode)
      [ "$#" -eq 2 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_construct "$argument" "$input" output || return 2
      printf '%s' "$output"
      ;;
    kind)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_kind "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    classify)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_classify "$input" output || return 1
      printf '%s\n' "$output"
      ;;
    body)
      [ "$#" -eq 1 ] || return 2
      fm_operational_read_stdin input || return 2
      fm_operational_input_body "$input" output || return 1
      printf '%s' "$output"
      ;;
    *)
      fm_operational_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_operational_main "$@"
  exit $?
fi
