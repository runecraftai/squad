#!/usr/bin/env bash
# Test the simple skill behavioral verification script and checker scripts.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir "$tmp_dir/good" "$tmp_dir/bad" "$tmp_dir/fenced" "$tmp_dir/body" "$tmp_dir/commented" "$tmp_dir/hidden" "$tmp_dir/boundary" "$tmp_dir/comment-fence" "$tmp_dir/fenced-comment" "$tmp_dir/concat" "$tmp_dir/bare" "$tmp_dir/h1" "$tmp_dir/custom-html" "$tmp_dir/nested-html" "$tmp_dir/comment-html" "$tmp_dir/raw-html" "$tmp_dir/void-html" "$tmp_dir/self-closing-html" "$tmp_dir/inline" "$tmp_dir/pre" "$tmp_dir/fenced-inline" "$tmp_dir/inline-comment" "$tmp_dir/promoted" "$tmp_dir/empty" "$tmp_dir/shadow" "$tmp_dir/invalid"
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
cat > "$tmp_dir/hidden/SKILL.md" <<'EOF'
<!--
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
-->
EOF
cat > "$tmp_dir/boundary/SKILL.md" <<'EOF'
---
name: malformed
description: Malformed skill.
<!--
---
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
-->
---
EOF
cat > "$tmp_dir/comment-fence/SKILL.md" <<'EOF'
---
name: comment-fence
description: Comment fence.
---
<!--
```
-->
## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
EOF
cat > "$tmp_dir/fenced-comment/SKILL.md" <<'EOF'
```markdown
<!-- unclosed comment in a code example
## Triggers
Fake declaration.
```

## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
EOF
cat > "$tmp_dir/concat/SKILL.md" <<'EOF'
<!-- hidden -->## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
EOF
cat > "$tmp_dir/bare/SKILL.md" <<'EOF'
## Triggers
##
## Do NOT use for
##
EOF
cat > "$tmp_dir/h1/SKILL.md" <<'EOF'
<h1>
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
</h1>
EOF
cat > "$tmp_dir/custom-html/SKILL.md" <<'EOF'
<my-widget>
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
</my-widget>
EOF
cat > "$tmp_dir/nested-html/SKILL.md" <<'EOF'
<div>
<div>
</div>
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
</div>
EOF
cat > "$tmp_dir/comment-html/SKILL.md" <<'EOF'
<div>
<!-- </div> -->
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
</div>
EOF
cat > "$tmp_dir/raw-html/SKILL.md" <<'EOF'
<div>
<script>
</div>
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
</script>
</div>
EOF
cat > "$tmp_dir/void-html/SKILL.md" <<'EOF'
---
name: void-html
description: Void HTML.
---

<br>
## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
EOF
cat > "$tmp_dir/self-closing-html/SKILL.md" <<'EOF'
---
name: self-closing-html
description: Self-closing HTML.
---

<custom-widget />
## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
EOF
cat > "$tmp_dir/inline/SKILL.md" <<'EOF'
`before
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
`
EOF
cat > "$tmp_dir/pre/SKILL.md" <<'EOF'
<pre>
## Triggers
Fake declaration.
## Do NOT use for
Fake declaration.
</pre>
EOF
cat > "$tmp_dir/fenced-inline/SKILL.md" <<'EOF'
`inline example
## Fake heading
`

## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
EOF
cat > "$tmp_dir/inline-comment/SKILL.md" <<'EOF'
`code <!-- unclosed
`
## Triggers
Use for example requests.

## Do NOT use for
Unrelated requests.
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
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/hidden" >/dev/null 2>&1; then
    echo "HTML-comment declarations unexpectedly passed format checking" >&2
    exit 1
fi
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/boundary" >/dev/null 2>&1; then
    echo "commented front matter boundary unexpectedly passed format checking" >&2
    exit 1
fi
"$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/comment-fence"
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/fenced-comment" >/dev/null 2>&1; then
    echo "fenced code without front matter unexpectedly passed format checking" >&2
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
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/hidden" >/dev/null 2>&1; then
    echo "HTML-comment declarations unexpectedly passed trigger checking" >&2
    exit 1
fi
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/boundary" >/dev/null 2>&1; then
    echo "commented front matter boundary unexpectedly passed trigger checking" >&2
    exit 1
fi
"$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/comment-fence"
"$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/fenced-comment"
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/concat" >/dev/null 2>&1; then
    echo "concatenated HTML-comment declarations unexpectedly passed trigger checking" >&2
    exit 1
fi
for malformed in bare h1 custom-html nested-html comment-html raw-html inline pre; do
    if malformed_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/$malformed"); then
        echo "$malformed Markdown unexpectedly passed verification" >&2
        exit 1
    fi
    python3 - "$malformed_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is False
assert report["has_dont_use"] is False
assert report["status"] == "fail"
PY
    if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/$malformed" >/dev/null 2>&1; then
        echo "$malformed Markdown unexpectedly passed trigger checking" >&2
        exit 1
    fi
done
"$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/fenced-inline"
"$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/inline-comment"
"$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/void-html"
"$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/self-closing-html"
"$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/void-html"
"$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/self-closing-html"
if "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/fenced-inline" >/dev/null 2>&1; then
    echo "fenced inline example unexpectedly passed format checking" >&2
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
if hidden_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/hidden"); then
    echo "HTML-comment declarations unexpectedly passed verification" >&2
    exit 1
fi
python3 - "$hidden_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is False
assert report["has_dont_use"] is False
assert report["status"] == "fail"
PY
if boundary_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/boundary"); then
    echo "commented front matter boundary unexpectedly passed verification" >&2
    exit 1
fi
python3 - "$boundary_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is False
assert report["has_dont_use"] is False
assert report["status"] == "fail"
PY
comment_fence_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/comment-fence")
python3 - "$comment_fence_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is True
assert report["has_dont_use"] is True
assert report["status"] == "pass"
PY
fenced_comment_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/fenced-comment")
python3 - "$fenced_comment_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is True
assert report["has_dont_use"] is True
assert report["status"] == "pass"
PY
inline_comment_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/inline-comment")
python3 - "$inline_comment_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is True
assert report["has_dont_use"] is True
assert report["status"] == "pass"
PY
if concat_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/concat"); then
    echo "concatenated HTML-comment declarations unexpectedly passed verification" >&2
    exit 1
fi
python3 - "$concat_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is False
assert report["has_dont_use"] is True
assert report["status"] == "fail"
PY
fenced_inline_json=$(python3 "$repo_root/bin/sq-skill-verify.py" "$tmp_dir/fenced-inline")
python3 - "$fenced_inline_json" <<'PY'
import json
import sys
report = json.loads(sys.argv[1])
assert report["has_triggers"] is True
assert report["has_dont_use"] is True
assert report["status"] == "pass"
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
"$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/void-html"
"$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/self-closing-html"
printf 'raise RuntimeError("shadowed parser")\n' > "$tmp_dir/shadow/sq_skill_markdown.py"
(
    cd "$tmp_dir/shadow"
    "$repo_root/bin/sq-check-skill-format.sh" "$tmp_dir/good"
    "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/good"
)
if "$repo_root/bin/sq-check-skill-triggers.sh" "$tmp_dir/bad" >/dev/null 2>&1; then
    echo "missing triggers unexpectedly passed" >&2
    exit 1
fi

echo "ok"
