#!/usr/bin/env bash
# Test the simple skill behavioral verification script and checker scripts.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir "$tmp_dir/good" "$tmp_dir/bad" "$tmp_dir/fenced" "$tmp_dir/body" "$tmp_dir/invalid"
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
cat > "$tmp_dir/fenced/SKILL.md" <<'EOF'
```markdown
## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
```
EOF
cat > "$tmp_dir/body/SKILL.md" <<'EOF'
name: fake
description: Fake skill.

## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
EOF
printf '\377\376' > "$tmp_dir/invalid/SKILL.md"

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

if fenced_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/fenced"); then
    echo "fenced declarations unexpectedly passed" >&2
    exit 1
fi
python3 - "$fenced_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is False
assert report["has_dont_use"] is False
assert report["status"] == "fail"
PY
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/fenced" >/dev/null 2>&1; then
    echo "fenced triggers unexpectedly passed" >&2
    exit 1
fi
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/fenced" >/dev/null 2>&1; then
    echo "fenced format declarations unexpectedly passed" >&2
    exit 1
fi
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/body" >/dev/null 2>&1; then
    echo "body declarations unexpectedly passed as front matter" >&2
    exit 1
fi

if invalid_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/invalid" 2>"$tmp_dir/invalid.stderr"); then
    echo "invalid UTF-8 unexpectedly passed" >&2
    exit 1
fi
python3 - "$invalid_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is False
assert report["has_dont_use"] is False
assert report["status"] == "fail"
PY
[[ ! -s "$tmp_dir/invalid.stderr" ]] || {
    echo "invalid UTF-8 emitted diagnostics instead of JSON" >&2
    exit 1
}

"$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/good"
"$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/good"
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/bad" >/dev/null 2>&1; then
    echo "missing triggers unexpectedly passed" >&2
    exit 1
fi

echo "ok"
