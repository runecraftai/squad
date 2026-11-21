#!/usr/bin/env bash
# Regression test for the pi conversation pin and resume-or-rebrief relaunch in
# bin/sq-spawn.sh (see its header, "Pi operator conversation").
#
# A pi operator spawn pins its conversation to sq-<task-id> and records
# pi_session_id= in the meta. A relaunch into a recovered agentless TUIOS window
# resumes that conversation with --session and a short continuation note, and
# never re-sends the brief, only when every gate holds. Each refused gate relaunches
# a fresh conversation with the full brief and no pin, and every relaunch appends
# exactly one status line naming the path it took. This test drives the real
# sq-spawn.sh with a fake TUIOS CLI (never a real daemon) and a private pi agent
# dir holding the transcripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/sq-spawn.sh"
TMP_ROOT=$(fm_test_tmproot sq-spawn-pi-session-resume)
WINDOW_ID=w-opaque-pi

# make_tuios_fakebin <dir>: the fake TUIOS and fob CLIs the spawn path drives. The
# window's reported cwd follows a `cd` typed into its own shell, and its agent
# state is scripted through SQUAD_FAKE_TUIOS_AGENTS_JSON.
make_tuios_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tuios" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${SQUAD_FAKE_TUIOS_LOG:?}"
case "${1:-}" in
  --version) printf 'tuios version 0.8.0\n' ;;
  session-info) printf '{"name":"owned","success":true}\n' ;;
  list-verbs)
    printf '%s\n' '{"version":1,"daemon_version":"0.8.0","success":true,"verbs":[
      {"verb":"capture-pane","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"close-window","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"get-agent-state","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"get-window","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"list-agents","params":[{"name":"session"},{"name":"all"}]},
      {"verb":"list-queued","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"list-windows","params":[{"name":"session"}]},
      {"verb":"list-workspaces","params":[{"name":"session"}]},
      {"verb":"set-workspace-name","params":[{"name":"session"},{"name":"workspace"},{"name":"name"}]},
      {"verb":"new-window","params":[{"name":"session"},{"name":"name"},{"name":"cwd"},{"name":"focus"},{"name":"workspace"}]},
      {"verb":"peek-prompt","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"queue-prompt","params":[{"name":"session"},{"name":"window"},{"name":"text"}]},
      {"verb":"resume-agent","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"send-keys","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"send-text","params":[{"name":"session"},{"name":"window"}]}]}'
    ;;
  list-attention) printf '{"boot_id":"boot-test","success":true,"items":[]}\n' ;;
  list-workspaces)
    rows=()
    for workspace in $(seq 1 9); do
      name= count=0
      if [ -f "${SQUAD_FAKE_TUIOS_WORKSPACEFILE:?}" ] && [ "$(cat "$SQUAD_FAKE_TUIOS_WORKSPACEFILE")" = "$workspace" ]; then
        name=$(cat "${SQUAD_FAKE_TUIOS_WORKSPACENAMEFILE:?}" 2>/dev/null || printf '')
        [ ! -f "${SQUAD_FAKE_TUIOS_WINDOWFILE:?}" ] || count=1
      fi
      rows+=("$(jq -cn --argjson ws "$workspace" --arg name "$name" --argjson count "$count" '{workspace:$ws,name:$name,window_count:$count}')")
    done
    printf '{"workspaces":[%s],"success":true}\n' "$(IFS=,; echo "${rows[*]}")"
    ;;
  set-workspace-name)
    shift
    [ "${1:-}" = --session ] && shift 2
    printf '%s\n' "${1:-}" > "${SQUAD_FAKE_TUIOS_WORKSPACEFILE:?}"
    printf '%s\n' "${2:-}" > "${SQUAD_FAKE_TUIOS_WORKSPACENAMEFILE:?}"
    ;;
  list-windows)
    cwd=$(cat "${SQUAD_FAKE_TUIOS_CWDFILE:?}" 2>/dev/null || printf '%s' "${SQUAD_FAKE_TUIOS_PROJECT:?}")
    if [ -f "${SQUAD_FAKE_TUIOS_WINDOWFILE:?}" ]; then
      printf '{"windows":[{"window_id":"%s","custom_name":"%s","workspace":%s,"cwd":"%s"}],"success":true}\n' \
        "${SQUAD_FAKE_TUIOS_ID:?}" "${SQUAD_FAKE_TUIOS_LABEL:-}" "$(cat "${SQUAD_FAKE_TUIOS_WORKSPACEFILE:?}" 2>/dev/null || printf '1')" "$cwd"
    else
      printf '{"windows":[],"success":true}\n'
    fi
    ;;
  new-window)
    shift
    label=$1
    shift
    workspace=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --workspace ]; then workspace=$2; shift 2; else shift; fi
    done
    printf '%s\n' "$workspace" > "${SQUAD_FAKE_TUIOS_WORKSPACEFILE:?}"
    printf '%s\n' "${SQUAD_FAKE_TUIOS_LABEL:-$label}" > "${SQUAD_FAKE_TUIOS_WORKSPACENAMEFILE:?}"
    printf '%s\n' "${SQUAD_FAKE_TUIOS_ID:?}"
    : > "${SQUAD_FAKE_TUIOS_WINDOWFILE:?}"
    printf '%s\n' "${SQUAD_FAKE_TUIOS_PROJECT:?}" > "${SQUAD_FAKE_TUIOS_CWDFILE:?}"
    ;;
  get-window)
    printf '{"window":{"id":"%s","custom_name":"%s","cwd":"%s"},"success":true}\n' \
      "${SQUAD_FAKE_TUIOS_ID:?}" "${SQUAD_FAKE_TUIOS_LABEL:-}" \
      "$(cat "${SQUAD_FAKE_TUIOS_CWDFILE:?}" 2>/dev/null || printf '%s' "${SQUAD_FAKE_TUIOS_PROJECT:?}")"
    ;;
  list-agents)
    if [ -n "${SQUAD_FAKE_TUIOS_AGENTS_JSON:-}" ]; then
      printf '%s\n' "$SQUAD_FAKE_TUIOS_AGENTS_JSON"
    else
      printf '{"agents":[{"window_id":"%s","state":"working","foreground":"pi","harness_id":"pi","confidence":"certain"}],"success":true}\n' "${SQUAD_FAKE_TUIOS_ID:?}"
    fi
    ;;
  send-text)
    # Record a top-level `cd` as the window's new shell cwd, as a real shell would.
    payload=${*: -1}
    case "$payload" in
      "cd -- "*)
        printf '%s\n' "${payload#cd -- }" | tr -d "'" > "${SQUAD_FAKE_TUIOS_CWDFILE:?}"
        ;;
    esac
    ;;
  send-keys) : ;;
  run-command)
    [ "${4:-}" != CloseWindow ] || rm -f "${SQUAD_FAKE_TUIOS_WINDOWFILE:?}"
    printf '{"message":"command executed","success":true}\n'
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tuios"
  cat > "$fakebin/fob" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${SQUAD_FAKE_FOB_LOG:?}"
