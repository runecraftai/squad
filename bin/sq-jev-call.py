#!/usr/bin/env python3
"""Shadow-only Jev recommendation client; never used to resolve dispatch."""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import threading
import http.client
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_URL = "https://api.typesafe.ai/v1/systemone"
MAX_TEXT = 240
MAX_RESPONSE = 65536
DEADLINE_SECONDS = 3


KNOWN_NAMES = ("claude", "codex", "gemini", "sonnet", "opus", "haiku", "gpt")


def redact(value, names=()):
    home = os.path.expanduser("~")
    if home and home != "/":
        value = value.replace(home, "~")
    value = value.replace("$HOME", "~")
    patterns = [
        (r"(?i)(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{8,}", "[REDACTED]"),
        (r"ghp_[A-Za-z0-9]{8,}", "[REDACTED]"),
        (r"AKIA[A-Z0-9]{16}[A-Za-z0-9]*", "[REDACTED]"),
        (r"eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*", "[REDACTED]"),
        (r"-----BEGIN [^-]*KEY(?: BLOCK)?-----.*?(?:-----END [^-]*KEY(?: BLOCK)?-----|\Z)", "[REDACTED]"),
        (r"(?im)\b[A-Z][A-Z0-9_]{1,}=(\"(?:\\.|[^\"\\])*\"?|'(?:\\.|[^'\\])*'?|\S+)", "[REDACTED]"),
        (r"([A-Za-z][A-Za-z0-9+.-]{0,31}://)\S*@", r"\1[REDACTED]@"),
    ]
    for pattern, replacement in patterns:
        value = re.sub(pattern, replacement, value, flags=re.DOTALL if "BEGIN" in pattern else 0)
    terms = sorted({term for term in set(names) | set(KNOWN_NAMES) if term}, key=len, reverse=True)
    value = re.sub(r"(?i)(?<![A-Za-z0-9])(?:" + "|".join(re.escape(term) for term in terms) + r")(?![A-Za-z0-9])",
                   "[REDACTED]", value)
    return value[:MAX_TEXT]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_with_deadline(request, seconds):
    outcome = {}

    def run():
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=seconds) as response:
                outcome["body"] = response.read(MAX_RESPONSE)
        except BaseException as error:
            outcome["error"] = error

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(seconds)
    if worker.is_alive():
        raise TimeoutError("jev deadline exceeded")
    if "error" in outcome:
        raise outcome["error"]
    return outcome["body"]


def project_enabled(config_path, project):
    try:
        config = json.loads(Path(config_path).read_text())
        enabled = config.get("enabled_projects", [])
        return isinstance(enabled, list) and os.path.realpath(project) in {
            os.path.realpath(item) for item in enabled if isinstance(item, str)
        }
    except (OSError, ValueError, AttributeError):
        return False


def unit_interval(value):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1


