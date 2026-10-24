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
OK_REPLY = {"type": "choice", "choice": "claude/sonnet", "confidence": .8,
            "probabilities": {"claude/sonnet": .8, "pi/gpt": .2}}


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
            "--lanes-json", '{"claude/sonnet":"claude/sonnet","pi/gpt":"pi/gpt"}',
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
        missing =subprocess.run(argv, text=True, capture_output=True,
                                 env={k: v for k, v in os.environ.items() if k != "TYPESAFE_API_KEY"})
        assert json.loads(missing.stdout) == {"status": "missing_key"}
        dry = subprocess.run(argv + ["--dry-run"], text=True, capture_output=True)
        payload = json.loads(dry.stdout)
        assert payload == {"type":"choice", "criteria":{"claude/sonnet":"claude/sonnet","pi/gpt":"pi/gpt"},
                           "instructions":"Recommend the best-fitting lane for this task. Task projection: "
                           + json.dumps({"task_type":"feature","title":"title","description":
                           "~/private [REDACTED] [REDACTED] [REDACTED] [REDACTED] "
                           "https://[REDACTED]@example.invalid [REDACTED]","file_count":3},
                           ensure_ascii=True,separators=(",",":"))}
        assert not captured

        state["location"] = f"http://localhost:{target.server_port}/v1/systemone"
        redirect = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(redirect.stdout) == {"status": "error"}
        assert not redirected and not (data / "task/dispatch.jsonl").exists()
        state["location"] = None

        captured.clear()
        state["reply"] = {"type": "choice", "choice": ["claude/sonnet"], "confidence": .8}
        unhashable = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(unhashable.stdout) == {"status": "error"} and unhashable.stderr == ""
        assert not (data / "task/dispatch.jsonl").exists()
        state["reply"] = {"type": "choice", "choice": "claude/sonnet", "confidence": None}
        unrecorded = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(unrecorded.stdout) == {"status": "error"}
        assert not (data / "task/dispatch.jsonl").exists()
        state["reply"] = {"type": "choice", "choice": "claude/sonnet", "confidence": .8, "padding": "x" * 70000}
        oversized = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(oversized.stdout) == {"status": "error"}
        assert not (data / "task/dispatch.jsonl").exists()
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
        assert json.loads(slow.stdout)["instructions"].endswith('"file_count":0}')

        result =subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(result.stdout) == {"status":"recommended","choice":"claude/sonnet"}
        assert captured["path"] == "/v1/systemone" and captured["auth"] == "Bearer runtime-test-key"
        assert captured["body"] == payload
        rows = [json.loads(line) for line in (data / "task/dispatch.jsonl").read_text().splitlines()]
        assert rows == [{"timestamp": rows[0]["timestamp"], "id":"task", "event":"recommendation",
                         "label":"recommendation", "choice":"claude/sonnet", "confidence":.8,
                         "probabilities":{"claude/sonnet":.8,"pi/gpt":.2}}]
        state["reply"] = {**OK_REPLY, "probabilities": {"claude/sonnet": .8, "pi/gpt": .1, "sq-send": .1}}
        leak_data = base / "leak"
        leak_argv = argv[:argv.index("--data") + 1] + [str(leak_data)] + argv[argv.index("--data") + 2:]
        leak = subprocess.run(leak_argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(leak.stdout) == {"status":"recommended","choice":"claude/sonnet"}
        leak_rows = [json.loads(line) for line in (leak_data / "task/dispatch.jsonl").read_text().splitlines()]
        assert leak_rows[0]["probabilities"] == {"claude/sonnet": .8, "pi/gpt": .1}
        state["reply"] = OK_REPLY
        assert "runtime-test-key" not in str(argv)
        assert module.redact("prefix $HOME/secret then sk-abcd1234567890") == "prefix ~/secret then [REDACTED]"
        boundary = module.redact("x" * 230 + " sk-abcd1234567890")
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
    finally:
        server.shutdown()
        target.shutdown()
print("PASS: Jev projection, project opt-in, no-key, dry-run, redirect refusal, unhashable choice, redaction fixtures, shadow event and fake HTTP contract")
PY
