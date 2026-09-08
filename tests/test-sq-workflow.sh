#!/usr/bin/env bash
# Tests for WORKFLOW.md parsing, validation, and spawn integration wiring.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WF="$TMP/WORKFLOW.md"
cat > "$WF" <<'EOF'
---
schema_version: "1.0.0"
tracker:
  kind: github
  provider:
    repo: acme/example
workspace:
  root: "$HOME/workspaces"
hooks:
  before_run:
    command: ["git", "fetch", "origin"]
    timeout_ms: 30000
execution:
  max_retry_attempts: 3
stall:
  timeout_ms: 300000
axi:
  provider: github
---
EOF
json=$("$ROOT"/bin/sq-workflow.sh parse "$WF")
[ "$(printf '%s' "$json" | jq -r .schema_version)" = 1.0.0 ]
[ "$(printf '%s' "$json" | jq -r .hooks.before_run.command[0])" = git ]
[ "$("$ROOT"/bin/sq-workflow.sh get "$WF" execution.max_retry_attempts)" = 3 ]
[ "$("$ROOT"/bin/sq-workflow.sh get "$WF" hooks.before_run.command | jq -r '.[1]')" = fetch ]
"$ROOT"/bin/sq-workflow.sh validate "$WF" >/dev/null

cat > "$TMP/missing.md" <<'EOF'
---
tracker:
  kind: github
---
EOF
if "$ROOT"/bin/sq-workflow.sh parse "$TMP/missing.md" >/dev/null 2>&1; then exit 1; fi
cat > "$TMP/unknown.md" <<'EOF'
---
schema_version: "1.0.0"
unknown: true
---
EOF
if "$ROOT"/bin/sq-workflow.sh validate "$TMP/unknown.md" >/dev/null 2>&1; then exit 1; fi
cat > "$TMP/malformed.md" <<'EOF'
---
schema_version: "1.0.0"
tracker: [
---
EOF
if "$ROOT"/bin/sq-workflow.sh parse "$TMP/malformed.md" >/dev/null 2>&1; then exit 1; fi
cat > "$TMP/value.md" <<'EOF'
---
schema_version: "1.0.0"
execution:
  max_retry_attempts: nope
---
EOF
if "$ROOT"/bin/sq-workflow.sh validate "$TMP/value.md" >/dev/null 2>&1; then exit 1; fi

mkdir -p "$TMP/sim"
cat > "$TMP/sim/WORKFLOW.md" <<'WEOF'
---
schema_version: "1.0.0"
tracker:
  kind: github
  provider:
    repo: acme/example
workspace:
  root: "/tmp/workspaces"
---
WEOF
sim_json=$("$ROOT"/bin/sq-workflow.sh parse "$TMP/sim/WORKFLOW.md")
[ "$(printf '%s' "$sim_json" | jq -r .tracker.kind)" = github ]
[ "$(printf '%s' "$sim_json" | jq -r .tracker.provider.repo)" = acme/example ]
[ "$(printf '%s' "$sim_json" | jq -r .workspace.root)" = /tmp/workspaces ]

mkdir -p "$TMP/no-wf-project"
if "$ROOT"/bin/sq-workflow.sh parse "$TMP/no-wf-project/WORKFLOW.md" >/dev/null 2>&1; then exit 1; fi
cat > "$TMP/tracker-array.md" <<'EOF'
---
schema_version: "1.0.0"
tracker:
  - github
---
EOF
if "$ROOT"/bin/sq-workflow.sh parse "$TMP/tracker-array.md" >/dev/null 2>&1; then exit 1; fi
cat > "$TMP/provider-array.md" <<'EOF'
---
schema_version: "1.0.0"
tracker:
  kind: github
  provider:
    - not
    - a
    - map
---
EOF
if "$ROOT"/bin/sq-workflow.sh validate "$TMP/provider-array.md" >/dev/null 2>&1; then exit 1; fi
printf 'ok - sq-workflow parser and spawn integration\n'
