#!/usr/bin/env bash
# Deterministic return-catch-up gate regression.
#
# Covers the second half of the 2026-07-14 incident: an away-mode blocked event
# survived in durable state, but the ordinary return request could proceed to
# Sitrep before Squad owned remediation. The shared script now stops,
# drains, preserves evidence, and refuses ordinary work until every live open
# `blocked:` event is resolved or durably reclassified.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/sq-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-afk-return-tests)

install_runner() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp "$ROOT/bin/sq-afk-return.sh" "$dir/bin/"
  cp "$ROOT/bin/sq-stand-to-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/sq-classify-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/sq-timeout-lib.sh" "$ROOT/bin/sq-afk-settings.sh" "$dir/bin/"
  cat > "$dir/bin/sq-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
printf 'stop\n' >> "$SQUAD_BASE/stop.log"
if [ -e "$SQUAD_BASE/state/.fail-terminal-stop-once" ]; then
  rm -f "$SQUAD_BASE/state/.fail-terminal-stop-once"
  exit 1
fi
rm -f "$SQUAD_BASE/state/.afk-daemon-terminal" "$SQUAD_BASE/state/.afk"
SH
  cat > "$dir/bin/sq-stand-to-drain.sh" <<'SH'
#!/usr/bin/env bash
file="$SQUAD_BASE/state/.fake-drain"
[ -f "$file" ] && cat "$file"
: > "$file"
SH
  chmod +x "$dir/bin/"*.sh
}

install_real_drain() {
  cp "$ROOT/bin/sq-stand-to-drain.sh" "$ROOT/bin/sq-line-cap-lib.sh" "$1/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bin/sq-guard.sh"
  chmod +x "$1/bin/sq-guard.sh"
}

run_return() {  # <case-dir> <mode>
  local dir=$1 mode=$2
  SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" "$dir/bin/sq-afk-return.sh" "$mode" 2>&1
}

seed_live_blocker() {  # <case-dir> <backend> <key>
  local dir=$1 backend=$2 key=$3 target
  case "$backend" in
    tmux) target='synthetic:sq-repair-task' ;;
    herdr) target='sq-lab-synthetic:w1:p2' ;;
  esac
  cat > "$dir/home/state/repair-task.meta" <<EOF
window=$target
backend=$backend
kind=strike
EOF
  printf 'blocked [key=%s]: Squad can refresh the synthetic token\n' "$key" > "$dir/home/state/repair-task.status"
}

