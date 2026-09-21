#!/usr/bin/env bash
# Check that a skill declares triggers.
# Usage: sq-check-skill-triggers.sh <skill-directory>
# Exit 0 when SKILL.md is readable and the skill declares how it triggers.
# Accepted patterns: section headings, description-field markers,
# user-invocable frontmatter, or meaningful description content that
# helps the agent decide when to load the skill.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <skill-directory>" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$1" "$script_dir" <<'PY'
import re
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from sq_skill_markdown import front_matter, section, _front_matter_match, without_html_comments

skill_file = Path(sys.argv[1]) / "SKILL.md"
try:
    text = skill_file.read_text(encoding="utf-8")
except (OSError, UnicodeError):
    print("missing or unreadable SKILL.md", file=sys.stderr)
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


has_section_triggers = bool(section(text, "Triggers"))
desc = extract_full_description(text)
has_desc_triggers = bool(re.search(r"\btriggers?\s*:", desc, re.IGNORECASE))
has_use_directive = bool(re.search(r"\b(use|load)\s+(when|before|on|whenever|after)\b", desc, re.IGNORECASE))
has_user_invocable = bool(re.search(r"(?im)^user-invocable:\s*true", text[:500]))
# A substantial description itself serves as the dispatch signal.
has_substantial_desc = len(desc.split()) >= 5

if not (has_section_triggers or has_desc_triggers or has_use_directive
        or has_user_invocable or has_substantial_desc):
    print("no trigger mechanism found (section, description marker, use-directive, "
          "user-invocable, or substantial description)", file=sys.stderr)
    raise SystemExit(1)
PY
