#!/usr/bin/env python3
"""Verify the basic behavioral sections of a skill directory.

Usage: sq-skill-verify.py <skill-directory>
"""

import json
import sys
from pathlib import Path

from sq_skill_markdown import front_matter, section


VERIFIED_SKILLS = ["drill", "no-mistakes", "humanizer"]


def main():
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <skill-directory>", file=sys.stderr)
        return 2

    skill_dir = Path(sys.argv[1])
    skill_file = skill_dir / "SKILL.md"
    try:
        text = skill_file.read_text(encoding="utf-8") if skill_file.is_file() else ""
    except (OSError, UnicodeError):
        text = ""
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