case "${1:-}" in
  get)
    case " $* " in
      *" --lease "*) printf '%s\n' "${SQUAD_FAKE_FOB_LEASE:?}" ;;
      *) printf 'Entered worktree at %s\n' "${SQUAD_FAKE_FOB_LEASE:?}" ;;
    esac
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/fob"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id>: a project, worktree, home base, and fake CLIs for one
# spawn. The base is pinned to pi through config/crew-harness.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_tuios_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/runtime" "$case_dir/pi-agent"
  printf 'pi\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\necho done >> %s.status\n' "$id" "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-sentry-beat"
  printf '%s\n' "$proj" > "$case_dir/cwd"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn <id> <label>: a single-task TUIOS spawn. Callers export any
# SQUAD_RESUME_MAX_BYTES override before calling.
run_spawn() {
  local id=$1 label=$2
  SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$HOME_DIR" \
    SQUAD_STATE_OVERRIDE="$HOME_DIR/state" SQUAD_DATA_OVERRIDE="$HOME_DIR/data" \
    SQUAD_PROJECTS_OVERRIDE="$HOME_DIR/projects" SQUAD_CONFIG_OVERRIDE="$HOME_DIR/config" \
    XDG_RUNTIME_DIR="$CASE_DIR/runtime" SQUAD_SPAWN_NO_GUARD=1 SQUAD_TUIOS_SESSION=owned \
    PI_CODING_AGENT_DIR="$CASE_DIR/pi-agent" \
    SQUAD_FAKE_TUIOS_LOG="$CASE_DIR/tuios.log" \
    SQUAD_FAKE_FOB_LOG="$CASE_DIR/fob.log" \
    SQUAD_FAKE_FOB_LEASE="$WT_DIR" \
    SQUAD_FAKE_TUIOS_ID="$WINDOW_ID" SQUAD_FAKE_TUIOS_LABEL="$label" \
    SQUAD_FAKE_TUIOS_PROJECT="$PROJ_DIR" \
    SQUAD_FAKE_TUIOS_CWDFILE="$CASE_DIR/cwd" \
    SQUAD_FAKE_TUIOS_WINDOWFILE="$CASE_DIR/window" \
    SQUAD_FAKE_TUIOS_WORKSPACEFILE="$CASE_DIR/workspace" \
    SQUAD_FAKE_TUIOS_WORKSPACENAMEFILE="$CASE_DIR/workspace-name" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode drill --yolo off --backend tuios 2>&1
}

