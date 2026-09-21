#!/usr/bin/env bash
# Check that a skill has SKILL.md front matter and required headings.
# Usage: sq-check-skill-format.sh <skill-directory>
# Exit 0 only when name and description front matter exist.
# Trigger and exclusion declarations are accepted in any of:
#   - Section headings (## Triggers / ## Do NOT use for)
#   - Description field markers (EN triggers: / Do NOT use for)
#   - user-invocable frontmatter (triggers via dispatch, no section needed)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <skill-directory>" >&2
  exit 2
fi

skill_file="$1/SKILL.md"
[[ -f "$skill_file" ]] || { echo "missing SKILL.md" >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$skill_file" "$script_dir" <<'PY'
import re
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from sq_skill_markdown import front_matter, has_section, _front_matter_match, without_html_comments

skill_file = Path(sys.argv[1])
try:
    text = skill_file.read_text(encoding="utf-8")
except (OSError, UnicodeError):
    print("unreadable SKILL.md", file=sys.stderr)
    raise SystemExit(1)


def extract_full_description(text):
    """Extract the full description from frontmatter, handling folded scalars."""
    match = _front_matter_match(text)
    if not match:
        return ""
    fm = without_html_comments(text[match.start(1):match.end(1)])
    desc_match = re.search(r"(?im)^description:[ \t]*(.+?)[ \t]*$", fm)
    if not desc_match:
        return ""
    indicator = desc_match.group(1).strip()
    if indicator in (">", ">-"):
        pos = desc_match.end()
        lines = []
        while pos < len(fm):
            nl = fm.find("\n", pos)
            if nl < 0:
                break
            next_start = nl + 1
            cont = re.match(r"^( +|\t)(.+)", fm[next_start:])
            if cont:
                lines.append(cont.group(2))
                pos = next_start + len(cont.group(0))
            else:
                break
        return " ".join(lines)
    return indicator


checks = (
    (bool(front_matter(text, "name")), "missing name"),
    (bool(front_matter(text, "description")), "missing description"),
)
for present, message in checks:
    if not present:
        print(message, file=sys.stderr)
        raise SystemExit(1)
PY
