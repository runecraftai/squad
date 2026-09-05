#!/usr/bin/env python3
"""Verify the basic behavioral sections of a skill directory.

Usage: sq-skill-verify.py <skill-directory>
"""

import json
import re
import sys
from pathlib import Path


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")


def without_fenced_code(text):
    lines = []
    fence_char = None
    fence_length = 0
    for line in text.splitlines():
        if fence_char:
            closing = re.match(
                rf"^ {{0,3}}{re.escape(fence_char)}{{{fence_length},}}[ \t]*$",
                line,
            )
            if closing:
                fence_char = None
            continue
        opening = _FENCE_OPEN.match(line)
        if opening:
            fence_char = opening.group(1)[0]
            fence_length = len(opening.group(1))
            continue
        lines.append(line)
    return "\n".join(lines)


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
    try:
        text = skill_file.read_text(encoding="utf-8") if skill_file.is_file() else ""
    except (OSError, UnicodeError):
        text = ""
    parsed_text = without_fenced_code(text)
    name = front_matter(parsed_text, "name") or skill_dir.name
    has_triggers = bool(section(parsed_text, "Triggers"))
    has_dont_use = bool(section(parsed_text, "Do NOT use for"))
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
