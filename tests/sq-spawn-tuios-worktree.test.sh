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
      {"verb":"new-window","params":[{"name":"session"},{"name":"name"},{"name":"cwd"},{"name":"focus"}]},
      {"verb":"peek-prompt","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"queue-prompt","params":[{"name":"session"},{"name":"window"},{"name":"text"}]},
      {"verb":"resume-agent","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"send-keys","params":[{"name":"session"},{"name":"window"}]},
      {"verb":"send-text","params":[{"name":"session"},{"name":"window"}]}]}'
    ;;
  list-attention) printf '{"boot_id":"boot-test","success":true,"items":[]}\n' ;;
  list-windows)
    # The reported cwd is the window's own shell cwd, tracked in a state file.
    cwd=$(cat "${SQUAD_FAKE_TUIOS_CWDFILE:?}" 2>/dev/null || printf '%s' "${SQUAD_FAKE_TUIOS_PROJECT:?}")
    if [ -f "${SQUAD_FAKE_TUIOS_WINDOWFILE:?}" ]; then
      printf '{"windows":[{"window_id":"%s","custom_name":"%s","cwd":"%s"}],"success":true}\n' \
        "${SQUAD_FAKE_TUIOS_ID:?}" "${SQUAD_FAKE_TUIOS_LABEL:-}" "$cwd"
    else
      printf '{"windows":[],"success":true}\n'
    fi
    ;;
  new-window)
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
    if [ "${SQUAD_FAKE_TUIOS_HOLD_LEASE:-0}" = 1 ]; then
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
  run-command) printf '{"message":"command executed","success":true}\n' ;;
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
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
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
    SQUAD_SPAWN_NO_GUARD=1 SQUAD_TUIOS_SESSION=owned \
    SQUAD_FAKE_TUIOS_LOG="$CASE_DIR/tuios.log" \
    SQUAD_FAKE_FOB_LOG="$CASE_DIR/fob.log" \
    SQUAD_FAKE_FOB_LEASE="$WT_DIR" \
    SQUAD_FAKE_TUIOS_ID="$WINDOW_ID" SQUAD_FAKE_TUIOS_LABEL="$label" \
    SQUAD_FAKE_TUIOS_PROJECT="$PROJ_DIR" SQUAD_FAKE_TUIOS_HOLD_LEASE="$hold" \
    SQUAD_FAKE_TUIOS_CWDFILE="$CASE_DIR/cwd" \
    SQUAD_FAKE_TUIOS_WINDOWFILE="$CASE_DIR/window" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode drill --yolo off --backend tuios 2>&1
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
  pass 'a TUIOS spawn that fails before metadata returns the lease'
}

test_tuios_spawn_leases_and_records_worktree
test_tuios_spawn_returns_lease_on_failure
test_tuios_spawn_returns_lease_on_send_failure
test_tuios_spawn_returns_lease_before_metadata

echo "# all sq-spawn-tuios-worktree tests passed"
