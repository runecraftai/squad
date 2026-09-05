#!/usr/bin/env python3
"""Verify the basic behavioral sections of a skill directory.

Usage: sq-skill-verify.py <skill-directory>
"""

import json
import re
import sys
from pathlib import Path


def section(text, heading):
    match = re.search(
        rf"(?im)^##\s+{re.escape(heading)}\s*$\n(.*?)(?=^##\s+|\Z)",
        text,
        re.DOTALL,
    )
    if match:
        return match.group(1).strip()
    label = re.search(rf"(?im)^{re.escape(heading)}:\s*(.+?)\s*$", text)
    return label.group(1).strip() if label else ""


def front_matter(text, key):
    match = re.search(rf"(?im)^{re.escape(key)}:\s*(.+?)\s*$", text)
    return match.group(1).strip() if match else ""


def main():
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <skill-directory>", file=sys.stderr)
        return 2

    skill_dir = Path(sys.argv[1])
    skill_file = skill_dir / "SKILL.md"
    text = skill_file.read_text(encoding="utf-8") if skill_file.is_file() else ""
    name = front_matter(text, "name") or skill_dir.name
    has_triggers = bool(section(text, "Triggers"))
    has_dont_use = bool(section(text, "Do NOT use for"))
    report = {
        "skill_name": name,
        "has_triggers": has_triggers,
        "has_dont_use": has_dont_use,
        "status": "pass" if text and has_triggers and has_dont_use else "fail",
    }
    print(json.dumps(report, separators=(",", ":")))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
