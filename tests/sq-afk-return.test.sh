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

TMP_ROOT=$(fm_test_tmproot sq-afk-return-tests)

install_runner() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp "$ROOT/bin/sq-afk-return.sh" "$dir/bin/"
  cp "$ROOT/bin/"sq-{stand-to-drain,stand-to-lib,classify-lib,line-cap-lib}.sh "$dir/bin/"
  cat > "$dir/bin/sq-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
printf 'stop\n' >> "$SQUAD_BASE/stop.log"
rm -f "$SQUAD_BASE/state/.afk"
if [ -e "$SQUAD_BASE/state/.fail-terminal-stop-once" ]; then
  rm -f "$SQUAD_BASE/state/.fail-terminal-stop-once"
  exit 1
fi
rm -f "$SQUAD_BASE/state/.afk-daemon-terminal"
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/sq-guard.sh"
  chmod +x "$dir/bin/"*.sh
}

run_return() {  # <case-dir> <mode>
  local dir=$1
  shift
  SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" "$dir/bin/sq-afk-return.sh" "$@" 2>&1
}

stored_identity() {
  awk -F '\t' -v key="${2:-id}" '$1 == key { print $2; exit }' "$1"
}

ack_return() {
  local dir=$1 id
  id=$(stored_identity "$dir/home/state/.afk-receipt") || return 1
  run_return "$dir" ack "$id"
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
  printf '1784074271\t2\tsignal\trepair-task.status\tsignal: synthetic status\n' > "$dir/home/state/.stand-to-queue"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "return begin should gate on a live blocker (rc=$rc): $out"
  gate="$dir/home/state/.afk-return-catchup"
  [ -s "$gate" ] || fail "return begin did not persist its fail-closed catch-up gate"
  assert_contains "$out" 'Squad-actionable blocker: repair-task [key=synthetic-dependency]' "return output did not assign blocker remediation to Squad"
  grep -F $'evidence\twake\t1784074271' "$gate" >/dev/null || fail "drained wake evidence was not retained in the durable gate"
  grep -F $'evidence\twake\twake annotation: latest wake-EVENT observed at drain, not current state' "$gate" >/dev/null \
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
  assert_contains "$out" 'catch-up summary' "successful check did not present the catch-up summary"
  out=$(ack_return "$dir") || fail "receipt acknowledgement failed: $out"
  assert_contains "$out" 'catch-up clear' "ack did not announce that ordinary work may proceed"
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
    : > "$dir/home/state/.stand-to-queue"
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
    [ ! -f "$dir/home/state/.afk-receipt" ] || ack_return "$dir" >/dev/null || fail "ack after reclassification failed"
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
  printf '1784074271\t1\tsignal\tdecision-task.status\tsignal: synthetic decision\n' > "$dir/home/state/.stand-to-queue"
  out=$(run_return "$dir" begin) || fail "approval decision should not be treated as a Squad blocker: $out"
  assert_contains "$out" 'queued wake records drained: 1' "approval decision wake record was not listed as an open item"
  assert_not_contains "$out" 'catch-up summary' "queued wake records alone presented an away-mode summary"
  assert_contains "$out" 'OPEN DECISIONS' "approval decision was not surfaced as an open item in the summary"
  ack_return "$dir" >/dev/null || fail "open-item receipt was not acknowledgeable"
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
  [ ! -e "$dir/home/state/.afk" ] || fail "failed terminal teardown did not preserve stop ordering"

  out=$(run_return "$dir" check) || fail "check did not retry recorded terminal teardown: $out"
  [ ! -e "$dir/home/state/.afk-daemon-terminal" ] || fail "successful check left the terminal teardown record behind"
  [ ! -e "$gate" ] || fail "successful terminal teardown retry left the return gate behind"
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
  ack_return "$dir" >/dev/null || fail "ledger receipt acknowledgement failed"
  [ ! -e "$dir/home/state/.subsuper-escalations" ] && [ ! -e "$dir/home/state/.subsuper-routine" ] || fail "clear left the ledger behind"
  out=$(run_return "$dir" begin) || fail "re-run of a cleared catch-up failed: $out"
  assert_not_contains "$out" 'catch-up summary' "re-run duplicated the away-mode summary"
  out=$(run_return "$dir" check) || fail "check after a cleared catch-up failed: $out"
  assert_not_contains "$out" 'catch-up summary' "check duplicated the away-mode summary"
  pass "away-mode ledger is presented once as one summary and a re-run never repeats it"
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
  } > "$dir/home/state/.stand-to-queue"
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
  ack_return "$dir" >/dev/null || fail "wedge-only acknowledgement failed"
  out=$(run_return "$dir" begin) || fail "wedge-only re-run failed: $out"
  assert_not_contains "$out" 'catch-up summary' "re-run duplicated the wedge notice summary"

  dir="$TMP_ROOT/ledger-undeliverable-partial-drain"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  {
    printf 'away-mode ledger undeliverable as of 2026-01-01T10:00:00+0000: escalation: fake-c4: failed: lint\n'
    printf 'away-mode ledger undeliverable as of 2026-01-01T10:05:00+0000: escalation: fake-c5: done: PR https://example.test/pr/88\n'
  } > "$dir/home/state/.subsuper-inject-wedged"
  printf '1784074300\t7\tcheck\tafk-ledger-undeliverable\tcheck: away-mode ledger could not record: escalation: fake-c5: done: PR https://example.test/pr/88\n' \
    > "$dir/home/state/.stand-to-queue"
  out=$(run_return "$dir" begin) || fail "partially drained undeliverable return should clear: $out"
  assert_contains "$out" 'daemon-notice=2' "partially drained undeliverable items were not both counted"
  assert_contains "$out" '[daemon-notice] away-mode ledger undeliverable as of 2026-01-01T10:00:00+0000: escalation: fake-c4: failed: lint' \
    "undeliverable item drained during the absence was lost from the summary"
  assert_contains "$out" '[daemon-notice] check: away-mode ledger could not record: escalation: fake-c5: done: PR https://example.test/pr/88' \
    "surviving undeliverable record was not presented"
  assert_not_contains "$out" 'as of 2026-01-01T10:05:00+0000' "marker line duplicated the surviving queued record"
  pass "an item the ledger could not record reaches the return summary once"
}

