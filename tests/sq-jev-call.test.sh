#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 - "$ROOT" <<'PY'
import http.server
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("jev", root / "bin/sq-jev-call.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
QUESTION = "lane"
DESIGN = "needs_design_decision"
LANES = {"claude/sonnet": "deep reasoning over large diffs",
         "pi/gpt": "fast mechanical edits"}
CRITERIA = {lane: {"fits": text, "not_for": "a task that another listed lane covers"}
            for lane, text in LANES.items()}
CRITERIA["other"] = {"fits": "none of these lanes fits the task",
                     "not_for": "a task that one of the listed lanes covers"}
LANE_INSTRUCTIONS = ("Choose the one lane whose harness, model and effort best match this task's "
                     "difficulty, risk and need for design judgment.")
DESIGN_INSTRUCTIONS = "Does this task need design decisions that a fixed plan cannot settle?"
DESIGN_ANSWER = {"type": "noul", "answer": True, "confidence": .7}


def answer(choice, **extra):
    return {"answers": {QUESTION: {"type": "choice", "choice": choice, **extra}}}


def expected_body(description, tracked_files):
    return {"state": {"task": {"type": "feature", "title": "title", "description": description},
                       "repository": {"tracked_files": tracked_files, "top_level": [],
                                      "has_tests": None, "language": None}},
            "model": "jev-latest",
            "questions": {QUESTION: {"type": "choice", "instructions": LANE_INSTRUCTIONS,
                                     "criteria": CRITERIA},
                          DESIGN: {"type": "noul", "instructions": DESIGN_INSTRUCTIONS}}}


OK_REPLY = {"answers": {QUESTION: {"type": "choice", "choice": "claude/sonnet", "confidence": .8,
                                   "probabilities": {"claude/sonnet": .8, "pi/gpt": .2}},
                         DESIGN: DESIGN_ANSWER},
            "model": "jev-2026-05"}


def serve(record, state):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            record["path"] = self.path
            record["auth"] = self.headers.get("Authorization")
            record["body"] = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if state.get("location"):
                self.send_response(302)
                self.send_header("Location", state["location"])
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps(state["reply"]).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def recorded_rows(data):
    path = data / "task/dispatch.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    return [{key: value for key, value in row.items() if key != "timestamp"} for row in rows]


with tempfile.TemporaryDirectory() as td:
    base = pathlib.Path(td)
    project = base / "project"
    project.mkdir()
    config = base / "jev.json"
    data = base / "data"
    config.write_text(json.dumps({"enabled_projects": [str(project)]}))
    captured = {}
    redirected = {}
    state = {"reply": OK_REPLY}
    server = serve(captured, state)
    target = serve(redirected, {"reply": OK_REPLY})
    url = f"http://127.0.0.1:{server.server_port}/v1/systemone"
    argv = [sys.executable, str(root / "bin/sq-jev-call.py"), "--id", "task",
            "--project", str(project), "--task-type", "feature", "--title", "title",
            "--description", "$HOME/private sk-abcd1234567890 ghp_abcdefgh AKIA1234567890ABCDEF "
            "eyJabc.def.ghi https://user:pass@example.invalid KEY=value", "--file-count", "3",
            "--lanes-json", json.dumps(LANES),
            "--config", str(config), "--data", str(data), "--url", url]
    env = {**os.environ, "TYPESAFE_API_KEY": "runtime-test-key"}

    def argv_for(path):
        return [str(path) if arg == str(project) else arg for arg in argv]

    try:
        config.write_text('{"enabled_projects":[]}')
        disabled = subprocess.run(argv, text=True, capture_output=True, env=env)
        assert json.loads(disabled.stdout) == {"status": "disabled"}
        assert not captured and not (data / "task/dispatch.jsonl").exists()
        other = base / "other"
        other.mkdir()
        config.write_text(json.dumps({"enabled_projects": [str(project)]}))
        unlisted = subprocess.run(argv_for(other), text=True, capture_output=True, env=env)
        assert json.loads(unlisted.stdout) == {"status": "disabled"}
        assert not captured and not (data / "task/dispatch.jsonl").exists()
        config.unlink()
        absent = subprocess.run(argv, text=True, capture_output=True, env=env)
        assert json.loads(absent.stdout) == {"status": "disabled"}
        assert not captured and not (data / "task/dispatch.jsonl").exists()
        config.write_text(json.dumps({"enabled_projects": [str(project)]}))
        missing = subprocess.run(argv, text=True, capture_output=True, check=True,
                                 env={k: v for k, v in os.environ.items() if k != "TYPESAFE_API_KEY"})
        assert json.loads(missing.stdout) == {"status": "unavailable", "reason": "missing_key"}
        assert not captured and recorded_rows(data) == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "unavailable", "reason": "missing_key"}]
        (data / "task/dispatch.jsonl").unlink()
        description = ("~/private [REDACTED] [REDACTED] [REDACTED] [REDACTED] "
                       "https://[REDACTED]@example.invalid [REDACTED]")
        dry = subprocess.run(argv + ["--dry-run"], text=True, capture_output=True)
        payload = json.loads(dry.stdout)
        assert payload == expected_body(description, 3)
        assert set(payload) == {"state", "model", "questions"}
        assert not captured
        config.write_text('{"enabled_projects":[]}')
        dry_opt_out = subprocess.run(argv + ["--dry-run"], text=True, capture_output=True, check=True)
        assert json.loads(dry_opt_out.stdout) == payload
        assert not captured and not (data / "task/dispatch.jsonl").exists()
        config.write_text(json.dumps({"enabled_projects": [str(project)]}))

        def recorded():
            return recorded_rows(data)

        state["location"] = f"http://localhost:{target.server_port}/v1/systemone"
        redirect = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(redirect.stdout) == {"status": "unavailable", "reason": "service_error"}
        assert not redirected and recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "unavailable", "reason": "service_error"}]
        (data / "task/dispatch.jsonl").unlink()
        state["location"] = None

        captured.clear()
        state["reply"] = answer(["claude/sonnet"], confidence=.8)
        unhashable = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(unhashable.stdout) == {"status": "unavailable", "reason": "no_lane_match"}
        assert unhashable.stderr == "" and recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "unavailable", "reason": "no_lane_match"}]
        (data / "task/dispatch.jsonl").unlink()
        captured.clear()
        state["reply"] = answer("claude/sonnet")
        bare = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(bare.stdout) == {"status": "recommended", "choice": "claude/sonnet"}
        assert recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "recommended", "choice": "claude/sonnet",
             "answers": {QUESTION: {"type": "choice", "choice": "claude/sonnet"}}}]
        (data / "task/dispatch.jsonl").unlink()
        state["reply"] = answer("other")
        unmatched = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(unmatched.stdout) == {"status": "unavailable", "reason": "no_lane_match"}
        assert unmatched.stderr == "" and recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "unavailable", "reason": "no_lane_match"}]
        (data / "task/dispatch.jsonl").unlink()
        # A documented answer shape: a flat two-way split and low confidence.
        state["reply"] = {"answers": {QUESTION: {"type": "choice", "choice": "claude/sonnet",
                                                  "confidence": .22,
                                                  "probabilities": {"claude/sonnet": .61, "pi/gpt": .39}}}}
        flat = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(flat.stdout) == {"status": "recommended", "choice": "claude/sonnet"}
        assert recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "recommended", "choice": "claude/sonnet", "confidence": .22,
             "low_confidence": True,
             "probabilities": {"claude/sonnet": .61, "pi/gpt": .39},
             "answers": {QUESTION: {"type": "choice", "choice": "claude/sonnet", "confidence": .22,
                                     "probabilities": {"claude/sonnet": .61, "pi/gpt": .39}}}}]
        (data / "task/dispatch.jsonl").unlink()
        state["reply"] = {"answers": {DESIGN: DESIGN_ANSWER}}
        judgment_only = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(judgment_only.stdout) == {"status": "unavailable", "reason": "answer_missing"}
        assert recorded()[0]["reason"] == "answer_missing"
        (data / "task/dispatch.jsonl").unlink()
        state["reply"] = answer("strong", confidence=.22, probabilities={"strong": .61, "cheap": .39})
        unrecognised = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(unrecognised.stdout) == {"status": "unavailable", "reason": "no_lane_match"}
        assert unrecognised.stderr == "" and recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "unavailable", "reason": "no_lane_match"}]
        (data / "task/dispatch.jsonl").unlink()
        for malformed, reason in (
                ({"status": "ok"}, "invalid_response"),
                ({"answers": []}, "invalid_response"),
                ({"answers": {}}, "answer_missing"),
                ({"answers": {"other": {"type": "choice", "choice": "claude/sonnet"}}},
                 "answer_missing"),
                ({"answers": {QUESTION: "claude/sonnet"}}, "invalid_response"),
                ({"answers": {QUESTION: {"type": "ranking", "choice": "claude/sonnet"}}},
                 "invalid_response")):
            state["reply"] = malformed
            broken = subprocess.run(argv, text=True, capture_output=True, env=env)
            assert broken.returncode == 0 and broken.stderr == ""
            assert json.loads(broken.stdout) == {"status": "unavailable", "reason": reason}
            assert recorded()[0]["reason"] == reason
            (data / "task/dispatch.jsonl").unlink()
        state["reply"] = answer("claude/sonnet", confidence=.8, padding="x" * 70000)
        oversized = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(oversized.stdout) == {"status": "unavailable", "reason": "service_error"}
        assert recorded()[0]["reason"] == "service_error"
        (data / "task/dispatch.jsonl").unlink()
        state["reply"] = OK_REPLY

        bin_dir = base / "bin"
        bin_dir.mkdir()
        fake_git = bin_dir / "git"
        fake_git.write_text("#!/bin/sh\nexec sleep 30\n")
        fake_git.chmod(0o755)
        no_count = argv[:argv.index("--file-count")] + argv[argv.index("--file-count") + 2:]
        started = time.monotonic()
        slow = subprocess.run(no_count + ["--dry-run"], text=True, capture_output=True, check=True,
                              env={**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"})
        assert time.monotonic() - started < 10
        assert json.loads(slow.stdout) == expected_body(description, None)
        captured.clear()
        unmeasured = subprocess.run(no_count, text=True, capture_output=True, check=True,
                                    env={**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                                         "TYPESAFE_API_KEY": "runtime-test-key"})
        assert json.loads(unmeasured.stdout) == {"status": "unavailable", "reason": "file_count_unmeasured"}
        assert not captured and recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "unavailable", "reason": "file_count_unmeasured"}]
        (data / "task/dispatch.jsonl").unlink()
        no_lanes_argv = [arg for i, arg in enumerate(argv) if i not in (argv.index("--lanes-json"), argv.index("--lanes-json") + 1)]
        no_lanes_argv += ["--project-config", str(base / "absent.json")]
        no_lanes = subprocess.run(no_lanes_argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(no_lanes.stdout) == {"status": "unavailable", "reason": "no_lanes"}
        assert not captured and recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "unavailable", "reason": "no_lanes"}]
        (data / "task/dispatch.jsonl").unlink()
        brief = base / "brief.md"
        brief.write_text("# Port lanes\nMove the sonnet and opus work to codex for this task; use kimi with Gemini 2.5 Pro.\n")
        brief_argv = [arg for i, arg in enumerate(argv) if i not in (argv.index("--description"), argv.index("--description") + 1)]
        brief_argv += ["--brief", str(brief), "--dry-run"]
        briefed = subprocess.run(brief_argv, text=True, capture_output=True, check=True)
        assert json.loads(briefed.stdout) == expected_body(
            "Move the [REDACTED] and [REDACTED] work to [REDACTED] for this task; "
            "use [REDACTED] with [REDACTED].", 3)

        result =subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(result.stdout) == {"status":"recommended","choice":"claude/sonnet"}
        assert captured["path"] == "/v1/systemone" and captured["auth"] == "Bearer runtime-test-key"
        assert captured["body"] == payload
        assert set(captured["body"]) == {"state", "model", "questions"}
        posted = captured["body"]["questions"]
        assert posted[QUESTION]["type"] == "choice" and posted[QUESTION]["criteria"] == CRITERIA
        assert posted[DESIGN] == {"type": "noul", "instructions": DESIGN_INSTRUCTIONS}
        assert "Task projection" not in posted[QUESTION]["instructions"]
        assert captured["body"]["state"] == {"task": {"type": "feature", "title": "title",
                                                          "description": description},
                                             "repository": {"tracked_files": 3, "top_level": [],
                                                            "has_tests": None, "language": None}}
        rows = [json.loads(line) for line in (data / "task/dispatch.jsonl").read_text().splitlines()]
        assert rows == [{"timestamp": rows[0]["timestamp"], "id":"task", "event":"recommendation",
                         "label":"recommendation", "status":"recommended", "choice":"claude/sonnet", "confidence":.8,
                         "probabilities":{"claude/sonnet":.8,"pi/gpt":.2},
                         "answers": {QUESTION: {"type": "choice", "choice": "claude/sonnet", "confidence": .8,
                                                 "probabilities": {"claude/sonnet": .8, "pi/gpt": .2}},
                                     DESIGN: DESIGN_ANSWER},
                         "model": "jev-2026-05"}]
        evidence_row = {"id": "task", "event": "recommendation", "label": "recommendation",
                        "status": "recommended", "choice": "claude/sonnet", "confidence": .8,
                        "probabilities": {"claude/sonnet": .8, "pi/gpt": .2},
                        "answers": {QUESTION: {"type": "choice", "choice": "claude/sonnet",
                                               "confidence": .8,
                                               "probabilities": {"claude/sonnet": .8, "pi/gpt": .2}},
                                    DESIGN: DESIGN_ANSWER}}
        for rejected_model in ("jev 2026-05", "sk-abcd1234567890"):
            (data / "task/dispatch.jsonl").unlink(missing_ok=True)
            state["reply"] = {**OK_REPLY, "model": rejected_model}
            kept = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
            assert json.loads(kept.stdout) == {"status": "recommended", "choice": "claude/sonnet"}
            assert recorded() == [evidence_row]
        (data / "task/dispatch.jsonl").unlink()
        state["reply"] = answer("claude/sonnet", confidence=.8,
                                notes="arbitrary service text", rationale={"nested": True})
        stripped = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(stripped.stdout) == {"status": "recommended", "choice": "claude/sonnet"}
        assert recorded() == [
            {"id": "task", "event": "recommendation", "label": "recommendation",
             "status": "recommended", "choice": "claude/sonnet", "confidence": .8,
             "answers": {QUESTION: {"type": "choice", "choice": "claude/sonnet",
                                     "confidence": .8}}}]
        final_row = (data / "task/dispatch.jsonl").read_text()
        (data / "task/dispatch.jsonl").unlink()
        state["reply"] = answer("claude/sonnet", confidence=.8,
                                probabilities={"claude/sonnet": .8, "pi/gpt": .1,
                                               "other": .05, "bogus": "high"})
        leak_data = base / "leak"
        leak_argv = argv[:argv.index("--data") + 1] + [str(leak_data)] + argv[argv.index("--data") + 2:]
        leak = subprocess.run(leak_argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(leak.stdout) == {"status":"recommended","choice":"claude/sonnet"}
        leak_rows = [json.loads(line) for line in (leak_data / "task/dispatch.jsonl").read_text().splitlines()]
        assert leak_rows[0]["probabilities"] == {"claude/sonnet": .8, "pi/gpt": .1, "other": .05}
        state["reply"] = OK_REPLY
        assert "runtime-test-key" not in result.stdout + result.stderr + final_row
        assert module.redact("prefix $HOME/secret then sk-abcd1234567890") == "prefix ~/secret then [REDACTED]"
        boundary = module.redact("word " * 46 + " sk-abcd1234567890")
        assert len(boundary) == 240 and "sk-" not in boundary
        assert module.redact("eyJabc.def.") == "[REDACTED]"
        assert module.redact("-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc") == "[REDACTED]"
        assert module.redact("-----BEGIN RSA PRIVATE KEY-----\nMIIabc") == "[REDACTED]"
        assert module.redact('TOKEN="a b" end') == "[REDACTED] end"
        assert module.redact("TOKEN='a b' end") == "[REDACTED] end"
        assert module.redact('TOKEN="abc def') == "[REDACTED]"
        assert module.redact(r'TOKEN="a\"b c" end') == "[REDACTED] end"
        assert module.redact("postgres://user:pa/ss@db") == "postgres://[REDACTED]@db"
        assert module.redact("https://u:p@ss@host") == "https://[REDACTED]@host"
        assert module.redact("postgres://user:pass@db.invalid/app") == "postgres://[REDACTED]@db.invalid/app"
        assert module.redact("redis://:secret@cache.invalid:6379") == "redis://[REDACTED]@cache.invalid:6379"
        assert module.redact("ssh://deploy:pw@host.invalid") == "ssh://[REDACTED]@host.invalid"
        assert module.redact("ftp://anon:pw@files.invalid") == "ftp://[REDACTED]@files.invalid"
        assert module.redact("TOKEN_ghp_abcdefgh12 end") == "TOKEN_[REDACTED] end"
        assert module.redact("xAKIA1234567890ABCDEFx end") == "x[REDACTED] end"
        assert module.redact("Refactor task-management-service for risk-assessment ask-user") == "Refactor task-management-service for risk-assessment ask-user"
        assert module.redact("sk-abcd1234567890 and task-sk-abcd1234567890") == "[REDACTED] and task-[REDACTED]"
        assert module.redact("XeyJX.abc.def end") == "X[REDACTED] end"
        assert module.redact("key sk_live_abcdefgh12 end") == "key [REDACTED] end"
        assert module.redact("password: hunter2 end") == "[REDACTED] end"
        assert module.redact("Token = abc def") == "[REDACTED] def"
        assert module.redact("api_key:\"a b\" end") == "[REDACTED] end"
        assert module.redact("opaque abcdefghijklmnopqrstuvwxyz0123456789 end") == "opaque [REDACTED] end"
        sha = "0123456789abcdef0123456789abcdef01234567"
        assert module.redact("commit " + sha) == "commit " + sha
        assert module.redact("a, b", [""]) == "a, b"
        assert module.redact("try o3 then grok-4, gpt4 and llama3.1.") == "try [REDACTED] then [REDACTED], [REDACTED] and [REDACTED]."
        assert module.redact("pipeline claude-sonnet-5 o3-mini") == "pipeline [REDACTED] [REDACTED]"
        assert module.redact("pi day with cursor and qwen2.5") == "[REDACTED] day with [REDACTED] and [REDACTED]"
        assert module.redact("kimi with Gemini 2.5 Pro and Claude 3.5 Sonnet") == "[REDACTED] with [REDACTED] and [REDACTED] [REDACTED]"
        # The documented response shape maps onto configured lanes.
        live = {"answers": {"lane": {"type": "choice", "choice": "strong", "confidence": .22,
                                      "probabilities": {"strong": .61, "cheap": .39}}}}
        assert module.classify(live, {"strong", "cheap"}) == {
            "status": "recommended", "choice": "strong", "confidence": .22, "low_confidence": True,
            "probabilities": {"strong": .61, "cheap": .39},
            "answers": {"lane": {"type": "choice", "choice": "strong", "confidence": .22,
                                   "probabilities": {"strong": .61, "cheap": .39}}}}
        assert module.classify(live, {"claude/sonnet", "pi/gpt"}) == {
            "status": "unavailable", "reason": "no_lane_match"}
        assert module.classify(None, {"strong"}) == {"status": "unavailable", "reason": "invalid_response"}
        assert module.classify("text", {"strong"}) == {"status": "unavailable", "reason": "invalid_response"}

        repo = base / "facts-repo"
        for directory in ("src", "tests", "web"):
            (repo / directory).mkdir(parents=True)
        (repo / "README.md").write_text("# service\n")
        (repo / "src/main.py").write_text("print('x')\n")
        (repo / "tests/test_main.py").write_text("")
        (repo / "web/app.tsx").write_text("export {};\n")
        (repo / "src/lib.go").write_text("package lib\n")
        tied = base / "facts-tie"
        (tied / "src").mkdir(parents=True)
        (tied / "src/a.go").write_text("package a\n")
        (tied / "src/b.py").write_text("")
        for fixture in (repo, tied):
            subprocess.run(["git", "-C", str(fixture), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(fixture), "add", "-A"], check=True)
        expected_facts = {"tracked_files": 5, "top_level": ["src", "tests", "web"],
                          "has_tests": True, "language": "Python"}
        assert module.project_facts(repo) == expected_facts
        assert module.project_facts(tied)["language"] == "Go"
        no_count = [arg for i, arg in enumerate(argv)
                    if i not in (argv.index("--file-count"), argv.index("--file-count") + 1)]
        facts_argv = [str(repo) if arg == str(project) else arg for arg in no_count]
        facts_payload = json.loads(subprocess.run(facts_argv + ["--dry-run"], text=True,
                                                  capture_output=True, check=True).stdout)
        assert facts_payload["state"]["repository"] == expected_facts

        crew = base / "crew-facts.json"
        crew.write_text(json.dumps({"default": [
            {"harness": "codex", "model": "gpt-5", "effort": "high"},
            {"harness": "claude", "model": "sonnet"}]}))

        def project_criteria(path):
            project_argv = [arg for i, arg in enumerate(facts_argv)
                            if i not in (facts_argv.index("--lanes-json"),
                                         facts_argv.index("--lanes-json") + 1)]
            out = subprocess.run(project_argv + ["--project-config", str(path), "--dry-run"],
                                 text=True, capture_output=True, check=True).stdout
            return json.loads(out)["questions"][QUESTION]["criteria"]

        mixed = project_criteria(crew)
        assert mixed["other"] == CRITERIA["other"]
        assert mixed["codex/gpt-5"]["fits"].startswith(module.EFFORT_CRITERIA["high"]["fits"])
        assert mixed["codex/gpt-5"]["not_for"].startswith(module.EFFORT_CRITERIA["high"]["not_for"])
        assert "codex/gpt-5" in mixed["codex/gpt-5"]["fits"]
        assert "harness claude" in mixed["claude/sonnet"]["fits"]
        assert "model sonnet" in mixed["claude/sonnet"]["fits"]
        assert mixed["codex/gpt-5"] != mixed["claude/sonnet"]

        no_effort = base / "crew-no-effort.json"
        no_effort.write_text(json.dumps({"default": [
            {"harness": "codex", "model": "gpt-5"},
            {"harness": "claude", "model": "sonnet", "account": "work"}]}))
        identified = project_criteria(no_effort)
        assert identified["codex/gpt-5"] != identified["claude/sonnet"]
        assert identified["codex/gpt-5"]["not_for"] != identified["claude/sonnet"]["not_for"]
        assert "account work" in identified["claude/sonnet"]["fits"]
        assert "harness codex" in identified["codex/gpt-5"]["fits"]

        shared_effort = base / "crew-shared-effort.json"
        shared_effort.write_text(json.dumps({"default": [
            {"harness": "codex", "model": "gpt-5", "effort": "medium"},
            {"harness": "claude", "model": "sonnet", "effort": "medium"}]}))
        shared = project_criteria(shared_effort)
        assert shared["codex/gpt-5"] != shared["claude/sonnet"]
        for lane in ("codex/gpt-5", "claude/sonnet"):
            assert shared[lane]["fits"].startswith(module.EFFORT_CRITERIA["medium"]["fits"])
            assert lane in shared[lane]["fits"] and lane in shared[lane]["not_for"]
    finally:
        server.shutdown()
        target.shutdown()
print("PASS: Jev projection, project opt-in, no-key, dry-run, redirect refusal, unhashable choice, redaction fixtures, shadow event and fake HTTP contract")
PY
