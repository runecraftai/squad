#!/usr/bin/env bash
# Writer-side contract for the append-only task status ledgers: the shared
# status_line_append path in bin/sq-classify-lib.sh, and a sibling programmatic
# closer that writes closing lines into the same ledgers - the remote-reply
# adapter's append_status_once (bin/sq-procevent-remote-reply.sh), driven
# through its real `ingest` command. The other sibling closers own their own
# suites: sq-send's resolve close in tests/sq-send-resolve-key.test.sh, the
# pending-reply close in tests/sq-pending-reply.test.sh, and the commander-held
# closers in tests/sq-decision-hold-lifecycle.test.sh.
#
# A ledger whose final record is unterminated must gain a separator newline
# before the next line, so the closing verb starts its own physical record and
# the fold can see the transition; an already-terminated ledger must keep its
# exact bytes. Assertions compare persisted ledger bytes and the real fold's
# open set (status_open_decisions) - never source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLASSIFY="$ROOT/bin/sq-classify-lib.sh"
ADAPTER="$ROOT/bin/sq-procevent-remote-reply.sh"
TMP_ROOT=$(fm_test_tmproot sq-status-line-append)

append_status_line() { # <status-file> <line> -> status_line_append's return code
  bash -c '. "$1"; status_line_append "$2" "$3"' _ "$CLASSIFY" "$1" "$2"
}

