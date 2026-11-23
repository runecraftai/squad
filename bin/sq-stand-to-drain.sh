#!/usr/bin/env bash
# Atomically drain durable sentry wake records, optionally annotate validated
# signal status keys after raw consumption commits, then assert liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-stand-to-lib.sh
. "$SCRIPT_DIR/sq-stand-to-lib.sh"
# shellcheck source=bin/sq-classify-lib.sh
. "$SCRIPT_DIR/sq-classify-lib.sh"
# shellcheck source=bin/sq-line-cap-lib.sh
. "$SCRIPT_DIR/sq-line-cap-lib.sh"

DRAIN_LOCK_HELD=false
RAW_ROWS=
DRAIN_BATCHES=()

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert supervision health here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (sq-peek/sq-send/...) happens to run.
# Reuse sq-guard.sh's model-aware alarm and SQUAD_GUARD_GRACE instead of duplicating
# its supervision verdict. Under Claude's between-turns auto-arm model, a normal
# fire leaves a recent beacon well inside grace and stays silent mid-turn. Under
# persistent-sentry models, the guard also requires the live identity-matched
# sentry. Call after the queue is emptied so guard never re-prints its own
# queued-wakes notice for the records this run just drained, and never let a
# guard hiccup change the drain's exit status.
assert_sentry_liveness() {
  "$SCRIPT_DIR/sq-guard.sh" || true
}

# Print the consolidated OPEN DECISIONS section: every still-open
# needs-decision/blocked, unit-wide, folded from the durable status logs by
# sq-classify-lib.sh's status_open_decisions fold (via its cursor-backed
# scan_open_decisions_incremental wrapper) rather than from the latest-line
# annotations above, so a decision buried under later unrelated appends cannot
# be silently missed. Runs on every drain - including the empty-queue fast path
# - because the decision can still be open even when nothing new is queued for
# its task this turn. The incremental wrapper bounds this scan's cost to bytes
# appended to each task's status log since the LAST drain, not that log's whole
# lifetime, while still never dropping an old buried decision (see
# sq-classify-lib.sh's "incremental (cursor-backed) open-decisions fold").
# Bounded and silent: prints nothing when no decision is open, which is the
# common case.
print_open_decisions_section() {
  local open task key verb note line item_bytes=220 global_bytes=4000
  local output='' used=0 shown=0 omitted=0 bytes

  open=$(scan_open_decisions_incremental "$STATE") || return 0
  [ -n "$open" ] || return 0

  while IFS=$(printf '\t') read -r task key verb note; do
    [ -n "$task" ] || continue
    line="$task"
    [ "$key" = default ] || line="$line [key=$key]"
    line="$line $verb: $note"
    # The shared cut counts the item's own characters; the trailing newline this
    # section's global budget also pays for is this caller's, so the per-item
    # allowance passed down is one short of the cap.
    fm_cap_line_var "$line" $((item_bytes - 1))
    line=$SQUAD_LINE_CAP_LINE
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$open
EOF

  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    printf 'OPEN DECISIONS: %d more omitted (byte cap)\n' "$omitted"
  fi
  # Answerer-closes hint, printed at exactly the moment an answer gets written:
  # the send that answers a listed decision also closes it, so closure never
  # depends on the busy worker writing a matching resolved line (contract:
  # bin/sq-send.sh header).
  printf "OPEN DECISIONS: close one by answering it: bin/sq-send.sh <task> --resolve-key <key> '<answer>'\n"
}