def count_tracked_files(project):
    try:
        tracked = subprocess.run(["git", "-C", project, "ls-files", "-z"],
                                 capture_output=True, check=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return len([path for path in tracked.split(b"\0") if path])


def load_lanes(args):
    try:
        if args.lanes_json:
            lanes = json.loads(args.lanes_json)
        else:
            dispatch = json.loads(Path(args.project_config).read_text())
            profiles = []
            for rule in dispatch.get("rules", []):
                use = rule.get("use", [])
                profiles.extend(use if isinstance(use, list) else [use])
            default = dispatch.get("default", [])
            profiles.extend(default if isinstance(default, list) else [default])
            lanes = {"/".join(str(profile.get(key, "default")) for key in ("harness", "model"))
                     for profile in profiles if isinstance(profile, dict) and profile.get("harness")}
    except (OSError, ValueError, AttributeError):
        return set()
    return set(lanes) if isinstance(lanes, (dict, set)) else set()


def classify(answer, lanes):
    if not isinstance(answer, dict) or answer.get("type") != "choice":
        return {"status": "unavailable", "reason": "invalid_response"}
    choice = answer.get("choice")
    if not isinstance(choice, str) or choice not in lanes:
        return {"status": "unavailable", "reason": "no_lane_match"}
    event = {"status": "recommended", "choice": choice}
    if unit_interval(answer.get("confidence")):
        event["confidence"] = answer["confidence"]
    probabilities = answer.get("probabilities")
    if isinstance(probabilities, dict):
        event["probabilities"] = {name: value for name, value in probabilities.items()
                                  if name in lanes and unit_interval(value)}
    return event


def record(args, event):
    env = os.environ.copy()
    env.pop("TYPESAFE_API_KEY", None)
    env["SQUAD_DATA_OVERRIDE"] = args.data
    env["SQUAD_RECOMMENDATION_JSON"] = json.dumps({"label": "recommendation", **event})
    logged = subprocess.run([str(Path(__file__).with_name("sq-dispatch-log.sh")),
                             args.id, "recommendation"], check=True,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
    if logged.stderr:
        raise OSError("recommendation not recorded")


def finish(args, event):
    try:
        record(args, event)
    except (OSError, subprocess.SubprocessError):
        print(json.dumps({"status": "error"}))
        return 0
    print(json.dumps({name: event[name] for name in ("status", "choice", "reason") if name in event}))
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--task-type", required=True)
    parser.add_argument("--title", default="")
    parser.add_argument("--description", default="")
    parser.add_argument("--brief")
    parser.add_argument("--project-config", default="config/crew-dispatch.json")
    parser.add_argument("--file-count", type=int)
    parser.add_argument("--lanes-json", help="JSON object mapping allowed lane ids to descriptions")
    parser.add_argument("--config", default=os.path.join(os.environ.get("SQUAD_CONFIG_OVERRIDE", "config"), "jev-dispatch.json"))
    parser.add_argument("--data", default=os.environ.get("SQUAD_DATA_OVERRIDE", "data"))
    parser.add_argument("--url", default=os.environ.get("SQUAD_JEV_URL_OVERRIDE", API_URL), help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.dry_run and not project_enabled(args.config, args.project):
        print(json.dumps({"status": "disabled"}))
        return 0
    key = os.environ.get("TYPESAFE_API_KEY")
    if not key and not args.dry_run:
        print(json.dumps({"status": "missing_key"}))
        return 0
    if args.brief:
        try:
            lines = Path(args.brief).read_text(errors="replace").splitlines()
            heading = next((line.lstrip("# ").strip() for line in lines if line.startswith("# ")), "")
            paragraph = " ".join(line.strip() for line in lines if line.strip() and not line.startswith("#"))
            args.title = args.title or heading
            args.description = args.description or paragraph
        except OSError:
            pass
    lanes = load_lanes(args)
    names = {part for lane in lanes for part in lane.split("/")}
    file_count = args.file_count if args.file_count is not None else count_tracked_files(args.project)
    projection = {
        "task_type": redact(args.task_type, names),
        "title": redact(args.title, names),
        "description": redact(args.description, names),
        "file_count": file_count,
    }
    payload = {
        "type": "choice",
        "instructions": "Recommend the best-fitting lane for this task. Task projection: "
        + json.dumps(projection, ensure_ascii=True, separators=(",", ":")),
    }
    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))
        return 0
    if not lanes:
        return finish(args, {"status": "unavailable", "reason": "no_lanes"})
    if file_count is None:
        return finish(args, {"status": "unavailable", "reason": "file_count_unmeasured"})
    parsed_url = urllib.parse.urlparse(args.url)
    if args.url != API_URL and parsed_url.hostname not in ("127.0.0.1", "localhost", "::1"):
        print(json.dumps({"status": "error"}))
        return 0
    request = urllib.request.Request(
        args.url, data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        event = classify(json.loads(fetch_with_deadline(request, DEADLINE_SECONDS)), lanes)
    except (urllib.error.URLError, http.client.HTTPException, TimeoutError, ValueError, OSError):
        event = {"status": "unavailable", "reason": "service_error"}
    return finish(args, event)


if __name__ == "__main__":
    raise SystemExit(main())
