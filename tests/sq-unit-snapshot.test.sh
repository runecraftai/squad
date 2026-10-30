#!/usr/bin/env bash
# Regression coverage for large backlog JSON transport in sq-unit-snapshot.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-unit-snapshot)
BASE="$TMP_ROOT/base"
mkdir -p "$BASE/data" "$BASE/state" "$BASE/config" "$BASE/projects"
cat > "$BASE/data/backlog.md" <<'EOF'
# Backlog

## In flight
EOF
python3 - "$BASE/data/backlog.md" <<'PY'
import sys

with open(sys.argv[1], "a", encoding="utf-8") as backlog:
    for index in range(1600):
        backlog.write(f"- [ ] item-{index} - " + "x" * 100 + "\n")
PY

out=$(SQUAD_BASE="$BASE" \
  SQUAD_ROOT="$ROOT" \
  SQUAD_STATE_OVERRIDE="$BASE/state" \
  SQUAD_DATA_OVERRIDE="$BASE/data" \
  SQUAD_CONFIG_OVERRIDE="$BASE/config" \
  SQUAD_PROJECTS_OVERRIDE="$BASE/projects" \
  "$ROOT/bin/sq-unit-snapshot.sh" 2>&1) || fail "large backlog snapshot should succeed"
printf '%s' "$out" | jq -e '.schema == "sq-unit-snapshot.v1" and (.backlog.records | length) == 1600 and (.main_inventory | type) == "object"' >/dev/null \
  || fail "large backlog snapshot should produce a structured inventory"


# pr.risk: a finished drill run's review level rides on sq-crew-state.sh's done
# detail; synthetic drill database and a fake drill, over a real git worktree.
RISK="$TMP_ROOT/risk"
mkdir -p "$RISK/fakebin" "$RISK/wt"
git -C "$RISK/wt" init -q
git -C "$RISK/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$RISK/wt" checkout -q -b sq/risk-task
RISK_HEAD=$(git -C "$RISK/wt" rev-parse HEAD)
cat > "$RISK/fakebin/drill" <<SH
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in
  axi:status) printf 'run:\n  id: "01RUN"\n  branch: sq/risk-task\n  status: completed\n  head: "$RISK_HEAD"\n  pr: "https://github.com/o/r/pull/9"\n  findings: none\noutcome: passed\n' ;;
  runs:*) printf 'completed sq/risk-task %.7s 2026-10-29\n' "$RISK_HEAD" ;;
esac
exit 0
SH
chmod +x "$RISK/fakebin/drill"
printf 'window=fm:sq-risk-task\nworktree=%s\nkind=strike\n' "$RISK/wt" > "$BASE/state/risk-task.meta"

snapshot_risk() {  # <drill-database>
  PATH="$RISK/fakebin:$PATH" SQUAD_DRILL_STATE="$1" SQUAD_BASE="$BASE" SQUAD_ROOT="$ROOT" \
    SQUAD_STATE_OVERRIDE="$BASE/state" SQUAD_DATA_OVERRIDE="$BASE/data" \
    SQUAD_CONFIG_OVERRIDE="$BASE/config" SQUAD_PROJECTS_OVERRIDE="$BASE/projects" \
    "$ROOT/bin/sq-unit-snapshot.sh" | jq -c '.tasks[] | select(.id == "risk-task") | .pr'
}
make_risk_db() {  # <path> <step> <final-findings-json-or-NULL> <round-findings-json-or-NULL>
  rm -f "$1"
  sqlite3 "$1" <<SQL
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
  step_order INTEGER NOT NULL, findings_json TEXT, started_at INTEGER);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL,
  findings_json TEXT);
INSERT INTO step_results VALUES ('sr1', '01RUN', '$2', 2, $3, 1);
INSERT INTO step_rounds VALUES ('rd1', 'sr1', 1, $4);
SQL
}

# The drill-pr sidecar is written by the first crew-state read, so warm it up.
snapshot_risk "$RISK/missing.sqlite" >/dev/null
none=$(snapshot_risk "$RISK/missing.sqlite")
printf '%s' "$none" | jq -e '.risk == null and .source == "drill" and (.url | endswith("/pull/9"))' >/dev/null \
  || fail "missing database should leave pr.risk null: $none"
base_keys=$(printf '%s' "$none" | jq -c 'del(.risk)')

make_risk_db "$RISK/state.sqlite" review "'{\"risk_level\":\"medium\"}'" NULL
got=$(snapshot_risk "$RISK/state.sqlite")
[ "$(printf '%s' "$got" | jq -r .risk)" = medium ] || fail "medium review risk should reach pr.risk: $got"
[ "$(printf '%s' "$got" | jq -c 'del(.risk)')" = "$base_keys" ] || fail "pr.url and pr.source must not change: $got"

make_risk_db "$RISK/state.sqlite" review NULL "'{\"risk_level\":\"high\"}'"
[ "$(snapshot_risk "$RISK/state.sqlite" | jq -r .risk)" = high ] || fail "null final findings should fall back to the round"

make_risk_db "$RISK/state.sqlite" review "'{\"risk_level\":\"unknown\"}'" NULL
[ "$(snapshot_risk "$RISK/state.sqlite" | jq -r .risk)" = null ] || fail "unknown review risk should leave pr.risk null"

make_risk_db "$RISK/state.sqlite" test "'{\"risk_level\":\"high\"}'" NULL
[ "$(snapshot_risk "$RISK/state.sqlite" | jq -r .risk)" = null ] || fail "a run without a review row should leave pr.risk null"

# Free-form detail from a non-run source is operator prose, not drill's review
# level: a status-log done note mentioning risk=high must not populate pr.risk.
NOTE="$RISK/note"
mkdir -p "$NOTE/fakebin" "$NOTE/wt"
git -C "$NOTE/wt" init -q
git -C "$NOTE/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$NOTE/wt" checkout -q -b sq/note-task
NOTE_HEAD=$(git -C "$NOTE/wt" rev-parse HEAD)
cat > "$NOTE/fakebin/drill" <<SH
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in
  axi:status) printf 'run:\n  id: "01NOTE"\n  branch: sq/note-task\n  status: running\n  head: "$NOTE_HEAD"\n  findings: none\n' ;;
  runs:*) printf 'running sq/note-task %.7s 2026-10-29\n' "$NOTE_HEAD" ;;
esac
exit 0
SH
chmod +x "$NOTE/fakebin/drill"
printf 'window=fm:sq-note-task\nworktree=%s\nkind=strike\n' "$NOTE/wt" > "$BASE/state/note-task.meta"
printf 'done: PR checks green · risk=high\n' > "$BASE/state/note-task.status"
note=$(PATH="$NOTE/fakebin:$PATH" SQUAD_DRILL_STATE="$RISK/missing.sqlite" SQUAD_BASE="$BASE" SQUAD_ROOT="$ROOT" \
  SQUAD_STATE_OVERRIDE="$BASE/state" SQUAD_DATA_OVERRIDE="$BASE/data" \
  SQUAD_CONFIG_OVERRIDE="$BASE/config" SQUAD_PROJECTS_OVERRIDE="$BASE/projects" \
  "$ROOT/bin/sq-unit-snapshot.sh" | jq -c '.tasks[] | select(.id == "note-task")')
printf '%s' "$note" | jq -e '.current_state.state == "done" and .current_state.source == "status-log"
  and (.current_state.detail | contains("risk=high")) and .pr.risk == null' >/dev/null \
  || fail "a status-log detail mentioning risk must not become pr.risk: $note"

pass "sq-unit-snapshot handles backlog JSON without argv transport"
