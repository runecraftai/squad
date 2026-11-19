#!/usr/bin/env python3
"""Shadow-only Jev recommendation client; never used to resolve dispatch.

Posts the documented System One request shape - a `model`, a `state` object with
named `task` and `repository` fields, and a map of keyed questions - and records the
answer as evidence instead of a decision.

One `choice` question keyed `lane` carries criteria that describe what each
configured lane fits and what belongs to another lane, taken from the lane's own
description when it has one, otherwise from its configured effort and lane
identity, and otherwise from its harness, model and account, plus a reserved
`other` option so a mismatch is an answer instead of a forced choice.
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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sq_dispatch_evidence import (recordable_answer, recordable_probabilities,  # noqa: E402
                                  recordable_text, unit_interval)

API_URL = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
QUESTION_KEY = "lane"
DESIGN_KEY = "needs_design_decision"
OTHER_OPTION = "other"
LANE_INSTRUCTIONS = ("Choose the one lane whose harness, model and effort best match "
                     "this task's difficulty, risk and need for design judgment.")
DESIGN_INSTRUCTIONS = "Does this task need design decisions that a fixed plan cannot settle?"
LOW_CONFIDENCE_THRESHOLD = 0.5
MAX_TOP_LEVEL = 24
MAX_TEXT = 240
MAX_RESPONSE = 65536
DEADLINE_SECONDS = 3


KNOWN_NAMES = ("claude", "codex", "gemini", "sonnet", "opus", "haiku", "gpt", "grok", "llama", "mistral",
               "deepseek", "qwen", "pi", "cursor", "aider", "copilot", "opencode", "kimi", "muse")


def redact(value, names=()):
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
        (r"([A-Za-z][A-Za-z0-9+.-]{0,31}://)\S*@", r"\1[REDACTED]@"),
        (r"(?im)\b[A-Z][A-Z0-9_]{1,}=(\"(?:\\.|[^\"\\])*\"?|'(?:\\.|[^'\\])*'?|\S+)", "[REDACTED]"),
        (r"(?i)\b(?:token|secret|passwd|password|api[_-]?key|credential)s?\s*[=:]\s*"
         r"(?:\"(?:\\.|[^\"\\])*\"?|'(?:\\.|[^'\\])*'?|\S+)", "[REDACTED]"),
        (r"(?<![A-Za-z0-9_+/])(?!(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})(?![A-Za-z0-9_+/]))[A-Za-z0-9_+/]{32,}",
         "[REDACTED]"),
    ]
    for pattern, replacement in patterns:
        value = re.sub(pattern, replacement, value, flags=re.DOTALL if "BEGIN" in pattern else 0)
    terms = sorted({term for term in set(names) | set(KNOWN_NAMES) if term}, key=len, reverse=True)
    alternatives = [re.escape(term) for term in terms] + [r"o[0-9]"]
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


LANGUAGES = {".py": "Python", ".ts": "TypeScript", ".tsx": "TypeScript", ".js": "JavaScript",
             ".jsx": "JavaScript", ".mjs": "JavaScript", ".go": "Go", ".rs": "Rust", ".rb": "Ruby",
             ".java": "Java", ".kt": "Kotlin", ".swift": "Swift", ".c": "C", ".h": "C",
             ".cc": "C++", ".cpp": "C++", ".hpp": "C++", ".cs": "C#", ".php": "PHP",
             ".sh": "Shell", ".bash": "Shell", ".zsh": "Shell", ".ex": "Elixir", ".exs": "Elixir",
             ".scala": "Scala", ".lua": "Lua", ".sql": "SQL", ".r": "R"}


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
    counts = {}
    directories = set()
    for path in files:
        parts = path.split("/")
        if len(parts) > 1 and not parts[0].startswith("."):
            directories.add(parts[0])
        language = LANGUAGES.get(os.path.splitext(path)[1].lower())
        if language:
            counts[language] = counts.get(language, 0) + 1
    return {
        "tracked_files": len(files),
        "top_level": sorted(directories)[:MAX_TOP_LEVEL],
        "has_tests": names_tests(files),
        "language": min(counts, key=lambda name: (-counts[name], name)) if counts else None,
    }


def load_lanes(args):
    """Allowed lanes mapped to their configured description, effort and identity."""
    lanes = {}
    try:
        if args.lanes_json:
            configured = json.loads(args.lanes_json)
            for lane, description in (configured.items() if isinstance(configured, dict) else ()):
                if not isinstance(lane, str) or not lane:
                    continue
                text = description.strip() if isinstance(description, str) else ""
                parts = lane.split("/")
                lanes[lane] = {"description": text if text and text != lane else "", "effort": "",
                               "harness": parts[0], "model": parts[1] if len(parts) > 1 else "",
                               "account": parts[2] if len(parts) > 2 else ""}
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
                account = profile.get("account")
                lanes[lane] = {"description": "",
                               "effort": effort.strip().lower() if isinstance(effort, str) else "",
                               "harness": str(profile.get("harness", "")),
                               "model": str(profile.get("model", "")),
                               "account": account.strip() if isinstance(account, str) else ""}
    except (OSError, ValueError, AttributeError, RecursionError):
        return {}
    return lanes


NEUTRAL_CRITERIA = {"fits": "a task whose difficulty, risk and reasoning depth match this configured lane",
                    "not_for": "a task that another listed lane matches more closely"}
EFFORT_CRITERIA = {
    "low": {"fits": "a well-understood, mechanical change whose steps a short plan already settles",
            "not_for": "a change that needs careful reasoning or spans unfamiliar code"},
    "medium": {"fits": "a routine change with some ambiguity, where breadth matters more than depth",
               "not_for": "a small mechanical change, or an unusually hard and risky one"},
    "high": {"fits": "a demanding or ambiguous change that needs careful reasoning across several files",
             "not_for": "a small mechanical change where speed matters more than depth"},
    "xhigh": {"fits": "a hard, open-ended change that needs the deepest reasoning a lane can offer",
              "not_for": "a small mechanical change where speed matters more than depth"},
    "max": {"fits": "a hard, open-ended change that needs the deepest reasoning a lane can offer",
            "not_for": "a small mechanical change where speed matters more than depth"},
}


def lane_criteria(lane, configured):
    description = configured.get("description", "")
    effort = configured.get("effort", "")
    if description:
        return {"fits": description, "not_for": "a task that another listed lane covers"}
    if effort:
        base = EFFORT_CRITERIA.get(effort, NEUTRAL_CRITERIA)
        return {"fits": f"{base['fits']}, run as lane {lane} at {effort} effort",
                "not_for": f"{base['not_for']}, or a task that another lane than {lane} matches"}
    identity = ", ".join(part for part in (
        f"harness {configured['harness']}" if configured.get("harness") else "",
        f"model {configured['model']}" if configured.get("model") else "",
        f"account {configured['account']}" if configured.get("account") else "") if part)
    return {"fits": f"a task whose difficulty and risk suit lane {lane}, configured as "
                     f"{identity or 'its harness and model'}",
            "not_for": f"a task that another listed lane, rather than {lane}, handles better"}


def answer_evidence(answer):
    """The bounded per-question fields worth recording, normalized to what the writer accepts."""
    return recordable_answer(answer) or None


def response_integer(token):
    return int(token) if len(token) <= 64 else float(token)


def classify(body, lanes):
    answers = body.get("answers") if isinstance(body, dict) else None
    if not isinstance(answers, dict):
        return {"status": "unavailable", "reason": "invalid_response"}
    answer = answers.get(QUESTION_KEY)
    if answer is None:
        return {"status": "unavailable", "reason": "answer_missing"}
    if not isinstance(answer, dict) or answer.get("type") != "choice":
        return {"status": "unavailable", "reason": "invalid_response"}
    choice = answer.get("choice")
    if not isinstance(choice, str) or choice not in lanes:
        return {"status": "unavailable", "reason": "no_lane_match"}
    event = {"status": "recommended", "choice": choice}
    confidence = answer.get("confidence")
    if unit_interval(confidence):
        event["confidence"] = confidence
        if confidence < LOW_CONFIDENCE_THRESHOLD:
            event["low_confidence"] = True
    probabilities = answer.get("probabilities")
    if isinstance(probabilities, dict):
        kept = recordable_probabilities(probabilities)
        if kept:
            event["probabilities"] = kept
    recorded = {}
    lane_evidence = answer_evidence(answer)
    if lane_evidence is not None:
        recorded[QUESTION_KEY] = lane_evidence
    design = answer_evidence(answers.get(DESIGN_KEY))
    if design is not None:
        recorded[DESIGN_KEY] = design
    if recorded:
        event["answers"] = recorded
    model = body.get("model")
    if recordable_text(model):
        event["model"] = model
    return event


def record(args, event):
    env = os.environ.copy()
    env.pop("TYPESAFE_API_KEY", None)
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
        return finish(args, {"status": "unavailable", "reason": "missing_key"})
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
    facts = project_facts(args.project) or {}
    tracked_files = args.file_count if args.file_count is not None else facts.get("tracked_files")
    projection = {
        "task": {
            "type": redact(args.task_type, names),
            "title": redact(args.title, names),
            "description": redact(args.description, names),
        },
        "repository": {
            "tracked_files": tracked_files,
            "top_level": [redact(name, names) for name in facts.get("top_level", [])],
            "has_tests": facts.get("has_tests"),
            "language": facts.get("language"),
        },
    }
    criteria = {lane: lane_criteria(lane, configured) for lane, configured in sorted(lanes.items())}
    criteria[OTHER_OPTION] = {"fits": "none of these lanes fits the task",
                              "not_for": "a task that one of the listed lanes covers"}
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
    if tracked_files is None:
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
        event = classify(response, lanes)
    except Exception:
        event = {"status": "unavailable", "reason": "service_error"}
    return finish(args, event)


if __name__ == "__main__":
    raise SystemExit(main())
