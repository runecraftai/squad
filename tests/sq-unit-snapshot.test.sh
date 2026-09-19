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

pass "sq-unit-snapshot handles backlog JSON without argv transport"
