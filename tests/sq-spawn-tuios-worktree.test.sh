#!/usr/bin/env bash
# Regression test for the TUIOS worktree acquisition in bin/sq-spawn.sh
# (spawn_acquire_worktree_tuios).
#
# TUIOS reports only its own top-level shell's cwd, while `fob get` moves into
# the worktree by opening a NESTED subshell. The pane's reported cwd therefore
# never changes, so the historical `fob get` + cwd-poll sequence timed out after
# 60s on every TUIOS spawn, wrote no metadata, and never launched an agent. This
# test drives the real sq-spawn.sh with a fake TUIOS CLI and asserts the TUIOS
# path acquires the lease non-interactively (`fob get --lease`), cds the
# window's own shell into the lease path, records that exact path as the task's
# worktree, and publishes the TUIOS endpoint metadata. It also asserts the
# failure path returns the lease instead of leaking it out of the pool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/sq-spawn.sh"
TMP_ROOT=$(fm_test_tmproot sq-spawn-tuios-worktree)
WINDOW_ID=w-opaque-tuios

# make_tuios_fakebin <dir>: a fake TUIOS CLI that models the one behavior the
# spawn path depends on - the window's reported cwd follows a `cd` typed into
# the window's own shell, and NOT a `fob get` subshell.
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
    # The reported cwd is the window's own shell cwd, tracked in a state file.
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
    elif [ "${SQUAD_FAKE_TUIOS_HOLD_LEASE:-0}" = 1 ]; then
      printf '{"agents":[{"window_id":"%s","state":"none","foreground":"","harness_id":"","confidence":"none"}],"success":true}\n' "${SQUAD_FAKE_TUIOS_ID:?}"
    else
      printf '{"agents":[{"window_id":"%s","state":"working","foreground":"pi","harness_id":"pi","confidence":"certain"}],"success":true}\n' "${SQUAD_FAKE_TUIOS_ID:?}"
    fi
    ;;
  send-text)
    if [ "${SQUAD_FAKE_TUIOS_SEND_TEXT_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    # Record any top-level `cd` as the window's new shell cwd. A `fob get`
    # subshell must NOT move it - that is the defect this test guards.
    payload=${*: -1}
    case "$payload" in
      "cd -- "*)
        if [ "${SQUAD_FAKE_TUIOS_HOLD_LEASE:-0}" != 1 ]; then
          printf '%s\n' "${payload#cd -- }" | tr -d "'" > "${SQUAD_FAKE_TUIOS_CWDFILE:?}"
        fi
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

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_tuios_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/runtime"
  printf 'codex\n' > "$home/config/crew-harness"
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

run_spawn() {
  local id=$1 label=$2 hold=$3
  SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$HOME_DIR" \
    SQUAD_STATE_OVERRIDE="$HOME_DIR/state" SQUAD_DATA_OVERRIDE="$HOME_DIR/data" \
    SQUAD_PROJECTS_OVERRIDE="$HOME_DIR/projects" SQUAD_CONFIG_OVERRIDE="$HOME_DIR/config" \
    XDG_RUNTIME_DIR="$CASE_DIR/runtime" SQUAD_SPAWN_NO_GUARD=1 SQUAD_TUIOS_SESSION=owned \
    SQUAD_FAKE_TUIOS_LOG="$CASE_DIR/tuios.log" \
    SQUAD_FAKE_FOB_LOG="$CASE_DIR/fob.log" \
    SQUAD_FAKE_FOB_LEASE="$WT_DIR" \
    SQUAD_FAKE_TUIOS_ID="$WINDOW_ID" SQUAD_FAKE_TUIOS_LABEL="$label" \
    SQUAD_FAKE_TUIOS_PROJECT="$PROJ_DIR" SQUAD_FAKE_TUIOS_HOLD_LEASE="$hold" \
    SQUAD_FAKE_TUIOS_CWDFILE="$CASE_DIR/cwd" \
    SQUAD_FAKE_TUIOS_WINDOWFILE="$CASE_DIR/window" \
    SQUAD_FAKE_TUIOS_WORKSPACEFILE="$CASE_DIR/workspace" \
    SQUAD_FAKE_TUIOS_WORKSPACENAMEFILE="$CASE_DIR/workspace-name" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode drill --yolo off --backend tuios 2>&1
}

assert_tuios_abort_released_workspace() {
  [ ! -f "$CASE_DIR/window" ] || fail 'an aborted TUIOS spawn must close only its task window'
  [ -z "$(cat "$CASE_DIR/workspace-name" 2>/dev/null || true)" ] || fail 'an aborted TUIOS spawn must release its task workspace name'
}

