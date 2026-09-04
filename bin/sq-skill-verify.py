#!/usr/bin/env python3
"""Verify an imported skill's declared scope, observed behavior, and allowlist status."""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import sys
from pathlib import Path

INFLUENCE_CATEGORIES = {
    "routing": "ROUTING",
    "tool": "ROUTING",
    "calibration": "CALIBRATION",
    "action": "CALIBRATION",
    "workflow": "WORKFLOW",
    "library": "PREFERENCE",
    "service": "PREFERENCE",
    "preference": "PREFERENCE",
}


def skill_version(path: Path, text: str) -> str:
    match = re.search(r"^\s*version:\s*['\"]?([^'\"\n]+)", text, re.M)
    return match.group(1).strip() if match else hashlib.sha256(text.encode()).hexdigest()[:12]


def declared(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    front = text.split("---", 2)[1] if text.startswith("---") else ""
    name_match = re.search(r"^name:\s*([^\n]+)$", front, re.M)
    description = re.search(r"^description:\s*(.+)$", front, re.M)
    sections = {}
    current = None
    for line in text.splitlines():
        heading = re.match(r"^#{1,3}\s+(.+)$", line)
        if heading:
            current = heading.group(1).strip().lower()
            sections[current] = []
        elif current:
            item = re.match(r"^\s*[-*]\s+(.+)$", line)
            if item:
                sections[current].append(item.group(1).strip())
    trigger_keys = ("when to use", "triggers", "use when")
    boundary_keys = ("do not use", "out of scope", "boundaries", "when not")
    triggers = next((v for k, v in sections.items() if any(x in k for x in trigger_keys)), [])
    boundaries = next((v for k, v in sections.items() if any(x in k for x in boundary_keys)), [])
    influence = []
    for name, category in (("tool", "ROUTING"), ("library", "PREFERENCE"), ("service", "PREFERENCE"),
                           ("architecture", "PREFERENCE"), ("workflow", "WORKFLOW"), ("decision", "CALIBRATION")):
        if re.search(rf"\b{name}\w*\b", text, re.I):
            influence.append(category)
    return {"name": (name_match.group(1).strip() if name_match else path.parent.name), "version": skill_version(path, text),
            "description": description.group(1).strip() if description else "",
            "triggers": triggers, "do_not_use": boundaries,
            "declared_influence": sorted(set(influence))}


def diff_tree(skill: Path, upstream: Path | None) -> dict:
    if not upstream:
        return {"available": False, "files": [], "patch": ""}
    files = sorted(set(p.relative_to(skill) for p in skill.rglob("*") if p.is_file()) |
                   set(p.relative_to(upstream) for p in upstream.rglob("*") if p.is_file()))
    chunks = []
    changed = []
    for rel in files:
        left = (upstream / rel).read_text(encoding="utf-8", errors="replace") if (upstream / rel).is_file() else ""
        right = (skill / rel).read_text(encoding="utf-8", errors="replace") if (skill / rel).is_file() else ""
        if left != right:
            changed.append(str(rel))
            chunks.extend(difflib.unified_diff(left.splitlines(True), right.splitlines(True),
                                                fromfile=f"upstream/{rel}", tofile=f"imported/{rel}"))
    return {"available": True, "files": changed, "patch": "".join(chunks)}


def observe(events_path: Path, declaration: dict) -> dict:
    events = []
    findings = []
    for number, line in enumerate(events_path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            findings.append({"class": "malformed-event", "line": number, "detail": str(exc)})
            continue
        events.append(event)
        kind = str(event.get("type", "")).lower()
        category = INFLUENCE_CATEGORIES.get(kind) or INFLUENCE_CATEGORIES.get(str(event.get("category", "")).lower())
        if category and category not in declaration["declared_influence"]:
            findings.append({"class": "scope-discrepancy", "line": number, "influence": category,
                             "event": event, "detail": "observed influence is absent from declared scope"})
        if kind in ("tool", "decision", "workflow_step", "preference") and not event.get("skill_triggered", True):
            findings.append({"class": "out-of-trigger-scope", "line": number, "event": event,
                             "detail": "influence was observed outside the declared trigger"})
    return {"events": len(events), "observed": events, "findings": findings,
            "influence": sorted({INFLUENCE_CATEGORIES.get(str(e.get("type", "")).lower(),
                                                           str(e.get("category", "")).upper()) for e in events
                                  if e.get("type") or e.get("category")})}


def registry_entry(registry: Path, declaration: dict) -> dict | None:
    if not registry.is_file():
        return None
    data = json.loads(registry.read_text(encoding="utf-8"))
    return data.get("skills", {}).get(declaration["name"], {}).get(declaration["version"])


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify imported skills before sensitive use.")
    sub = parser.add_subparsers(dest="command", required=True)
    inspect = sub.add_parser("inspect", help="show declared scope and upstream diff")
    inspect.add_argument("skill", type=Path)
    inspect.add_argument("--upstream", type=Path)
    inspect.add_argument("--json", action="store_true")
    obs = sub.add_parser("observe", help="compare JSONL execution events with declarations")
    obs.add_argument("skill", type=Path)
    obs.add_argument("events", type=Path)
    obs.add_argument("--json", action="store_true")
    check = sub.add_parser("check", help="require a verified skill version in the registry")
    check.add_argument("skill", type=Path)
    check.add_argument("--registry", type=Path, default=Path("config/skill-verification.json"))
    check.add_argument("--json", action="store_true")
    mark = sub.add_parser("mark", help="write a verification result to a registry")
    mark.add_argument("skill", type=Path)
    mark.add_argument("--registry", type=Path, default=Path("config/skill-verification.json"))
    mark.add_argument("--result", choices=("verified", "unverified"), required=True)
    mark.add_argument("--evidence", required=True)
    args = parser.parse_args()
    if not (args.skill / "SKILL.md").is_file():
        parser.error(f"skill must contain SKILL.md: {args.skill}")
    info = declared(args.skill / "SKILL.md")
    if args.command == "inspect":
        info["upstream_diff"] = diff_tree(args.skill, args.upstream)
        if args.json:
            print(json.dumps(info, indent=2, sort_keys=True))
        else:
            print(f"{info['name']} version {info['version']}")
            print(f"Description: {info['description']}")
            print("Triggers: " + ("; ".join(info["triggers"]) or "not declared"))
            print("Do not use for: " + ("; ".join(info["do_not_use"]) or "not declared"))
            print("Potential influence: " + (", ".join(info["declared_influence"]) or "none detected"))
            diff = info["upstream_diff"]
            print(f"Changed upstream files: {', '.join(diff['files']) if diff['available'] else 'unavailable'}")
            if diff["patch"]: print(diff["patch"], end="")
        return 0
    if args.command == "observe":
        result = {"skill": info, **observe(args.events, info)}
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print(f"Observed {result['events']} events; findings: {len(result['findings'])}")
            for event in result["observed"]:
                kind = event.get("type", event.get("category", "event"))
                detail = event.get("name", event.get("action", event.get("after", "")))
                print(f"- {kind}: {detail}")
            for finding in result["findings"]:
                print(f"FINDING {finding['class']} line {finding['line']}: {finding['detail']}")
        return 1 if result["findings"] else 0
    if args.command == "check":
        entry = registry_entry(args.registry, info)
        result = {"skill": info["name"], "version": info["version"], "verified": bool(entry and entry.get("result") == "verified"),
                  "registry": str(args.registry)}
        print(json.dumps(result, sort_keys=True) if args.json else
              f"{info['name']}@{info['version']}: {'verified' if result['verified'] else 'unverified'}")
        return 0 if result["verified"] else 1
    registry = args.registry
    data = json.loads(registry.read_text(encoding="utf-8")) if registry.is_file() else {"skills": {}}
    data.setdefault("skills", {}).setdefault(info["name"], {})[info["version"]] = {
        "result": args.result, "evidence": args.evidence}
    registry.parent.mkdir(parents=True, exist_ok=True)
    registry.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{info['name']}@{info['version']}: {args.result}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