test_return_gate_orders_catchup_before_bearings() {
  local dir out rc gate wake_count
  dir="$TMP_ROOT/ordering"
  install_runner "$dir"
  seed_live_blocker "$dir" herdr synthetic-dependency
  date +%s > "$dir/home/state/.afk"
  printf 'repair-task.status: blocked synthetic dependency\n' > "$dir/home/state/.subsuper-escalations"
  printf 'fm away-mode inject WEDGED: 4555s undelivered\n' > "$dir/home/state/.subsuper-inject-wedged"
  {
    printf '1784074271\t2\tsignal\trepair-task.status\tsignal: synthetic status\n'
    printf 'wake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency\n'
  } > "$dir/home/state/.fake-drain"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "return begin should gate on a live blocker (rc=$rc): $out"
  gate="$dir/home/state/.afk-return-catchup"
  [ -s "$gate" ] || fail "return begin did not persist its fail-closed catch-up gate"
  assert_contains "$out" 'Squad-actionable blocker: repair-task [key=synthetic-dependency]' "return output did not assign blocker remediation to Squad"
  grep -F $'evidence\twake\t1784074271' "$gate" >/dev/null || fail "drained wake evidence was not retained in the durable gate"
  grep -F $'evidence\twake\twake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency' "$gate" >/dev/null \
    || fail "the separate drain annotation was not retained as away-return evidence"
  grep -F $'evidence\twedge\tfm away-mode inject WEDGED: 4555s undelivered' "$gate" >/dev/null || fail "wedge evidence was not retained in the durable gate"
  grep -F $'evidence\tescalation\trepair-task.status: blocked synthetic dependency' "$gate" >/dev/null || fail "buffered escalation evidence was not retained in the durable gate"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 1 ] || fail "return begin did not stop away mode exactly once"

  # The exact incident regression: Sitrep is an ordinary request and must
  # refuse before reading/rendering while this shared gate remains open.
  set +e
  out=$(SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/sq-sitrep-snapshot.sh" --json 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "Sitrep should refuse behind the return gate (rc=$rc): $out"
  assert_contains "$out" 'return catch-up is pending' "Sitrep refusal did not point to the shared return owner"

  # Restart/re-entry is idempotent: no second stop, no duplicate catch-up line,
  # and the same unresolved blocker remains authoritative.
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "repeated begin should preserve the unresolved gate"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 1 ] || fail "repeated begin stopped an already-stopped daemon twice"
  wake_count=$(grep -c $'^evidence\twake\t1784074271' "$gate" || true)
  [ "$wake_count" -eq 1 ] || fail "repeated begin duplicated retained wake evidence ($wake_count copies)"
  [ "$(grep -c $'^evidence\twedge\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained wedge evidence"
  [ "$(grep -c $'^evidence\tescalation\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained escalation evidence"

  printf 'resolved [key=synthetic-dependency]: refreshed the synthetic token and resumed the task\n' >> "$dir/home/state/repair-task.status"
  out=$(run_return "$dir" check) || fail "resolved blocker did not clear return catch-up: $out"
  assert_contains "$out" 'catch-up clear' "successful check did not announce that ordinary work may proceed"
  [ ! -e "$gate" ] || fail "successful check left the return gate behind"
  [ ! -e "$dir/home/state/.subsuper-escalations" ] || fail "successful check left delivered escalation state behind"
  [ ! -e "$dir/home/state/.subsuper-inject-wedged" ] || fail "successful check left the wedge marker behind"

  out=$(run_return "$dir" check) || fail "an already-clear repeated check should be idempotent: $out"
  [ ! -e "$gate" ] || fail "idempotent clear check recreated a gate"
  pass "return catch-up precedes Sitrep, owns live blocker remediation, preserves evidence once, and clears idempotently"
}

test_explicit_reclassification_requires_durable_reason() {
  local backend dir out rc
  for backend in tmux herdr; do
    dir="$TMP_ROOT/reclassify-$backend"
    install_runner "$dir"
    seed_live_blocker "$dir" "$backend" vendor-release
    date +%s > "$dir/home/state/.afk"
    : > "$dir/home/state/.fake-drain"
    set +e
    out=$(run_return "$dir" begin)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend blocker did not open the return gate"

    # A pause alone cannot mask the keyed blocker. The old concern must be
    # explicitly resolved with the durable reclassification reason first.
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    set +e
    out=$(run_return "$dir" check)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend pause silently masked an unresolved blocked key"

    printf 'resolved [key=vendor-release]: reclassified as an external wait because the synthetic vendor owns the next event\n' >> "$dir/home/state/repair-task.status"
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    out=$(run_return "$dir" check) || fail "$backend durable reclassification did not clear the return gate: $out"
    [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "$backend reclassification left a gate behind"
  done
  pass "tmux and Herdr blockers require the same explicit durable reclassification before ordinary work"
}

test_commander_decision_does_not_masquerade_as_Squad_blocker() {
  local dir out
  dir="$TMP_ROOT/commander-decision"
  install_runner "$dir"
  cat > "$dir/home/state/decision-task.meta" <<'EOF'
window=synthetic:sq-decision-task
backend=tmux
kind=strike
EOF
  printf 'needs-decision [key=api-shape]: commander must choose the synthetic API shape\n' > "$dir/home/state/decision-task.status"
  date +%s > "$dir/home/state/.afk"
  {
    printf '1784074271\t1\tsignal\tdecision-task.status\tsignal: synthetic decision\n'
    printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
    printf 'decision-task [key=api-shape] needs-decision: commander must choose the synthetic API shape\n'
  } > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "approval decision should not be treated as a Squad blocker: $out"
  assert_contains "$out" 'queued wake records drained: 1' "approval decision wake record was not listed as an open item"
  assert_not_contains "$out" 'catch-up summary' "queued wake records alone presented an away-mode summary"
  assert_contains "$out" 'OPEN DECISIONS' "approval decision was not surfaced as an open item in the summary"
  [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "approval decision incorrectly opened a Squad blocker gate"
  pass "needs-decision remains reportable without masquerading as a Squad-actionable blocker"
}

test_away_reentry_refuses_pending_return_gate() {
  local dir out rc
  dir="$TMP_ROOT/reentry"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf 'schema\tsq-afk-return.v1\nphase\tblocked\n' > "$dir/home/state/.afk-return-catchup"
  set +e
  out=$(SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/sq-afk-launch.sh" start-native 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "away re-entry succeeded while return catch-up was pending"
  assert_contains "$out" 'return catch-up is still pending' "away re-entry refusal did not explain the pending owner"
  [ ! -e "$dir/home/state/.afk" ] || fail "away re-entry wrote .afk despite the pending return gate"
  pass "away-mode re-entry fails closed while the prior return catch-up is pending"
}

test_check_retries_recorded_terminal_teardown() {
  local dir gate out rc
  dir="$TMP_ROOT/terminal-teardown"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  printf 'herdr\tsynthetic:pane\tsynthetic-workspace\n' > "$dir/home/state/.afk-daemon-terminal"
  touch "$dir/home/state/.fail-terminal-stop-once"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "failed terminal teardown should keep return catch-up gated (rc=$rc): $out"
  [ -e "$gate" ] || fail "failed terminal teardown cleared the return gate"
  [ -e "$dir/home/state/.afk-daemon-terminal" ] || fail "failed terminal teardown discarded its durable record"
  [ -e "$dir/home/state/.afk" ] || fail "failed terminal teardown cleared away mode"
  assert_not_contains "$out" 'resuming a catch-up' "fresh return reported an interrupted drain"
  rc=0; out=$(run_return "$dir" guard) || rc=$?
  [ "$rc" -eq 3 ] || fail "guard did not refuse while shutdown was pending"
  assert_contains "$out" 'return catch-up gate phase: shutdown-failed' "away mode masked the lifecycle diagnosis"
  assert_not_contains "$out" 'handle each blocker' "lifecycle failure was attributed to blockers"

  out=$(run_return "$dir" check) || fail "check did not retry recorded terminal teardown: $out"
  [ ! -e "$dir/home/state/.afk-daemon-terminal" ] || fail "successful check left the terminal teardown record behind"
  [ ! -e "$gate" ] || fail "successful terminal teardown retry left the return gate behind"
  [ ! -e "$dir/home/state/.afk" ] || fail "successful terminal teardown retry left away mode active"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 2 ] || fail "check did not retry terminal teardown exactly once"
  pass "check retries recorded terminal teardown and keeps catch-up gated until success"
}

test_away_ledger_is_presented_once_and_never_repeated() {
  local dir out count
  dir="$TMP_ROOT/ledger-summary"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  printf '1784074271|routine|fake-c1.status -> working: step one\n' > "$dir/home/state/.subsuper-routine"
  printf '1784074280|escalation|fake-c1: done: PR https://example.test/pr/300\n' >> "$dir/home/state/.subsuper-escalations"
  out=$(run_return "$dir" begin) || fail "ledger return should clear without a Squad blocker: $out"
  assert_contains "$out" 'catch-up summary' "ledger return did not present one summary"
  assert_contains "$out" 'counts: escalation=1 routine=1' "summary did not count each class"
  assert_contains "$out" 'https://example.test/pr/300' "summary did not carry the link to act on"
  assert_contains "$out" 'never executed while you were away' "summary did not state what was never executed"
  count=$(printf '%s' "$out" | grep -c 'catch-up summary' || true)
  [ "$count" -eq 1 ] || fail "summary presented $count times in one return"
  [ ! -e "$dir/home/state/.subsuper-escalations" ] && [ ! -e "$dir/home/state/.subsuper-routine" ] || fail "clear left the ledger behind"
  out=$(run_return "$dir" begin) || fail "re-run of a cleared catch-up failed: $out"
  assert_not_contains "$out" 'catch-up summary' "re-run duplicated the away-mode summary"
  out=$(run_return "$dir" check) || fail "check after a cleared catch-up failed: $out"
  assert_not_contains "$out" 'catch-up summary' "check duplicated the away-mode summary"
  pass "away-mode ledger is presented once as one summary and a re-run never repeats it"
}

test_single_class_ledger_clears_return_gate() {
  local dir out class counts ledger
  for class in routine escalation; do
    dir="$TMP_ROOT/ledger-$class-only"
    install_runner "$dir"
    date +%s > "$dir/home/state/.afk"
    case "$class" in
      routine) ledger=routine; counts='escalation=0 routine=1' ;;
      escalation) ledger=escalations; counts='escalation=1 routine=0' ;;
    esac
    printf '1784074271|%s|task update\n' "$class" > "$dir/home/state/.subsuper-$ledger"
    out=$(run_return "$dir" begin) || fail "$class-only return failed: $out"
    assert_contains "$out" "counts: $counts" "$class-only return reported incorrect counts"
    assert_contains "$out" "[$class] task update" "$class-only return omitted the event"
    [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "$class-only return left the gate behind"
  done
  pass "routine-only and escalation-only ledgers both clear the return gate"
}

test_away_ledger_while_blocked_presents_only_a_count() {
  local dir out
  dir="$TMP_ROOT/ledger-blocked"
  install_runner "$dir"
  seed_live_blocker "$dir" herdr blocked-ledger
  date +%s > "$dir/home/state/.afk"
  printf '1784074280|escalation|repair-task: done: PR https://example.test/pr/9\n' > "$dir/home/state/.subsuper-escalations"
  set +e
  out=$(run_return "$dir" begin)
  set -e
  assert_not_contains "$out" 'catch-up summary' "blocked return presented the summary before the blockers cleared"
  assert_contains "$out" '1 away-mode event(s) are held' "blocked return did not count the held events"
  pass "blocked catch-up holds the away-mode events as a count until the blockers clear"
}

test_undeliverable_ledger_item_reaches_the_summary() {
  local dir out
  dir="$TMP_ROOT/ledger-undeliverable"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  printf 'away-mode ledger undeliverable as of now: escalation: fake-c2: done: PR https://example.test/pr/77\n' \
    > "$dir/home/state/.subsuper-inject-wedged"
  {
    printf '1784074290\t5\tcheck\tafk-ledger-undeliverable\tcheck: away-mode ledger could not record: escalation: fake-c2: done: PR https://example.test/pr/77\n'
    printf '1784074295\t6\tsignal\tfake-c2.status\tsignal: fake-c2.status\n'
  } > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "undeliverable return should clear: $out"
  assert_contains "$out" 'catch-up summary' "undeliverable ledger item did not open the away-mode summary"
  assert_contains "$out" '[daemon-notice] check: away-mode ledger could not record: escalation: fake-c2: done: PR https://example.test/pr/77' \
    "undeliverable ledger item was not presented as an event"
  assert_contains "$out" '    https://example.test/pr/77' "undeliverable ledger item link was not listed"
  assert_not_contains "$out" 'away-mode ledger undeliverable as of' "wedge marker duplicated the queued undeliverable record"
  assert_contains "$out" 'queued wake records drained: 1' "other queued wake records were not listed as open items"

  dir="$TMP_ROOT/ledger-wedge-only"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  printf 'away-mode ledger undeliverable as of now: escalation: fake-c3: failed: build\n' > "$dir/home/state/.subsuper-inject-wedged"
  out=$(run_return "$dir" begin) || fail "wedge-only return should clear: $out"
  assert_contains "$out" '[daemon-notice] away-mode ledger undeliverable as of now: escalation: fake-c3: failed: build' \
    "wedge marker was not presented when no queued record survived"
  out=$(run_return "$dir" begin) || fail "wedge-only re-run failed: $out"
  assert_not_contains "$out" 'catch-up summary' "re-run duplicated the wedge notice summary"

  dir="$TMP_ROOT/ledger-undeliverable-partial-drain"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  {
    printf 'away-mode ledger undeliverable as of 2026-01-01T10:00:00+0000: escalation: fake-c4: failed: lint\n'
    printf 'away-mode ledger undeliverable as of 2026-01-01T10:05:00+0000: escalation: fake-c5: done: PR https://example.test/pr/88\n'
    printf 'away-mode ledger undeliverable as of 2026-01-01T10:06:00+0000: escalation: fake-c4: failed: lint\n'
  } > "$dir/home/state/.subsuper-inject-wedged"
  printf '1784074300\t7\tcheck\tafk-ledger-undeliverable\tcheck: away-mode ledger could not record: escalation: fake-c5: done: PR https://example.test/pr/88\n' \
    > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "partially drained undeliverable return should clear: $out"
  assert_contains "$out" 'daemon-notice=2' "partially drained undeliverable items were not both counted"
  assert_contains "$out" '[daemon-notice] away-mode ledger undeliverable as of 2026-01-01T10:00:00+0000: escalation: fake-c4: failed: lint' \
    "undeliverable item drained during the absence was lost from the summary"
  assert_contains "$out" '[daemon-notice] check: away-mode ledger could not record: escalation: fake-c5: done: PR https://example.test/pr/88' \
    "surviving undeliverable record was not presented"
  assert_not_contains "$out" 'as of 2026-01-01T10:05:00+0000' "marker line duplicated the surviving queued record"
  pass "an item the ledger could not record reaches the return summary once"
}

# The 2026-11-22 non-termination. A gate left in its fail-closed seed phase plus a
# ledger a repeating wake had inflated made `check` run for minutes: the evidence
# merge rescanned the whole growing file once per candidate line, and the summary
# rebuilt a growing string once per event. Both are linear now, the routine class
# is presented under a documented limit, and the run finishes inside the bound.
seed_stuck_gate() {  # <case-dir> [evidence-lines]
  local dir=$1 lines=${2:-0}
  {
    printf 'schema\tsq-afk-return.v1\n'
    printf 'started\t%s\n' "$(( $(date +%s) - 600 ))"
    printf 'phase\tstopping-and-draining\n'
    awk -v n="$lines" 'BEGIN {
      for (i = 1; i <= n; i++) printf "evidence\tescalation\t1700000000|escalation|held-%d: done: PR https://example.test/pr/%d\n", i, i
    }'
  } > "$dir/home/state/.afk-return-catchup"
}

seed_routine_ledger() {  # <case-dir> <lines> <duplicates|distinct>
  local dir=$1 lines=$2 shape=$3
  awk -v n="$lines" -v distinct="$shape" 'BEGIN {
    for (i = 1; i <= n; i++) {
      if (distinct == "distinct") {
        printf "1700000001|routine|gone-task.status -> self|stale tick %d: no activity\n", i
      } else {
        printf "1700000001|routine|gone-task.status -> self|stale: tmux:sq-gone-task (idle 600s): no activity\n"
      }
    }
  }' > "$dir/home/state/.subsuper-routine"
}

