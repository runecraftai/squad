#!/usr/bin/env bash
# Behavior test: a Jev recommendation is shadow-only. bin/sq-spawn.sh runs the
# REAL dispatch with and without an opted-in project; a fake localhost Jev
# endpoint recommends a different lane. The actual dispatch (launch command,
# spawn metadata, decision and spawn rows) must match the run with Jev off, and
# the recommendation must be recorded as its own labelled event.
# The same endpoint then observes where the bearer key comes from: the ambient
# environment wins, the base .env is the fallback for that single key, and an
# absent, incomplete, or malformed .env keeps the client's missing_key path.
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

# One spawn against the fake endpoint, with the isolated network and key-source
# environment it needs. <port|empty> <ambient-key|empty> <command...>
# A dead proxy port keeps a stray real request on the machine, no_proxy keeps
# loopback direct, and the key is set only when the case supplies one so an
# empty ambient key exercises the base .env fallback.
with_fake_endpoint() {
  local port=$1 ambient=$2
  shift 2
  (
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
    export http_proxy=http://127.0.0.1:1 https_proxy=http://127.0.0.1:1 all_proxy=http://127.0.0.1:1 no_proxy=127.0.0.1
    [ -z "$port" ] || export SQUAD_JEV_URL_OVERRIDE="http://127.0.0.1:$port/v1/systemone"
    if [ -n "$ambient" ]; then export TYPESAFE_API_KEY="$ambient"; else unset TYPESAFE_API_KEY; fi
    "$@"
  )
}

test_recommendation_never_changes_actual_dispatch() {
  local baseline shadow case_base case_shadow home_shadow proj_shadow proj_real
  local out_shadow jev_port status requests
  local reply='{"answers":{"lane":{"type":"choice","choice":"o2","confidence":0.9,"probabilities":{"o2":0.9,"o1":0.08,"other":0.02}},"needs_design_decision":{"type":"noul","answer":false}},"model":"jev-2026-05"}'
  baseline=$(make_case shadow-off)
  shadow=$(make_case shadow-on)
  IFS='|' read -r case_base _ <<< "$baseline"
  IFS='|' read -r case_shadow home_shadow proj_shadow _ <<< "$shadow"
  proj_real=$(cd "$proj_shadow" && pwd -P)
  start_jev_server "$case_shadow" "$reply"
  printf '{"enabled_projects":["%s"]}\n' "$proj_real" > "$home_shadow/config/jev-dispatch.json"

  with_fake_endpoint '' '' spawn_explicit "$baseline" "$case_base/launch.log"
  status=$?
  expect_code 0 "$status" "baseline explicit spawn should succeed"
  jev_port=$(cat "$case_shadow/port")
  out_shadow=$(with_fake_endpoint "$jev_port" runtime-test-key spawn_explicit "$shadow" "$case_shadow/launch.log")
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
assert set(request["body"]) == {"state", "model", "questions"}
assert request["body"]["model"] == "jev-latest"
state = request["body"]["state"]
assert set(state) == {"task", "repository"}
assert state["task"] == {"type": "strike"}
repository = state["repository"]
assert set(repository) == {"tracked_files", "extension_counts", "has_tests", "has_docs"}
assert isinstance(repository["tracked_files"], int) and repository["tracked_files"] >= 1
assert repository["extension_counts"] == {".md": 1} and repository["has_tests"] is False and repository["has_docs"] is True
questions = request["body"]["questions"]
assert set(questions) == {"lane", "needs_design_decision"}
assert questions["lane"]["type"] == "choice"
assert questions["needs_design_decision"]["type"] == "noul"
criteria = questions["lane"]["criteria"]
assert set(criteria) == {"o1", "o2", "other"}
for option in ("o1", "o2"):
    assert set(criteria[option]) == {"fits", "not_for"}
    assert criteria[option]["fits"] and criteria[option]["fits"] != option
assert criteria["o1"]["fits"].startswith("a routine change")
assert criteria["o2"]["fits"].startswith("a demanding or ambiguous change")
assert criteria["other"]["fits"] == "none of these lanes fits the task"
assert all(text not in json.dumps(request["body"]) for text in (
    "codex/gpt-5", "grok/grok-4", "brief for", ".status",
))
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
assert recommendations[0]["confidence"] == 0.9
assert recommendations[0]["probabilities"] == {"grok/grok-4": 0.9, "codex/gpt-5": 0.08, "other": 0.02}
assert recommendations[0]["model"] == "jev-2026-05"
assert set(recommendations[0]["answers"]) == {"lane", "needs_design_decision"}
assert recommendations[0]["answers"]["lane"]["choice"] == "grok/grok-4"
assert recommendations[0]["answers"]["lane"]["probabilities"] == recommendations[0]["probabilities"]
assert recommendations[0]["answers"]["needs_design_decision"] == {"type": "noul", "answer": False}
assert "low_confidence" not in recommendations[0]
assert {row.get("event") for row in rows if row.get("label") != "recommendation"} == {"decision", "spawn"}
PY
  pass "a Jev recommendation for another lane leaves the actual dispatch unchanged and is recorded separately"
}