# Read one key from a state/<id>.meta file (same simple key=value reading the
# rest of Squad uses; the meta file's schema is owned by bin/sq-spawn.sh).
_drain_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^${key}=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Print the consolidated TEARDOWN PENDING section: every task whose LATEST
# status-log line verifies done:/failed: but whose state/<id>.meta still exists
# - exactly the pre-teardown state, since bin/sq-teardown.sh removes the meta.
# This is a pure reminder: it never runs teardown, because sq-teardown.sh owns
# the landed-work safety check (AGENTS.md hard rule 3) and skipping it would be
# unsafe. Runs on every drain - including the empty-queue fast path - so a
# finished-but-live task cannot slip through on operator memory. kind=xo tasks
# are excluded: XOs retire through xo-provisioning, never sq-teardown.sh.
# Bounded and silent: prints nothing when no task matches, which is the common
# case.
print_teardown_pending_section() {
  local meta id status_file status_line verb note line output='' used=0 shown=0 omitted=0 bytes
  local item_bytes=220 global_bytes=4000

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ ! -L "$meta" ] || continue
    id=$(basename "$meta"); id=${id%.meta}
    [ "$(_drain_meta_get "$meta" kind)" = xo ] && continue
    status_file="$STATE/$id.status"
    [ -f "$status_file" ] && [ ! -L "$status_file" ] && [ -s "$status_file" ] || continue
    status_line=$(LC_ALL=C command tail -n 1 "$status_file" 2>/dev/null) || continue
    [ -n "$status_line" ] || continue
    verb=$(status_line_verb "$status_line")
    case "$verb" in
      done|failed) ;;
      *) continue ;;
    esac
    note=$(status_line_note "$status_line")
    line="$id: $verb: $note"
    # The shared cut counts the item's own characters; the trailing newline this
    # section's global budget also pays for is this caller's, so the per-item
    # allowance passed down is one short of the cap.
    fm_cap_line_var "$line" $((item_bytes - 1))
    line=$SQUAD_LINE_CAP_LINE
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done

  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf 'TEARDOWN PENDING (reported done/failed but bin/sq-teardown.sh has not run - still live in state/*.meta and the sidebar):\n'
  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    printf 'TEARDOWN PENDING: %d more omitted (byte cap)\n' "$omitted"
  fi
  # Clear hint, printed at exactly the moment a finished task is surfaced. The
  # drain only reminds; the landed-work check in bin/sq-teardown.sh stays the
  # authority on whether the recorded work is actually safe to clean up.
  printf "TEARDOWN PENDING: clear one once its work is confirmed landed: bin/sq-teardown.sh <id>\n"
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$SQUAD_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${SQUAD_WAKE_DRAIN_LOCK_SECS:-}" ]; then
  fm_lock_acquire_wait_bounded "$SQUAD_WAKE_QUEUE_LOCK" "$SQUAD_WAKE_DRAIN_LOCK_SECS" || exit 3
else
  fm_lock_acquire_wait "$SQUAD_WAKE_QUEUE_LOCK"
fi
DRAIN_LOCK_HELD=true

recovered=0
for batch in "$SQUAD_WAKE_BATCH_PREFIX"*; do
  [ -e "$batch" ] || [ -L "$batch" ] || continue
  DRAIN_BATCHES+=("$batch")
  recovered=$((recovered + 1))
done

read_drain_batch() {
  local batch=$1
  if [ ! -f "$batch" ] || [ -L "$batch" ] || ! fm_wake_print_deduped "$batch"; then
    printf 'sq-stand-to-drain: could not read drain batch %s; leaving batches in place for retry\n' "$batch" >&2
    return 1
  fi
}

if [ "$recovered" -gt 0 ]; then
  RAW_ROWS=$(
    for batch in "${DRAIN_BATCHES[@]}"; do
      read_drain_batch "$batch" || exit 1
    done
  ) || exit 1
fi

live_batch=
if [ -s "$SQUAD_WAKE_QUEUE" ]; then
  live_batch=$(mktemp "${SQUAD_WAKE_BATCH_PREFIX}XXXXXX") || exit 1
  mv "$SQUAD_WAKE_QUEUE" "$live_batch" || exit 1
  DRAIN_BATCHES+=("$live_batch")
fi
: > "$SQUAD_WAKE_QUEUE" || exit 1

if [ -n "$live_batch" ]; then
  live_rows=$(read_drain_batch "$live_batch") || exit 1
  if [ -n "$live_rows" ]; then
    RAW_ROWS=${RAW_ROWS:+$RAW_ROWS$'\n'}$live_rows
  fi
fi
if [ -n "$RAW_ROWS" ]; then
  case "${SQUAD_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$SQUAD_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
  esac
  # Print-before-delete is the deliberate at-least-once no-loss boundary: a
  # crash in this micro-gap may replay a wake, and annotations stay outside it.
  if [ -n "${SQUAD_WAKE_DRAIN_CHECKPOINT:-}" ]; then
    printf '%s\n' "$RAW_ROWS" > "${SQUAD_WAKE_DRAIN_CHECKPOINT}.pending" &&
      mv "${SQUAD_WAKE_DRAIN_CHECKPOINT}.pending" "$SQUAD_WAKE_DRAIN_CHECKPOINT" || exit 1
  else
    printf '%s\n' "$RAW_ROWS" || exit "$?"
  fi
fi
if [ -n "${DRAIN_BATCHES[0]:-}" ]; then
  rm -f -- "${DRAIN_BATCHES[@]}" || exit 1
fi
fm_lock_release "$SQUAD_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false
if [ "$recovered" -gt 0 ]; then
  printf 'sq-stand-to-drain: recovered %s interrupted drain batch(es)\n' "$recovered" >&2
fi

# Raw output and queue deletion are authoritative. Everything below is
# best-effort and cannot restore, duplicate, hide, or fail the consumed rows.
[ -z "$RAW_ROWS" ] || (fm_wake_print_annotations "$RAW_ROWS") || true
(print_open_decisions_section) || true
(print_teardown_pending_section) || true
assert_sentry_liveness
exit 0