test_decimal_limits_preserve_summary_order() {
  local dir out
  dir="$TMP_ROOT/decimal-limits"
  install_runner "$dir"
  seed_routine_ledger "$dir" 9 distinct
  printf '1700000001|escalation|same-second escalation\n' > "$dir/home/state/.subsuper-escalations"

  out=$(SQUAD_AFK_RETURN_MAX_ROUTINE_EVENTS=08 SQUAD_AFK_RETURN_LOCK_SECS=08 run_return "$dir" begin) \
    || fail "return failed with decimal limits: $out"
  assert_contains "$out" 'counts: escalation=1 routine=9' "the display cap changed the event counts"
  assert_contains "$out" 'routine entries past the first 8 are counted but not listed' "08 was not treated as decimal 8"
  printf '%s\n' "$out" | grep -qE '^  8\. .*\[routine\].*stale tick 8:' \
    || fail "the eighth routine event did not retain its position: $out"
  printf '%s\n' "$out" | grep -qE '^  9\. .*\[escalation\] same-second escalation$' \
    || fail "the escalation did not follow the same-second routine events: $out"
  case "$out" in *'stale tick 9:'*) fail "the ninth routine event was not suppressed" ;; esac
  [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "return did not clear the catch-up gate"
  pass "decimal settings preserve evidence order while capping routine output"
}