# seed_relaunch_meta <id>: publish a recorded TUIOS task endpoint so the next
# spawn takes the relaunch path instead of creating a fresh task window.
seed_relaunch_meta() {
  local id=$1
  cat > "$HOME_DIR/state/$id.meta" <<EOF
window=owned:$WINDOW_ID
endpoint_task_id=$id
worktree=$WT_DIR
project=$PROJ_DIR
backend=tuios
tuios_session=owned
tuios_window_id=$WINDOW_ID
tuios_workspace_id=4
tuios_boot_id=boot-test
EOF
  printf '4\n' > "$CASE_DIR/workspace"
  : > "$CASE_DIR/window"
}

# A TUIOS spawn must acquire the lease non-interactively, cd the window's own
# shell into it, record that exact path, and publish the endpoint metadata.
test_tuios_spawn_leases_and_records_worktree() {
  local rec id label out status
  id=tuios-spawn-lease-t1
  label="sq-$id"
  rec=$(make_case tuios-lease "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$label" 0)
  status=$?
  expect_code 0 "$status" "TUIOS spawn should succeed: $out"
  assert_contains "$out" "spawned $id" 'spawn did not report success'
  assert_grep "backend=tuios" "$HOME_DIR/state/$id.meta" 'meta did not record backend=tuios'
  assert_grep "tuios_session=owned" "$HOME_DIR/state/$id.meta" 'meta did not record the TUIOS session'
  assert_grep "tuios_window_id=$WINDOW_ID" "$HOME_DIR/state/$id.meta" 'meta did not record the opaque window id'
  assert_grep 'tuios_workspace_id=1' "$HOME_DIR/state/$id.meta" 'meta did not record the task workspace id'
  assert_grep "tuios_boot_id=boot-test" "$HOME_DIR/state/$id.meta" 'meta did not record the daemon boot id'
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" 'meta did not record the leased worktree path'
  assert_contains "$(cat "$CASE_DIR/fob.log")" 'get --lease' 'the worktree must be acquired with a non-interactive lease'
  assert_contains "$(cat "$CASE_DIR/tuios.log")" "send-text --session owned --window $WINDOW_ID -- cd -- '$WT_DIR'" \
    'the window shell must receive a top-level cd into the lease path'
  if grep -qE "send-text --session owned --window $WINDOW_ID -- fob get" "$CASE_DIR/tuios.log"; then
    fail 'the TUIOS window must never be sent the nested-shell fob get sequence'
  fi
  pass 'a TUIOS spawn acquires a lease, cds the window into it, and records that exact worktree'
}

# When the window never reports the lease path, the spawn must fail AND return
# the durable lease, which a window close would otherwise leak forever.
test_tuios_spawn_returns_lease_on_failure() {
  local rec id label out status
  id=tuios-spawn-lease-t2
  label="sq-$id"
  rec=$(make_case tuios-lease-fail "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$label" 1)
  status=$?
  [ "$status" -ne 0 ] || fail 'a window that never enters the lease must fail the spawn'
  assert_contains "$out" 'did not enter' 'the failure must say the window never entered the worktree'
  [ -f "$HOME_DIR/state/$id.meta" ] && fail 'a failed spawn must not publish metadata'
  assert_contains "$(cat "$CASE_DIR/fob.log")" "return --force $WT_DIR" 'a failed spawn must return the durable lease'
  assert_tuios_abort_released_workspace
  pass 'a TUIOS spawn that cannot enter the lease fails and returns the lease'
}

# A failure to type the top-level cd (e.g. the daemon refuses send-text right
# after window creation) must also return the durable lease. The acquisition
# guard runs before any metadata exists, so teardown could never recover it.
test_tuios_spawn_returns_lease_on_send_failure() {
  local rec id label out status
  id=tuios-spawn-lease-t3
  label="sq-$id"
  rec=$(make_case tuios-lease-send-fail "$id")
  read_case "$rec"

  SQUAD_FAKE_TUIOS_SEND_TEXT_FAIL=1
  export SQUAD_FAKE_TUIOS_SEND_TEXT_FAIL
  out=$(run_spawn "$id" "$label" 0)
  status=$?
  unset SQUAD_FAKE_TUIOS_SEND_TEXT_FAIL
  [ "$status" -ne 0 ] || fail 'a refused worktree cd must fail the spawn'
  [ -f "$HOME_DIR/state/$id.meta" ] && fail 'a failed spawn must not publish metadata'
  assert_contains "$(cat "$CASE_DIR/fob.log")" "return --force $WT_DIR" 'a send failure must return the durable lease'
  assert_tuios_abort_released_workspace
  pass 'a TUIOS spawn whose worktree cd is refused fails and returns the lease'
}

