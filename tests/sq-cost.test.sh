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

write_exec_window() {
  local state=$1 id=$2 workspace=$3 start=$4 end=$5
  printf 'exec_state=released\nexec_started_at=%s\nexec_last_activity=%s\nexec_workspace=%s\n' \
    "$start" "$end" "$workspace" > "$state/$id.exec"
}

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

# ── (h2) Pi task discovery and exact attribution ───────────────────────────

test_pi_task_report() {
  local pi_root="$TMP_ROOT/pi-sessions" pi_dir="$TMP_ROOT/pi-sessions/fixture" state="$TMP_ROOT/pi-state" wt="$TMP_ROOT/pi-worktree"
  mkdir -p "$pi_dir" "$state"
  printf 'window=sq:pi-test\nharness=pi\nworktree=%s\nproject=test\nmodel=default\n' "$wt" > "$state/pi-task.meta"
  write_exec_window "$state" pi-task "$wt" 1767225600 1767484800
  cat > "$pi_dir/matched.jsonl" <<EOF
{"type":"session","version":3,"id":"pi-session-1","timestamp":"2026-01-01T00:00:00Z","cwd":"$wt"}
{"type":"model_change","provider":"anthropic","modelId":"claude-sonnet-4"}
{"type":"message","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input":2600000000,"output":53,"cacheRead":7,"cacheWrite":2,"totalTokens":2600000062,"cost":{"total":0.02}}}}
EOF
  cat > "$pi_dir/wrong-worktree.jsonl" <<EOF
{"type":"session","version":3,"id":"other-task","timestamp":"2026-01-01T00:00:00Z","cwd":"$TMP_ROOT/other"}
{"type":"model_change","provider":"anthropic","modelId":"claude-opus-4"}
{"type":"message","message":{"role":"assistant","model":"claude-opus-4","usage":{"input":9999,"output":9999,"totalTokens":19998,"cost":{"total":9}}}}
EOF
  cat > "$pi_dir/reused-slot.jsonl" <<EOF
{"type":"session","version":3,"id":"previous-mission","timestamp":"2025-12-31T23:59:59Z","cwd":"$wt"}
{"type":"model_change","provider":"openai-codex","modelId":"gpt-6-astra"}
{"type":"message","message":{"role":"assistant","model":"gpt-6-astra","usage":{"input":8888,"output":7777,"totalTokens":16665,"cost":{"total":12.59}}}}
EOF
  local output
  output=$(SQUAD_STATE_OVERRIDE="$state" SQUAD_PI_SESSION_DIR="$pi_root" "$COST_CLI" report pi-task --json)
  assert_contains "$output" '"input": 2600000000' "Pi report finds matching worktree session"
  assert_contains "$output" '"sessions": 1' "Pi report counts one matching session"
  assert_contains "$output" '"reported_cost": 0.02' "Pi report preserves provider cost"
  if printf '%s' "$output" | grep -q '9999'; then fail "Pi report counted another worktree"; fi
  if printf '%s' "$output" | grep -q 'gpt-6-astra\|8888\|12.59'; then
    fail "Pi report counted a prior mission from the reused worktree slot"
  fi
  cat > "$pi_dir/subscription.jsonl" <<EOF
{"type":"session","version":3,"id":"pi-session-2","timestamp":"2026-01-02T00:00:00Z","cwd":"$wt"}
{"type":"model_change","provider":"opencode-go","modelId":"opencode-go"}
{"type":"message","message":{"role":"assistant","model":"opencode-go","usage":{"input":10,"output":5,"totalTokens":15}}}
EOF
  output=$(SQUAD_STATE_OVERRIDE="$state" SQUAD_PI_SESSION_DIR="$pi_root" "$COST_CLI" report pi-task)
  assert_contains "$output" "2.6 billion" "large token counts are humanized"
  assert_contains "$output" "Pi" "Pi harness is rendered as a product label"
  assert_contains "$output" "flat-rate subscription" "flat-rate providers are labelled without fabricated spend"
  pass "Pi task report attributes sessions exactly and avoids zero-result regression"
}

test_pi_task_report

# ── (h2b) Pi execution-window requirement ─────────────────────────────────