test_pathological_ledger_terminates_within_bound() {
  local dir out rc shape
  for shape in duplicates distinct; do
    dir="$TMP_ROOT/pathological-$shape"
    install_runner "$dir"
    seed_stuck_gate "$dir" 200
    if [ "$shape" = distinct ]; then
      seed_routine_ledger "$dir" 8000 distinct
    else
      seed_routine_ledger "$dir" 12000 duplicates
    fi
    set +e
    out=$(fm_run_timed 45 env SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" "$dir/bin/sq-afk-return.sh" check 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 124 ] || fail "the $shape-ledger return did not terminate inside the 45s bound"
    [ "$rc" -eq 0 ] || fail "the $shape-ledger return failed (rc=$rc): $(printf '%s' "$out" | tail -3)"
    [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "the $shape-ledger return left the stuck gate behind"
    [ "$(printf '%s' "$out" | grep -c 'catch-up summary')" -eq 1 ] \
      || fail "the $shape-ledger return did not present exactly one summary"
    assert_contains "$out" 'resuming a catch-up found in phase stopping-and-draining' \
      "the $shape-ledger return did not name the phase it resumed"
    assert_contains "$out" 'held-1: done: PR https://example.test/pr/1' \
      "the $shape-ledger return lost a preserved escalation"
  done
  pass "an inflated away-mode ledger returns inside the bound instead of stalling the commander"
}

test_stuck_gate_names_its_phase_and_the_supported_recovery() {
  local dir out rc gate
  dir="$TMP_ROOT/stuck-gate"
  install_runner "$dir"
  seed_stuck_gate "$dir" 3
  gate="$dir/home/state/.afk-return-catchup"

  set +e
  out=$(SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" "$dir/bin/sq-afk-return.sh" guard 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "guard should refuse ordinary work behind a stuck gate (rc=$rc): $out"
  assert_contains "$out" 'return catch-up gate phase: stopping-and-draining' "guard did not name the phase it found"
  assert_contains "$out" 'why it could not advance: a previous return run stopped before it could finish' \
    "guard did not name why the gate could not advance"
  assert_contains "$out" '3 evidence record(s)' "guard did not report what the gate holds"
  assert_contains "$out" 'recovery is bin/sq-afk-return.sh check' "guard did not name the supported recovery"
  assert_contains "$out" 'no state file needs to be removed by hand' "guard left hand-deleting the gate as the only way out"
  [ -e "$gate" ] || fail "the read-only guard mutated the gate it was only supposed to report"

  out=$(run_return "$dir" check) || fail "check did not resume the stuck gate: $out"
  assert_contains "$out" 'resuming a catch-up found in phase stopping-and-draining' "check did not name the phase it resumed"
  assert_contains "$out" 'catch-up clear' "the resumed check did not report a clear catch-up"
  [ ! -e "$gate" ] || fail "the resumed check left the stuck gate behind"
  pass "a stuck gate names its phase and reason and check is the supported recovery"
}

test_catchup_lock_wait_is_bounded() {
  local dir out rc holder lock elapsed started_at
  dir="$TMP_ROOT/lock-bound"
  install_runner "$dir"
  lock="$dir/home/state/.afk-return-catchup.lock"
  seed_stuck_gate "$dir" 2
  SQUAD_STATE_OVERRIDE="$dir/home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.1; done
  ' _ "$dir/bin/sq-stand-to-lib.sh" "$lock" "$dir/held" "$dir/release" &
  holder=$!
  local waited=0
  while [ ! -e "$dir/held" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$dir/held" ] || { kill "$holder" 2>/dev/null; fail "the lock holder never acquired the catch-up lock"; }

  started_at=$(date +%s)
  set +e
  out=$(fm_run_timed 30 env SQUAD_AFK_RETURN_LOCK_SECS=0001 SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" "$dir/bin/sq-afk-return.sh" check 2>&1)
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started_at ))
  : > "$dir/release"
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 124 ] || fail "a held catch-up lock spun without a bound instead of reporting a timeout"
  [ "$rc" -eq 3 ] || fail "a held catch-up lock should refuse with the timeout diagnosis (rc=$rc): $out"
  assert_contains "$out" 'waiting for the held return catch-up lock' "the lock timeout did not name its bound"
  assert_contains "$out" 'return catch-up gate phase: stopping-and-draining' "the lock timeout did not report the gate phase"
  [ "$elapsed" -le 15 ] || fail "the bounded lock wait took ${elapsed}s against a 1s bound"
  pass "a held catch-up lock reports a bounded timeout with the gate phase instead of hanging the return"
}

install_hanging_launcher() {  # <case-dir>
  cat > "$1/bin/sq-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
# An unresponsive backend: the shutdown never returns on its own.
sleep 60
exit 1
SH
  chmod +x "$1/bin/sq-afk-launch.sh"
}

# A shutdown that fails while the daemon and its terminal are still there: the
# lifecycle state survives, so every check retries the same stop and fails again.
install_failing_launcher() {  # <case-dir>
  cat > "$1/bin/sq-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
exit 1
SH
  chmod +x "$1/bin/sq-afk-launch.sh"
}

# Finding: the shutdown step ran without a deadline, so one unresponsive backend
# held the catch-up lock and `check` could never recover. The step now spends the
# run's budget and leaves the lifecycle state in place when it cannot finish.
test_shutdown_step_is_bounded_and_retains_lifecycle() {
  local dir out rc started_at elapsed
  dir="$TMP_ROOT/shutdown-bound"
  install_runner "$dir"
  install_hanging_launcher "$dir"
  date +%s > "$dir/home/state/.afk"
  printf 'tmux\tsynthetic-session\towned\n' > "$dir/home/state/.afk-daemon-terminal"
  : > "$dir/home/state/.fake-drain"

  started_at=$(date +%s)
  set +e
  out=$(fm_run_timed 40 env SQUAD_AFK_RETURN_LOCK_SECS=3 SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/sq-afk-return.sh" begin 2>&1)
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started_at ))
  [ "$rc" -ne 124 ] || fail "an unresponsive away-mode shutdown held the catch-up lock instead of returning inside its budget"
  [ "$rc" -eq 3 ] || fail "a bounded shutdown failure should keep the catch-up gated (rc=$rc): $out"
  assert_contains "$out" 'catch-up exceeded its 3s budget' "the bounded shutdown did not report the budget it hit"
  [ -s "$dir/home/state/.afk-return-catchup" ] || fail 'the bounded shutdown did not retain the gate'
  [ -e "$dir/home/state/.afk" ] || fail "the bounded shutdown cleared the away-mode flag it could not confirm"
  [ -e "$dir/home/state/.afk-daemon-terminal" ] || fail "the bounded shutdown discarded the recorded terminal id"
  [ "$elapsed" -le 20 ] || fail "the bounded shutdown took ${elapsed}s against a 3s budget"
  pass "an unresponsive away-mode shutdown is bounded and retains the lifecycle state for the next check"
}

test_shutdown_contains_real_backend() {
  local dir out rc=0 started_at elapsed
  dir="$TMP_ROOT/shutdown-real-backend"
  install_runner "$dir"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$ROOT/bin/sq-afk-launch.sh" > "$dir/bin/sq-afk-launch.sh"
  date +%s > "$dir/home/state/.afk"
  printf 'tmux\tsynthetic-session\towned\n' > "$dir/home/state/.afk-daemon-terminal"
  cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'kill-session -t synthetic-session' ] || exit 1
printf 'backend entered\n'
[ "${MOCK_TERMINAL_DIRECT:-0}" != 1 ] || exec sleep 14
(trap '' TERM; sleep 14; touch "$SQUAD_BASE/backend-escaped") &
wait
SH
  chmod +x "$dir/bin/tmux"

  started_at=$(date +%s)
  out=$(env PATH="$dir/bin:$PATH" SQUAD_AFK_RETURN_LOCK_SECS=3 SQUAD_AFK_BACKEND_TIMEOUT_SECS=12 \
    SQUAD_BASE="$dir/home" "$dir/bin/sq-afk-return.sh" begin 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - started_at ))
  [ "$rc" -eq 3 ] || fail "the return did not gate on timed-out backend cleanup (rc=$rc): $out"
  assert_contains "$out" 'backend entered' 'the real launcher did not reach the stalled backend'
  assert_contains "$out" 'catch-up exceeded its 3s budget' 'the backend escaped the return deadline'
  [ -s "$dir/home/state/.afk-return-catchup" ] || fail 'the backend timeout did not retain the gate'
  [ "$elapsed" -lt 10 ] || fail "the backend held return output open for ${elapsed}s after the shutdown deadline"
  [ -e "$dir/home/state/.afk" ] && [ -e "$dir/home/state/.afk-daemon-terminal" ] \
    || fail 'the timed-out backend lost its lifecycle state'
  rc=0
  out=$(env PATH="$dir/bin:$PATH" MOCK_TERMINAL_DIRECT=1 SQUAD_AFK_RETURN_LOCK_SECS=6 SQUAD_AFK_BACKEND_TIMEOUT_SECS=1 \
    SQUAD_BASE="$dir/home" "$dir/bin/sq-afk-return.sh" check 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "the nested backend cap did not gate the retry (rc=$rc): $out"
  assert_contains "$out" 'return catch-up gate phase: shutdown-failed' 'the nested backend ignored its shorter cap'
  assert_not_contains "$out" 'catch-up exceeded' 'the nested backend spent the whole return budget'
  pass 'the return deadline contains the real launcher without disabling its backend cap'
}