# The origin fix for the 2026-11-24 repeat: a notification about a window whose
# task already finished names no new work, so the ledger must not grow with it.
test_pathological_ledger_is_counted_and_bounded() {
  local dir out events started elapsed
  dir="$TMP_ROOT/ledger-pathological"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  awk 'BEGIN {
    for (i = 0; i < 25087; i++)
      printf "179551%04d|routine|stale: squad:0a5b0c1f -> task already finished: done: PR https://example.test/pr/12\n", i % 9000
  }' > "$dir/home/state/.subsuper-routine"
  printf '1795517952|escalation|pantheon-v2-front-2: done: PR https://example.test/pr/12 checks green\n' \
    > "$dir/home/state/.subsuper-escalations"
  printf '20087\n' > "$dir/home/state/.subsuper-dropped-finished-repeat"

  started=$SECONDS
  out=$(SQUAD_AFK_SUMMARY_MAX_EVENTS_DEFAULT=9999 SQUAD_AFK_SUMMARY_MAX_LEDGER_ROWS=9999 \
    SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$dir/home/state" \
    perl -e 'alarm shift; exec @ARGV or die $!' 15 "$dir/bin/sq-afk-return.sh" begin) ||
    fail "pathological ledger did not return within 15 seconds: $out"
  elapsed=$((SECONDS - started))
  assert_contains "$out" 'catch-up summary' "pathological ledger did not present a summary"
  assert_contains "$out" 'counts: escalation=1 routine=1999' "class counts did not match the bounded read"
  assert_contains "$out" '25088 rows counted, 2000 read, 23088 not read' "the summary did not account for unread rows"
  assert_contains "$out" 'coverage: these counts cover only the retained away-mode window' \
    "the summary did not state that its counts cover the retained window, not the whole absence"
  assert_contains "$out" '201 listed, 0 duplicate collapses, 1799 cap omissions' "the summary did not name what the presentation bound skipped"
  assert_contains "$out" 'dropped before the ledger: finished-repeat=20087' \
    "the summary did not report the repetitions dropped at origin"
  assert_contains "$out" 'https://example.test/pr/12 checks green' \
    "the bounded presentation dropped the escalation a commander has to read"
  events=$(printf '%s' "$out" | grep -cE '^  [0-9]+\. ' || true)
  [ "$events" -le 201 ] || fail "the presentation listed $events events instead of its bound"
  ack_return "$dir" >/dev/null || fail "bounded receipt acknowledgement failed"
  [ ! -e "$dir/home/state/.subsuper-routine" ] || fail "the bounded return left the ledger behind"

  # An absence whose only content was finished-window repeats still reports them:
  # the drop is the account of what the window held, not a silent zero.
  dir="$TMP_ROOT/ledger-drops-only"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  printf '25028\n' > "$dir/home/state/.sentry-dropped-finished-repeat"
  out=$(run_return "$dir" begin) || fail "a drops-only return should present: $out"
  assert_contains "$out" 'dropped before the ledger: sentry-finished-repeat=25028' \
    "an absence made only of repeats reported no drop at all"
  assert_contains "$out" 'counts: escalation=0 routine=0 daemon-notice=0' \
    "a drops-only summary did not state its empty counts"
  ack_return "$dir" >/dev/null || fail "drops-only receipt acknowledgement failed"
  [ ! -e "$dir/home/state/.sentry-dropped-finished-repeat" ] || fail "ack did not clear the sentry drop counter"
  pass "25,087 routine rows plus one escalation: ${elapsed}s (15s deadline), 2,000 parsed, 23,088 not read"
}

