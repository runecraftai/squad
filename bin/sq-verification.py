#!/usr/bin/env python3
"""Record and report explicitly linked escaped defects in GitHub issue bodies."""
import argparse
import datetime as dt
import json
import re
import subprocess
import sys

MARKER = "<!-- squad-escaped-defect:v1 -->"
FIELDS = ("discovered_at", "affected_pr", "affected_sha", "reproduction",
          "regression", "pre_merge_gate", "missed_gate")


def gh(args, *, input_text=None):
    return subprocess.run(["sq-gh", *args], input=input_text, text=True,
                          check=True, capture_output=True).stdout


def repo_issue(url):
    match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/issues/(\d+)/?", url)
    if not match:
        raise ValueError("issue URL must be https://github.com/OWNER/REPO/issues/NUMBER")
    return match.group(1), match.group(2)


def issue_record(args):
    repo, number = repo_issue(args.issue)
    values = {
        "discovered_at": args.discovered_at,
        "affected_pr": args.pr,
        "affected_sha": args.sha,
        "reproduction": args.reproduction or f"unknown: {args.no_reproduction_reason}",
        "regression": args.regression or f"unknown: {args.no_regression_reason}",
        "pre_merge_gate": args.gate,
        "missed_gate": args.missed_reason,
    }
    for key, value in values.items():
        if not value or value.startswith("unknown:") and not value.partition(":")[2].strip():
            raise ValueError(f"{key} must have a value or an unknown reason")
    if not re.fullmatch(r"[0-9a-fA-F]{40,64}", args.sha):
        raise ValueError("affected SHA must be a full 40- or 64-character hexadecimal SHA")
    try:
        parsed = dt.datetime.fromisoformat(args.discovered_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("discovery time must be an ISO-8601 timestamp with timezone") from exc
    if parsed.tzinfo is None:
        raise ValueError("discovery time must include a timezone")
    body = gh(["api", f"/repos/{repo}/issues/{number}", "--jq", ".body // \"\""])
    if MARKER in body:
        body = body.split(MARKER, 1)[0].rstrip()
    section = [MARKER, "### Escaped defect linkage"]
    section.extend(f"{key}: {values[key]}" for key in FIELDS)
    body = (body.rstrip() + "\n\n" if body.strip() else "") + "\n".join(section) + "\n"
    gh(["api", "PATCH", f"/repos/{repo}/issues/{number}", "--field", f"body={body}"])
    print(f"recorded: {args.issue}")


def extract(body):
    if MARKER not in body:
        return None
    section = body.split(MARKER, 1)[1]
    result = {}
    for line in section.splitlines():
        key, sep, value = line.partition(":")
        if sep and key.strip() in FIELDS:
            result[key.strip()] = value.strip() or "unknown (recorded without a value)"
    return {key: result.get(key, "unknown (not recorded)") for key in FIELDS}


def report(repo):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("repo must be OWNER/REPO")
    raw = gh(["api", "--paginate", f"/repos/{repo}/issues?state=all&per_page=100"])
    decoder, offset, issues = json.JSONDecoder(), 0, []
    while offset < len(raw):
        while offset < len(raw) and raw[offset].isspace():
            offset += 1
        if offset == len(raw):
            break
        page, offset = decoder.raw_decode(raw, offset)
        if not isinstance(page, list):
            raise ValueError("issue listing did not return a JSON array")
        issues.extend(page)
    found = []
    for issue in issues:
        if "pull_request" in issue:
            continue
        fields = extract(issue.get("body") or "")
        if fields is not None:
            found.append((issue, fields))
    if not found:
        print("no escaped defects recorded (this is not evidence that none exist)")
        return
    for issue, fields in sorted(found, key=lambda item: item[0].get("number", 0)):
        print(f"Defect #{issue.get('number', 'unknown')}: {issue.get('title') or 'unknown (not recorded)'}")
        print(f"Issue: {issue.get('html_url') or 'unknown (not recorded)'}")
        for key in FIELDS:
            print(f"  {key}: {fields[key]}")
        print()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    record = sub.add_parser("record", help="record one defect on its existing GitHub issue")
    record.add_argument("issue")
    record.add_argument("--discovered-at", required=True)
    record.add_argument("--pr", required=True)
    record.add_argument("--sha", required=True)
    reproduction = record.add_mutually_exclusive_group(required=True)
    reproduction.add_argument("--reproduction")
    reproduction.add_argument("--no-reproduction-reason")
    regression = record.add_mutually_exclusive_group(required=True)
    regression.add_argument("--regression")
    regression.add_argument("--no-regression-reason")
    record.add_argument("--gate", required=True)
    record.add_argument("--missed-reason", required=True)
    listing = sub.add_parser("report", help="report every explicitly recorded defect for OWNER/REPO")
    listing.add_argument("repo")
    args = parser.parse_args()
    try:
        issue_record(args) if args.command == "record" else report(args.repo)
    except (ValueError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "")
        print(f"error: {str(exc)}{(': ' + detail.strip()) if detail else ''}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