# Finding: when the evidence merge failed after the queue was consumed, the gate
# still said `stopping-and-draining` and the run only printed a generic retry, so
# the phase that actually failed could not be named.
test_failed_evidence_merge_names_its_phase() {
  local dir gate out rc phase
  dir="$TMP_ROOT/merge-phase"
  install_runner "$dir"
  install_real_drain "$dir"
  seed_live_blocker "$dir" tmux merge-blocker
  gate="$dir/home/state/.afk-return-catchup"
  printf '1784074300|escalation|evidence merge trigger\n' > "$dir/home/state/.subsuper-escalations"
  printf '1784074300\t1\tcheck\tafk-ledger-undeliverable\tcheck: away-mode ledger could not record: merge checkpoint\n' \
    > "$dir/home/state/.stand-to-queue"
  REAL_SORT=$(command -v sort)
  export REAL_SORT
  cat > "$dir/bin/sort" <<'SH'
#!/usr/bin/env bash
case "$*" in *.subsuper-escalations*) exit 1 ;; esac
exec "$REAL_SORT" "$@"
SH
  chmod +x "$dir/bin/sort"

  set +e
  out=$(PATH="$dir/bin:$PATH" run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "the failed evidence merge was not surfaced (rc=$rc): $out"
  [ -s "$gate" ] || fail "the failed evidence merge cleared its gate"
  phase=$(awk -F '\t' '$1 == "phase" { print $2; exit }' "$gate")
  [ "$phase" = merging-evidence ] \
    || fail "the failed evidence merge left the gate in phase '${phase}' instead of naming the merge it could not commit"
  assert_contains "$out" 'return catch-up gate phase: merging-evidence' "the failed merge did not report the phase it reached"
  assert_contains "$out" 'the drain consumed the queue but the evidence merge could not commit' \
    "the failed merge did not explain why the gate could not advance"

  grep -q 'merge checkpoint' "$dir/home/state"/.afk-return-drain.*/raw || fail 'the failed merge lost the drained checkpoint'
  [ ! -s "$dir/home/state/.stand-to-queue" ] || fail 'the live blocker prevented the queue drain'
  rm -f "$dir/bin/sort"
  rc=0
  out=$(run_return "$dir" check) || rc=$?
  [ "$rc" -eq 3 ] || fail "the merge retry did not preserve the live blocker: $out"
  assert_contains "$out" 'return catch-up gate phase: blocked' 'the retry did not commit the blocked outcome'
  printf 'resolved [key=merge-blocker]: cleared\n' >> "$dir/home/state/repair-task.status"
  out=$(run_return "$dir" check) || fail "the merge retry did not recover: $out"
  assert_contains "$out" '[escalation] evidence merge trigger' "the merge retry lost the ledger escalation"
  assert_contains "$out" 'check: away-mode ledger could not record: merge checkpoint' 'the merge retry lost the drained wake'
  [ ! -e "$gate" ] || fail "the successful merge retry left the gate behind"
  pass "a failed evidence merge persists and reports the phase it could not commit"
}

