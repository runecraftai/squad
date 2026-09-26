#!/usr/bin/env bash
set -euo pipefail
# Focused CLI contract tests for the private trajectory projection.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BASE="$TMP/base"
mkdir -p "$BASE/state" "$BASE/data"
export SQUAD_BASE="$BASE" SQUAD_STATE_OVERRIDE="$BASE/state" SQUAD_DATA_OVERRIDE="$BASE/data"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
fixture() {
  local id=$1
  printf 'window=w1\nharness=codex\nmodel=test-model\n' > "$BASE/state/$id.meta"
  printf 'exec_state=released\nexec_attempt=2\nexec_retry_count=1\nexec_started_at=100\nexec_last_activity=145\n' > "$BASE/state/$id.exec"
  printf 'working: private prompt must not escape\ndone: checks green\n' > "$BASE/state/$id.status"
}
CLI="$ROOT/bin/sq-trajectory.sh"
fixture alpha

# 1, 2, 3, 5: complete schema; unavailable usage never becomes zero; metadata allowlist.
json=$("$CLI" task alpha --json)
jq -e '.schema_version==1 and .task.id=="alpha" and .attempts.value==2 and .duration_seconds.value==45 and .outcome.value=="done" and .tokens.input.value==null and .tokens.input.availability=="unknown" and (.tokens.input.reason|length>0) and (.sources|length==3)' <<<"$json" >/dev/null || fail 'task JSON contract'
if grep -Eq 'private prompt|checks green' <<<"$json"; then fail 'status content leaked'; fi
pass 'criteria 1-3 and 5: allowlisted JSON, explicit unknowns, source provenance'

# 4, 5: snapshot is private, repeatable, and generated from authoritative sources.
"$CLI" snapshot alpha >/dev/null
snapshot="$BASE/data/alpha/artifacts/trajectory.v1.json"
[[ $(stat -c %a "$snapshot") == 600 ]] || fail 'snapshot permissions are not 0600'
first=$(sha256sum "$snapshot" | cut -d' ' -f1)
"$CLI" snapshot alpha >/dev/null
second=$(sha256sum "$snapshot" | cut -d' ' -f1)
[[ "$first" == "$second" ]] || fail 'snapshot bytes changed without source changes'
pass 'criteria 4-5: private atomic snapshot is deterministic and records sources'

# 6: missing task and malformed required source return 2 without artifact.
set +e
"$CLI" task missing --json >/dev/null 2>&1; rc=$?
set -e
[[ $rc == 2 ]] || fail 'missing task did not exit 2'
before=$(sha256sum "$snapshot" | cut -d' ' -f1)
printf 'invalid source\n' >> "$BASE/state/alpha.exec"
set +e
"$CLI" snapshot alpha >/dev/null 2>&1; rc=$?
set -e
after=$(sha256sum "$snapshot" | cut -d' ' -f1)
[[ $rc == 2 && "$before" == "$after" ]] || fail 'malformed source modified artifact or wrong exit'
pass 'criterion 6: invalid/missing inputs stop with exit 2 and no artifact'

# 7-8: completed distinct tasks, bounded coverage, three availability classes/reasons surface.
fixture beta
report=$("$CLI" coverage --limit 20 --json)
jq -e '.analyzed==1 and (.tasks|map(.id)|unique|length)==1 and (.coverage|length)>0 and all(.coverage[]; has("known") and has("unknown") and has("not_applicable"))' <<<"$report" >/dev/null || fail 'JSON coverage contract'
human=$("$CLI" coverage --limit 20)
grep -q 'Most frequent unknown reasons:' <<<"$human" || fail 'human coverage omits unknown reasons'
pass 'criteria 7-8: distinct bounded coverage and human unknown-reason summary'

# 9: coverage --limit 20 clips to 20 when more tasks exist; >20 is rejected.
for i in $(seq 1 21); do
  fixture "task$(printf '%02d' $i)"
done
report=$("$CLI" coverage --limit 20 --json)
jq -e '.analyzed==20 and (.tasks|length)==20' <<<"$report" >/dev/null || fail 'coverage did not clip to limit of 20'
set +e
"$CLI" coverage --limit 21 --json >/dev/null 2>&1; rc=$?
set -e
[[ $rc == 2 ]] || fail 'coverage --limit 21 should be rejected'
pass 'criterion 9: coverage limit clips at 20 and rejects >20'
