#!/usr/bin/env bash
# Behavior tests for bin/sq-cost-lib.sh and bin/sq-cost.sh.
#
# Verifies transcript-derived cost estimation:
#   (a) pricing table resolves correctly for known model families
#   (b) cost calculation is accurate for known token splits
#   (c) Claude JSONL transcript parsing extracts token counts and model
#   (d) end-to-end: synthetic transcript → correct total cost
#   (e) directory scanning sums multiple transcripts
#   (f) graceful degradation: missing/empty transcript returns zero
#   (g) model normalization strips variant suffixes
#   (h) CLI commands work correctly
#   (i) shellcheck-clean
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COST_LIB="$ROOT/bin/sq-cost-lib.sh"
COST_CLI="$ROOT/bin/sq-cost.sh"
TMP_ROOT=$(fm_test_tmproot sq-cost)

# Source the library for direct function tests
# shellcheck disable=SC1090 # test source
. "$COST_LIB"

# ── Create synthetic JSONL fixture ─────────────────────────────────────────

FIXTURE_DIR="$TMP_ROOT/transcripts"
mkdir -p "$FIXTURE_DIR"

# Synthetic Claude transcript with known token counts
# Model: claude-sonnet-4-20250514
# Record 1: input=1000, output=500, cache_read=2000, cache_write=500
# Record 2: input=2000, output=800, cache_read=3000, cache_write=1000
cat > "$FIXTURE_DIR/session-001.jsonl" <<'FIXTURE'
{"type":"user","message":{"role":"user","content":"Hello"},"sessionId":"s1","cwd":"/tmp/test"}
{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":500,"cache_read_input_tokens":2000}},"sessionId":"s1"}
{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":2000,"output_tokens":800,"cache_creation_input_tokens":1000,"cache_read_input_tokens":3000}},"sessionId":"s1"}
FIXTURE

# Second transcript with a different model
cat > "$FIXTURE_DIR/session-002.jsonl" <<'FIXTURE'
{"type":"user","message":{"role":"user","content":"Test"},"sessionId":"s2","cwd":"/tmp/test"}
{"type":"assistant","message":{"role":"assistant","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":500,"output_tokens":200,"cache_creation_input_tokens":100,"cache_read_input_tokens":400}},"sessionId":"s2"}
FIXTURE

# Empty transcript (no assistant messages)
cat > "$FIXTURE_DIR/empty.jsonl" <<'FIXTURE'
{"type":"user","message":{"role":"user","content":"Hello"},"sessionId":"s3","cwd":"/tmp/test"}
FIXTURE

# ── (a) pricing table ─────────────────────────────────────────────────────

test_pricing_table() {
  local prices

  # Opus
  prices=$(sq_cost_price_for "claude-opus-4-20250514")
  local p_in p_out
  p_in=$(echo "$prices" | cut -d'|' -f1)
  p_out=$(echo "$prices" | cut -d'|' -f2)
  [ "$p_in" = "15" ] || fail "opus input price should be 15, got: $p_in"
  [ "$p_out" = "75" ] || fail "opus output price should be 75, got: $p_out"
  pass "opus pricing resolves correctly"

  # Sonnet
  prices=$(sq_cost_price_for "claude-sonnet-4-20250514")
  p_in=$(echo "$prices" | cut -d'|' -f1)
  p_out=$(echo "$prices" | cut -d'|' -f2)
  [ "$p_in" = "3" ] || fail "sonnet input price should be 3, got: $p_in"
  [ "$p_out" = "15" ] || fail "sonnet output price should be 15, got: $p_out"
  pass "sonnet pricing resolves correctly"

  # Haiku
  prices=$(sq_cost_price_for "claude-haiku-4-5-20251001")
  p_in=$(echo "$prices" | cut -d'|' -f1)
  p_out=$(echo "$prices" | cut -d'|' -f2)
  [ "$p_in" = "0.80" ] || fail "haiku input price should be 0.80, got: $p_in"
  [ "$p_out" = "4" ] || fail "haiku output price should be 4, got: $p_out"
  pass "haiku pricing resolves correctly"

  # GPT-4o
  prices=$(sq_cost_price_for "gpt-4o")
  p_in=$(echo "$prices" | cut -d'|' -f1)
  [ "$p_in" = "2.50" ] || fail "gpt-4o input price should be 2.50, got: $p_in"
  pass "gpt-4o pricing resolves correctly"

  # Unknown model defaults to Sonnet
  prices=$(sq_cost_price_for "some-unknown-model")
  p_in=$(echo "$prices" | cut -d'|' -f1)
  [ "$p_in" = "3" ] || fail "unknown model should default to sonnet (3), got: $p_in"
  pass "unknown model defaults to sonnet pricing"
}

test_pricing_table

# ── (b) cost calculation accuracy ─────────────────────────────────────────

test_cost_calculation() {
  local cost

  # Sonnet: 1M input + 1M output = $3 + $15 = $18
  cost=$(sq_cost_estimate "claude-sonnet-4" "1000000" "1000000" "0" "0")
  local expected="18.000000"
  [ "$cost" = "$expected" ] || fail "1M+1M sonnet should be \$18, got: $cost"
  pass "1M input + 1M output sonnet = \$18"

  # Haiku: 500K input + 200K output = $0.40 + $0.80 = $1.20
  cost=$(sq_cost_estimate "claude-haiku-4" "500000" "200000" "0" "0")
  # awk formatting: 0.4 + 0.8 = 1.2
  local cost_int
  cost_int=$(awk -v c="$cost" 'BEGIN { printf "%d", c * 100 }')
  [ "$cost_int" = "120" ] || fail "500K+200K haiku should be ~\$1.20, got: $cost"
  pass "500K input + 200K output haiku ≈ \$1.20"

  # With cache tokens
  cost=$(sq_cost_estimate "claude-sonnet-4" "100000" "50000" "200000" "100000")
  # Expected: 0.3 + 0.75 + 0.06 + 0.375 = 1.485
  local cost_rounded
  cost_rounded=$(awk -v c="$cost" 'BEGIN { printf "%.3f", c }')
  [ "$cost_rounded" = "1.485" ] || fail "cache tokens sonnet should be ~\$1.485, got: $cost"
  pass "cache tokens included in cost calculation"
}

test_cost_calculation

# ── (c) JSONL transcript parsing ──────────────────────────────────────────

test_transcript_parsing() {
  local parsed in out cr cw model

  parsed=$(sq_cost_parse_transcript "$FIXTURE_DIR/session-001.jsonl")
  in=$(echo "$parsed" | cut -d'|' -f1)
  out=$(echo "$parsed" | cut -d'|' -f2)
  cr=$(echo "$parsed" | cut -d'|' -f3)
  cw=$(echo "$parsed" | cut -d'|' -f4)
  model=$(echo "$parsed" | cut -d'|' -f5)

  # Expected: 1000+2000=3000 input, 500+800=1300 output, 2000+3000=5000 cache_read, 500+1000=1500 cache_write
  [ "$in" = "3000" ] || fail "session-001 input should be 3000, got: $in"
  [ "$out" = "1300" ] || fail "session-001 output should be 1300, got: $out"
  [ "$cr" = "5000" ] || fail "session-001 cache_read should be 5000, got: $cr"
  [ "$cw" = "1500" ] || fail "session-001 cache_write should be 1500, got: $cw"
  assert_contains "$model" "sonnet" "session-001 model contains sonnet"
  pass "JSONL transcript parsing extracts correct token counts"
}

test_transcript_parsing

# ── (d) end-to-end: synthetic transcript → cost ───────────────────────────

test_end_to_end() {
  local result in out cr cw model cost
  result=$(sq_cost_from_transcript "$FIXTURE_DIR/session-001.jsonl")

  in=$(echo "$result" | cut -d'|' -f1)
  out=$(echo "$result" | cut -d'|' -f2)
  cr=$(echo "$result" | cut -d'|' -f3)
  cw=$(echo "$result" | cut -d'|' -f4)
  model=$(echo "$result" | cut -d'|' -f5)
  cost=$(echo "$result" | cut -d'|' -f6)

  [ "$in" = "3000" ] || fail "e2e input should be 3000, got: $in"
  [ "$out" = "1300" ] || fail "e2e output should be 1300, got: $out"

  # Expected cost for Sonnet:
  # input:    3000/1M * $3   = $0.009
  # output:   1300/1M * $15  = $0.0195
  # cache_r:  5000/1M * $0.3 = $0.0015
  # cache_w:  1500/1M * $3.75 = $0.005625
  # Total:    $0.035625
  local cost_check
  cost_check=$(awk -v c="$cost" 'BEGIN { printf "%.6f", c }')
  [ "$cost_check" = "0.035625" ] || fail "e2e cost should be 0.035625, got: $cost_check"
  pass "end-to-end: synthetic transcript → correct cost"
}

test_end_to_end

# ── (e) directory scanning ────────────────────────────────────────────────

test_dir_scanning() {
  local result total_in total_out total_cost
  result=$(sq_cost_scan_dir "$FIXTURE_DIR")

  total_in=$(echo "$result" | cut -d'|' -f1)
  total_out=$(echo "$result" | cut -d'|' -f2)
  local total_cost
  total_cost=$(echo "$result" | cut -d'|' -f6)

  # session-001: 3000 in, 1300 out
  # session-002: 500 in, 200 out (haiku)
  # empty: 0 in, 0 out
  # Total: 3500 in, 1500 out
  [ "$total_in" = "3500" ] || fail "dir scan input should be 3500, got: $total_in"
  [ "$total_out" = "1500" ] || fail "dir scan output should be 1500, got: $total_out"

  # Cost should be > 0 (combined sonnet + haiku)
  local cost_gt_zero
  cost_gt_zero=$(awk -v c="$total_cost" 'BEGIN { print (c > 0) ? 1 : 0 }')
  [ "$cost_gt_zero" = "1" ] || fail "dir scan cost should be > 0, got: $total_cost"
  pass "directory scanning sums multiple transcripts"
}

test_dir_scanning

# ── (f) graceful degradation ─────────────────────────────────────────────

test_missing_transcript() {
  local result
  result=$(sq_cost_parse_transcript "/nonexistent/path.jsonl")
  local in
  in=$(echo "$result" | cut -d'|' -f1)
  [ "$in" = "0" ] || fail "missing transcript should return 0, got: $in"
  pass "missing transcript returns zero gracefully"

  result=$(sq_cost_from_transcript "$FIXTURE_DIR/empty.jsonl")
  local cost
  cost=$(echo "$result" | cut -d'|' -f6)
  # Empty transcript (no assistant messages) should have 0 cost
  local cost_zero
  cost_zero=$(awk -v c="$cost" 'BEGIN { print (c == 0) ? 1 : 0 }')
  [ "$cost_zero" = "1" ] || fail "empty transcript cost should be 0, got: $cost"
  pass "empty transcript (no assistant messages) returns zero cost"

  # Missing directory
  result=$(sq_cost_scan_dir "/nonexistent/dir")
  in=$(echo "$result" | cut -d'|' -f1)
  [ "$in" = "0" ] || fail "missing directory should return 0, got: $in"
  pass "missing directory returns zero gracefully"
}

test_missing_transcript

# ── (f2) graceful degradation: no-meta task lookup ────────────────────────

test_no_meta_task() {
  # sq-cost.sh task <id> with no state/<id>.meta must exit 0 and print
  # the documented [estimate] fallback line instead of dying under
  # set -euo pipefail.
  local output rc
  local fake_state="$TMP_ROOT/no-meta-state"
  mkdir -p "$fake_state"
  output=$(SQUAD_STATE_OVERRIDE="$fake_state" "$COST_CLI" task nonexistent-task 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "no-meta task should exit 0, got: $rc"
  assert_contains "$output" "[estimate]" "no-meta task prints [estimate] label"
  assert_contains "$output" "0|0|0|0|" "no-meta task prints zero token counts"
  pass "no-meta task cost lookup returns estimate line gracefully"

  # CLI transcript with missing file must not crash
  output=$("$COST_CLI" transcript /nonexistent/bad.jsonl 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "transcript on missing file should exit 0, got: $rc"
  pass "transcript on missing file returns gracefully"

  # CLI dir with missing directory must not crash
  output=$("$COST_CLI" dir /nonexistent/bad-dir 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "dir on missing directory should exit 0, got: $rc"
  pass "dir on missing directory returns gracefully"
}

test_no_meta_task

# ── (g) model normalization ───────────────────────────────────────────────

test_model_normalization() {
  local norm

  norm=$(sq_cost_normalize_model "claude-sonnet-4-20250514")
  assert_contains "$norm" "claude-sonnet" "normalization preserves base model"

  norm=$(sq_cost_normalize_model "claude-opus-4-8[1m]")
  assert_contains "$norm" "claude-opus" "normalization strips [bracket] suffix"

  norm=$(sq_cost_normalize_model "  claude-haiku-4  ")
  assert_contains "$norm" "claude-haiku" "normalization trims whitespace"

  pass "model normalization works correctly"
}

test_model_normalization

# ── (h) CLI commands ──────────────────────────────────────────────────────

test_cli_transcript() {
  local output
  output=$("$COST_CLI" transcript "$FIXTURE_DIR/session-001.jsonl")
  assert_contains "$output" "3000" "CLI transcript returns correct input tokens"
  assert_contains "$output" "1300" "CLI transcript returns correct output tokens"
  pass "CLI transcript command works"
}

test_cli_estimate() {
  local output
  output=$("$COST_CLI" estimate "claude-sonnet-4" "1000000" "1000000")
  assert_contains "$output" "18.000000" "CLI estimate returns correct cost"
  pass "CLI estimate command works"
}

test_cli_dir() {
  local output
  output=$("$COST_CLI" dir "$FIXTURE_DIR")
  assert_contains "$output" "3500" "CLI dir returns correct total input"
  pass "CLI dir command works"
}

test_cli_price() {
  local output
  output=$("$COST_CLI" price "claude-opus-4")
  assert_contains "$output" "\$15" "CLI price shows input price"
  pass "CLI price command works"
}

test_cli_pricing_table() {
  local output
  output=$("$COST_CLI" pricing-table)
  assert_contains "$output" "claude-opus" "pricing table includes opus"
  assert_contains "$output" "claude-sonnet" "pricing table includes sonnet"
  assert_contains "$output" "gpt-4o" "pricing table includes gpt-4o"
  pass "CLI pricing-table command works"
}

test_cli_transcript
test_cli_estimate
test_cli_dir
test_cli_price
test_cli_pricing_table

# ── (i) shellcheck-clean ──────────────────────────────────────────────────

test_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --norc "$COST_LIB" || fail "shellcheck failed on sq-cost-lib.sh"
    shellcheck --norc "$COST_CLI" || fail "shellcheck failed on sq-cost.sh"
    pass "shellcheck passes on cost scripts"
  else
    pass "shellcheck not available (skipped)"
  fi
}

test_shellcheck