# A failure in the window between verified acquisition and metadata publication
# (here the after_create workspace hook) must also return the durable lease:
# no metadata exists yet, so teardown could never recover it.
test_tuios_spawn_returns_lease_before_metadata() {
  local rec id label out status
  id=tuios-spawn-lease-t4
  label="sq-$id"
  rec=$(make_case tuios-lease-pre-meta "$id")
  read_case "$rec"

  cat > "$PROJ_DIR/WORKFLOW.md" <<'EOF'
---
schema_version: "1.0.0"
hooks:
  after_create:
    command: ["bash", "-c", "exit 1"]
    timeout_ms: 2000
---
EOF
  out=$(run_spawn "$id" "$label" 0)
  status=$?
  [ "$status" -ne 0 ] || fail 'a failed after_create hook must fail the spawn'
  assert_contains "$out" 'after_create hook failed' 'the failure must name the workspace hook'
  [ -f "$HOME_DIR/state/$id.meta" ] && fail 'a failed spawn must not publish metadata'
  assert_contains "$(cat "$CASE_DIR/fob.log")" "return --force $WT_DIR" 'a pre-metadata failure must return the durable lease'
  assert_tuios_abort_released_workspace
  pass 'a TUIOS spawn that fails before metadata returns the lease'
}

# A recorded task window whose endpoint still holds a live agent must refuse a
# duplicate launch: the recovery path must never relax that guard.
test_tuios_relaunch_refuses_live_endpoint() {
  local rec id label out status
  id=tuios-relaunch-live
  label="sq-$id"
  rec=$(make_case tuios-relaunch-live "$id")
  read_case "$rec"

  seed_relaunch_meta "$id"
  out=$(run_spawn "$id" "$label" 0)
  status=$?
  [ "$status" -ne 0 ] || fail 'a live recorded endpoint must refuse a duplicate launch'
  assert_contains "$out" "existing tuios endpoint for $id is alive; refusing duplicate launch" \
    'the refusal must name the live endpoint'
  if grep -q 'new-window' "$CASE_DIR/tuios.log"; then
    fail 'a refused duplicate launch must not create a second window'
  fi
  pass 'a TUIOS relaunch refuses a live recorded agent instead of duplicating it'
}

# A finished agent whose foreground program has exited leaves its window behind;
# the relaunch must reuse that exact window and the recorded worktree rather than
# refusing on the label or leasing a second copy.
test_tuios_relaunch_reuses_finished_agentless_window() {
  local rec id label out status
  id=tuios-relaunch-finished
  label="sq-$id"
  rec=$(make_case tuios-relaunch-finished "$id")
  read_case "$rec"

  seed_relaunch_meta "$id"
  SQUAD_FAKE_TUIOS_AGENTS_JSON=$(jq -cn --arg id "$WINDOW_ID" '{agents:[{window_id:$id,state:"done",foreground:"",harness_id:"pi",confidence:"certain"}],success:true}')
  export SQUAD_FAKE_TUIOS_AGENTS_JSON
  out=$(run_spawn "$id" "$label" 0)
  status=$?
  unset SQUAD_FAKE_TUIOS_AGENTS_JSON
  expect_code 0 "$status" "a finished, foreground-less recorded agent must relaunch: $out"
  assert_contains "$out" "reusing the recorded agentless task window owned:$WINDOW_ID" \
    'the relaunch must reuse the recorded agentless window'
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" 'the relaunch must keep the recorded worktree'
  assert_grep "tuios_window_id=$WINDOW_ID" "$HOME_DIR/state/$id.meta" 'the relaunch must keep the recorded window id'
  assert_grep 'tuios_boot_id=boot-test' "$HOME_DIR/state/$id.meta" 'the relaunch must refresh the recorded boot id'
  if grep -q 'new-window' "$CASE_DIR/tuios.log"; then
    fail 'an agentless relaunch must reuse the recorded window, not create a new one'
  fi
  pass 'a TUIOS relaunch reuses the recorded window for a finished, foreground-less agent'
}

test_tuios_spawn_leases_and_records_worktree
test_tuios_spawn_returns_lease_on_failure
test_tuios_spawn_returns_lease_on_send_failure
test_tuios_spawn_returns_lease_before_metadata
test_tuios_relaunch_refuses_live_endpoint
test_tuios_relaunch_reuses_finished_agentless_window

echo "# all sq-spawn-tuios-worktree tests passed"