test_recommendation_never_changes_actual_dispatch

# The bearer key normally arrives in the environment; when it does not, the
# spawn reads exactly that one key from the base .env and hands it to the
# client child only. Each case below runs the real spawn against the same fake
# endpoint and changes nothing but where the key comes from.
OK_REPLY='{"answers":{"lane":{"type":"choice","choice":"o2","confidence":0.9,"probabilities":{"o2":0.9,"o1":0.08,"other":0.02}},"needs_design_decision":{"type":"noul","answer":false}},"model":"jev-2026-05"}'

retire_jev_server() {
  [ -z "${JEV_SERVER_PID:-}" ] || kill "$JEV_SERVER_PID" 2>/dev/null || true
  JEV_SERVER_PID=
}

# One spawn whose only variable is where the key comes from. Runs in the
# calling shell because the fake endpoint's EXIT trap owns this test's temp
# root. Usage: key_case <case-name> <dotenv-body> <ambient-key>
# Leaves the case under $TMP_ROOT/<case-name>, the endpoint's Authorization
# header (or "no-request") in <case>/auth, and the spawn output in
# <case>/spawn.out.
key_case() {
  local name=$1 body=$2 ambient=$3 rec case_dir home proj wt fakebin port auth
  rec=$(make_case "$name")
  IFS='|' read -r case_dir home proj wt fakebin <<< "$rec"
  printf '{"enabled_projects":["%s"]}\n' "$(cd "$proj" && pwd -P)" > "$home/config/jev-dispatch.json"
  [ -z "$body" ] || printf '%s\n' "$body" > "$home/.env"
  retire_jev_server
  rm -f "$case_dir/requests.jsonl" "$case_dir/launch.log"
  start_jev_server "$case_dir" "$OK_REPLY"
  port=$(cat "$case_dir/port")
  local spawn_out status
  spawn_out=$(with_fake_endpoint "$port" "$ambient" spawn_explicit "$rec" "$case_dir/launch.log")
  status=$?
  printf '%s\n' "$spawn_out" > "$case_dir/spawn.out"
  printf '%s\n' "$status" > "$case_dir/spawn.code"
  if [ -s "$case_dir/requests.jsonl" ]; then
    auth=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["auth"])' \
      "$case_dir/requests.jsonl")
  else
    auth=no-request
  fi
  printf '%s\n' "$auth" > "$case_dir/auth"
}

case_auth() {  # <case-name>
  cat "$TMP_ROOT/$1/auth"
}

# The single labelled recommendation row, as "<status> <reason> <choice>".
recorded_recommendation() {  # <dispatch.jsonl>
  python3 - "$1" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1])]
recorded = [row for row in rows if row.get("label") == "recommendation"]
assert len(recorded) == 1, recorded
row = recorded[0]
print(row.get("status", "-"), row.get("reason", "-"), row.get("choice", "-"))
PY
}

# No value may reach the spawn output, the launch command, a status line, a
# meta record, or the dispatch log. The fixture .env is the one place it is
# allowed to live; the fake endpoint's own request log is the observation, not a
# product surface.
assert_secret_absent() {  # <value> <case-name>
  local root hit
  root="$TMP_ROOT/$2"
  hit=$(grep -rIl --exclude=.env -- "$1" "$root/home" "$root/spawn.out" "$root/launch.log" 2>/dev/null || true)
  [ -z "$hit" ] || fail "$2: bearer value reached $hit"
}

assert_case_exit() {  # <case-name>
  local code
  code=$(cat "$TMP_ROOT/$1/spawn.code")
  [ "$code" = 0 ] || fail "$1: spawn exited $code"
}

test_ambient_key_wins_over_dotenv() {
  key_case ambient-wins "TYPESAFE_API_KEY=dotenv-value-ignored-88" "ambient-value-11"
  local auth
  auth=$(case_auth ambient-wins)
  [ "$auth" = "Bearer ambient-value-11" ] || fail "ambient key did not win: $auth"
  [ "$(recorded_recommendation "$TMP_ROOT/ambient-wins/home/data/$ID/dispatch.jsonl")" = "recommended - grok/grok-4" ] \
    || fail "ambient run did not record the stub recommendation"
  assert_case_exit ambient-wins
  assert_secret_absent "ambient-value-11" ambient-wins
  pass "an ambient TYPESAFE_API_KEY wins and the base .env is ignored"
}

