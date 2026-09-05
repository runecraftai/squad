#!/usr/bin/env bash
# Test the simple skill behavioral verification script and checker scripts.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir "$tmp_dir/good" "$tmp_dir/bad" "$tmp_dir/fenced" "$tmp_dir/body" "$tmp_dir/commented" "$tmp_dir/promoted" "$tmp_dir/empty" "$tmp_dir/invalid"
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
cat > "$tmp_dir/commented/SKILL.md" <<'EOF'
---
name: commented
description: Commented skill.
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
---
EOF
cat > "$tmp_dir/promoted/SKILL.md" <<'EOF'
```yaml
---
name: fake
description: Fake skill.
---
```

## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
EOF
cat > "$tmp_dir/empty/SKILL.md" <<'EOF'
---
name: empty
description: Empty skill.
---

Triggers:
Do NOT use for:
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
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/commented" >/dev/null 2>&1; then
    echo "front matter declarations unexpectedly passed as sections" >&2
    exit 1
fi
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/promoted" >/dev/null 2>&1; then
    echo "non-leading front matter unexpectedly passed" >&2
    exit 1
fi
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/empty" >/dev/null 2>&1; then
    echo "empty labels unexpectedly passed format checking" >&2
    exit 1
fi
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/commented" >/dev/null 2>&1; then
    echo "front matter declarations unexpectedly passed trigger checking" >&2
    exit 1
fi
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/empty" >/dev/null 2>&1; then
    echo "empty labels unexpectedly passed trigger checking" >&2
    exit 1
fi
promoted_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/promoted")
python3 - "$promoted_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["skill_name"] == "promoted"
assert report["status"] == "pass"
PY
if commented_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/commented"); then
    echo "front matter declarations unexpectedly passed verification" >&2
    exit 1
fi
python3 - "$commented_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is False
assert report["has_dont_use"] is False
assert report["status"] == "fail"
PY
if empty_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/empty"); then
    echo "empty labels unexpectedly passed verification" >&2
    exit 1
fi
python3 - "$empty_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is False
assert report["has_dont_use"] is False
assert report["status"] == "fail"
PY

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
