#!/usr/bin/env bash
# Test the simple skill behavioral verification script and checker scripts.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir "$tmp_dir/good" "$tmp_dir/bad"
cat > "$tmp_dir/good/SKILL.md" <<'EOF'
---
name: example
description: Example skill.
---

## Triggers

Use for example requests.

## Do NOT use for

Unrelated requests.
EOF
cat > "$tmp_dir/bad/SKILL.md" <<'EOF'
---
name: incomplete
description: Incomplete skill.
---
EOF

pass_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/good")
python3 - "$pass_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report == {
    "skill_name": "example",
    "has_triggers": True,
    "has_dont_use": True,
    "status": "pass",
}
PY

if python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/bad" >/dev/null; then
    echo "incomplete skill unexpectedly passed" >&2
    exit 1
fi

"$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/good"
"$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/good"
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/bad" >/dev/null 2>&1; then
    echo "missing triggers unexpectedly passed" >&2
    exit 1
fi

echo "ok"
