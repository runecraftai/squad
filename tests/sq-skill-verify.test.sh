#!/usr/bin/env bash
# Tests for the external skill behavioral verification gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/bin/sq-skill-verify.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/skill" "$TMP/upstream" "$TMP/registry"
cat > "$TMP/skill/SKILL.md" <<'EOF'
---
name: example-skill
description: Example imported skill
metadata:
  version: '2.4.0'
---
# Example Skill
## Triggers
- use when choosing an implementation
## Do Not Use For
- unrelated conversation
## Workflow
- choose a tool and library
EOF
cp "$TMP/skill/SKILL.md" "$TMP/upstream/SKILL.md"
printf '\nchanged upstream\n' >> "$TMP/skill/SKILL.md"

inspect=$($VERIFY inspect "$TMP/skill" --upstream "$TMP/upstream" --json)
python3 -c 'import json,sys; x=json.loads(sys.argv[1]); assert x["version"] == "2.4.0"; assert "SKILL.md" in x["upstream_diff"]["files"]; assert "ROUTING" in x["declared_influence"]' "$inspect"

echo '{"type":"tool","category":"routing","name":"sq-gh","skill_triggered":true}' > "$TMP/events.jsonl"
echo '{"type":"preference","category":"library","selected":"a","alternatives":["b"],"skill_triggered":true}' >> "$TMP/events.jsonl"
$VERIFY observe "$TMP/skill" "$TMP/events.jsonl" --json >/dev/null

# An undeclared calibration influence must block observation.
echo '{"type":"decision","category":"calibration","before":"inspect","after":"deploy","skill_triggered":true}' >> "$TMP/events.jsonl"
if $VERIFY observe "$TMP/skill" "$TMP/events.jsonl" --json >/dev/null; then
  echo "expected undeclared influence to fail" >&2
  exit 1
fi

if $VERIFY check "$TMP/skill" --registry "$TMP/registry/status.json" >/dev/null; then
  echo "unregistered skill unexpectedly passed" >&2
  exit 1
fi
$VERIFY mark "$TMP/skill" --registry "$TMP/registry/status.json" --result verified --evidence evidence.json >/dev/null
$VERIFY check "$TMP/skill" --registry "$TMP/registry/status.json" >/dev/null

echo "ok - skill verification inspect, observation, and version allowlist"
