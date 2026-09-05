#!/usr/bin/env bash
# Check that a skill has a non-empty Triggers section.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <skill-directory>" >&2
  exit 2
fi

python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

text = (Path(sys.argv[1]) / "SKILL.md").read_text(encoding="utf-8")
match = re.search(r"(?im)^##\s+Triggers\s*$\n(.*?)(?=^##\s+|\Z)", text, re.DOTALL)
if match:
    present = bool(match.group(1).strip())
else:
    present = bool(re.search(r"(?im)^Triggers:\s*.+$", text))
if not present:
    print("missing or empty Triggers section", file=sys.stderr)
    raise SystemExit(1)
PY