# Finding: the drain folded each status log through the cursor-backed fold, but
# the blocker scan re-folded every task's whole history - a subshell per
# historical line on every retry - so a long-running task could stall the return.
test_blocker_scan_is_bounded_by_new_appends() {
  local dir state out rc
  dir="$TMP_ROOT/blocker-fold"
  install_runner "$dir"
  state="$dir/home/state"
  printf 'window=synthetic:sq-fold\nbackend=tmux\nkind=strike\n' > "$state/fold-task.meta"
  awk 'BEGIN {
    for (i = 1; i <= 40000; i++) printf "working: historical step %d\n", i
    print "blocked [key=slow-history]: synthetic blocker"
  }' > "$state/fold-task.status"
  : > "$state/.fake-drain"
  # The drain has already folded this log, so its cursor sits at the end of the
  # history before the blocker scan runs - exactly the retry shape of the finding.
  SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    status_open_decisions_incremental "$2" >/dev/null
  ' _ "$ROOT/bin/sq-classify-lib.sh" "$state/fold-task.status" || fail "could not prime the open-decisions cursor"

  set +e
  out=$(fm_run_timed 25 env SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$state" "$dir/bin/sq-afk-return.sh" begin 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 124 ] \
    || fail "the blocker scan re-folded a 40k-line status history instead of only the bytes appended since the drain"
  [ "$rc" -eq 3 ] || fail "the long-history return did not gate on its live blocker (rc=$rc): $(printf '%s' "$out" | tail -3)"
  assert_contains "$out" 'Squad-actionable blocker: fold-task [key=slow-history]' "the bounded blocker scan lost the live blocker"
  pass "the blocker scan costs new appends, not a whole status history"
}