test_pi_requires_execution_window() {
  local state="$TMP_ROOT/no-exec-state" pi_root="$TMP_ROOT/no-exec-pi" wt="$TMP_ROOT/no-exec-worktree"
  mkdir -p "$state" "$pi_root/fixture" "$wt"
  printf 'window=sq:no-exec\nharness=pi\nworktree=%s\nmodel=default\n' "$wt" > "$state/no-exec.meta"
  cat > "$pi_root/fixture/session.jsonl" <<EOF
{"type":"session","version":3,"id":"no-exec-session","timestamp":"2026-01-01T00:00:00Z","cwd":"$wt"}
{"type":"model_change","provider":"anthropic","modelId":"claude-sonnet-4"}
{"type":"message","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input":100,"output":50,"totalTokens":150}}}
EOF
  local output
  output=$(SQUAD_STATE_OVERRIDE="$state" SQUAD_PI_SESSION_DIR="$pi_root" \
    "$COST_CLI" report no-exec --json)
  assert_contains "$output" '"found":false' "Pi report refuses path-only attribution without an execution window"
  assert_contains "$output" 'execution window is unavailable' "missing execution window explains unavailable attribution"
  pass "Pi task report requires the recorded execution window"
}

test_pi_requires_execution_window

# ── (h3) client-visible publish guard ──────────────────────────────────────

