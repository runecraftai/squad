#!/usr/bin/env bash
# Deterministic contract tests for the opt-in Pi model benchmark.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCHMARK="$ROOT/bin/sq-pi-model-benchmark.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sq-pi-model-benchmark-test.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

models=$($BENCHMARK --list-models)
expected_models=$(printf '%s\n' \
  opencode-go/mimo-v2.5 \
  opencode-go/muse-spark-1.2-contributor \
  opencode-go/longcat-2.0)
[ "$models" = "$expected_models" ] || fail "model allowlist changed"

report_a="$TMP_ROOT/a.json"
report_b="$TMP_ROOT/b.json"
$BENCHMARK --fixtures --output "$report_a" >/dev/null
$BENCHMARK --fixtures --output "$report_b" >/dev/null
cmp -s "$report_a" "$report_b" || fail "fixture report is not deterministic"

jq -e '
  .run.mode == "fixtures" and
  .run.live_calls == false and
  .run.models == [
    "opencode-go/mimo-v2.5",
    "opencode-go/muse-spark-1.2-contributor",
    "opencode-go/longcat-2.0"
  ] and
  .run.scenario_count == 5 and
  .run.trials_per_scenario == 3 and
  (.records | length) == 45 and
  (.records | all(.[]; .mode == "fixtures" and .scored == true and .failure_class == null)) and
  (.records | map(.scenario) | unique | length) == 5 and
  .recommendation.status == "fixture_only" and
  (.run.muse_data_boundary | contains("synthetic"))
' "$report_a" >/dev/null || fail "fixture report contract changed"

if SQ_PI_BENCHMARK_LIVE=0 $BENCHMARK --live --trials 1 >"$TMP_ROOT/gate.out" 2>&1; then
  fail "live mode ran without explicit opt-in"
fi
grep -Fq 'SQ_PI_BENCHMARK_LIVE=1' "$TMP_ROOT/gate.out" || fail "live gate did not explain its requirement"

if CI=1 SQ_PI_BENCHMARK_LIVE=1 $BENCHMARK --live --trials 1 >"$TMP_ROOT/ci.out" 2>&1; then
  fail "live mode ran in CI"
fi
grep -Fq 'prohibited in CI' "$TMP_ROOT/ci.out" || fail "CI gate did not explain its prohibition"

printf 'ok - Pi benchmark allowlist, isolated fixture scoring, deterministic reports, and live gates\n'