# Finding: each retried shutdown preserved the previous gate's evidence and copied
# in the current routine ledger, so every rotation of the bounded ledger left its
# evicted rows in the gate and the routine evidence grew without limit.
test_routine_evidence_stays_bounded_across_shutdown_retries() {
  local dir gate out routine_rows escalation_rows rotation
  dir="$TMP_ROOT/gate-routine-budget"
  install_runner "$dir"
  install_failing_launcher "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  printf 'tmux\tsynthetic-session\towned\n' > "$dir/home/state/.afk-daemon-terminal"
  : > "$dir/home/state/.fake-drain"
  printf '1700000001|escalation|escalation-one\n1700000002|escalation|escalation-two\n' \
    > "$dir/home/state/.subsuper-escalations"

  for rotation in 1 2 3; do
    awk -v r="$rotation" 'BEGIN {
      for (i = 1; i <= 8; i++) printf "17000000%02d|routine|rotation %d event %d\n", r, r, i
    }' > "$dir/home/state/.subsuper-routine"
    set +e
    out=$(env SQUAD_ROUTINE_LEDGER_LIMIT=08 SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" \
      "$dir/bin/sq-afk-return.sh" check 2>&1)
    set -e
    [ -s "$gate" ] || fail "retry $rotation cleared a gate whose shutdown keeps failing: $out"
    routine_rows=$(awk -F '\t' '$1 == "evidence" && $2 == "escalation" && $3 ~ /^[0-9]+\|routine\|/ { n++ } END { print n + 0 }' "$gate")
    [ "$routine_rows" -eq 8 ] \
      || fail "retry $rotation retained $routine_rows routine evidence rows instead of the 8-row window"
  done
  grep -F $'evidence\tescalation\t1700000003|routine|rotation 3 event 8' "$gate" >/dev/null \
    || fail "the routine evidence window dropped the newest routine row"
  if grep -F 'rotation 1 event 1' "$gate" >/dev/null; then
    fail "the routine evidence window kept the oldest routine row instead of the newest"
  fi
  escalation_rows=$(awk -F '\t' '$1 == "evidence" && $2 == "escalation" && $3 ~ /\|escalation\|/ { n++ } END { print n + 0 }' "$gate")
  [ "$escalation_rows" -eq 2 ] || fail "the routine evidence window capped escalation evidence ($escalation_rows of 2 rows survived)"

  # A shutdown that finally succeeds still presents the retained evidence, so the
  # routine bound cannot hide an escalation.
  cat > "$dir/bin/sq-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
rm -f "$SQUAD_BASE/state/.afk" "$SQUAD_BASE/state/.afk-daemon-terminal"
SH
  chmod +x "$dir/bin/sq-afk-launch.sh"
  out=$(env SQUAD_ROUTINE_LEDGER_LIMIT=08 SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/sq-afk-return.sh" check 2>&1) || fail "the recovered shutdown did not clear the gate: $out"
  assert_contains "$out" 'counts: escalation=2 routine=8' "the cleared summary did not present both escalations and the retained routine class"
  assert_contains "$out" '[escalation] escalation-one' "the cleared summary lost an escalation"
  pass "routine evidence stays inside the ledger's retention window across shutdown retries while escalations stay uncapped"
}

# Finding: the summary counted retained rows while reading as if it counted the
# whole absence, and the routine ledger's retention window was undocumented.
test_summary_count_names_the_retained_scope() {
  local dir out
  dir="$TMP_ROOT/summary-scope"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  printf '1784074271|routine|retained routine event\n' > "$dir/home/state/.subsuper-routine"
  printf '1784074280|escalation|retained escalation event\n' > "$dir/home/state/.subsuper-escalations"
  out=$(run_return "$dir" begin) || fail "the ledger return failed: $out"
  assert_contains "$out" 'counts: escalation=1 routine=1 daemon-notice=0 (retained rows only:' \
    "the summary count did not say it covers retained rows rather than the whole absence"
  assert_contains "$out" 'the routine ledger keeps its most recent 1000 rows' \
    "the summary did not name the routine retention window behind that count"
  pass "the away-mode summary states that its counts cover the retained ledger rows"
}

test_real_drain_preserves_wakes_across_return_failures() (
  dir="$TMP_ROOT/real-drain"
  install_runner "$dir"
  cp "$ROOT/bin/sq-stand-to-drain.sh" "$ROOT/bin/sq-line-cap-lib.sh" "$dir/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/sq-guard.sh"
  chmod +x "$dir/bin/sq-guard.sh"
  # The function body IS the subshell, so exporting here is the intended scope.
  # shellcheck disable=SC2030,SC2031
  export SQUAD_STATE_OVERRIDE="$dir/home/state"
  . "$dir/bin/sq-stand-to-lib.sh"
  fm_wake_append check afk-ledger-undeliverable 'check: away-mode ledger could not record: retained wake' || fail 'could not seed the queue'
  printf '1784074300|escalation|retained escalation\n' > "$SQUAD_STATE_OVERRIDE/.subsuper-escalations"
  fm_lock_acquire_wait "$SQUAD_WAKE_QUEUE_LOCK"
  rc=0
  out=$(fm_run_timed 15 env SQUAD_AFK_RETURN_LOCK_SECS=1 SQUAD_BASE="$dir/home" "$dir/bin/sq-afk-return.sh" begin 2>&1) || rc=$?
  fm_lock_release "$SQUAD_WAKE_QUEUE_LOCK"
  [ "$rc" -eq 3 ] || fail "held queue lock did not return a bounded refusal: $rc: $out"
  case "$out" in
    *'catch-up exceeded its 1s budget'*|*'return catch-up gate phase: drain-failed'*) ;;
    *) fail "queue lock refusal lacked a diagnosis: $out" ;;
  esac
  grep -q 'retained wake' "$SQUAD_WAKE_QUEUE" || fail 'timed-out drain consumed its queue'

  REAL_SORT=$(command -v sort)
  export REAL_SORT
  cat > "$dir/bin/sort" <<'SH'
#!/usr/bin/env bash
case "$*" in *.subsuper-escalations*) exit 1 ;; esac
exec "$REAL_SORT" "$@"
SH
  chmod +x "$dir/bin/sort"
  rc=0
  out=$(PATH="$dir/bin:$PATH" run_return "$dir" check) || rc=$?
  [ "$rc" -eq 1 ] || fail "failed evidence merge was not surfaced: $rc: $out"
  [ ! -s "$SQUAD_WAKE_QUEUE" ] || fail 'successful drain did not advance its queue'
  [ -s "$SQUAD_STATE_OVERRIDE/.subsuper-escalations" ] || fail 'failed merge cleared the ledger'
  [ -s "$SQUAD_STATE_OVERRIDE/.afk-return-catchup" ] || fail 'failed merge cleared the gate'
  out=$(run_return "$dir" check) || fail "merge retry did not recover: $out"
  assert_contains "$out" '[escalation] retained escalation' 'retry lost the ledger escalation'
  assert_contains "$out" '[daemon-notice] check: away-mode ledger could not record: retained wake' 'retry lost the drained queue record'
  pass 'return bounds the real drain lock wait and retries failed evidence merges without losing wakes'
)

