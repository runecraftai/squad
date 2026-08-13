#!/usr/bin/env bash
# Deterministic new-session handoff queue regression (docs/handoff-request.md).
#
# Covers the durable state machine (pending -> surfaced -> resolved), the
# writer's idempotence and validation, the surfacer's atomic once-per-milestone
# mark including a concurrent-surfacer race, the primary-scope silence, and the
# payload sanitization that keeps the TAB wire format unbreakable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REQ="$ROOT/bin/sq-handoff-request.sh"
SURFACE="$ROOT/bin/sq-handoff-surface.sh"
TMP_ROOT=$(fm_test_tmproot sq-handoff-queue-tests)

# make_home <dir>: an empty home with a state dir.
make_home() {
  local dir=$1
  mkdir -p "$dir/state"
}

# make_primary_root <dir>: a plain git checkout that satisfies the surfacer's
# primary-scope predicate (AGENTS.md and bin/ present, not a linked worktree).
make_primary_root() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" config user.name 'Squad Tests'
  git -C "$dir" config user.email 'tests@example.invalid'
  printf '# Squad\n' > "$dir/AGENTS.md"
  mkdir -p "$dir/bin"
  git -C "$dir" add AGENTS.md
  git -C "$dir" commit -qm init
}

add_record() {  # <home> <kind> <key> <payload...>
  local home=$1
  shift
  SQUAD_BASE="$home" "$REQ" add "$@"
}

list_records() {  # <home> [filter]
  local home=$1 filter=${2-}
  if [ -n "$filter" ]; then
    SQUAD_BASE="$home" "$REQ" list "$filter"
  else
    SQUAD_BASE="$home" "$REQ" list
  fi
}

run_surface() {  # <home> <root>
  SQUAD_BASE="$1" SQUAD_ROOT_OVERRIDE="$2" "$SURFACE"
}

test_add_writes_pending_and_list_filters() {
  local home="$TMP_ROOT/add"
  make_home "$home"
  add_record "$home" pr-merged m2 "M2 landed via PR #42"
  add_record "$home" queue-drained q1 "flight queue drained (3 items)"

  local open pending all
  open=$(list_records "$home" --open)
  assert_contains "$open" $'\tpr-merged\tm2\tpending\t' "open list lost the pending pr-merged record"
  assert_contains "$open" $'\tqueue-drained\tq1\tpending\t' "open list lost the pending queue-drained record"
  pending=$(list_records "$home" --pending)
  assert_contains "$pending" $'\tpr-merged\tm2\tpending\t' "pending filter lost the pr-merged record"
  assert_contains "$pending" $'\tqueue-drained\tq1\tpending\t' "pending filter lost the queue-drained record"
  surfaced=$(list_records "$home" --surfaced)
  [ -z "$surfaced" ] || fail "surfaced filter listed pending records: $surfaced"
  all=$(list_records "$home" --all)
  assert_contains "$all" $'\tpr-merged\tm2\tpending\tM2 landed via PR #42' "all-list lost the pr-merged payload"
  pass "add writes pending records and list filters by state"
}

test_add_is_idempotent_by_kind_and_key() {
  local home="$TMP_ROOT/idem"
  make_home "$home"
  add_record "$home" pr-merged m2 "first write"
  add_record "$home" pr-merged m2 "duplicate write"
  local all lines
  all=$(list_records "$home" --all)
  lines=$(printf '%s\n' "$all" | grep -c .)
  [ "$lines" -eq 1 ] || fail "idempotent add created $lines records instead of 1: $all"
  assert_contains "$all" "first write" "the duplicate add replaced the original payload"
  pass "add is idempotent by kind+key and never duplicates a milestone"
}

test_add_validation() {
  local home="$TMP_ROOT/validate"
  make_home "$home"
  local rc
  SQUAD_BASE="$home" "$REQ" add bogus-kind k "x" 2>/dev/null && fail "an unknown kind was accepted"
  rc=$?
  expect_code 2 "$rc" "an unknown handoff kind must be rejected"
  SQUAD_BASE="$home" "$REQ" add pr-merged 'bad key!' "x" 2>/dev/null && fail "an invalid key was accepted"
  rc=$?
  expect_code 2 "$rc" "an invalid handoff key must be rejected"
  SQUAD_BASE="$home" "$REQ" add pr-merged k 2>/dev/null && fail "a missing payload was accepted"
  rc=$?
  expect_code 2 "$rc" "a missing payload must be rejected"
  pass "add rejects unknown kinds, invalid keys, and missing payloads"
}

test_payload_sanitization_keeps_the_wire_format() {
  local home="$TMP_ROOT/sanitize"
  make_home "$home"
  add_record "$home" pr-merged tabbed $'line one\tline two\nline three'
  local line
  line=$(list_records "$home" --all)
  case "$line" in
    *$'\tpr-merged\ttabbed\tpending\tline one line two line three') : ;;
    *) fail "payload tabs/newlines were not collapsed: $line" ;;
  esac
  pass "payload sanitization collapses tabs and newlines so the TAB format survives"
}

