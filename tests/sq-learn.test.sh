#!/usr/bin/env bash
# End-to-end behavior tests for durable operational lesson capture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEARN="$ROOT/bin/sq-learn.sh"
TMP_ROOT=$(fm_test_tmproot sq-learn)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

run_learn() {
  local home=$1
  shift
  SQUAD_BASE="$home" SQUAD_ROOT_OVERRIDE="$ROOT" \
    SQUAD_DATA_OVERRIDE="$home/data" SQUAD_CONFIG_OVERRIDE="$home/config" \
    "$LEARN" "$@"
}

with_budget() {
  local home=$1 budget=$2
  mkdir -p "$home/config"
  printf '%s\n' "$budget" > "$home/config/startup-memory-budget"
}

expect_rejected() {
  local home=$1 expected=$2 out rc
  shift 2
  set +e
  out=$(run_learn "$home" "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "lesson unexpectedly accepted: $expected"
  assert_contains "$out" "$expected" "rejection did not explain $expected"
}

test_capture_normalizes_and_deduplicates() {
  local home output before after entry
  home=$(make_home capture)
  with_budget "$home" 7500

  output=$(run_learn "$home" $'A lesson\nwith  extra spaces' --task $'task\nid' --source $'evidence\nref') 
  [ "$output" = 'lesson captured' ] || fail "capture did not report success: $output"
  entry=$(<"$home/data/learnings.md")
  assert_contains "$entry" 'A lesson with extra spaces' "captured lesson was not flattened"
  assert_contains "$entry" '[task: task id]' "task metadata was not flattened"
  assert_contains "$entry" '[source: evidence ref]' "source metadata was not flattened"
  [ "$(printf '%s' "$entry" | wc -l | tr -d ' ')" = 2 ] \
    || fail "lesson capture wrote more than one Markdown entry line"

  before=$(sha256sum "$home/data/learnings.md" | awk '{print $1}')
  output=$(run_learn "$home" 'a LESSON with extra spaces' --task another-task)
  after=$(sha256sum "$home/data/learnings.md" | awk '{print $1}')
  [ "$output" = 'duplicate skipped' ] || fail "near-duplicate was not skipped: $output"
  [ "$before" = "$after" ] || fail "duplicate detection changed persisted learnings"
  pass "capture persists a flattened lesson and skips a case-insensitive near duplicate"
}

test_invalid_input_is_rejected_before_truncation() {
  local home whitespace long
  home=$(make_home invalid)
  with_budget "$home" 7500
  whitespace=$(printf ' %.0s' {1..600})
  long=$(printf 'x%.0s' {1..600})
  expect_rejected "$home" 'lesson must not be empty' "$whitespace"
  [ ! -e "$home/data/learnings.md" ] || fail "whitespace-only input created a lesson file"
  run_learn "$home" "$long" >/dev/null || fail "valid long lesson was rejected"
  [ "$(grep -c '^-' "$home/data/learnings.md")" = 1 ] || fail "long lesson did not create one entry"
  local entry payload
  entry=$(grep '^-' "$home/data/learnings.md")
  payload=${entry#*):** }
  [ "${#payload}" = 500 ] || fail "long lesson was not capped at 500 characters: ${#payload}"
  pass "whitespace-only input is rejected while a long valid lesson is captured and capped"
}

test_budget_and_hardlink_safety_refuse_without_mutation() {
  local home outside before output
  home=$(make_home safety)
  with_budget "$home" 1
  expect_rejected "$home" 'startup-memory budget would be exceeded' 'budget should refuse this lesson'
  [ ! -e "$home/data/learnings.md" ] || fail "over-budget capture created learnings"

  home=$(make_home hardlink)
  with_budget "$home" 7500
  outside="$TMP_ROOT/external-learnings"
  printf '# existing\n' > "$outside"
  ln "$outside" "$home/data/learnings.md"
  before=$(sha256sum "$outside" | awk '{print $1}')
  expect_rejected "$home" 'learnings file is hardlinked' 'new lesson'
  output=$(sha256sum "$outside" | awk '{print $1}')
  [ "$before" = "$output" ] || fail "hardlink refusal changed the external source"
  [ "$(stat -c %h "$outside" 2>/dev/null || stat -f %l "$outside")" = 2 ] \
    || fail "hardlink refusal altered link count"
  pass "budget overflow and hardlinked persistence are refused without mutation"
}

test_concurrent_captures_are_serialized() {
  local home output1 output2 p1 p2 entries
  home=$(make_home concurrent)
  with_budget "$home" 7500
  (run_learn "$home" 'first concurrent lesson' > "$home/one.out") & p1=$!
  (run_learn "$home" 'second concurrent lesson' > "$home/two.out") & p2=$!
  wait "$p1" || fail "first concurrent capture failed"
  wait "$p2" || fail "second concurrent capture failed"
  output1=$(<"$home/one.out")
  output2=$(<"$home/two.out")
  [ "$output1" = 'lesson captured' ] || fail "first concurrent capture did not succeed"
  [ "$output2" = 'lesson captured' ] || fail "second concurrent capture did not succeed"
  entries=$(grep -c '^-' "$home/data/learnings.md")
  [ "$entries" = 2 ] || fail "concurrent captures lost an entry: $entries"
  assert_contains "$(<"$home/data/learnings.md")" 'first concurrent lesson' "first concurrent lesson missing"
  assert_contains "$(<"$home/data/learnings.md")" 'second concurrent lesson' "second concurrent lesson missing"
  pass "concurrent captures retain both persisted lessons"
}

test_capture_normalizes_and_deduplicates
test_invalid_input_is_rejected_before_truncation
test_budget_and_hardlink_safety_refuse_without_mutation
test_concurrent_captures_are_serialized
printf '# all sq-learn tests passed\n'
