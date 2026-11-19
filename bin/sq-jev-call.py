#!/usr/bin/env python3
"""Shadow-only Jev recommendation client; never used to resolve dispatch.

Posts the documented System One request shape - a `model`, a `state` object with
named `task` and `repository` fields, and a map of keyed questions - and records the
answer as evidence instead of a decision.

One `choice` question keyed `lane` carries criteria that describe what each
configured lane fits and what belongs to another lane, using only approved
criteria selected by effort, opaque option IDs, and a reserved `other` option.
A second `noul` question records whether the task needs design decisions a fixed
plan cannot settle; it never selects the lane.

The recorded recommendation keeps the chosen lane, its confidence, the full
probability map, the per-question answers and the model version the service
reported, and adds `low_confidence: true` under LOW_CONFIDENCE_THRESHOLD (0.5).
A low-confidence answer is still recorded and still has no authority.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sq_dispatch_evidence import (DESIGN_KEY, EMAIL_ADDRESS, MAX_RESPONSE, QUESTION_KEY, URL_USERINFO,  # noqa: E402
                                  recordable_answer, recordable_reason, recordable_text, unit_interval)

API_URL = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
OTHER_OPTION = "other"
LANE_INSTRUCTIONS = ("Choose the option whose criteria best match the task's difficulty, "
                     "risk and need for design judgment.")
DESIGN_INSTRUCTIONS = "Does this task need design decisions that a fixed plan cannot settle?"
LOW_CONFIDENCE_THRESHOLD = 0.5
TASK_TYPES = frozenset({"strike", "recon", "xo", "feature"})
MAX_TEXT = 240
DEADLINE_SECONDS = 3


KNOWN_NAMES = ("claude", "codex", "gemini", "sonnet", "opus", "haiku", "gpt", "grok", "llama", "mistral",
               "deepseek", "qwen", "pi", "cursor", "aider", "copilot", "opencode", "kimi", "muse")


def redact(value, names=(), secret=None, *, lane_id=False):
    if secret:
        value = value.replace(secret, "[REDACTED]")
    home = os.path.expanduser("~")
    if home and home != "/":
        value = value.replace(home, "~")
    value = value.replace("$HOME", "~")
    patterns = [
        (r"(?i)(?<![A-Za-z0-9])(?:sk|pk)[-_][A-Za-z0-9_-]{8,}", "[REDACTED]"),
        (r"(?<![A-Za-z0-9])(?:gh[pousr]_|glpat-)[A-Za-z0-9_-]{8,}", "[REDACTED]"),
        (r"github_pat_[A-Za-z0-9_]{8,}", "[REDACTED]"),
        (r"xox[abprs]-[A-Za-z0-9-]{8,}", "[REDACTED]"),
        (r"AIza[0-9A-Za-z_-]{20,}", "[REDACTED]"),
        (r"(?i)\bbearer\s+\S+", "[REDACTED]"),
        (r"AKIA[A-Z0-9]{16}[A-Za-z0-9]*", "[REDACTED]"),
        (r"eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*", "[REDACTED]"),
        (r"-----BEGIN [^-]*KEY(?: BLOCK)?-----.*?(?:-----END [^-]*KEY(?: BLOCK)?-----|\Z)", "[REDACTED]"),
        (URL_USERINFO.pattern, r"\1[REDACTED]@"),
        (EMAIL_ADDRESS.pattern, "[REDACTED]"),
        (r"(?im)\b[A-Z][A-Z0-9_]{1,}=(\"(?:\\.|[^\"\\])*\"?|'(?:\\.|[^'\\])*'?|\S+)", "[REDACTED]"),
        (r"(?i)\b(?:token|secret|passwd|password|api[_-]?key|credential)s?\s*[=:]\s*"
         r"(?:\"(?:\\.|[^\"\\])*\"?|'(?:\\.|[^'\\])*'?|\S+)", "[REDACTED]"),
        (r"(?<![A-Za-z0-9_+/])(?!(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})(?![A-Za-z0-9_+/]))[A-Za-z0-9_+/]{32,}",
         "[REDACTED]"),
    ]
    for pattern, replacement in patterns:
        value = re.sub(pattern, replacement, value, flags=re.DOTALL if "BEGIN" in pattern else 0)
    terms = sorted(set(names) - {""} | (set() if lane_id else set(KNOWN_NAMES)), key=len, reverse=True)
    alternatives = [re.escape(term) for term in terms]
    if not lane_id:
        alternatives.append(r"o[0-9]")
    if alternatives:
        value = re.sub(r"(?i)(?<![A-Za-z0-9])(?:" + "|".join(alternatives) + r")"
                       r"(?:[._-]?[0-9][A-Za-z0-9]*|[._-][A-Za-z0-9]+|"
                       r"[ \t]+[0-9][A-Za-z0-9._+-]*(?:[ \t]+(?:pro|flash|thinking|preview|nano|mini))?)*(?![A-Za-z0-9])",
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
    except (OSError, ValueError, AttributeError, RecursionError):
        return False


FILE_EXTENSIONS = (".bash", ".c", ".cc", ".cpp", ".cs", ".ex", ".exs", ".go", ".h", ".hpp",
                   ".java", ".js", ".jsx", ".kt", ".lua", ".md", ".mjs", ".php", ".py", ".r",
                   ".rb", ".rs", ".scala", ".sh", ".sql", ".swift", ".ts", ".tsx", ".txt", ".zsh")


def names_tests(files):
    for path in files:
        if path.split("/")[0] in ("tests", "test", "__tests__"):
            return True
        name = path.rsplit("/", 1)[-1]
        if name.startswith("test_") or ".test." in name or ".spec." in name:
            return True
    return False


def project_facts(project):
    """One tracked-file read for the repository fields the state carries."""
    try:
        tracked = subprocess.run(["git", "-C", project, "ls-files", "-z"],
                                 capture_output=True, check=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    files = [path.decode("utf-8", "replace") for path in tracked.split(b"\0") if path]
    counts = Counter(os.path.splitext(path)[1].lower() for path in files)
    return {
        "tracked_files": len(files),
        "extension_counts": {ext: counts[ext] for ext in FILE_EXTENSIONS if counts[ext]},
        "has_tests": names_tests(files),
        "has_docs": any(path.lower().startswith(("docs/", "doc/", "readme.", "readme/"))
                        or path.lower() == "readme" for path in files),
    }


def load_lanes(args, secret):
    lanes = {}
    explicit_accounts = set()
    try:
        if args.lanes_json:
            configured = json.loads(args.lanes_json)
            for lane in (configured if isinstance(configured, dict) else ()):
                lanes[lane] = {""}
                parts = lane.split("/", 2)
                if len(parts) == 3:
                    explicit_accounts.add(parts[2])
        else:
            dispatch = json.loads(Path(args.project_config).read_text())
            profiles = []
            for rule in dispatch.get("rules", []):
                use = rule.get("use", [])
                profiles.extend(use if isinstance(use, list) else [use])
            default = dispatch.get("default", [])
            profiles.extend(default if isinstance(default, list) else [default])
            for profile in profiles:
                if not isinstance(profile, dict) or not profile.get("harness"):
                    continue
                lane = "/".join(str(profile.get(key, "default")) for key in ("harness", "model"))
                effort = profile.get("effort")
                efforts = lanes.setdefault(lane, set())
                efforts.add(effort.strip().lower() if isinstance(effort, str) else "")
    except (OSError, ValueError, TypeError, AttributeError, RecursionError):
        lanes = {}
    return {lane: efforts for lane, efforts in lanes.items()
            if lane != OTHER_OPTION and recordable_text(lane, secret)
            and redact(lane, explicit_accounts, secret, lane_id=True) == lane}


def lane_criteria(option, efforts, approved):
    variants = [approved["efforts"].get(effort, approved["default"]) for effort in sorted(efforts)]
    fits = dict.fromkeys(variant["fits"] for variant in variants)
    exclusions = {variant["not_for"] for variant in variants}
    not_for = exclusions.pop() if len(exclusions) == 1 else approved["mixed_not_for"]
    return {"fits": " or ".join(fits) + f", for option {option}",
            "not_for": f"{not_for}, for option {option}"}


def response_integer(token):
    return int(token) if len(token) <= 64 else float(token)


def classify(body, options, secret=None):
    answers = body.get("answers") if isinstance(body, dict) else None
    if not isinstance(answers, dict):
        return {"status": "unavailable", "reason": "invalid_response"}
    if QUESTION_KEY not in answers:
        return {"status": "unavailable", "reason": "answer_missing"}
    answer = answers[QUESTION_KEY]
    if not isinstance(answer, dict) or answer.get("type") != "choice":
        return {"status": "unavailable", "reason": "invalid_response"}
    option = answer.get("choice")
    if not isinstance(option, str) or option not in options:
        return {"status": "unavailable", "reason": "no_lane_match"}
    choice = options[option]
    event = {"status": "recommended", "choice": choice}
    confidence = answer.get("confidence")
    if unit_interval(confidence):
        event["confidence"] = confidence
        if confidence < LOW_CONFIDENCE_THRESHOLD:
            event["low_confidence"] = True
    recorded = {}
    lane_evidence = recordable_answer(answer, secret)
    lane_evidence["choice"] = choice
    offered = {**options, OTHER_OPTION: OTHER_OPTION}
    probabilities = {offered[key]: score for key, score in lane_evidence.pop("probabilities", {}).items()
                     if key in offered and recordable_text(offered[key], secret)}
    if probabilities:
        lane_evidence["probabilities"] = event["probabilities"] = probabilities
    recorded[QUESTION_KEY] = lane_evidence
    design = recordable_answer(answers.get(DESIGN_KEY), secret)
    if design is not None:
        design.pop("probabilities", None)
    if design:
        recorded[DESIGN_KEY] = design
    if recorded:
        event["answers"] = recorded
    model = body.get("model")
    if recordable_text(model, secret):
        event["model"] = model
    return event


def record(args, event):
    env = os.environ.copy()
    secret = env.pop("TYPESAFE_API_KEY", None)
    if event["status"] == "unavailable" and not recordable_reason(event["reason"], secret):
        raise OSError("invalid recommendation reason")
    env["SQUAD_DATA_OVERRIDE"] = args.data
    env.pop("SQUAD_RECOMMENDATION_JSON", None)
    payload = json.dumps({"label": "recommendation", **event}, separators=(",", ":"))
    logged = subprocess.run([str(Path(__file__).with_name("sq-dispatch-log.sh")),
                             args.id, "recommendation", "--stdin"], check=True, input=payload.encode(),
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
    parser.add_argument("--lanes-json", help="JSON object keyed by allowed lane IDs; values are ignored")
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
        return finish(args, {"status": "unavailable", "reason": "missing_key"})
    lanes = load_lanes(args, key)
    facts = project_facts(args.project) or {
        "tracked_files": None, "extension_counts": {}, "has_tests": False, "has_docs": False,
    }
    if args.file_count is not None and args.file_count >= 0:
        facts["tracked_files"] = args.file_count
    projection = {
        "task": {"type": args.task_type if args.task_type in TASK_TYPES else "unknown"},
        "repository": facts,
    }
    options = {f"o{number}": lane for number, lane in enumerate(sorted(lanes), 1)}
    approved = json.loads(Path(__file__).resolve().with_name("sq-jev-criteria.v1.json").read_text())
    criteria = {option: lane_criteria(option, lanes[lane], approved) for option, lane in options.items()}
    criteria[OTHER_OPTION] = {field: approved["other"][field] for field in ("fits", "not_for")}
    payload = {
        "state": projection,
        "model": MODEL,
        "questions": {
            QUESTION_KEY: {"type": "choice", "instructions": LANE_INSTRUCTIONS, "criteria": criteria},
            DESIGN_KEY: {"type": "noul", "instructions": DESIGN_INSTRUCTIONS},
        },
    }
    body = json.dumps(payload, ensure_ascii=True, separators=(",", ":"))
    if args.dry_run:
        print(body)
        return 0
    if not lanes:
        return finish(args, {"status": "unavailable", "reason": "no_lanes"})
    if facts["tracked_files"] is None:
        return finish(args, {"status": "unavailable", "reason": "file_count_unmeasured"})
    parsed_url = urllib.parse.urlparse(args.url)
    if args.url != API_URL and parsed_url.hostname not in ("127.0.0.1", "localhost", "::1"):
        return finish(args, {"status": "unavailable", "reason": "endpoint_refused"})
    request = urllib.request.Request(
        args.url, data=body.encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        response = json.loads(fetch_with_deadline(request, DEADLINE_SECONDS), parse_int=response_integer)
        event = classify(response, options, key)
    except Exception:
        event = {"status": "unavailable", "reason": "service_error"}
    return finish(args, event)


if __name__ == "__main__":
    raise SystemExit(main())