test_dotenv_key_reaches_the_client_only() {
  key_case dotenv-fallback "TYPESAFE_API_KEY=dotenv-value-22" ""
  local auth
  auth=$(case_auth dotenv-fallback)
  [ "$auth" = "Bearer dotenv-value-22" ] || fail "the base .env key did not reach the client: $auth"
  [ "$(recorded_recommendation "$TMP_ROOT/dotenv-fallback/home/data/$ID/dispatch.jsonl")" = "recommended - grok/grok-4" ] \
    || fail "the stub recommendation was not recorded"
  assert_case_exit dotenv-fallback
  assert_secret_absent "dotenv-value-22" dotenv-fallback
  pass "a base .env key reaches the client without appearing in output or the log"
}

test_absent_or_incomplete_dotenv_keeps_missing_key() {
  local name body auth
  name=no-dotenv
  key_case "$name" "" ""
  auth=$(case_auth "$name")
  [ "$auth" = no-request ] || fail "$name: a request was sent without a key: $auth"
  [ "$(recorded_recommendation "$TMP_ROOT/$name/home/data/$ID/dispatch.jsonl")" = "unavailable missing_key -" ] \
    || fail "$name: expected unavailable missing_key"
  assert_case_exit "$name"

  name=dotenv-without-key
  body='OTHER_KEY=1
#TYPESAFE_API_KEY=commented-out
TYPESAFE_API_KEY_SUFFIX="nope"'
  key_case "$name" "$body" ""
  auth=$(case_auth "$name")
  [ "$auth" = no-request ] || fail "$name: a request was sent without a key: $auth"
  [ "$(recorded_recommendation "$TMP_ROOT/$name/home/data/$ID/dispatch.jsonl")" = "unavailable missing_key -" ] \
    || fail "$name: expected unavailable missing_key"
  assert_case_exit "$name"
  pass "an absent or incomplete base .env keeps the missing_key path unchanged"
}

test_dotenv_values_parse_predictably() {
  local auth
  key_case parse-double $'TYPESAFE_API_KEY="double-quoted-value"   # trailing comment' ""
  auth=$(case_auth parse-double)
  [ "$auth" = "Bearer double-quoted-value" ] || fail "double-quoted value parsed as '$auth'"
  assert_secret_absent double-quoted-value parse-double

  key_case parse-single "TYPESAFE_API_KEY='single-quoted-value'" ""
  auth=$(case_auth parse-single)
  [ "$auth" = "Bearer single-quoted-value" ] || fail "single-quoted value parsed as '$auth'"
  assert_secret_absent single-quoted-value parse-single

  key_case parse-spaced $'TYPESAFE_API_KEY=plain-value   ' ""
  auth=$(case_auth parse-spaced)
  [ "$auth" = "Bearer plain-value" ] || fail "value with trailing whitespace parsed as '$auth'"

  key_case parse-comment 'TYPESAFE_API_KEY=inline-comment-value  # note' ""
  auth=$(case_auth parse-comment)
  [ "$auth" = "Bearer inline-comment-value" ] || fail "value with a comment parsed as '$auth'"

  key_case parse-crlf $'export TYPESAFE_API_KEY="crlf-value"\r' ""
  auth=$(case_auth parse-crlf)
  [ "$auth" = "Bearer crlf-value" ] || fail "CRLF line parsed as '$auth'"
  assert_secret_absent crlf-value parse-crlf
  pass "quoted, spaced, commented, exported, and CRLF base .env lines parse predictably"
}

test_malformed_dotenv_never_yields_a_partial_key() {
  local name body auth
  for pair in 'unterminated|TYPESAFE_API_KEY="half-a-key' 'trailing-junk|TYPESAFE_API_KEY="half-a-key"junk'; do
    name=${pair%%|*}
    body=${pair#*|}
    key_case "malformed-$name" "$body" ""
    auth=$(case_auth "malformed-$name")
    [ "$auth" = no-request ] || fail "$name: a partial key was sent: $auth"
    [ "$(recorded_recommendation "$TMP_ROOT/malformed-$name/home/data/$ID/dispatch.jsonl")" = "unavailable missing_key -" ] \
      || fail "$name: expected unavailable missing_key"
    assert_case_exit "malformed-$name"
    assert_secret_absent half-a-key "malformed-$name"
  done
  pass "a malformed base .env line never yields a partial key"
}

test_ambient_key_wins_over_dotenv
test_dotenv_key_reaches_the_client_only
test_absent_or_incomplete_dotenv_keeps_missing_key
test_dotenv_values_parse_predictably
test_malformed_dotenv_never_yields_a_partial_key
retire_jev_server

echo "# all sq-jev-shadow-dispatch tests passed"
