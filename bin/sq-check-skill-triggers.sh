#!/usr/bin/env bash
# Check that a skill has a non-empty Triggers section.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <skill-directory>" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PYTHONPATH="$script_dir${PYTHONPATH:+:$PYTHONPATH}" python3 - "$1" <<'PY'
import sys
from pathlib import Path

from sq_skill_markdown import section

skill_file = Path(sys.argv[1]) / "SKILL.md"
try:
    text = skill_file.read_text(encoding="utf-8")
except (OSError, UnicodeError):
    print("missing or unreadable SKILL.md", file=sys.stderr)
    raise SystemExit(1)
if not section(text, "Triggers"):
    print("missing or empty Triggers section", file=sys.stderr)
    raise SystemExit(1)
PY