# A crash between building the summary and the commander seeing it must neither
# lose the summary nor double it, and the replay must keep one identity.
test_return_receipt_survives_a_crash_without_doubling() {
  local dir state out rc id ack count
  dir="$TMP_ROOT/receipt-crash"
  state="$dir/home/state"
  install_runner "$dir"
  date +%s > "$state/.afk"
  printf '%s\n' '1784074271|routine|identical event' '1784074271|routine|identical event' > "$state/.subsuper-routine"
  printf '1784074280\t2\tcheck\tafk-ledger-undeliverable\tcheck: queue-only escalation\n' > "$state/.stand-to-queue"

  rc=0
  out=$(SQUAD_AFK_RETURN_CRASH=drained run_return "$dir" begin) || rc=$?
  [ "$rc" -eq 9 ] && [ ! -s "$state/.stand-to-queue" ] || fail "crash did not follow queue consumption: $out"
  [ ! -e "$state/.afk-receipt" ] || fail "drain unexpectedly built a receipt before the crash"

  mkdir "$state/.afk-receipt"
  rc=0
  out=$(run_return "$dir" begin) || rc=$?
  [ "$rc" -eq 1 ] || fail "receipt publication failure was not reported: $out"
  assert_contains "$out" 'could not publish receipt' "publication failure had no diagnostic"
  assert_not_contains "$out" 'catch-up summary' "publication failure presented an unrecorded summary"
  [ -s "$state/.subsuper-routine" ] && [ -s "$state/.afk-return-catchup" ] || fail "publication failure cleared inputs"
  rmdir "$state/.afk-receipt"

  rc=0
  out=$(SQUAD_AFK_RETURN_CRASH=receipt run_return "$dir" begin) || rc=$?
  [ "$rc" -eq 9 ] || fail "crash after build did not stop the return: $out"
  assert_not_contains "$out" 'catch-up summary' "summary presented before the replay"
  id=$(stored_identity "$state/.afk-receipt")
  [ -n "$id" ] && [ ! -e "$state/.afk-receipt.ack" ] || fail "the built receipt did not remain pending"
  printf 'crash after build: presented=0 pending=%s\n' "$id"

  if SQUAD_BASE="$dir/home" SQUAD_STATE_OVERRIDE="$state" "$dir/bin/sq-afk-return.sh" begin >&- 2>/dev/null; then
    fail "receipt presentation to closed stdout succeeded"
  fi
  [ "$(stored_identity "$state/.afk-receipt")" = "$id" ] && [ ! -e "$state/.afk-receipt.ack" ] || fail "failed write consumed the receipt"
  rc=0
  out=$(run_return "$dir" guard) || rc=$?
  [ "$rc" -eq 3 ] || fail "guard admitted ordinary work before acknowledgement: $out"
  if run_return "$dir" ack wrong-id >/dev/null; then fail "ack accepted an unrelated identity"; fi

  out=$(run_return "$dir" begin) || fail "replay failed: $out"
  assert_contains "$out" "Receipt $id: bin/sq-afk-return.sh ack $id" "the replay did not identify the stored receipt"
  assert_contains "$out" 'queue-only escalation' "the replay lost already-consumed queue evidence"
  assert_contains "$out" '1 listed, 1 duplicate collapses, 0 cap omissions' "duplicate ledger accounting did not match rendered rows"
  count=$(printf '%s' "$out" | grep -c 'catch-up summary' || true)
  [ "$count" -eq 1 ] || fail "the replay presented the summary $count times"
  [ ! -e "$state/.afk-receipt.ack" ] || fail "presentation acknowledged its own receipt"
  printf 'replay: presented=%s pending=%s\n' "$count" "$id"

  rc=0
  out=$(SQUAD_AFK_RETURN_CRASH=acknowledged run_return "$dir" ack "$id") || rc=$?
  ack=$(stored_identity "$state/.afk-receipt.ack" ack)
  [ "$rc" -eq 9 ] && [ "$ack" = "$id" ] && [ -s "$state/.subsuper-routine" ] || fail "ack did not land before cleanup: $out"
  printf 'ack: consumed=%s (cleanup interrupted)\n' "$ack"

  out=$(run_return "$dir" begin) || fail "ack cleanup did not resume: $out"
  assert_not_contains "$out" 'catch-up summary' "ack cleanup presented a replacement summary"
  [ ! -e "$state/.afk-receipt" ] && [ ! -e "$state/.afk-receipt.ack" ] || fail "ack cleanup left receipt state behind"
  [ ! -e "$state/.subsuper-routine" ] || fail "ack cleanup left the ledger behind"
  out=$(run_return "$dir" check) || fail "a later return failed: $out"
  assert_not_contains "$out" 'catch-up summary' "later return presented the acknowledged receipt"
  pass "post-ack cleanup and later return: presented=0"
}

