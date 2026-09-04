#!/usr/bin/env bash
# Integration tests for bin/sq-learn.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/sq-learn.sh"

if [ ! -x "$SCRIPT" ]; then
  printf 'FAIL - required executable bin/sq-learn.sh is missing\n' >&2
  exit 1
fi

passed=0
failed=0

pass() {
  passed=$((passed + 1))
  printf 'PASS - %s\n' "$1"
}

fail() {
  failed=$((failed + 1))
  printf 'FAIL - %s: %s\n' "$1" "$2" >&2
}

run_test() {
  local name=$1
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name" "assertion failed"
  fi
}

new_home() {
  local home
  home=$(mktemp -d "${TMPDIR:-/tmp}/sq-learn.XXXXXX") || return 1
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

cleanup_home() {
  rm -rf "$1"
}

run_learn() {
  local home=$1
  shift
  SQUAD_BASE="$home" "$SCRIPT" "$@"
}

test_basic_append() {
  local home output
  home=$(new_home) || return 1
  output=$(run_learn "$home" 'Use the guarded sync command after a merged change.') || {
    cleanup_home "$home"
    return 1
  }
  grep -Fq 'Use the guarded sync command after a merged change.' "$home/data/learnings.md"
  cleanup_home "$home"
}

test_metadata() {
  local home
  home=$(new_home) || return 1
  run_learn "$home" 'The API requires an explicit timeout.' --task task-42 --source 'integration test' >/dev/null || {
    cleanup_home "$home"
    return 1
  }
  grep -Eq '20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$home/data/learnings.md" &&
    grep -Eiq 'task[^[:alnum:]]*task-42' "$home/data/learnings.md" &&
    grep -Eiq 'source[^[:alnum:]]*integration test' "$home/data/learnings.md"
  local result=$?
  cleanup_home "$home"
  return "$result"
}

test_truncation() {
  local home lesson entry payload
  home=$(new_home) || return 1
  lesson=$(printf '%600s' '' | tr ' ' 'x')
  run_learn "$home" "$lesson" >/dev/null || {
    cleanup_home "$home"
    return 1
  }
  entry=$(grep '^-' "$home/data/learnings.md")
  payload=${entry#*):** }
  [ "${#payload}" -eq 500 ]
  local result=$?
  cleanup_home "$home"
  return "$result"
}

test_deduplication() {
  local home second count
  home=$(new_home) || return 1
  run_learn "$home" 'Do not parse status logs as current state.' >/dev/null || {
    cleanup_home "$home"
    return 1
  }
  second=$(run_learn "$home" 'Do not parse status logs as current state.') || {
    cleanup_home "$home"
    return 1
  }
  count=$(grep -Fc 'Do not parse status logs as current state.' "$home/data/learnings.md")
  cleanup_home "$home"
  [ "$count" -eq 1 ] && printf '%s\n' "$second" | grep -Eqi 'skip|duplicate|already'
}

test_missing_file() {
  local home
  home=$(mktemp -d "${TMPDIR:-/tmp}/sq-learn.XXXXXX") || return 1
  run_learn "$home" 'Create the memory file on first use.' >/dev/null || {
    cleanup_home "$home"
    return 1
  }
  [ -s "$home/data/learnings.md" ]
  local result=$?
  cleanup_home "$home"
  return "$result"
}

test_help() {
  local output
  output=$($SCRIPT --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -Fq 'sq-learn' &&
    printf '%s\n' "$output" | grep -Fq -- '--task' &&
    printf '%s\n' "$output" | grep -Fq -- '--source'
}

run_test 'basic append' test_basic_append
run_test 'metadata includes date, task, and source' test_metadata
run_test 'lesson is limited to 500 characters' test_truncation
run_test 'duplicate lesson is skipped' test_deduplication
run_test 'missing learnings.md is created' test_missing_file
run_test 'help output describes usage' test_help

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
