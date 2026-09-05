#!/usr/bin/env bash
# Check that a skill has SKILL.md front matter and required headings.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <skill-directory>" >&2
  exit 2
fi

skill_file="$1/SKILL.md"
[[ -f "$skill_file" ]] || { echo "missing SKILL.md" >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$skill_file" "$script_dir" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from sq_skill_markdown import front_matter, has_section

skill_file = Path(sys.argv[1])
try:
    text = skill_file.read_text(encoding="utf-8")
except (OSError, UnicodeError):
    print("unreadable SKILL.md", file=sys.stderr)
    raise SystemExit(1)
checks = (
    (bool(front_matter(text, "name")), "missing name"),
    (bool(front_matter(text, "description")), "missing description"),
    (has_section(text, "Triggers"), "missing Triggers"),
    (has_section(text, "Do NOT use for"), "missing Do NOT use for"),
)
for present, message in checks:
    if not present:
        print(message, file=sys.stderr)
        raise SystemExit(1)
PY