test_failed_ledger_selection_preserves_catchup() {
  local dir state out rc real_awk row wake
  dir="$TMP_ROOT/ledger-selection-failure"
  state="$dir/home/state"
  install_runner "$dir"
  real_awk=$(command -v awk)
  cat > "$dir/bin/awk" <<'SH'
#!/usr/bin/env bash
if [ "${!#}" = "$SQUAD_STATE_OVERRIDE/.subsuper-routine" ]; then
  printf 'rows=1 escalation=0 routine=1 listed=0 oldest= newest=\n'
  exit 1
fi
exec "$REAL_AWK" "$@"
SH
  chmod +x "$dir/bin/awk"
  row='1784074290|routine|synthetic ledger event'
  wake=$'1784074271\t2\tsignal\trepair-task.status\tsignal: synthetic status'
  printf '%s\n' "$row" > "$state/.subsuper-routine"
  printf '%s\n' "$wake" > "$state/.stand-to-queue"

  rc=0
  out=$(PATH="$dir/bin:$PATH" REAL_AWK="$real_awk" run_return "$dir" begin) || rc=$?
  [ "$rc" -eq 1 ] || fail "failed ledger collection did not fail closed (rc=$rc): $out"
  assert_contains "$out" 'could not collect the away-mode ledger' "return did not report the ledger failure"
  assert_not_contains "$out" 'catch-up summary' "failed ledger collection published a partial summary"
  [ -s "$state/.afk-return-catchup" ] || fail "failed ledger collection cleared the catch-up gate"
  [ ! -e "$state/.afk-receipt" ] || fail "failed ledger collection wrote a receipt"
  [ "$(<"$state/.subsuper-routine")" = "$row" ] || fail "failed ledger collection changed the source ledger"
  [ "$(<"$state/.stand-to-queue")" = "$wake" ] || fail "failed ledger collection consumed pending wake evidence"

  out=$(run_return "$dir" check) || fail "retry did not clear catch-up: $out"
  assert_contains "$out" 'synthetic ledger event' "retry did not present the retained ledger event"
  ack_return "$dir" >/dev/null || fail "receipt acknowledgement after retry failed"
  [ ! -e "$state/.afk-return-catchup" ] || fail "successful retry left catch-up pending"
  pass "failed ledger selection leaves catch-up inputs intact for retry"
}

test_return_gate_orders_catchup_before_bearings
test_undeliverable_ledger_item_reaches_the_summary
test_explicit_reclassification_requires_durable_reason
test_away_ledger_is_presented_once_and_never_repeated
test_away_ledger_while_blocked_presents_only_a_count
test_commander_decision_does_not_masquerade_as_Squad_blocker
test_away_reentry_refuses_pending_return_gate
test_check_retries_recorded_terminal_teardown
test_pathological_ledger_is_counted_and_bounded
test_return_receipt_survives_a_crash_without_doubling
test_failed_ledger_selection_preserves_catchup