# seed_relaunch_meta <id> <harness> <model> [pi-session-id]: a recorded TUIOS pi
# endpoint, so the next spawn takes the relaunch path into the same window.
seed_relaunch_meta() {
  local id=$1 harness=$2 model=$3 session=${4-}
  {
    printf 'window=owned:%s\n' "$WINDOW_ID"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$WT_DIR"
    printf 'project=%s\n' "$PROJ_DIR"
    printf 'harness=%s\n' "$harness"
    printf 'model=%s\n' "$model"
    printf 'backend=tuios\n'
    printf 'tuios_session=owned\n'
    printf 'tuios_window_id=%s\n' "$WINDOW_ID"
    printf 'tuios_workspace_id=4\n'
    printf 'tuios_boot_id=boot-test\n'
    [ -z "$session" ] || printf 'pi_session_id=%s\n' "$session"
  } > "$HOME_DIR/state/$id.meta"
  printf '4\n' > "$CASE_DIR/workspace"
  : > "$CASE_DIR/window"
}

# The finished, foreground-less agent shape: the window is recovered for reuse.
finished_agentless() {
  SQUAD_FAKE_TUIOS_AGENTS_JSON=$(jq -cn --arg id "$WINDOW_ID" '{agents:[{window_id:$id,state:"done",foreground:"",harness_id:"pi",confidence:"certain"}],success:true}')
  export SQUAD_FAKE_TUIOS_AGENTS_JSON
}

