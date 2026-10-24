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

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("jev", root / "bin/sq-jev-call.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as td:
    base = pathlib.Path(td)
    project = base / "project"
    project.mkdir()
    config = base / "jev.json"
    data = base / "data"
    config.write_text(json.dumps({"enabled_projects": [str(project)]}))
    captured = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            captured["path"] = self.path
            captured["auth"] = self.headers.get("Authorization")
            captured["body"] = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            body = json.dumps({"type": "choice", "choice": "claude/sonnet", "confidence": .8,
                               "probabilities": {"claude/sonnet": .8, "pi/gpt": .2}}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/v1/systemone"
    argv = [sys.executable, str(root / "bin/sq-jev-call.py"), "--id", "task",
            "--project", str(project), "--task-type", "feature", "--title", "title",
            "--description", "$HOME/private sk-abcd1234567890 ghp_abcdefgh AKIA1234567890ABCDEF "
            "eyJabc.def.ghi https://user:pass@example.invalid KEY=value", "--file-count", "3",
            "--lanes-json", '{"claude/sonnet":"claude/sonnet","pi/gpt":"pi/gpt"}',
            "--config", str(config), "--data", str(data), "--url", url]
    try:
        # No project opt-in means no request and no log, even with a key.
        config.write_text('{"enabled_projects":[]}')
        disabled = subprocess.run(argv, text=True, capture_output=True, env={**os.environ, "TYPESAFE_API_KEY":"runtime-test-key"})
        assert json.loads(disabled.stdout) == {"status": "disabled"}
        assert not captured and not (data / "task/dispatch.jsonl").exists()
        config.write_text(json.dumps({"enabled_projects": [str(project)]}))
        missing = subprocess.run(argv, text=True, capture_output=True, env={k:v for k,v in os.environ.items() if k != "TYPESAFE_API_KEY"})
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
        env = {**os.environ, "TYPESAFE_API_KEY":"runtime-test-key"}
        result = subprocess.run(argv, text=True, capture_output=True, env=env, check=True)
        assert json.loads(result.stdout) == {"status":"recommended","choice":"claude/sonnet"}
        assert captured["path"] == "/v1/systemone" and captured["auth"] == "Bearer runtime-test-key"
        assert set(captured["body"]) == {"type", "criteria", "instructions"}
        assert "sk-abcd" not in json.dumps(captured["body"]) and "$HOME" not in json.dumps(captured["body"])
        rows = [json.loads(line) for line in (data / "task/dispatch.jsonl").read_text().splitlines()]
        assert rows == [{"timestamp": rows[0]["timestamp"], "id":"task", "event":"recommendation",
                         "label":"recommendation", "choice":"claude/sonnet", "confidence":.8,
                         "probabilities":{"claude/sonnet":.8,"pi/gpt":.2}}]
        assert "runtime-test-key" not in str(argv)
        assert module.redact("prefix $HOME/secret then sk-abcd1234567890") == "prefix ~/secret then [REDACTED]"
        boundary = module.redact("x" * 230 + " sk-abcd1234567890")
        assert len(boundary) == 240 and "sk-" not in boundary
    finally:
        server.shutdown()
print("PASS: Jev projection, project opt-in, no-key, dry-run, shadow event and fake HTTP contract")
PY