test_resolve_closes_the_record() {
  local home="$TMP_ROOT/resolve"
  make_home "$home"
  add_record "$home" pr-merged m2 "M2 landed"
  SQUAD_BASE="$home" "$REQ" resolve m2 || fail "resolve failed on an existing record"
  local open all
  open=$(list_records "$home" --open)
  [ -z "$open" ] || fail "resolved record still appears in the open list: $open"
  all=$(list_records "$home" --all)
  assert_contains "$all" $'\tpr-merged\tm2\tresolved\t' "resolved record lost its closed state"
  pass "resolve durably closes a record and open listing drops it"
}

test_resolve_unknown_key_fails() {
  local home="$TMP_ROOT/resolve-miss"
  make_home "$home"
  local rc
  SQUAD_BASE="$home" "$REQ" resolve nope 2>/dev/null && fail "resolving an absent key succeeded"
  rc=$?
  expect_code 1 "$rc" "resolving an absent key must fail"
  pass "resolve reports a missing record"
}

test_surface_marks_once_and_prints_the_card() {
  local home="$TMP_ROOT/surface"
  local root="$TMP_ROOT/surface-root"
  make_home "$home"
  make_primary_root "$root"
  add_record "$home" pr-merged m2 "M2 landed via PR #42"

  local out again all
  out=$(run_surface "$home" "$root")
  assert_contains "$out" "HANDOFF - MILESTONE CLOSE" "the surfaced card did not print"
  assert_contains "$out" "m2" "the surfaced card lost its key"
  assert_contains "$out" "M2 landed via PR #42" "the surfaced card lost the milestone context"
  assert_contains "$out" "never auto-start" "the surfaced card lost the commander-owned /new reminder"
  assert_contains "$out" "sq-handoff-request.sh resolve m2" "the surfaced card lost its close command"

  again=$(run_surface "$home" "$root")
  [ -z "$again" ] || fail "a second surface printed the card again: $again"

  all=$(list_records "$home" --all)
  assert_contains "$all" $'\tpr-merged\tm2\tsurfaced\t' "the surfaced record did not move to surfaced"
  pass "surface marks a pending record surfaced exactly once and prints the card once"
}

test_surface_is_silent_outside_a_primary_checkout() {
  local home="$TMP_ROOT/scope-home"
  local repo="$TMP_ROOT/scoperepo"
  local wt="$TMP_ROOT/scopewt"
  make_home "$home"
  make_primary_root "$repo"
  git -C "$repo" worktree add -q -b wt "$wt" || fail "could not add a linked worktree fixture"

  add_record "$home" pr-merged m2 "M2 landed"
  local out
  out=$(run_surface "$home" "$wt")
  [ -z "$out" ] || fail "the surfacer fired from a linked worktree: $out"
  local all
  all=$(list_records "$home" --all)
  assert_contains "$all" $'\tpr-merged\tm2\tpending\t' "a worktree surface still advanced the record state"
  pass "the surfacer is inert outside a real primary checkout"
}

test_concurrent_surfacers_print_exactly_one_card() {
  local home="$TMP_ROOT/race"
  local root="$TMP_ROOT/race-root"
  make_home "$home"
  make_primary_root "$root"
  add_record "$home" pr-merged m2 "M2 landed"

  local out1 out2
  # Background subshells share $$, so they inherit the test cleanup trap and
  # would delete the fixture on exit; clear the trap inside each job.
  ( trap - EXIT INT TERM; SQUAD_BASE="$home" SQUAD_ROOT_OVERRIDE="$root" "$SURFACE" > "$TMP_ROOT/race.out1" 2>&1 ) &
  local p1=$!
  ( trap - EXIT INT TERM; SQUAD_BASE="$home" SQUAD_ROOT_OVERRIDE="$root" "$SURFACE" > "$TMP_ROOT/race.out2" 2>&1 ) &
  local p2=$!
  wait "$p1"
  wait "$p2"
  out1=$(cat "$TMP_ROOT/race.out1")
  out2=$(cat "$TMP_ROOT/race.out2")
  local cards=0
  [ -n "$out1" ] && cards=$((cards + 1))
  [ -n "$out2" ] && cards=$((cards + 1))
  [ "$cards" -eq 1 ] || fail "concurrent surfaces printed $cards cards instead of exactly one: [$out1] [$out2]"
  pass "concurrent surfacers present the card exactly once under the queue lock"
}

test_surface_prints_one_card_per_pending_milestone() {
  local home="$TMP_ROOT/batch"
  local root="$TMP_ROOT/batch-root"
  make_home "$home"
  make_primary_root "$root"
  add_record "$home" pr-merged m2 "M2 landed"
  add_record "$home" queue-drained q1 "queue drained"

  local out count
  out=$(run_surface "$home" "$root")
  count=$(printf '%s\n' "$out" | grep -c "HANDOFF - MILESTONE CLOSE" || true)
  [ "$count" -eq 2 ] || fail "two pending milestones surfaced $count cards instead of 2: $out"
  pass "surface prints one card per pending milestone"
}

test_add_writes_pending_and_list_filters
test_add_is_idempotent_by_kind_and_key
test_add_validation
test_payload_sanitization_keeps_the_wire_format
test_resolve_closes_the_record
test_resolve_unknown_key_fails
test_surface_marks_once_and_prints_the_card
test_surface_is_silent_outside_a_primary_checkout
test_concurrent_surfacers_print_exactly_one_card
test_surface_prints_one_card_per_pending_milestone

echo "# sq-handoff-queue.test.sh: all assertions passed"