test_cold_fold_obeys_return_deadline() {
  local dir state out rc=0 total offset
  dir="$TMP_ROOT/cold-deadline"
  install_runner "$dir"
  install_real_drain "$dir"
  seed_live_blocker "$dir" tmux cold-blocker
  state="$dir/home/state"
  awk 'BEGIN { for (i=0; i<36; i++) printf "working: %02048d\n", i }' >> "$state/repair-task.status"
  total=$(wc -c < "$state/repair-task.status")
  printf '1784074300\t1\tcheck\tafk-ledger-undeliverable\tcheck: away-mode ledger could not record: cold checkpoint\n' > "$state/.stand-to-queue"
  {
    cat <<'SH'
#!/usr/bin/env bash
if [[ "$1" = -c && "$2" != +1 && "$3" = */repair-task.status ]]; then exec sleep 15; fi
SH
    printf "exec %q \"\$@\"\n" "$(command -v tail)"
  } > "$dir/bin/tail"
  chmod +x "$dir/bin/tail"
  out=$(fm_run_timed 9 env SQUAD_AFK_RETURN_LOCK_SECS=3 PATH="$dir/bin:$PATH" SQUAD_BASE="$dir/home" \
    "$dir/bin/sq-afk-return.sh" begin 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "the real cold drain escaped its enclosing budget ($rc): $out"
  assert_contains "$out" 'catch-up exceeded its 3s budget' 'the real cold fold did not hit the deadline'
  offset=$(awk -F= '$1 == "offset" { print $2 }' "$state/.repair-task.open-decisions-cursor")
  [ "$offset" -gt 0 ] && [ "$offset" -lt "$total" ] || fail 'the interrupted fold did not checkpoint partial progress'
  grep -q 'cold checkpoint' "$state"/.afk-return-drain.*/raw || fail 'the deadline lost the published raw batch'
  rm -f "$dir/bin/tail"
  rc=0
  out=$(run_return "$dir" check) || rc=$?
  [ "$rc" -eq 3 ] || fail "the resumed cold fold did not retain the live blocker: $out"
  assert_contains "$out" 'return catch-up gate phase: blocked' 'the resumed fold lost the blocker'
  printf 'resolved [key=cold-blocker]: cleared\n' >> "$state/repair-task.status"
  out=$(run_return "$dir" check) || fail "the resolved return stayed gated: $out"
  assert_contains "$out" 'cold checkpoint' 'the timed-out drain lost its queued wake'
  pass 'the return deadline contains the real cold drain and preserves fold progress and wakes'
}

test_unread_blocker_fails_closed() {
  local dir out rc=0
  dir="$TMP_ROOT/unread-blocker"
  install_runner "$dir"
  seed_live_blocker "$dir" tmux unread-blocker
  {
    cat <<'SH'
#!/usr/bin/env bash
[ "$1" != -c ] || exit 1
SH
    printf "exec %q \"\$@\"\n" "$(command -v tail)"
  } > "$dir/bin/tail"
  chmod +x "$dir/bin/tail"
  out=$(PATH="$dir/bin:$PATH" run_return "$dir" begin) || rc=$?
  [ "$rc" -eq 1 ] && [ -s "$dir/home/state/.afk-return-catchup" ] || fail "unread status cleared the gate: $out"
  rc=0
  out=$(run_return "$dir" check) || rc=$?
  [ "$rc" -eq 3 ] || fail "the readable blocker did not gate the retry: $out"
  assert_contains "$out" 'return catch-up gate phase: blocked' 'the retry lost the unread blocker'
  pass 'an incomplete blocker fold cannot clear the return gate'
}

test_retry_preserves_checkpoint_published_during_merge() (
  dir="$TMP_ROOT/late-checkpoint"
  install_runner "$dir"
  cp "$ROOT/bin/sq-stand-to-drain.sh" "$ROOT/bin/sq-line-cap-lib.sh" "$dir/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/sq-guard.sh"
  chmod +x "$dir/bin/sq-guard.sh"
  # The function body IS the subshell, so exporting here is the intended scope.
  # shellcheck disable=SC2030,SC2031
  export SQUAD_STATE_OVERRIDE="$dir/home/state"
  . "$dir/bin/sq-stand-to-lib.sh"
  export LATE_CHECKPOINT="$SQUAD_STATE_OVERRIDE/.afk-return-drain.interrupted/raw"
  mkdir -p "${LATE_CHECKPOINT%/*}"
  : > "${LATE_CHECKPOINT%/*}/output"
  printf '1784074300 1 check afk-ledger-undeliverable check: away-mode ledger could not record: late wake\n' > "$LATE_CHECKPOINT.pending"
  printf '1784074300|escalation|trigger evidence merge\n' > "$SQUAD_STATE_OVERRIDE/.subsuper-escalations"
  REAL_SORT=$(command -v sort)
  export REAL_SORT
  cat > "$dir/bin/sort" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *.subsuper-escalations*) mv "$LATE_CHECKPOINT.pending" "$LATE_CHECKPOINT" || exit 1 ;;
esac
exec "$REAL_SORT" "$@"
SH
  chmod +x "$dir/bin/sort"
  fm_lock_acquire_wait "$SQUAD_WAKE_QUEUE_LOCK"
  rc=0
  out=$(PATH="$dir/bin:$PATH" SQUAD_AFK_RETURN_LOCK_SECS=0 run_return "$dir" check) || rc=$?
  fm_lock_release "$SQUAD_WAKE_QUEUE_LOCK"
  [ "$rc" -eq 3 ] || fail "held queue lock did not preserve the gate: $rc: $out"
  [ -s "$LATE_CHECKPOINT" ] || fail 'retry removed a checkpoint published after the merge snapshot'
  out=$(run_return "$dir" check) || fail "late checkpoint retry did not recover: $out"
  assert_contains "$out" '[daemon-notice] check: away-mode ledger could not record: late wake' 'retry lost the late wake'
  [ ! -e "$LATE_CHECKPOINT" ] || fail 'successful merge did not remove the recorded checkpoint'
  pass 'return only removes checkpoints included in its evidence commit'
)

test_summary_write_failure_preserves_evidence() (
  dir="$TMP_ROOT/summary-write-failure"
  install_runner "$dir"
  state="$dir/home/state"
  printf '1784074300|escalation|undelivered summary event\n' > "$state/.subsuper-escalations"
  rc=0
  SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$state" "$dir/bin/sq-afk-return.sh" begin >&- 2> "$dir/error" || rc=$?
  [ "$rc" -eq 1 ] || fail "summary write failure was not surfaced: $rc"
  [ -s "$state/.afk-return-catchup" ] || fail 'summary write failure cleared the gate'
  [ -s "$state/.subsuper-escalations" ] || fail 'summary write failure cleared the ledger'
  out=$(run_return "$dir" check) || fail "summary retry failed: $out"
  assert_contains "$out" '[escalation] undelivered summary event' 'summary retry lost the escalation'
  [ ! -e "$state/.afk-return-catchup" ] || fail 'successful summary did not clear the gate'
  pass 'return retries an undelivered summary without losing its evidence'
)

test_real_drain_preserves_wakes_across_return_failures
test_retry_preserves_checkpoint_published_during_merge
test_summary_write_failure_preserves_evidence
test_shutdown_step_is_bounded_and_retains_lifecycle
test_shutdown_contains_real_backend
test_failed_evidence_merge_names_its_phase
test_cold_fold_obeys_return_deadline
test_unread_blocker_fails_closed
test_blocker_scan_is_bounded_by_new_appends
test_routine_evidence_stays_bounded_across_shutdown_retries
test_summary_count_names_the_retained_scope
test_return_gate_orders_catchup_before_bearings
test_undeliverable_ledger_item_reaches_the_summary
test_explicit_reclassification_requires_durable_reason
test_away_ledger_is_presented_once_and_never_repeated
test_single_class_ledger_clears_return_gate
test_away_ledger_while_blocked_presents_only_a_count
test_commander_decision_does_not_masquerade_as_Squad_blocker
test_away_reentry_refuses_pending_return_gate
test_check_retries_recorded_terminal_teardown
test_decimal_limits_preserve_summary_order
test_pathological_ledger_terminates_within_bound
test_stuck_gate_names_its_phase_and_the_supported_recovery
test_catchup_lock_wait_is_bounded
