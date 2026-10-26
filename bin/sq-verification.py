#!/usr/bin/env python3
"""Record and report explicitly linked escaped defects in GitHub issue bodies."""
import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path

MARKER = "<!-- squad-escaped-defect:v1 -->"
FIELDS = ("discovered_at", "affected_pr", "affected_sha", "reproduction",
          "regression", "pre_merge_gate", "missed_gate")
TOON_DECODER = Path(__file__).resolve().parent / "sq-factory-collect-toon.mjs"
BODY_CHUNK_CODEPOINTS = 500
SQ_GH_TIMEOUT_SECONDS = 60
DECODE_TIMEOUT_SECONDS = 30
PAGE_SIZE = 100
MAX_PAGES = 100


def sq_gh(args):
    return subprocess.run(["sq-gh", *args], text=True, check=True,
                          capture_output=True, timeout=SQ_GH_TIMEOUT_SECONDS).stdout


def decode_toon(text):
    try:
        decoded = subprocess.run(["node", str(TOON_DECODER)], input=text, text=True,
                                 check=True, capture_output=True,
                                 timeout=DECODE_TIMEOUT_SECONDS)
    except FileNotFoundError as exc:
        raise ValueError("node is required to decode sq-gh output") from exc
    try:
        return json.loads(decoded.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise ValueError(f"could not decode sq-gh output: {exc}") from exc


def sq_gh_json(args):
    return decode_toon(sq_gh(args))


def body_fields(value):
    return (f"body_chunks: (({value}) as $body | [range(0; ($body | length); "
            f"{BODY_CHUNK_CODEPOINTS}) as $i | $body[$i:$i + {BODY_CHUNK_CODEPOINTS}]]), "
            f"body_length: ({value} | length)")


def joined_body(payload):
    if not isinstance(payload, dict):
        raise ValueError("sq-gh did not return an issue object")
    chunks = payload.get("body_chunks")
    if not isinstance(chunks, list) or not all(isinstance(chunk, str) for chunk in chunks):
        raise ValueError("sq-gh did not return the issue body")
    body = "".join(chunks)
    if payload.get("body_length") != len(body):
        raise ValueError("sq-gh returned a truncated issue body")
    return body


def read_body(repo, number):
    payload = sq_gh_json(["api", f"/repos/{repo}/issues/{number}", "--jq",
                          "{" + body_fields('.body // ""') + "}"])
    return joined_body(payload)


def repo_issue(url):
    match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/issues/(\d+)/?", url)
    if not match:
        raise ValueError("issue URL must be https://github.com/OWNER/REPO/issues/NUMBER")
    return match.group(1), match.group(2)


def full_sha(value):
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value):
        raise ValueError("affected SHA must be a full 40- or 64-character lowercase hexadecimal SHA")
    return value


def discovery_time(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("discovery time must be an ISO-8601 timestamp with timezone") from exc
    if parsed.tzinfo is None:
        raise ValueError("discovery time must include a timezone")
    return value.strip()


def recorded_or_reason(key, value, reason):
    recorded = (value or "").strip()
    if recorded:
        return recorded
    unknown = (reason or "").strip()
    if not unknown:
        raise ValueError(f"{key} must have a value or an explicit unknown reason")
    return f"unknown: {unknown}"


def render_section(values):
    lines = [MARKER, "### Escaped defect linkage"]
    for key in FIELDS:
        first, *continuation = values[key].split("\n")
        lines.append(f"{key}: {first}")
        lines.extend(f"  {line}" for line in continuation)
    return "\n".join(lines) + "\n"


def issue_record(args):
    repo, number = repo_issue(args.issue)
    values = {
        "discovered_at": discovery_time(args.discovered_at),
        "affected_pr": args.pr,
        "affected_sha": full_sha(args.sha),
        "reproduction": recorded_or_reason("reproduction", args.reproduction,
                                           args.no_reproduction_reason),
        "regression": recorded_or_reason("regression", args.regression,
                                         args.no_regression_reason),
        "pre_merge_gate": args.gate,
        "missed_gate": args.missed_reason,
    }
    for key, value in values.items():
        if not value.strip():
            raise ValueError(f"{key} must have a value or an explicit unknown reason")
        if value.startswith("unknown:") and not value.partition(":")[2].strip():
            raise ValueError(f"{key} must name the reason it is unknown")
    body = read_body(repo, number)
    if MARKER in body:
        body = body.split(MARKER, 1)[0].rstrip()
    prefix = body.rstrip() + "\n\n" if body.strip() else ""
    sq_gh(["api", "PATCH", f"/repos/{repo}/issues/{number}",
           "--field", f"body={prefix}{render_section(values)}"])
    print(f"recorded: {args.issue}")


def extract(body):
    if MARKER not in body:
        return None
    recorded = {}
    current = None
    for line in body.split(MARKER, 1)[1].splitlines():
        field = re.fullmatch(r"([A-Za-z_]+):[ ]?(.*)", line)
        if field and field.group(1) in FIELDS:
            current = field.group(1)
            recorded[current] = [field.group(2)]
        elif current is not None and line.startswith("  "):
            recorded[current].append(line[2:])
        elif current is not None:
            break
    return {
        key: ("\n".join(recorded[key]).strip() or "unknown (recorded without a value)")
        if key in recorded else "unknown (not recorded)"
        for key in FIELDS
    }


def list_issues(repo):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("repo must be OWNER/REPO")
    listing = ('[.[] | select(type == "object") | select(has("pull_request") | not) | '
               '{number, title, html_url, ' + body_fields('.body // ""') + "}]")
    issues, page = [], 1
    while page <= MAX_PAGES:
        batch = sq_gh_json(["api", f"/repos/{repo}/issues?state=all&per_page={PAGE_SIZE}&page={page}",
                            "--jq", listing])
        if not isinstance(batch, list):
            raise ValueError("issue listing did not return a list of issues")
        for issue in batch:
            if not isinstance(issue, dict):
                raise ValueError("issue listing returned an entry that is not an issue object")
        issues.extend(batch)
        if len(batch) < PAGE_SIZE:
            return issues
        page += 1
    raise ValueError(f"issue listing for {repo} exceeded {MAX_PAGES} pages")


def report(repo):
    found = []
    for issue in list_issues(repo):
        fields = extract(joined_body(issue))
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
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        detail = getattr(exc, "stderr", "")
        print(f"error: {str(exc)}{(': ' + detail.strip()) if detail else ''}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
