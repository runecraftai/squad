#!/usr/bin/env bash
# Behavior test: a Jev recommendation is shadow-only. bin/sq-spawn.sh runs the
# REAL dispatch with and without an opted-in project; a fake localhost Jev
# endpoint recommends a different lane. The actual dispatch (launch command,
# spawn metadata, decision and spawn rows) must match the run with Jev off, and
# the recommendation must be recorded as its own labelled event.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/sq-spawn.sh"
TMP_ROOT=$(fm_test_tmproot sq-jev-shadow-dispatch)
ID=jev-shadow-z1

make_case() {
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$ID" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-sentry-beat"
  printf 'brief for %s\necho done >> %s.status\n' "$ID" "$home/data/$ID" > "$home/data/$ID/brief.md"
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${SQUAD_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'Squad\n'; exit 0 ;;
  send-keys)
    prev=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then printf '%s\n' "$a" >> "$SQUAD_FAKE_LAUNCH_LOG"; fi
      prev=$a
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" fob pi-signed
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

start_jev_server() {
  local dir=$1 reply=$2
  cat > "$dir/jev-server.py" <<'PY'
import http.server
import json
import pathlib
import sys

log, port_file, reply = sys.argv[1], sys.argv[2], sys.argv[3].encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with open(log, "ab") as record:
            record.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"),
                                     "body": json.loads(body)}).encode() + b"\n")
        self.send_response(200)
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(port_file).write_text(str(server.server_port))
server.serve_forever()
PY
  python3 "$dir/jev-server.py" "$dir/requests.jsonl" "$dir/port" "$reply" &
  JEV_SERVER_PID=$!
  trap 'kill "$JEV_SERVER_PID" 2>/dev/null; fm_test_cleanup' EXIT
  local waited=0
  while [ ! -s "$dir/port" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -s "$dir/port" ] || fail "fake Jev server did not start"
}

spawn_explicit() {  # <record> <launchlog>
  local rec=$1 launchlog=$2 home proj wt fakebin
  IFS='|' read -r _ home proj wt fakebin <<< "$rec"
  : > "$launchlog"
  SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$home" \
    SQUAD_STATE_OVERRIDE="$home/state" SQUAD_DATA_OVERRIDE="$home/data" \
    SQUAD_PROJECTS_OVERRIDE="$home/projects" SQUAD_CONFIG_OVERRIDE="$home/config" \
    SQUAD_SPAWN_NO_GUARD=1 SQUAD_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' SQUAD_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$ID" "$proj" --mode drill --yolo off --harness codex --model gpt-5 --effort high 2>&1
}

# Rows that Squad itself writes for the dispatch decision, timestamps removed.
dispatch_rows() {
  python3 - "$1" <<'PY'
import json
import sys

for line in open(sys.argv[1]):
    row = json.loads(line)
    row.pop("timestamp", None)
    if row.get("label") != "recommendation":
        print(json.dumps(row, sort_keys=True))
PY
}

test_recommendation_never_changes_actual_dispatch() {
  local baseline shadow case_base case_shadow home_shadow proj_shadow proj_real
  local out_base out_shadow status requests
  local reply='{"type":"choice","choice":"grok/grok-4","confidence":0.9,"probabilities":{"grok/grok-4":0.9,"codex/gpt-5":0.1}}'
  baseline=$(make_case shadow-off)
  shadow=$(make_case shadow-on)
  IFS='|' read -r case_base _ <<< "$baseline"
  IFS='|' read -r case_shadow home_shadow proj_shadow _ <<< "$shadow"
  proj_real=$(cd "$proj_shadow" && pwd -P)
  start_jev_server "$case_shadow" "$reply"
  printf '{"enabled_projects":["%s"]}\n' "$proj_real" > "$home_shadow/config/jev-dispatch.json"

  out_base=$(unset TYPESAFE_API_KEY; spawn_explicit "$baseline" "$case_base/launch.log")
  status=$?
  expect_code 0 "$status" "baseline explicit spawn should succeed"
  out_shadow=$(export TYPESAFE_API_KEY=runtime-test-key SQUAD_JEV_URL_OVERRIDE="http://127.0.0.1:$(cat "$case_shadow/port")/v1/systemone"
    spawn_explicit "$shadow" "$case_shadow/launch.log")
  status=$?
  expect_code 0 "$status" "explicit spawn with Jev shadow should succeed"

  assert_contains "$out_shadow" "spawned $ID harness=codex" "shadow run did not dispatch the established codex lane"
  assert_grep "harness=codex" "$home_shadow/state/$ID.meta" "shadow run metadata drifted from codex"
  assert_grep "model=gpt-5" "$home_shadow/state/$ID.meta" "shadow run metadata drifted from gpt-5"
  assert_no_grep "grok" "$case_shadow/launch.log" "recommendation leaked into the launch command"
  assert_contains "$(cat "$case_shadow/launch.log")" "codex --model 'gpt-5'" "shadow run did not launch codex with gpt-5"
  [ "$(cat "$case_base/launch.log")" = "$(sed "s#$case_shadow#$case_base#g" "$case_shadow/launch.log")" ] \
    || fail "recommendation changed the launch command"

  requests=$(wc -l < "$case_shadow/requests.jsonl")
  [ "$requests" -eq 1 ] || fail "expected exactly one Jev request, got $requests"
  python3 - "$case_shadow/requests.jsonl" <<'PY' || fail "Jev request was not the allowlisted shadow projection"
import json
import sys

request = json.loads(open(sys.argv[1]).readline())
assert request["auth"] == "Bearer runtime-test-key"
assert request["body"]["type"] == "choice"
assert sorted(request["body"]["criteria"]) == ["codex/gpt-5", "grok/grok-4"]
PY

  diff <(dispatch_rows "$case_base/home/data/$ID/dispatch.jsonl") \
       <(dispatch_rows "$case_shadow/home/data/$ID/dispatch.jsonl") \
    || fail "recommendation altered the decision or spawn rows"
  python3 - "$case_shadow/home/data/$ID/dispatch.jsonl" <<'PY' || fail "recommendation row was not recorded as a labelled event"
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1])]
recommendations = [row for row in rows if row.get("label") == "recommendation"]
assert len(recommendations) == 1
assert recommendations[0]["choice"] == "grok/grok-4"
assert recommendations[0]["event"] == "recommendation"
assert {row.get("event") for row in rows if row.get("label") != "recommendation"} == {"decision", "spawn"}
PY
  pass "a Jev recommendation for another lane leaves the actual dispatch unchanged and is recorded separately"
}

test_recommendation_never_changes_actual_dispatch

echo "# all sq-jev-shadow-dispatch tests passed"
