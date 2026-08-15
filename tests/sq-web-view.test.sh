#!/usr/bin/env bash
# Behavior tests for the read-only web dashboard (bin/sq-web-view.sh).
#
# Covers the card renderer contract: one card per state/<id>.meta with the
# live busy classification, the last wake event, window, project, and the full
# status log; strict HTML escaping of operator-written text; empty and missing
# state directories; the read-only guarantee (render and serve never mutate
# the state directory); and the serve mode's HTTP surface. All hermetic over
# temp dirs; no real Squad base is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/sq-web-view.sh"
EV="$ROOT/bin/sq-busy-event.sh"

TMP_ROOT=$(fm_test_tmproot sq-web-view)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

write_meta() {  # <id> <window> <project> <harness> <kind> <mode>
  fm_write_meta "$STATE/$1.meta" \
    "window=$2" \
    "endpoint_task_id=$1" \
    "worktree=$TMP_ROOT/wt" \
    "project=$3" \
    "harness=$4" \
    "kind=$5" \
    "mode=$6" \
    "yolo=off" \
    "tasktmp=$TMP_ROOT/tmp" \
    "model=default" \
    "effort=medium"
}

busy_apply() {  # <id> <state>
  local gen
  gen=$("$EV" arm "$STATE" "$1") || fail "busy arm failed for $1"
  "$EV" apply "$STATE" "$1" "$2" --gen "$gen" --source sq-spawn --event user-prompt-submit \
    || fail "busy apply failed for $1"
}

# --- fixtures ----------------------------------------------------------------

# t1: full strike meta, done wake event, live busy record.
write_meta t1 squad:sq-t1 /home/example/alpha pi strike drill
printf 'working: setup done\n' > "$STATE/t1.status"
printf 'done: PR https://github.com/example/alpha/pull/9 checks green\n' >> "$STATE/t1.status"
busy_apply t1 busy

# t2: minimal xo meta (no effort/model fields), no status log, idle busy record.
fm_write_meta "$STATE/t2.meta" \
  "window=Squad:sq-xo-omega" \
  "endpoint_task_id=t2" \
  "worktree=$TMP_ROOT/xo" \
  "project=/home/example/omega" \
  "harness=echo" \
  "kind=xo" \
  "mode=xo" \
  "yolo=off"
busy_apply t2 idle

# t3: needs-decision wake event, with HTML-shaped text in the log that must be
# escaped, and no busy record.
write_meta t3 squad:sq-t3 /home/example/beta pi strike direct-PR
printf 'working: report has <script>alert(1)</script> & "quotes"\n' > "$STATE/t3.status"
printf 'needs-decision: [key=esc] pick a plan\n' >> "$STATE/t3.status"

# t4: canonical keyed blocked wake event (verb [key=...]: note), busy record
# with a stale gen (gen-mismatch).
write_meta t4 squad:sq-t4 /home/example/gamma pi strike drill
printf 'blocked [key=api-shape]: upstream API unreachable\n' > "$STATE/t4.status"
"$EV" arm "$STATE" t4 > /dev/null || fail "busy arm failed for t4"
printf 'v1 gen=wrong seq=1 state=busy source=stale event=stale ts=1\n' > "$STATE/t4.busy-state"

# t5: working wake event, live busy record.
write_meta t5 squad:sq-t5 /home/example/delta pi recon drill
printf 'working: implementing the widget\n' > "$STATE/t5.status"
busy_apply t5 busy

# --- render: card contract ---------------------------------------------------

test_render_lists_each_task() {
  local out
  out=$("$VIEW" render --state "$STATE") || fail "render failed"
  assert_contains "$out" '>t1<' "render should list task t1"
  assert_contains "$out" '>t2<' "render should list task t2"
  assert_contains "$out" '>t3<' "render should list task t3"
  assert_contains "$out" '>t4<' "render should list task t4"
  assert_contains "$out" '>t5<' "render should list task t5"
  assert_contains "$out" "window: squad:sq-t1" "render should show the window"
  assert_contains "$out" 'title="/home/example/alpha">alpha' "render should show the project basename with the full path in a title"
  assert_contains "$out" "done: PR https://github.com/example/alpha/pull/9 checks green" "render should show the last wake event"
  assert_contains "$out" "working: setup done" "render should embed the full status log, not only the last line"
  assert_contains "$out" "no wake events yet" "render should say so when a task has no status log"
  assert_contains "$out" "5 operator(s)" "render should count operators"
  pass "render lists every task with window, project, last event, and full log"
}

test_render_escapes_operator_text() {
  local out
  out=$("$VIEW" render --state "$STATE") || fail "render failed"
  assert_contains "$out" "&lt;script&gt;alert(1)&lt;/script&gt;" "log HTML must be escaped"
  assert_not_contains "$out" "<script>alert(1)" "raw log HTML must never reach the page"
  assert_contains "$out" "&amp; &quot;quotes&quot;" "log ampersands and quotes must be escaped"
  assert_contains "$out" "needs-decision: [key=esc] pick a plan" "last event text must survive escaping"
  pass "render escapes every operator-written string"
}

