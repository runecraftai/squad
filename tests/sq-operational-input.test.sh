#!/usr/bin/env bash
# Canonical current and isolated legacy operational-input protocol matrices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/sq-operational-input.sh"
# shellcheck source=/dev/null
. "$OWNER"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

test_current_generic_matrix() {
  local kind body encoded parsed stripped prefix_hex
  prefix_hex=$(printf '%s' "$SQUAD_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a353515541445f4f503a20 ] \
    || fail "current operational prefix lost the landed U+2063 SQUAD_OP bytes: $prefix_hex"

  for kind in session-start sentry turn-end-guard away-supervisor launch-brief handoff-request; do
    body="CURRENT_BODY_FOR_${kind}"
    fm_operational_input_encode "$kind" "$body" encoded \
      || fail "could not encode current $kind fixture"
    fm_operational_input_kind "$encoded" parsed \
      || fail "could not parse current $kind fixture"
    [ "$parsed" = "$kind" ] \
      || fail "current $kind fixture became $parsed"
    [ "$(kind_cli "$encoded")" = "$kind" ] \
      || fail "cross-language CLI lost current $kind"
    [ "$(classify_cli "$encoded")" = "$kind" ] \
      || fail "classifier lost current $kind"
    fm_operational_input_body "$encoded" stripped \
      || fail "could not recover current $kind body"
    [ "$stripped" = "$body" ] \
      || fail "current $kind body changed during encode/parse"
  done
  pass "operational input: every current generic envelope retains its exact structured kind"
}

test_current_from_Squad_carrier() {
  local encoded parsed separator
  separator=$(printf '\342\201\243')
  fm_message_mark_from_Squad "corr=0123456789abcdef inspect the report" encoded
  [ "${encoded#"[sq-from-squad]$separator"}" != "$encoded" ] \
    || fail "from-squad lost its live-charter-compatible leading carrier"
  fm_operational_input_kind "$encoded" parsed \
    || fail "from-squad current carrier did not parse"
  [ "$parsed" = from-squad ] \
    || fail "from-squad current carrier became $parsed"
  [ "$(classify_cli "$encoded")" = from-squad ] \
    || fail "cross-language classifier lost from-squad"
  pass "operational input: the established from-squad carrier remains structurally typed and byte-compatible"
}

test_landed_untyped_prefix_is_explicitly_legacy() {
  local untyped parsed
  untyped="${SQUAD_OPERATIONAL_PREFIX}body whose historical subtype is unknowable"
  fm_legacy_operational_input_kind "$untyped" parsed \
    || fail "landed untyped SQUAD_OP input was not retained"
  [ "$parsed" = legacy-operational ] \
    || fail "landed untyped SQUAD_OP input falsely became $parsed"
  ! fm_operational_input_kind "$untyped" parsed \
    || fail "untyped SQUAD_OP input passed the current typed parser"
  [ "$(classify_cli "$untyped")" = legacy-operational ] \
    || fail "CLI did not expose the untyped prefix as legacy-operational"
  pass "operational input: untyped landed SQUAD_OP transcripts are explicit legacy-operational input"
}

test_isolated_legacy_matrix() {
  local sentry turnend away parsed
  sentry="${SQUAD_LEGACY_WATCHER_PREFIX}signal: legacy${SQUAD_LEGACY_WATCHER_SUFFIX}"
  turnend="${SQUAD_LEGACY_TURNEND_PREFIX}sentry: FAILED - legacy"
  away="${SQUAD_LEGACY_AWAY_PREFIX}1 event(s)): done: legacy"

  for fixture in \
    "session-start|$SQUAD_LEGACY_SESSIONSTART" \
    "sentry|$sentry" \
    "turn-end-guard|$turnend" \
    "away-supervisor|$away"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture leaked into the current parser"
    fm_legacy_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture was not recognized"
    [ "$parsed" = "$expected" ] \
      || fail "legacy $expected fixture became $parsed"
  done
  pass "operational input: historical prose compatibility is isolated from current parsing"
}

test_genuine_near_misses_remain_unclassified() {
  local marker fixture parsed
  marker=$SQUAD_OPERATIONAL_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_operational_input_classify "$fixture" parsed \
      || fail "genuine near miss was classified as $parsed: $fixture"
    [ -z "$(classify_cli "$fixture" || true)" ] \
      || fail "CLI classified a genuine near miss: $fixture"
  done <<EOF
Commander quote: ${SQUAD_OPERATIONAL_PREFIX}v1 sentry
SQUAD_OP: v1 sentry
$marker arbitrary commander text
Commander quote: $SQUAD_LEGACY_SESSIONSTART
${SQUAD_LEGACY_SESSIONSTART} Please explain this sentence.
SQUAD WATCHER WAKE: can you explain this phrase?
TURN WOULD END BLIND - can you make this warning friendlier?
Supervisor escalate (1 event(s)): is this wording clear?
[sq-from-squad] inspect this visible label
EOF
  pass "operational input: quoted, ASCII-only, arbitrary-U+2063, altered-legacy, and label-only near misses stay genuine"
}

test_cross_language_adapter_uses_the_owner() {
  local encoded parsed
  encoded=$(SQUAD_TEST_ROOT="$ROOT" HELPER="$ROOT/.opencode/plugins/lib/sq-operational-input.js" \
    node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const { encodeSquadOperationalInput } = await import(pathToFileURL(process.env.HELPER).href);
process.stdout.write(await encodeSquadOperationalInput(process.env.SQUAD_TEST_ROOT, "sentry", "CROSS_LANGUAGE_BODY"));
JS
  ) || fail "OpenCode cross-language adapter could not invoke the canonical owner"
  fm_operational_input_kind "$encoded" parsed \
    || fail "OpenCode cross-language adapter returned an invalid current envelope"
  [ "$parsed" = sentry ] \
    || fail "OpenCode cross-language adapter changed sentry to $parsed"
  pass "operational input: the OpenCode adapter constructs through the canonical owner"
}

test_invalid_current_encodings_are_rejected() {
  local output
  output=$(printf 'body' | "$OWNER" encode legacy-operational 2>/dev/null) \
    && fail "legacy-operational was accepted as a current producer kind"
  [ -z "$output" ] || fail "invalid current kind printed protocol data"
  output=$(printf '' | "$OWNER" encode sentry 2>/dev/null) \
    && fail "empty current operational body was accepted"
  [ -z "$output" ] || fail "empty current body printed protocol data"
  pass "operational input: current construction rejects legacy kinds and empty bodies"
}

test_current_generic_matrix
test_current_from_Squad_carrier
test_landed_untyped_prefix_is_explicitly_legacy
test_isolated_legacy_matrix
test_genuine_near_misses_remain_unclassified
test_cross_language_adapter_uses_the_owner
test_invalid_current_encodings_are_rejected
