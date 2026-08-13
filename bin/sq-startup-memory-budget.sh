#!/usr/bin/env bash
# Read and account for the local startup-memory budget.
# Usage:
#   sq-startup-memory-budget.sh read
#   sq-startup-memory-budget.sh report
#
# `read` prints the one validated effective budget from
# config/startup-memory-budget.  `report` prints the stable local estimate for
# data/commander.md, data/commander-shared.md, and data/learnings.md together.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent, malformed, symlinked, hardlinked, or otherwise
# unsafe value is a concrete error rather than an inferred default.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
CONFIG="${SQUAD_CONFIG_OVERRIDE:-$SQUAD_BASE/config}"
DATA="${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}"

# shellcheck source=bin/sq-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/sq-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,11{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'startup-memory-budget: %s\n' "$1" >&2
}

read_budget() {
  if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
    print_error "invalid config/$SQUAD_STARTUP_MEMORY_BUDGET_FILE - $SQUAD_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$SQUAD_STARTUP_MEMORY_BUDGET_VALUE"
}

report() {
  local budget bytes tokens presence total=0 shared_tokens=0 role=primary
  if ! budget=$(read_budget); then
    return 2
  fi

  if [ -e "$SQUAD_BASE/.sq-xo-home" ] || [ -L "$SQUAD_BASE/.sq-xo-home" ]; then
    role=xo
  fi

  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'role=%s\n' "$role"
  printf 'effective_budget_tokens=%s\n' "$budget"
  for file in commander.md commander-shared.md learnings.md; do
    if ! fm_startup_memory_measure_file "$DATA/$file" >/dev/null; then
      print_error "$SQUAD_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    bytes=$SQUAD_STARTUP_MEMORY_MEASURE_BYTES
    tokens=$SQUAD_STARTUP_MEMORY_MEASURE_TOKENS
    presence=$SQUAD_STARTUP_MEMORY_MEASURE_PRESENCE
    total=$((total + tokens))
    [ "$file" != commander-shared.md ] || shared_tokens=$tokens
    printf 'file=data/%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$file" "$bytes" "$tokens" "$presence"
  done
  printf 'total_estimated_tokens=%s\n' "$total"
  if fm_startup_memory_decimal_le "$total" "$budget"; then
    printf 'budget_status=within-budget\n'
  else
    printf 'budget_status=over-budget\n'
  fi
  if [ "$role" = xo ] \
    && ! fm_startup_memory_decimal_le "$shared_tokens" "$budget"; then
    printf 'exception=primary-owned-shared-file-alone-exceeds-budget\n'
  fi
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