test_render_colors_known_verbs() {
  local out
  out=$("$VIEW" render --state "$STATE") || fail "render failed"
  assert_contains "$out" 'pill green">done' "done should render green"
  assert_contains "$out" 'pill blue">needs-decision' "needs-decision should render blue"
  assert_contains "$out" 'pill red">blocked' "keyed blocked should still render red"
  assert_contains "$out" "blocked [key=api-shape]: upstream API unreachable" "the keyed wake event text should survive"
  assert_contains "$out" 'pill amber">working' "working should render amber"
  pass "render maps known wake verbs to pill colors"
}

test_render_shows_busy_classification() {
  local out
  out=$("$VIEW" render --state "$STATE") || fail "render failed"
  assert_contains "$out" 'title="busy: sq-spawn"' "a live busy record should render busy with its source"
  assert_contains "$out" 'title="idle: sq-spawn"' "an idle busy record should render idle"
  assert_contains "$out" 'title="unknown: missing"' "a missing busy record should render unknown"
  assert_contains "$out" 'title="unknown: gen-mismatch"' "a stale-gen busy record should render unknown with the reason"
  pass "render surfaces the busy classification and why it is unknown"
}

test_render_respects_state_flag_and_env() {
  local out
  out=$("$VIEW" render --state "$STATE") || fail "render with --state failed"
  assert_contains "$out" "squad:sq-t1" "--state should select the fixture state dir"
  out=$(SQUAD_STATE_OVERRIDE="$STATE" "$VIEW" render) || fail "render with env override failed"
  assert_contains "$out" "squad:sq-t1" "SQUAD_STATE_OVERRIDE should select the fixture state dir"
  pass "render resolves the state directory from --state and the env override"
}

test_render_is_read_only() {
  local before after
  before=$(cd "$STATE" && find . -type f -exec cksum {} \; | sort)
  "$VIEW" render --state "$STATE" > /dev/null || fail "render failed"
  after=$(cd "$STATE" && find . -type f -exec cksum {} \; | sort)
  [ "$before" = "$after" ] || fail "render mutated the state directory"
  pass "render never mutates the state directory"
}

test_render_empty_and_missing_state() {
  local empty out code
  empty="$TMP_ROOT/empty"
  mkdir -p "$empty"
  out=$("$VIEW" render --state "$empty") || fail "render of an empty state dir failed"
  assert_contains "$out" "No operators found" "an empty state dir should say so"
  "$VIEW" render --state "$TMP_ROOT/does-not-exist" > /dev/null 2>&1
  code=$?
  expect_code 1 "$code" "render of a missing state dir should exit 1"
  pass "render handles empty and missing state directories"
}

test_render_rejects_unknown_options() {
  local code
  "$VIEW" render --bogus > /dev/null 2>&1
  code=$?
  expect_code 2 "$code" "render with an unknown option should exit 2"
  pass "render fails closed on unknown options"
}

# --- serve: HTTP surface ------------------------------------------------------

test_serve_answers_requests() {
  local port pid out code
  command -v python3 >/dev/null 2>&1 || {
    echo "skip: python3 not found"
    return 0
  }
  port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()")
  "$VIEW" serve --state "$STATE" --port "$port" > "$TMP_ROOT/serve.log" 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; fm_test_cleanup' EXIT
  trap 'kill "$pid" 2>/dev/null || true; fm_test_cleanup; exit 130' INT
  trap 'kill "$pid" 2>/dev/null || true; fm_test_cleanup; exit 143' TERM
  local tries=0
  while [ "$tries" -lt 40 ]; do
    if curl -sf "http://127.0.0.1:$port/" > "$TMP_ROOT/served.html" 2>/dev/null; then
      break
    fi
    tries=$((tries + 1))
    sleep 0.25
  done
  assert_present "$TMP_ROOT/served.html" "serve never answered a request"
  out=$(cat "$TMP_ROOT/served.html")
  assert_contains "$out" '>t1<' "serve should return freshly rendered cards"
  assert_contains "$out" "done: PR https://github.com/example/alpha/pull/9 checks green" "serve should return the live status log"
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/other")
  expect_code 404 "$code" "serve should 404 unknown paths"
  before=$(cd "$STATE" && find . -type f -exec cksum {} \; | sort)
  after=$(cd "$STATE" && find . -type f -exec cksum {} \; | sort)
  [ "$before" = "$after" ] || fail "serve mutated the state directory"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap fm_test_cleanup EXIT
  trap 'fm_test_cleanup; exit 130' INT
  trap 'fm_test_cleanup; exit 143' TERM
  pass "serve answers GET / with fresh HTML, 404s unknown paths, and never mutates state"
}

test_render_lists_each_task
test_render_escapes_operator_text
test_render_colors_known_verbs
test_render_shows_busy_classification
test_render_respects_state_flag_and_env
test_render_is_read_only
test_render_empty_and_missing_state
test_render_rejects_unknown_options
test_serve_answers_requests

echo "all sq-web-view tests passed"