# write_transcript <case-dir-pi-agent> <wt> <id> [bytes]: a pi transcript at the
# path pi's cwd-keyed store uses for the worktree, named as pi names it.
write_transcript() {
  local agent=$1 wt=$2 id=$3 bytes=${4:-200} key dir
  key=${wt#/}
  key=${key//\//-}
  dir="$agent/sessions/--$key--"
  mkdir -p "$dir"
  head -c "$bytes" /dev/zero | tr '\0' 'x' > "$dir/2026-11-20T00-00-00-000Z_$id.jsonl"
}

# launch_line: the pi launch the spawn typed into the window (the send-text
# payload is the only tuios call that carries the brief encoder).
launch_line() {
  grep -F 'launch-brief' "$CASE_DIR/tuios.log" || true
}

status_lines() {
  cat "$HOME_DIR/state/$1.status" 2>/dev/null || true
}

# A first pi operator spawn pins its conversation to the task id, and the meta
# records the pin so a later relaunch can find the same conversation.
test_fresh_pi_spawn_pins_conversation() {
  local rec id label out status line
  id=pi-resume-fresh
  label="sq-$id"
  rec=$(make_case fresh "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$label")
  status=$?
  expect_code 0 "$status" "a fresh pi spawn should succeed: $out"
  assert_grep "pi_session_id=sq-$id" "$HOME_DIR/state/$id.meta" 'meta did not record the pinned pi session id'
  line=$(launch_line)
  assert_contains "$line" "--session-id sq-$id " 'the fresh pi launch must pin the conversation with --session-id'
  assert_contains "$line" 'encode launch-brief < ' 'a fresh pi launch must carry the full brief'
  [ -z "$(status_lines "$id")" ] || fail 'a fresh spawn is not a relaunch and must append no status line'
  pass 'a fresh pi operator spawn pins sq-<task-id> and records pi_session_id'
}

# An agentless recovered window with an in-budget transcript and matching harness
# and model resumes the same conversation, never re-sending the brief.
test_relaunch_resumes_same_conversation() {
  local rec id label out status line
  id=pi-resume-yes
  label="sq-$id"
  rec=$(make_case resume-yes "$id")
  read_case "$rec"

  seed_relaunch_meta "$id" pi default "sq-$id"
  write_transcript "$CASE_DIR/pi-agent" "$WT_DIR" "sq-$id" 200
  finished_agentless
  out=$(run_spawn "$id" "$label")
  status=$?
  unset SQUAD_FAKE_TUIOS_AGENTS_JSON
  expect_code 0 "$status" "a resumable pi relaunch should succeed: $out"
  assert_contains "$out" "reusing the recorded agentless task window owned:$WINDOW_ID" \
    'the relaunch must reuse the recovered window'
  line=$(launch_line)
  assert_contains "$line" "--session sq-$id " 'a resumed relaunch must reopen the pinned conversation with --session'
  assert_contains "$line" 'same conversation' 'a resumed relaunch must carry the continuation note'
  if printf '%s' "$line" | grep -qF -- '--session-id'; then
    fail 'a resumed relaunch must not start a new pinned conversation'
  fi
  if printf '%s' "$line" | grep -qF -- 'encode launch-brief < '; then
    fail 'a resumed relaunch must never re-send the full brief'
  fi
  assert_grep "pi_session_id=sq-$id" "$HOME_DIR/state/$id.meta" 'a resumed relaunch must keep the pinned session id'
  [ "$(status_lines "$id")" = "resumed: same conversation (session sq-$id)" ] \
    || fail "a resumed relaunch must append exactly the resumed status line, got: $(status_lines "$id")"
  pass 'a recovered agentless pi window resumes the same conversation and never re-sends the brief'
}

# Each refused gate relaunches a fresh conversation with the full brief, with no
# pin, and names the refusal in its one status line. The transcript is never reopened.
# refuse_case <name> <reason> <pinned yes|no> <meta-harness> <meta-model> <transcript-bytes|none> [max-bytes] [window recovered|gone]
# A transcript is always named for the task's pinned id, so the id gate is the only
# thing that differs when pinned is no.
refuse_case() {
  local name=$1 reason=$2 pinned=$3 harness=$4 model=$5 bytes=$6 max=${7-} window=${8:-recovered}
  local id label rec out status line session=
  id=pi-resume-$name
  label="sq-$id"
  rec=$(make_case "$name" "$id")
  read_case "$rec"
  [ "$pinned" != yes ] || session="sq-$id"

  seed_relaunch_meta "$id" "$harness" "$model" "$session"
  [ "$window" != gone ] || rm -f "$CASE_DIR/window"
  if [ "$bytes" != none ]; then
    write_transcript "$CASE_DIR/pi-agent" "$WT_DIR" "sq-$id" "$bytes"
  fi
  if [ -n "$max" ]; then
    SQUAD_RESUME_MAX_BYTES=$max
    export SQUAD_RESUME_MAX_BYTES
  fi
  finished_agentless
  out=$(run_spawn "$id" "$label")
  status=$?
  unset SQUAD_FAKE_TUIOS_AGENTS_JSON SQUAD_RESUME_MAX_BYTES
  expect_code 0 "$status" "a refused resume must still relaunch ($reason): $out"
  line=$(launch_line)
  if printf '%s' "$line" | grep -qF -- "--session sq-$id "; then
    fail "a refused resume ($reason) must never reopen the recorded conversation"
  fi
  if printf '%s' "$line" | grep -qF -- "--session-id sq-$id "; then
    fail "a refused resume ($reason) must not pin the old conversation id"
  fi
  assert_contains "$line" 'encode launch-brief < ' "a refused resume ($reason) must re-send the full brief"
  if grep -q '^pi_session_id=' "$HOME_DIR/state/$id.meta"; then
    fail "a refused resume ($reason) must not record a pinned session id"
  fi
  [ "$(status_lines "$id")" = "relaunched: fresh brief ($reason)" ] \
    || fail "a refused resume ($reason) must append exactly the re-brief status line, got: $(status_lines "$id")"
  pass "a refused resume ($reason) relaunches a fresh conversation with the full brief"
}

test_refused_no_recorded_session() {
  refuse_case no-session 'no recorded session id' no pi default 200
}

test_refused_missing_transcript() {
  refuse_case missing-transcript 'missing or unreadable transcript' yes pi default none
}

test_refused_oversize_transcript() {
  refuse_case oversize 'oversize transcript' yes pi default 200 8
}

test_refused_harness_mismatch() {
  refuse_case harness 'harness mismatch' yes codex default 200
}

test_refused_model_mismatch() {
  refuse_case model 'model mismatch' yes pi claude-other 200
}

test_refused_window_not_reused() {
  refuse_case not-reused 'endpoint was not a recovered agentless window' yes pi default 200 '' gone
}

test_refused_invalid_max_bytes() {
  refuse_case invalid-max 'invalid SQUAD_RESUME_MAX_BYTES' yes pi default 200 not-a-number
}

# expect_unpinned_fresh_launch <id> <why>: the spawn launched a fresh conversation
# with the full brief, no --session-id pin, and no recorded pi_session_id.
expect_unpinned_fresh_launch() {
  local id=$1 why=$2 line
  line=$(launch_line)
  assert_contains "$line" 'encode launch-brief < ' "$why: the launch must carry the full brief"
  if printf '%s' "$line" | grep -qE -- '--session(-id)? sq-'; then
    fail "$why: the launch must carry no pi session argument"
  fi
  if grep -q '^pi_session_id=' "$HOME_DIR/state/$id.meta"; then
    fail "$why: the meta must record no pi_session_id"
  fi
}

# A first spawn whose worktree already holds an sq-<task-id> transcript (meta lost)
# must not pin that id, because pi's --session-id would silently reopen it.
test_fresh_spawn_with_stale_transcript_is_unpinned() {
  local rec id label out status
  id=pi-resume-stale
  label="sq-$id"
  rec=$(make_case stale "$id")
  read_case "$rec"

  write_transcript "$CASE_DIR/pi-agent" "$WT_DIR" "sq-$id" 200
  out=$(run_spawn "$id" "$label")
  status=$?
  expect_code 0 "$status" "a fresh pi spawn over a stale transcript should succeed: $out"
  expect_unpinned_fresh_launch "$id" 'a stale sq-<task-id> transcript'
  pass 'a fresh pi spawn never pins an id whose transcript already exists'
}

# A valid task id that does not end in a letter or number cannot be a pi session
# id, so the spawn launches unpinned instead of failing pi's argument check.
test_fresh_spawn_with_unpinnable_id_is_unpinned() {
  local rec id label out status
  id=pi-resume-trailing-
  label="sq-$id"
  rec=$(make_case trailing "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$label")
  status=$?
  expect_code 0 "$status" "a pi spawn with a trailing-dash id should succeed: $out"
  expect_unpinned_fresh_launch "$id" 'an id outside pi session-id grammar'
  pass 'a task id outside pi session-id grammar launches unpinned'
}

# Pi keys its store by the physical cwd, so a worktree reached through a symlink
# must still find the transcript stored under the resolved path.
test_symlinked_worktree_resumes_physical_transcript() {
  local rec id label out status line real
  id=pi-resume-symlink
  label="sq-$id"
  rec=$(make_case symlink "$id")
  read_case "$rec"
  real=$(cd "$WT_DIR" && pwd -P)
  ln -s "$real" "$CASE_DIR/wt-link"
  WT_DIR="$CASE_DIR/wt-link"

  seed_relaunch_meta "$id" pi default "sq-$id"
  write_transcript "$CASE_DIR/pi-agent" "$real" "sq-$id" 200
  finished_agentless
  out=$(run_spawn "$id" "$label")
  status=$?
  unset SQUAD_FAKE_TUIOS_AGENTS_JSON
  expect_code 0 "$status" "a resumable relaunch through a symlinked worktree should succeed: $out"
  line=$(launch_line)
  assert_contains "$line" "--session sq-$id " 'a symlinked worktree must resume from the physical-path transcript'
  [ "$(status_lines "$id")" = "resumed: same conversation (session sq-$id)" ] \
    || fail "a symlinked worktree resume must append the resumed status line, got: $(status_lines "$id")"
  pass 'a symlinked worktree resumes from the transcript keyed by its physical path'
}

# PI_CODING_AGENT_SESSION_DIR moves pi's store; a stale transcript there must still
# keep a first spawn from pinning the id.
test_fresh_spawn_with_stale_transcript_in_session_dir_is_unpinned() {
  local rec id label out status
  id=pi-resume-sessiondir
  label="sq-$id"
  rec=$(make_case sessiondir "$id")
  read_case "$rec"
  mkdir -p "$CASE_DIR/sessions"
  printf 'x\n' > "$CASE_DIR/sessions/2026-11-20T00-00-00-000Z_sq-$id.jsonl"

  out=$(PI_CODING_AGENT_SESSION_DIR="$CASE_DIR/sessions" run_spawn "$id" "$label")
  status=$?
  expect_code 0 "$status" "a fresh pi spawn over a stale session-dir transcript should succeed: $out"
  expect_unpinned_fresh_launch "$id" 'a stale transcript in PI_CODING_AGENT_SESSION_DIR'
  pass 'a fresh pi spawn honours PI_CODING_AGENT_SESSION_DIR for the stale-transcript guard'
}

# A sessionDir setting moves pi's store to a location this script does not resolve,
# so a first spawn must not risk pinning an existing conversation.
test_fresh_spawn_with_session_dir_setting_is_unpinned() {
  local rec id label out status
  id=pi-resume-sessionsetting
  label="sq-$id"
  rec=$(make_case sessionsetting "$id")
  read_case "$rec"
  printf '{"sessionDir": "%s"}\n' "$CASE_DIR/elsewhere" > "$CASE_DIR/pi-agent/settings.json"

  out=$(run_spawn "$id" "$label")
  status=$?
  expect_code 0 "$status" "a fresh pi spawn with a sessionDir setting should succeed: $out"
  expect_unpinned_fresh_launch "$id" 'a sessionDir setting'
  pass 'a fresh pi spawn launches unpinned when a sessionDir setting moves the store'
}

# Only a pi operator relaunch records its path; a codex relaunch into the same
# recovered window keeps its prior behaviour and appends no status line.
test_codex_relaunch_appends_no_status_line() {
  local rec id label out status
  id=pi-resume-codex
  label="sq-$id"
  rec=$(make_case codex "$id")
  read_case "$rec"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"

  seed_relaunch_meta "$id" codex default
  finished_agentless
  out=$(run_spawn "$id" "$label")
  status=$?
  unset SQUAD_FAKE_TUIOS_AGENTS_JSON
  expect_code 0 "$status" "a codex relaunch into a recovered window should succeed: $out"
  assert_contains "$out" "reusing the recorded agentless task window owned:$WINDOW_ID" \
    'the codex relaunch must reuse the recovered window'
  [ -z "$(status_lines "$id")" ] \
    || fail "a codex relaunch must append no status line, got: $(status_lines "$id")"
  if grep -q '^pi_session_id=' "$HOME_DIR/state/$id.meta"; then
    fail 'a codex relaunch must record no pi_session_id'
  fi
  pass 'a codex relaunch into a recovered window appends no status line'
}

test_fresh_pi_spawn_pins_conversation
test_codex_relaunch_appends_no_status_line
test_fresh_spawn_with_stale_transcript_is_unpinned
test_fresh_spawn_with_stale_transcript_in_session_dir_is_unpinned
test_fresh_spawn_with_session_dir_setting_is_unpinned
test_symlinked_worktree_resumes_physical_transcript
test_fresh_spawn_with_unpinnable_id_is_unpinned
test_relaunch_resumes_same_conversation
test_refused_window_not_reused
test_refused_invalid_max_bytes
test_refused_no_recorded_session
test_refused_missing_transcript
test_refused_oversize_transcript
test_refused_harness_mismatch
test_refused_model_mismatch

echo "# all sq-spawn-pi-session-resume tests passed"
