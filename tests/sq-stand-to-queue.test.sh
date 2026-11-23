#!/usr/bin/env bash
# tests/sq-stand-to-queue.test.sh - stand-to queue losslessness (the queue safety matrix):
# concurrent append/drain, bounded structural enrichment, interruption safety,
# signal catch-up while no sentry runs, stale/check enqueue-before-suppressor
# ordering, atomic double-drain, duplicate collapse, and liveness assertion.
# Nothing is lost and nothing is double-consumed. General sentry/lock liveness
# lives in sq-sentry-lock.test.sh; daemon classification/injection in
# sq-daemon.test.sh.
set -u

# shellcheck source=tests/stand-to-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/stand-to-helpers.sh"

WATCH="$ROOT/bin/sq-sentry.sh"
DRAIN="$ROOT/bin/sq-stand-to-drain.sh"

TMP_ROOT=$(fm_test_tmproot sq-stand-to-tests)


test_concurrent_append_and_drain() {
  local dir state out1 out2 all pids i pid count unique malformed
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "final drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 40 ] || fail "expected 40 drained records, got $count"
  malformed=$(awk -F '\t' 'NF != 5 { bad++ } END { print bad + 0 }' "$all")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' '{ keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$all")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  pass "concurrent append plus drain preserves queue records"
}

test_signal_catchup_without_running_sentry() {
  local dir state fakebin out drain_out status_file
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # The durable-queue catch-up contract applies to ACTIONABLE wakes (the always-on
  # sentry can absorb no-verb working: notes when the operator is provably working).
  # Use a commander-relevant verb so the wake is surfaced and the catch-up path is
  # tested.
  printf 'blocked: first\n' > "$status_file"
  printf 'id=task\n' > "$state/task.meta"
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "sentry did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "sentry did not print first signal"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "sentry did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no sentry was not caught"
  pass "signal written while no sentry runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:sq-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/stale.meta"
  # A stale pane sitting on a commander-relevant status is actionable when the operator
  # is not provably working, so give the window one and prime the .seen-* marker
  # to its current signature so the per-poll signal scan does not pre-empt the
  # stale wake with a signal wake.
  printf 'done: ready in branch sq/stale\n' > "$state/stale.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stale.status"); else sig=$(stat -c '%s:%Y' "$state/stale.status"); fi
  printf '%s' "$sig" > "$state/.seen-stale_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "sentry did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "sentry did not print stale wake"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

# Absorb-only-when-provably-working adds a new actionable wake: a non-terminal stale
# whose crew is NOT provably working is surfaced immediately. That new path must keep
# the queue-safety invariant - enqueue the stale wake BEFORE advancing the .stale-*
# suppressor - so a sentry killed between the two never swallows the surfaced finish.
test_not_working_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:sq-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (no commander-relevant verb); prime .seen-* so the per-poll
  # signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stopped.status"); else sig=$(stat -c '%s:%Y' "$state/stopped.status"); fi
  printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # NOT provably working: no running pipeline, idle pane. (make_case installed the
  # fake sq-crew-state.sh the sentry reads via SQUAD_CREW_STATE_BIN.)
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "sentry did not surface a not-provably-working stale"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "sentry did not print the immediate stale wake"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the immediate stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced after the enqueue"
  unset SQUAD_FAKE_CREW_STATE
  pass "a not-provably-working stale wake is queued before its suppressor is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  printf '%s\n' sq-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' sq-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod 0700 "$check_file"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-check-register.sh" task >/dev/null \
    || fail "could not register queue custom check"
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=0 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "sentry did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "sentry did not print check wake"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "registered custom check output is queued before cadence suppression"
}