test_publish_guard() {
  local state="$TMP_ROOT/guard-state" data="$TMP_ROOT/guard-data"
  mkdir -p "$state" "$data"
  local pi_root="$TMP_ROOT/guard-pi" pi_dir="$TMP_ROOT/guard-pi/fixture"
  mkdir -p "$pi_dir"
  local wt="$TMP_ROOT/guard-worktree"
  mkdir -p "$wt"
  printf 'window=sq:guard-test\nharness=pi\nworktree=%s\nproject=globo\nmodel=default\n' "$wt" > "$state/guard-task.meta"
  write_exec_window "$state" guard-task "$wt" 1767225600 1767484800
  cat > "${data}/projects.md" <<'REG'
- globo [local-only] - Globo Backstage workspace; REGRA: MRs visiveis ao cliente (added 2026-01-01)
- alpha [drill +cost-report] - Alpha project (added 2026-01-01)
REG
  # Pi session fixture for report generation
  cat > "$pi_dir/guard.jsonl" <<EOF
{"type":"session","version":3,"id":"g1","timestamp":"2026-01-01T00:00:00Z","cwd":"$wt"}
{"type":"model_change","provider":"anthropic","modelId":"claude-sonnet-4"}
{"type":"message","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"total":0.01}}}}
EOF
  # Verify guard blocks publish for globo (client-visible, no +cost-report)
  local output rc
  output=$(SQUAD_STATE_OVERRIDE="$state" SQUAD_DATA_OVERRIDE="$data" \
           SQUAD_PI_SESSION_DIR="$pi_root" \
           "$COST_CLI" publish guard-task "https://github.com/org/repo/pull/1" 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "blocked publish should exit 0, got: $rc"
  assert_contains "$output" "not published: client-visible project policy" "guard blocks publish for client-visible project"
  # Verify guard allows publish for alpha (+cost-report opt-in)
  printf 'window=sq:alpha-test\nharness=pi\nworktree=%s\nproject=alpha\nmodel=default\n' "$wt" > "$state/alpha-task.meta"
  write_exec_window "$state" alpha-task "$wt" 1767225600 1767484800
  cat > "$pi_dir/alpha.jsonl" <<EOF
{"type":"session","version":3,"id":"a1","timestamp":"2026-01-01T00:00:00Z","cwd":"$wt"}
{"type":"model_change","provider":"anthropic","modelId":"claude-sonnet-4"}
{"type":"message","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input":200,"output":100,"cacheRead":0,"cacheWrite":0,"totalTokens":300,"cost":{"total":0.02}}}}
EOF
  # Mock sq-gh to simulate no existing comment and successful post
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/guard-fake")
  cat > "$fakebin/sq-gh" <<'SH'
#!/usr/bin/env bash
# sq-gh stub: simulate no existing comment, accept new comment creation
exit 0
SH
  chmod +x "$fakebin/sq-gh"
  output=$(PATH="$fakebin:$PATH" \
           SQUAD_STATE_OVERRIDE="$state" SQUAD_DATA_OVERRIDE="$data" \
           SQUAD_PI_SESSION_DIR="$pi_root" \
           "$COST_CLI" publish alpha-task "https://github.com/org/repo/pull/1" 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "opt-in publish should exit 0, got: $rc"
  assert_not_contains "$output" "not published" "guard allows publish for opted-in project"
  # Verify empty project skips guard entirely
  printf 'window=sq:empty-proj\nharness=pi\nworktree=%s\nmodel=default\n' "$wt" > "$state/empty-proj.meta"
  write_exec_window "$state" empty-proj "$wt" 1767225600 1767484800
  cat > "$pi_dir/empty-proj.jsonl" <<EOF
{"type":"session","version":3,"id":"e1","timestamp":"2026-01-01T00:00:00Z","cwd":"$wt"}
{"type":"model_change","provider":"anthropic","modelId":"claude-sonnet-4"}
{"type":"message","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75,"cost":{"total":0.005}}}}
EOF
  output=$(PATH="$fakebin:$PATH" \
           SQUAD_STATE_OVERRIDE="$state" SQUAD_DATA_OVERRIDE="$data" \
           SQUAD_PI_SESSION_DIR="$pi_root" \
           "$COST_CLI" publish empty-proj "https://github.com/org/repo/pull/2" 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "empty-project publish should exit 0, got: $rc"
  assert_not_contains "$output" "not published" "empty project skips guard and publishes"
  pass "client-visible publish guard blocks, opts in, and skips for empty project"
}

test_publish_guard

# ── (h4) idempotent publish (marked-comment update) ────────────────────────

test_publish_idempotent() {
  local state="$TMP_ROOT/idemp-state" data="$TMP_ROOT/idemp-data" fakebin
  mkdir -p "$state" "$data"
  local pi_root="$TMP_ROOT/idemp-pi" pi_dir="$TMP_ROOT/idemp-pi/fixture"
  mkdir -p "$pi_dir"
  local wt="$TMP_ROOT/idemp-worktree"
  mkdir -p "$wt"
  printf 'window=sq:idemp-test\nharness=pi\nworktree=%s\nproject=test-proj\nmodel=default\n' "$wt" > "$state/idemp-task.meta"
  write_exec_window "$state" idemp-task "$wt" 1767225600 1767484800
  cat > "$pi_dir/idemp.jsonl" <<EOF
{"type":"session","version":3,"id":"i1","timestamp":"2026-01-01T00:00:00Z","cwd":"$wt"}
{"type":"model_change","provider":"anthropic","modelId":"claude-sonnet-4"}
{"type":"message","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"total":0.01}}}}
EOF
  fakebin=$(fm_fakebin "$TMP_ROOT/idemp-fake")
  local different_checkout="$TMP_ROOT/idemp-other-checkout"
  mkdir -p "$different_checkout"
  git -C "$different_checkout" init -q
  git -C "$different_checkout" remote add origin https://github.com/wrong/current-repository.git
  local invocations_file="$TMP_ROOT/idemp-invocations"
  printf '' > "$invocations_file"
  # Mock sq-gh: first api call returns an existing comment with the marker,
  # second api call (PATCH) returns nothing to signal update was processed.
  # pr comment (create) also exits 0 but should not be reached on re-publish.
  cat > "$fakebin/sq-gh" <<'SH'
#!/usr/bin/env bash
invocations_file="${SQUAD_STATE_OVERRIDE}/../idemp-invocations"
printf '%s\n' "$*" >> "$invocations_file"
if [ "$1" = "api" ]; then
  shift
  if [ "$1" = "PATCH" ]; then
    exit 0
  fi
  # comment listing: return one existing comment with the marker
  printf '12345\t<!-- squad-cost-report --> existing body\n'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/sq-gh"
  git -C "$wt" remote add origin file:///dev/null 2>/dev/null || true
  local output rc
  # First publish: should detect existing comment and PATCH it
  output=$(cd "$different_checkout" && PATH="$fakebin:$PATH" \
           SQUAD_STATE_OVERRIDE="$state" SQUAD_DATA_OVERRIDE="$data" \
           SQUAD_PI_SESSION_DIR="$pi_root" \
           "$COST_CLI" publish idemp-task "https://github.com/url-owner/url-repository/pull/42" 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "first publish should exit 0, got: $rc"
  assert_contains "$output" "published" "first publish succeeds"
  # Verify sq-gh api was called (for comment listing)
  assert_contains "$(cat "$invocations_file")" "/repos/url-owner/url-repository/issues/42/comments" "publish targets repository and number from PR URL"
  assert_not_contains "$(cat "$invocations_file")" "wrong/current-repository" "publish ignores the current checkout repository"
  # Second publish: should detect existing comment again and PATCH again
  printf '' > "$invocations_file"
  output=$(cd "$different_checkout" && PATH="$fakebin:$PATH" \
           SQUAD_STATE_OVERRIDE="$state" SQUAD_DATA_OVERRIDE="$data" \
           SQUAD_PI_SESSION_DIR="$pi_root" \
           "$COST_CLI" publish idemp-task "https://github.com/url-owner/url-repository/pull/42" 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "second publish (re-publish) should exit 0, got: $rc"
  assert_contains "$output" "published" "re-publish succeeds"
  local all_invocations
  all_invocations=$(cat "$invocations_file")
  assert_contains "$all_invocations" "PATCH" "re-publish uses PATCH for idempotent update"
  assert_not_contains "$all_invocations" "pr comment" "re-publish does not create a duplicate comment"
  pass "idempotent publish uses PATCH to update existing marked comment"
}

test_publish_idempotent

# ── (h5) creation targets the parsed PR repository ─────────────────────────

test_publish_create_targets_pr_repository() {
  local state="$TMP_ROOT/create-state" data="$TMP_ROOT/create-data" fakebin invocations
  mkdir -p "$state" "$data"
  local pi_root="$TMP_ROOT/create-pi" pi_dir="$TMP_ROOT/create-pi/fixture" wt="$TMP_ROOT/create-worktree"
  mkdir -p "$pi_dir" "$wt"
  printf 'window=sq:create-test\nharness=pi\nworktree=%s\nproject=test-proj\nmodel=default\n' "$wt" > "$state/create-task.meta"
  write_exec_window "$state" create-task "$wt" 1767225600 1767484800
  cat > "$pi_dir/create.jsonl" <<EOF
{"type":"session","version":3,"id":"c1","timestamp":"2026-01-01T00:00:00Z","cwd":"$wt"}
{"type":"model_change","provider":"anthropic","modelId":"claude-sonnet-4"}
{"type":"message","message":{"role":"assistant","model":"claude-sonnet-4","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"total":0.01}}}}
EOF
  fakebin=$(fm_fakebin "$TMP_ROOT/create-fake")
  invocations="$TMP_ROOT/create-invocations"
  : > "$invocations"
  cat > "$fakebin/sq-gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SQUAD_CREATE_INVOCATIONS"
if [ "$1" = "api" ]; then
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/sq-gh"
  local output rc
  output=$(PATH="$fakebin:$PATH" SQUAD_CREATE_INVOCATIONS="$invocations" \
           SQUAD_STATE_OVERRIDE="$state" SQUAD_DATA_OVERRIDE="$data" \
           SQUAD_PI_SESSION_DIR="$pi_root" "$COST_CLI" publish create-task \
           "https://github.com/url-owner/url-repository/pull/42" 2>&1) && rc=$? || rc=$?
  [ "$rc" -eq 0 ] || fail "create publish should exit 0, got: $rc"
  assert_contains "$(cat "$invocations")" "pr comment 42 --repo url-owner/url-repository" \
    "create publish passes the PR repository explicitly"
  pass "new cost comment targets the repository parsed from the PR URL"
}

test_publish_create_targets_pr_repository

# ── (h6) publication failure reason reaches stderr ─────────────────────────

test_publish_failure_reason() {
  local state="$TMP_ROOT/failure-state" fakebin err rc
  mkdir -p "$state"
  : > "$state/failure-task.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/failure-fake")
  cat > "$fakebin/sq-gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
  exit 0
fi
printf 'target repository rejected the comment\n'
exit 1
SH
  chmod +x "$fakebin/sq-gh"
  err="$TMP_ROOT/failure-stderr"
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" \
    "$COST_CLI" publish failure-task "https://github.com/org/repo/pull/1" \
    > /dev/null 2> "$err" && rc=$? || rc=$?
  [ "$rc" -ne 0 ] || fail "failed publication should exit non-zero"
  assert_contains "$(cat "$err")" "target repository rejected the comment" \
    "publication failure preserves the underlying reason on stderr"
  pass "publication failure reason reaches stderr"
}

test_publish_failure_reason

# ── (h7) invalid PR URL has no repository fallback ─────────────────────────

test_publish_invalid_url() {
  local state="$TMP_ROOT/invalid-url-state" output rc
  mkdir -p "$state"
  : > "$state/invalid-url-task.meta"
  output=$(SQUAD_STATE_OVERRIDE="$state" "$COST_CLI" publish invalid-url-task \
           "https://github.com/owner/repository/pull/not-a-number" 2>&1) && rc=$? || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid PR URL should fail"
  assert_contains "$output" "error: invalid PR URL" "invalid PR URL reports a clear error"
  pass "invalid PR URL cannot fall back to the current repository"
}

test_publish_invalid_url

# ── (h8) Pi zero-result regression ────────────────────────────────────────

test_pi_zero_result() {
  local pi_root="$TMP_ROOT/zero-pi" state="$TMP_ROOT/zero-state"
  mkdir -p "$state"
  # No Pi sessions directory exists at all
  local output
  output=$(SQUAD_STATE_OVERRIDE="$state" SQUAD_PI_SESSION_DIR="$pi_root" \
           "$COST_CLI" report zero-task 2>&1)
  assert_contains "$output" "Usage unavailable" "zero-result report shows unavailable message"
  # Verify no fabricated zero token counts appear in the markdown table
  if printf '%s' "$output" | grep -q '| *0 *| *0 *|'; then
    fail "zero-result report fabricated zero token rows"
  fi
  pass "Pi zero-result reports explicit reason instead of fabricated zeros"
}

test_pi_zero_result

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
