#!/usr/bin/env bash
# Tests for atomic WORKFLOW.md reload and execution-version pinning.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WF=$TMP/WORKFLOW.md
STATE=$TMP/state
mkdir -p "$STATE"
cat >"$WF" <<'EOF'
---
schema_version: "1.0.0"
execution:
  max_retry_attempts: 3
---
EOF

raw_hash=$("$ROOT/bin/sq-workflow.sh" hash "$WF")
[ "${#raw_hash}" -eq 64 ]
v1=$("$ROOT/bin/sq-workflow-reload.sh" hash "$WF" "$ROOT/.agents/skills")
[ "${#v1}" -eq 64 ]
"$ROOT/bin/sq-workflow-reload.sh" reload "$WF" "$STATE" | grep -q '^reloaded version='
v1=$(sed -n 's/^workflow_version=//p' "$STATE"/.workflow-reload-*)

# A malformed edit preserves the last known-good version.
printf '%s\n' '---' 'schema_version: "1.0.0"' 'execution: [' '---' >"$WF"
touch -d '2 seconds ago' "$WF"
output=$("$ROOT/bin/sq-workflow-reload.sh" check "$WF" "$STATE")
[ "$output" = "invalid-preserved version=$v1" ]

# A valid edit gets a new version; an already-running attempt remains pinned.
cat >"$WF" <<'EOF'
---
schema_version: "1.0.0"
execution:
  max_retry_attempts: 4
---
EOF
touch -d '3 seconds ago' "$WF"
v2=$("$ROOT/bin/sq-workflow-reload.sh" reload "$WF" "$STATE" | sed 's/.*version=//')
[ "$v1" != "$v2" ]

id=reload-pin
mkdir -p "$TMP/project"
cat >"$STATE/$id.meta" <<EOF
workflow=$WF
workflow_version=$v2
project=$TMP/project
worktree=$TMP
harness=pi
EOF
SQUAD_STATE_OVERRIDE="$STATE" SQUAD_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/sq-exec-state.sh" claim "$id" >/dev/null
[ "$(sed -n 's/^exec_workflow_version=//p' "$STATE/$id.exec")" = "$v2" ]
SQUAD_STATE_OVERRIDE="$STATE" SQUAD_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/sq-exec-state.sh" running "$id" >/dev/null
pinned=$(sed -n 's/^exec_workflow_version=//p' "$STATE/$id.exec")
[ "$pinned" = "$v2" ]
python3 - "$WF" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
p.write_text(p.read_text().replace('max_retry_attempts: 4', 'max_retry_attempts: 5'))
PY
touch -d '4 seconds ago' "$WF"
v3=$("$ROOT/bin/sq-workflow-reload.sh" reload "$WF" "$STATE" | sed 's/.*version=//')
[ "$v3" != "$v2" ]
[ "$(sed -n 's/^exec_workflow_version=//p' "$STATE/$id.exec")" = "$pinned" ]
SQUAD_STATE_OVERRIDE="$STATE" SQUAD_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/sq-exec-state.sh" retry "$id" >/dev/null
SQUAD_STATE_OVERRIDE="$STATE" SQUAD_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/sq-exec-state.sh" claim "$id" >/dev/null
[ "$(sed -n 's/^exec_workflow_version=//p' "$STATE/$id.exec")" = "$v3" ]
printf 'ok - sq-workflow atomic reload and version pinning\n'