test_atomic_double_drain() {
  local dir state out1 out2 all count leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:sq-task' 'stale: s:sq-task' || fail "stale append failed"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pid1=$!
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 3 ] || fail "two drains consumed records more than once or lost records; got $count"
  leftover=$(SQUAD_STATE_OVERRIDE="$state" "$DRAIN" | awk 'NF { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "queue was not empty after double drain"
  pass "two atomic drains cannot consume the same records twice"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# sentry liveness via sq-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live sentry, and stay silent right after a
# normal fire from a live sentry with a fresh beacon, so it never false-alarms.
test_drain_asserts_sentry_liveness() {
  local dir state err identity
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  printf 'window=test:sq-x\nkind=strike\n' > "$state/x.meta"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the sentry-down banner with work in flight and no live sentry"
  : > "$err"
  identity=$(SQUAD_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/sq-stand-to-lib.sh" "$$") \
    || fail "could not identify the live sentry fixture"
  mkdir "$state/.sentry.lock"
  printf '%s\n' "$$" > "$state/.sentry.lock/pid"
  printf '%s\n' "$dir" > "$state/.sentry.lock/sq-home"
  printf '%s\n' "$WATCH" > "$state/.sentry.lock/sentry-path"
  printf '%s\n' "$identity" > "$state/.sentry.lock/pid-identity"
  touch "$state/.last-sentry-beat"
  SQUAD_BASE="$dir" SQUAD_STATE_OVERRIDE="$state" SQUAD_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" \
    || fail "drain failed with a live sentry and fresh beacon"
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed with a live sentry and fresh beacon"
  fi
  pass "drain asserts sentry liveness: warns on a lapse, stays silent for a live sentry with a fresh beacon"
}

test_structural_signal_enrichment_preserves_raw_rows() {
  local dir state out expected actual annotation_count outside perl_bin
  dir=$(make_case enrichment)
  state="$dir/state"
  out="$dir/drain.out"
  expected="$dir/expected.out"
  actual="$dir/actual.out"
  outside="$dir/outside-secret"
  printf 'working: first\n\ndone: latest event\n' > "$state/task.status"
  printf 'working: old turn-end context\n' > "$state/turn-only.status"
  printf 'must-not-be-read\n' > "$outside"
  ln -s "$outside" "$state/escape.status"
  perl_bin=$(command -v perl) || fail "perl is required for safe status reads"
  cat > "$dir/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -MFcntl=:DEFAULT ]; then
  for arg in "$@"; do
    if [ "$arg" = "${SQUAD_WAKE_ENRICH_SWAP_PATH:-}" ]; then
      rm -f "$arg"
      ln -s "$SQUAD_WAKE_ENRICH_SWAP_TARGET" "$arg"
      break
    fi
  done
fi
exec "$SQUAD_WAKE_ENRICH_REAL_PERL" "$@"
SH
  chmod +x "$dir/fakebin/perl"

  append_wake "$state" signal task.status "signal: $outside" || fail "direct status wake append failed"
  append_wake "$state" signal task.turn-ended "signal: $outside" || fail "coalesced turn-end wake append failed"
  append_wake "$state" signal turn-only.turn-ended "signal: $outside" || fail "bare turn-end wake append failed"
  append_wake "$state" signal escape.status "signal: $outside" || fail "symlink status wake append failed"
  append_wake "$state" signal arbitrary-key "signal: $outside" || fail "non-status signal wake append failed"
  append_wake "$state" check task.check.sh "check: complete payload" || fail "check wake append failed"
  append_wake "$state" stale test:sq-task "stale: test:sq-task" || fail "stale wake append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat wake append failed"

  SQUAD_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_print_deduped "$2"' _ \
    "$ROOT/bin/sq-stand-to-lib.sh" "$state/.stand-to-queue" > "$expected"
  PATH="$dir/fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_WAKE_ENRICH_SWAP_PATH="$state/task.status" \
    SQUAD_WAKE_ENRICH_SWAP_TARGET="$outside" SQUAD_WAKE_ENRICH_REAL_PERL="$perl_bin" "$DRAIN" > "$out" \
    || fail "structural enrichment drain failed"
  awk -F '\t' 'NF == 5 { print }' "$out" > "$actual"
  cmp -s "$expected" "$actual" || fail "enrichment changed or reordered an authoritative raw row"

  annotation_count=$(grep -c '^wake annotation:' "$out" || true)
  [ "$annotation_count" -eq 1 ] || fail "expected only the unreadable-race-safe status annotation, got $annotation_count"
  if grep -E '^wake annotation:.*: task\.status:' "$out" >/dev/null; then
    fail "replaced status file produced an annotation"
  fi
  grep -F 'latest wake-EVENT observed at drain, not current state; historical / not necessarily the triggering event: turn-only.status:' "$out" >/dev/null \
    || fail "bare turn-end mapping did not carry the historical warning"
  if grep -F 'must-not-be-read' "$out" >/dev/null; then
    fail "drain trusted a payload path or followed an out-of-state status symlink"
  fi
  pass "structural signal enrichment is separate, deduped, home-local, and tier-zero for other wakes"
}

test_enrichment_caps_and_status_file_failures() {
  local dir state out fake_perl_log perl_bin i raw_count annotation_bytes annotation_count oversized_lines perl_reads
  dir=$(make_case caps)
  state="$dir/state"
  out="$dir/drain.out"
  fake_perl_log="$dir/perl.log"
  perl_bin=$(command -v perl) || fail "perl is required for safe status reads"
  cat > "$dir/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -MFcntl=:DEFAULT ]; then
  printf 'read\n' >> "$SQUAD_WAKE_ENRICH_PERL_LOG"
fi
exec "$SQUAD_WAKE_ENRICH_REAL_PERL" "$@"
SH
  chmod +x "$dir/fakebin/perl"
  awk 'BEGIN { printf "done: "; for (i = 0; i < 20000; i++) printf "x"; printf "\n" }' > "$state/huge.status"
  append_wake "$state" signal huge.status "signal: huge" || fail "huge status wake append failed"
  i=1
  while [ "$i" -le 8 ]; do
    awk -v n="$i" 'BEGIN { printf "working-%d: ", n; for (j = 0; j < 3000; j++) printf "y"; printf "\n" }' > "$state/many-$i.status"
    append_wake "$state" signal "many-$i.status" "signal: many-$i" || fail "many-status wake append failed"
    i=$((i + 1))
  done
  : > "$state/empty.status"
  append_wake "$state" signal empty.status "signal: empty" || fail "empty status wake append failed"
  append_wake "$state" signal missing.status "signal: missing" || fail "missing status wake append failed"
  mkdir "$state/malformed.status"
  append_wake "$state" signal malformed.status "signal: malformed" || fail "malformed status wake append failed"
  printf 'done: unreadable\n' > "$state/unreadable.status"
  chmod 000 "$state/unreadable.status"
  append_wake "$state" signal unreadable.status "signal: unreadable" || fail "unreadable status wake append failed"

  PATH="$dir/fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_WAKE_ENRICH_PERL_LOG="$fake_perl_log" \
    SQUAD_WAKE_ENRICH_REAL_PERL="$perl_bin" "$DRAIN" > "$out" \
    || fail "capped enrichment drain failed"
  raw_count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$raw_count" -eq 13 ] || fail "missing, unreadable, malformed, empty, or oversized status input hid a raw row"
  grep '^wake annotation:.*\[truncated\]$' "$out" >/dev/null || fail "per-item/input truncation marker was not emitted"
  grep -E '^wake annotation: [1-9][0-9]* annotations omitted \(global enrichment byte cap\)$' "$out" >/dev/null \
    || fail "global omitted-annotation marker was not emitted"
  annotation_bytes=$(LC_ALL=C awk '/^wake annotation:/ { bytes += length($0) + 1 } END { print bytes + 0 }' "$out")
  [ "$annotation_bytes" -le 8192 ] || fail "global annotation output exceeded 8192 bytes ($annotation_bytes)"
  oversized_lines=$(LC_ALL=C awk '/^wake annotation: latest/ && length($0) + 1 > 2048 { count++ } END { print count + 0 }' "$out")
  [ "$oversized_lines" -eq 0 ] || fail "a per-item annotation exceeded 2048 bytes"
  annotation_count=$(grep -c '^wake annotation: latest' "$out" || true)
  [ "$annotation_count" -lt 9 ] || fail "global cap did not omit any of the nine readable status annotations"
  perl_reads=$(wc -l < "$fake_perl_log" | tr -d ' ')
  [ "$perl_reads" -eq 8 ] || fail "enrichment read cap allowed $perl_reads safe reads instead of 8"
  grep -E '^wake annotation: [1-9][0-9]* annotations omitted \(enrichment read cap\)$' "$out" >/dev/null \
    || fail "enrichment read-cap omission marker was not emitted"
  if grep -E ': (empty|missing|malformed|unreadable)\.status:' "$out" >/dev/null; then
    fail "missing, unreadable, malformed, or empty status file produced an annotation"
  fi
  pass "bounded reads and per-item/global caps fail open with explicit truncation and omission markers"
}

wait_for_file_text() {  # <file> <fixed-text>
  local file=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_slow_annotation_does_not_block_append_and_deleted_file_fails_open() {
  local dir state out1 out2 pid
  dir=$(make_case slow-annotation)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  printf 'done: disappears before bounded read\n' > "$state/slow.status"
  append_wake "$state" signal slow.status "signal: slow" || fail "slow status wake append failed"

  SQUAD_STATE_OVERRIDE="$state" SQUAD_WAKE_ENRICH_TEST_DELAY=3 "$DRAIN" > "$out1" &
  pid=$!
  wait_for_file_text "$out1" "$(printf '\tsignal\tslow.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "slow drain did not commit its raw row"; }
  printf 'done: appended while first drain annotates\n' > "$state/next.status"
  append_wake "$state" signal next.status "signal: next" || fail "append blocked or failed during annotation"
  kill -0 "$pid" 2>/dev/null || fail "slow annotation finished before the concurrent append proved lock independence"
  rm -f "$state/slow.status"
  wait "$pid" || fail "deleted status file made the committed drain fail"
  grep -F "$(printf '\tsignal\tslow.status\t')" "$out1" >/dev/null || fail "deleted status file hid the committed raw row"
  if grep -F ': slow.status:' "$out1" >/dev/null; then
    fail "status deleted during annotation still produced an annotation"
  fi
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "follow-up drain after concurrent append failed"
  grep -F "$(printf '\tsignal\tnext.status\t')" "$out2" >/dev/null || fail "concurrent append was not left for the next drain"
  pass "slow annotation releases the append lock and a deleted status file fails open"
}

test_interruption_before_and_after_raw_commit() {
  local dir state before_out after_out replay_out empty_out pid rc count i
  dir=$(make_case interruption)
  state="$dir/state"
  before_out="$dir/before.out"
  after_out="$dir/after.out"
  replay_out="$dir/replay.out"
  empty_out="$dir/empty.out"
  printf 'done: interruption fixture\n' > "$state/task.status"
  append_wake "$state" signal task.status "signal: task" || fail "pre-commit interruption wake append failed"
  append_wake "$state" check procevent:interrupted:1 'check: captured result' || fail 'process-event wake append failed'

  SQUAD_STATE_OVERRIDE="$state" SQUAD_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=5 "$DRAIN" > "$before_out" &
  pid=$!
  i=0
  for ((i = 0; i < 100; i++)); do
    if [ -f "$state/.stand-to-queue" ] && [ ! -s "$state/.stand-to-queue" ] &&
       compgen -G "$state/.stand-to-queue.drain.*" >/dev/null; then
      break
    fi
    sleep 0.05
  done
  [ "$i" -lt 100 ] || { kill "$pid" 2>/dev/null || true; fail "pre-commit drain never rotated the queue"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain before raw commitment"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pre-commit interruption unexpectedly succeeded"
  [ ! -s "$state/.stand-to-queue" ] || fail 'the interrupted fixture still has a live queue row'
  printf 'id=task\n' > "$state/task.meta"
  SQUAD_ROOT_OVERRIDE="$dir" SQUAD_STATE_OVERRIDE="$state" SQUAD_GUARD_READ_ONLY=1 \
    "$ROOT/bin/sq-guard.sh" > "$dir/guard.out" 2>&1
  grep -Fq 'WARNING: queued wakes pending' "$dir/guard.out" || fail 'the guard missed the unpublished batch'
  PATH="$dir/fakebin:$PATH" SQUAD_BASE="$dir" SQUAD_STATE_OVERRIDE="$state" \
    SQUAD_POLL=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  wait_for_exit "$!" 40 || fail 'the sentry did not surface the unpublished process-event wake'
  grep -Fxq 'check: process-event result captured: procevent:interrupted:1' "$dir/watch.out" \
    || fail 'the sentry missed the process-event key in the unpublished batch'
  append_wake "$state" signal task.status 'signal: newer task wake after TERM' || fail 'post-TERM wake append failed'
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" || fail 'pre-commit wakes did not drain'
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$replay_out")
  [ "$count" -eq 3 ] || fail 'pre-commit interruption lost or duplicated a wake'
  grep -Fxq 'signal: task' < <(cut -f5 "$replay_out") || fail 'pre-commit interruption lost the original payload'
  grep -Fxq 'signal: newer task wake after TERM' < <(cut -f5 "$replay_out") || fail 'pre-commit interruption lost the newer payload'

  append_wake "$state" signal task.status "signal: task after commit" || fail "post-commit interruption wake append failed"
  SQUAD_STATE_OVERRIDE="$state" SQUAD_WAKE_ENRICH_TEST_DELAY=5 "$DRAIN" > "$after_out" &
  pid=$!
  wait_for_file_text "$after_out" "$(printf '\tsignal\ttask.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain did not print its raw row"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain after raw commitment"
  set +e
  wait "$pid"
  set -e
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$empty_out" || fail "drain after post-commit interruption failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$after_out" "$empty_out")
  [ "$count" -eq 1 ] || fail "post-commit interruption restored or duplicated the consumed row"
  pass "interruptions preserve separate batches before commitment and never replay after raw commitment"
}

# A drain killed with no chance to run its EXIT trap (SIGKILL, a hard crash) leaves
# the queue empty and its in-flight batch in .stand-to-queue.drain.*. The next
# drain must recover that batch before deciding the queue is empty; otherwise the
# wake is never reported, and bin/sq-afk-return.sh would clear its return gate as
# if nothing had happened.
test_killed_drain_batch_is_recovered() {
  local dir state queue pid count i
  dir=$(make_case killed-batch)
  state="$dir/state"
  printf 'done: killed batch fixture\n' > "$state/task.status"
  append_wake "$state" signal task.status "signal: task before the kill" || fail "wake append failed"

  SQUAD_STATE_OVERRIDE="$state" SQUAD_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=10 "$DRAIN" > "$dir/killed.out" &
  pid=$!
  queue="$state/.stand-to-queue"
  for ((i = 0; i < 200; i++)); do
    if [ -f "$queue" ] && [ ! -s "$queue" ] && compgen -G "$state/.stand-to-queue.drain.*" >/dev/null; then
      break
    fi
    sleep 0.05
  done
  [ "$i" -lt 200 ] \
    || { kill -KILL "$pid" 2>/dev/null || true; fail "the drain never rotated the batch and recreated the empty queue"; }
  kill -KILL "$pid" 2>/dev/null || fail "could not kill the drain before it published its raw output"
  wait "$pid" 2>/dev/null || true
  [ -f "$queue" ] && [ ! -s "$queue" ] \
    || fail "the killed drain did not leave a recreated empty queue"
  compgen -G "$state/.stand-to-queue.drain.*" >/dev/null \
    || fail "the killed drain left no in-flight batch to recover"

  mkdir -p "$dir/bin"
  {
    cat <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.stand-to-queue.drain.*)
    printf 'partial batch read\n'
    exit 1
    ;;
esac
SH
    printf "exec %q \"\$@\"\n" "$(command -v awk)"
  } > "$dir/bin/awk"
  chmod +x "$dir/bin/awk"
  append_wake "$state" signal task.status 'signal: task after the kill' || fail 'live wake append failed'
  cp "$queue" "$dir/live.expected" || fail 'could not snapshot the live queue'
  if SQUAD_STATE_OVERRIDE="$state" PATH="$dir/bin:$PATH" "$DRAIN" > "$dir/failed.out" 2> "$dir/failed.err"; then
    fail 'the drain reported success after failing to read the abandoned batch'
  fi
  [ ! -s "$dir/failed.out" ] || fail 'a failed read reported a wake as delivered'
  grep -Fq 'could not read drain batch' "$dir/failed.err" || fail 'the drain did not name the failed read'
  compgen -G "$state/.stand-to-queue.drain.*" >/dev/null || fail 'a failed read removed the abandoned batch'
  cmp -s "$queue" "$dir/live.expected" || fail 'a failed recovery read rotated the live queue'

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/recovered.out" 2> "$dir/recovered.err" \
    || fail "the drain after a killed batch failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$dir/recovered.out")
  [ "$count" -eq 2 ] || fail 'the retry did not deliver exactly two wakes'
  grep -F 'signal: task before the kill' "$dir/recovered.out" >/dev/null \
    || fail "the recovered wake lost its payload"
  grep -F 'signal: task after the kill' "$dir/recovered.out" >/dev/null \
    || fail 'the live wake lost its payload'
  compgen -G "$state/.stand-to-queue.drain.*" >/dev/null \
    && fail "the recovered batch was left in place for the next drain to replay"
  grep -F 'recovered 1 interrupted drain batch' "$dir/recovered.err" >/dev/null \
    || fail "the recovery was not reported"

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" || fail "the drain after recovery failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$dir/replay.out")
  [ "$count" -eq 0 ] || fail "a recovered batch was reported twice"
  pass 'a failed recovery read leaves the live queue untouched and a retry delivers both wakes once'
}

test_failed_rotation_preserves_only_populated_batches() {
  local dir state queue mode
  dir=$(make_case failed-rotation)
  state="$dir/state"
  queue="$state/.stand-to-queue"
  append_wake "$state" signal task.status 'signal: failed rotation fixture' || fail 'wake append failed'
  cp "$queue" "$dir/expected" || fail 'could not snapshot the live queue'
  {
    printf '#!/usr/bin/env bash\nreal_mv=%q\n' "$(command -v mv)"
    cat <<'SH'
case "$1:$2" in
  *.stand-to-queue:*.stand-to-queue.drain.*)
    if [ "$ROTATION_FAILURE" = after ]; then
      "$real_mv" "$@" || exit 2
    fi
    exit 1
    ;;
esac
exec "$real_mv" "$@"
SH
  } > "$dir/fakebin/mv"
  chmod +x "$dir/fakebin/mv"

  for mode in before before after; do
    if PATH="$dir/fakebin:$PATH" ROTATION_FAILURE="$mode" SQUAD_STATE_OVERRIDE="$state" \
      "$DRAIN" > "$dir/failed.out"; then
      fail "rotation failure ($mode move) was reported as success"
    fi
    [ ! -s "$dir/failed.out" ] || fail 'a failed rotation reported a wake as delivered'
    if [ "$mode" = before ]; then
      if compgen -G "$queue.drain.*" >/dev/null; then
        fail 'a failed move left an empty recovery reservation'
      fi
      cmp -s "$queue" "$dir/expected" || fail 'a failed move changed the live queue'
    else
      [ ! -e "$queue" ] || fail 'the move fault did not populate the recovery batch'
    fi
  done

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/retry.out" || fail 'rotation retry failed'
  cmp -s "$dir/retry.out" "$dir/expected" || fail 'the retry did not deliver the populated batch exactly once'
  pass 'failed rotation removes empty reservations and preserves a populated batch for retry'
}

test_queued_keys_survive_unreadable_batch() {
  local dir state unreadable
  dir=$(make_case queued-keys)
  state="$dir/state"
  unreadable="$state/.stand-to-queue.drain.00-unreadable"
  printf '1\t1\tcheck\tprocevent:hidden:1\tcheck: hidden\n' > "$unreadable"
  printf '1\t2\tcheck\tprocevent:batch:1\tcheck: recovered\n' > "$state/.stand-to-queue.drain.01-readable"
  printf '2\t3\tcheck\tprocevent:live:1\tcheck: live\n2\t4\tcheck\tprocevent:batch:1\tcheck: repeat\n' > "$state/.stand-to-queue"
  {
    cat <<'SH'
#!/usr/bin/env bash
for arg; do
  if [ "$arg" = "$UNREADABLE_BATCH" ]; then
    printf 'permission denied: %s\n' "$arg" >&2
    exit 2
  fi
done
SH
    printf "exec %q \"\$@\"\n" "$(command -v awk)"
  } > "$dir/fakebin/awk"
  chmod +x "$dir/fakebin/awk"

  PATH="$dir/fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" UNREADABLE_BATCH="$unreadable" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_queued_keys check
  ' _ "$ROOT/bin/sq-stand-to-lib.sh" > "$dir/keys" 2> "$dir/errors" || fail 'queued-key lookup failed'
  printf 'procevent:batch:1\nprocevent:live:1\n' > "$dir/expected"
  cmp -s "$dir/expected" "$dir/keys" || fail 'a failed read hid readable keys or broke ordering or deduplication'
  grep -Fq "$unreadable" "$dir/errors" || fail 'queued-key lookup did not name the failed input'
  pass 'queued-key lookup reports read errors and keeps readable keys'
}

test_concurrent_append_and_drain
test_signal_catchup_without_running_sentry
test_stale_enqueue_before_suppressor
test_not_working_stale_enqueue_before_suppressor
test_check_output_is_queued
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_drain_asserts_sentry_liveness
test_structural_signal_enrichment_preserves_raw_rows
test_enrichment_caps_and_status_file_failures
test_slow_annotation_does_not_block_append_and_deleted_file_fails_open
test_interruption_before_and_after_raw_commit
test_killed_drain_batch_is_recovered
test_failed_rotation_preserves_only_populated_batches
test_queued_keys_survive_unreadable_batch