fold_open() { # <status-file>
  bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

test_append_separates_unterminated_record() {
  local dir f expected rc
  dir="$TMP_ROOT/unterminated"; mkdir -p "$dir"
  f="$dir/t1.status"
  printf 'blocked [key=api]: answer required' > "$f"
  assert_contains "$(fold_open "$f")" $'api\tblocked' \
    "precondition: the unterminated record should open a decision"
  append_status_line "$f" 'resolved [key=api]: answered: go'; rc=$?
  [ "$rc" -eq 0 ] || fail "append over an unterminated ledger should succeed, got rc=$rc"
  expected="$dir/expected.status"
  printf 'blocked [key=api]: answer required\nresolved [key=api]: answered: go\n' > "$expected"
  cmp -s "$expected" "$f" || fail "the closing line did not start its own physical line: $(cat "$f")"
  [ -z "$(fold_open "$f")" ] || fail "the decision stayed open after the separated close: $(fold_open "$f")"
  pass "shared append separates an unterminated final record"
}

test_append_preserves_terminated_ledger() {
  local dir f expected rc
  dir="$TMP_ROOT/terminated"; mkdir -p "$dir"
  f="$dir/t2.status"
  printf 'blocked [key=steady]: answer required\n' > "$f"
  append_status_line "$f" 'resolved [key=steady]: answered: ok'; rc=$?
  [ "$rc" -eq 0 ] || fail "append over a terminated ledger should succeed, got rc=$rc"
  expected="$dir/expected.status"
  printf 'blocked [key=steady]: answer required\nresolved [key=steady]: answered: ok\n' > "$expected"
  cmp -s "$expected" "$f" || fail "an already-terminated ledger changed bytes beyond the append: $(cat "$f")"
  [ -z "$(fold_open "$f")" ] || fail "the decision stayed open on a terminated ledger: $(fold_open "$f")"
  pass "shared append leaves a terminated ledger byte-identical apart from the appended line"
}

test_append_creates_missing_ledger() {
  local dir f rc
  dir="$TMP_ROOT/missing"; mkdir -p "$dir"
  f="$dir/t3.status"
  append_status_line "$f" 'working: started'; rc=$?
  [ "$rc" -eq 0 ] || fail "append to a missing ledger should succeed, got rc=$rc"
  [ "$(cat "$f")" = 'working: started' ] || fail "a new ledger was not one plain line: $(cat "$f")"
  append_status_line "$f" 'done: finished' || fail "second append should succeed"
  [ "$(cat "$f")" = $'working: started\ndone: finished' ] \
    || fail "appends to a fresh ledger introduced a blank line: $(cat "$f")"
  pass "shared append creates a missing ledger as plain consecutive records"
}

test_append_reports_separator_write_failure() {
  local dir f before rc
  dir="$TMP_ROOT/no-sep"; mkdir -p "$dir"
  f="$dir/t4.status"
  printf 'blocked [key=sep]: answer required' > "$f"
  before="$dir/before.status"
  cp "$f" "$before"
  chmod 444 "$f"
  append_status_line "$f" 'resolved [key=sep]: answered: ok'; rc=$?
  chmod 644 "$f"
  [ "$rc" -eq 1 ] || fail "a failed separator write should return 1, got rc=$rc"
  cmp -s "$before" "$f" || fail "a failed separator write still changed the ledger: $(cat "$f")"
  pass "shared append reports a failed separator write distinctly and writes nothing"
}

test_append_reports_line_write_failure() {
  local dir f before rc
  dir="$TMP_ROOT/no-line"; mkdir -p "$dir"
  f="$dir/t5.status"
  printf 'blocked [key=line]: answer required\n' > "$f"
  before="$dir/before.status"
  cp "$f" "$before"
  chmod 444 "$f"
  append_status_line "$f" 'resolved [key=line]: answered: ok'; rc=$?
  chmod 644 "$f"
  [ "$rc" -eq 2 ] || fail "a failed line write should return 2, got rc=$rc"
  cmp -s "$before" "$f" || fail "a failed line write still changed the ledger: $(cat "$f")"
  pass "shared append reports a failed line write distinctly and writes nothing"
}

# The adapter mirrors remote closing lines into the parent ledger through its
# own append_status_once wrapper. Feed the real `ingest` command a delta whose
# payload closes a decision while the parent ledger's final record is
# unterminated: the mirrored closing line must land on its own physical line
# and the fold must close, and a replayed generation must stay byte-stable.
test_adapter_ingest_separates_unterminated_parent_status() {
  local dir state f payload bytes p_hash e_hash result expected out
  dir="$TMP_ROOT/adapter"; mkdir -p "$dir/base"
  state="$dir/state"; mkdir -p "$state"
  f="$state/mirrorbus.status"
  printf 'blocked [key=mirror]: awaiting remote confirmation' > "$f"
  assert_contains "$(fold_open "$f")" $'mirror\tblocked' \
    "precondition: the unterminated parent record should open a decision"
  payload="$dir/payload"
  printf 'resolved [key=mirror]: confirmed over the wire\n' > "$payload"
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  p_hash=$(sha256_of "$payload")
  : > "$dir/empty"
  e_hash=$(sha256_of "$dir/empty")
  result="$dir/generation.result"
  {
    printf 'schema=sq-remote-delta.v1\n'
    printf 'status=delta\n'
    printf 'path=state/parent-replies.status\n'
    printf 'from_offset=0\n'
    printf 'to_offset=%s\n' "$bytes"
    printf 'from_prefix_sha256=%s\n' "$e_hash"
    printf 'to_prefix_sha256=%s\n' "$p_hash"
    printf 'payload_sha256=%s\n' "$p_hash"
    printf 'payload_bytes=%s\n' "$bytes"
    printf 'reason=\n\n'
    cat "$payload"
  } > "$result"

  out=$(env SQUAD_BASE="$dir/base" SQUAD_STATE_OVERRIDE="$state" \
    "$ADAPTER" ingest mirrorbus "$result") \
    || fail "adapter ingest over an unterminated parent status failed: $out"
  assert_contains "$out" "ingested: mirrorbus appended=1" \
    "the mirrored closing line should append exactly once"
  expected="$dir/expected.status"
  printf 'blocked [key=mirror]: awaiting remote confirmation\nresolved [key=mirror]: confirmed over the wire\n' \
    > "$expected"
  cmp -s "$expected" "$f" \
    || fail "the mirrored closing line folded into the unterminated record: $(cat "$f")"
  [ -z "$(fold_open "$f")" ] || fail "the mirrored close left the decision open: $(fold_open "$f")"

  out=$(env SQUAD_BASE="$dir/base" SQUAD_STATE_OVERRIDE="$state" \
    "$ADAPTER" ingest mirrorbus "$result") \
    || fail "replayed adapter ingest failed: $out"
  assert_contains "$out" "ingested: mirrorbus appended=0" "a replay must not append again"
  cmp -s "$expected" "$f" || fail "a replay changed the ledger bytes: $(cat "$f")"
  pass "remote-reply ingest separates an unterminated parent status record"
}

test_append_separates_unterminated_record
test_append_preserves_terminated_ledger
test_append_creates_missing_ledger
test_append_reports_separator_write_failure
test_append_reports_line_write_failure
test_adapter_ingest_separates_unterminated_parent_status
