#!/usr/bin/env bash
# Behavior tests for the Claude account axis: bin/sq-claude-account.sh's
# registry parsing/verification, and bin/sq-spawn.sh's --account selector
# (docs/configuration.md "Claude account selection").
#
# All of this is exercised against a fake `claude` executable, never the real
# CLI or any real credential store - the live counterpart is
# tests/sq-claude-account-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACCOUNT="$ROOT/bin/sq-claude-account.sh"
SPAWN="$ROOT/bin/sq-spawn.sh"
TMP_ROOT=$(fm_test_tmproot sq-claude-account)

# make_fake_claude <fakebin-dir>: a `claude` stub whose `auth status --json`
# reports loggedIn based on a marker file inside CLAUDE_CONFIG_DIR, mirroring
# the real CLI's exit codes (0 when logged in, 1 otherwise) and JSON shape
# (verified live against claude 2.1.259, 2026-09-03;
# docs/verification/claude-accounts.md). Any other invocation is a hard
# contract violation for this suite.
make_fake_claude() {
  local fakebin=$1
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = auth ] && [ "${2:-}" = status ] && [ "${3:-}" = --json ] && [ "$#" -eq 3 ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/logged-in-marker" ]; then
    printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai",\n  "email": "%s"\n}\n' "${SQUAD_FAKE_CLAUDE_EMAIL:-fake@example.invalid}"
    exit 0
  fi
  printf '{\n  "loggedIn": false,\n  "authMethod": "none"\n}\n'
  exit 1
fi
printf 'unexpected claude invocation: %s\n' "$*" >&2
exit 64
SH
  chmod +x "$fakebin/claude"
}

run_account() {
  local config=$1
  shift
  SQUAD_ROOT_OVERRIDE='' SQUAD_CONFIG_OVERRIDE="$config" "$ACCOUNT" "$@" 2>&1
}

# --- bin/sq-claude-account.sh: registry parsing -----------------------------

test_list_and_resolve() {
  local case_dir config out status
  case_dir="$TMP_ROOT/list-resolve"
  config="$case_dir/config"
  mkdir -p "$config"
  cat > "$config/claude-accounts" <<'EOF'
# comment line, and a blank line follow

work /Users/example/.claude-work
personal /Users/example/.claude-personal
EOF
  out=$(run_account "$config" list)
  status=$?
  expect_code 0 "$status" "list should succeed on a well-formed registry"
  assert_contains "$out" "work /Users/example/.claude-work" "list did not print the work account"
  assert_contains "$out" "personal /Users/example/.claude-personal" "list did not print the personal account"

  out=$(run_account "$config" resolve personal)
  status=$?
  expect_code 0 "$status" "resolve should succeed for a registered label"
  [ "$out" = "/Users/example/.claude-personal" ] || fail "resolve personal returned '$out'"

  pass "list and resolve read a well-formed config/claude-accounts registry"
}

test_resolve_unknown_label_is_actionable() {
  local case_dir config out status
  case_dir="$TMP_ROOT/unknown-label"
  config="$case_dir/config"
  mkdir -p "$config"
  printf 'work /Users/example/.claude-work\n' > "$config/claude-accounts"
  out=$(run_account "$config" resolve nope)
  status=$?
  [ "$status" -ne 0 ] || fail "resolve should fail for an unregistered label"
  assert_contains "$out" "unknown Claude account 'nope'" "refusal did not name the unknown label"
  assert_contains "$out" "work" "refusal did not list the known account"
  pass "resolve refuses an unregistered label and lists the known ones"
}

test_resolve_absent_registry_is_actionable() {
  local case_dir config out status
  case_dir="$TMP_ROOT/absent-registry"
  config="$case_dir/config"
  mkdir -p "$config"
  out=$(run_account "$config" resolve work)
  status=$?
  [ "$status" -ne 0 ] || fail "resolve should fail when config/claude-accounts is absent"
  assert_contains "$out" "no Claude accounts are registered" "refusal did not explain the absent registry"
  pass "resolve refuses cleanly when no registry is present"
}

test_registry_rejects_malformed_lines() {
  local case_dir config out status
  case_dir="$TMP_ROOT/malformed"
  config="$case_dir/config"

  mkdir -p "$config"
  printf 'work relative/path\n' > "$config/claude-accounts"
  out=$(run_account "$config" list)
  status=$?
  [ "$status" -ne 0 ] || fail "a relative config dir should be refused"
  assert_contains "$out" "absolute path" "refusal did not name the absolute-path requirement"

  printf 'onlyonetoken\n' > "$config/claude-accounts"
  out=$(run_account "$config" list)
  status=$?
  [ "$status" -ne 0 ] || fail "a single-token line should be refused"
  assert_contains "$out" "expected '<label> <config-dir>'" "refusal did not name the expected shape"

  printf 'work /a\nwork /b\n' > "$config/claude-accounts"
  out=$(run_account "$config" list)
  status=$?
  [ "$status" -ne 0 ] || fail "a duplicate label should be refused"
  assert_contains "$out" "duplicate account label 'work'" "refusal did not name the duplicate label"

  pass "config/claude-accounts refuses malformed lines instead of guessing"
}

# --- bin/sq-claude-account.sh: verify ---------------------------------------

test_verify_logged_in_and_not() {
  local case_dir config fakebin out status
  case_dir="$TMP_ROOT/verify"
  config="$case_dir/config"
  mkdir -p "$config/work-dir" "$config/personal-dir"
  fakebin=$(fm_fakebin "$case_dir/fake")
  make_fake_claude "$fakebin"
  touch "$config/work-dir/logged-in-marker"
  printf 'work %s\npersonal %s\n' "$config/work-dir" "$config/personal-dir" > "$config/claude-accounts"

  out=$(PATH="$fakebin:$PATH" run_account "$config" verify work)
  status=$?
  expect_code 0 "$status" "verify should succeed for a logged-in account"
  [ "$out" = "$config/work-dir" ] || fail "verify work printed '$out', expected the resolved dir"

  out=$(PATH="$fakebin:$PATH" run_account "$config" verify personal)
  status=$?
  [ "$status" -ne 0 ] || fail "verify should fail for an account with no logged-in marker"
  assert_contains "$out" "is not logged in" "refusal did not say the account is not logged in"
  assert_contains "$out" "commander's own action" "refusal did not defer login to the commander"
  assert_not_contains "$out" "claude auth login\"" "refusal should never be phrased as a command sq-claude-account itself ran"

  pass "verify distinguishes a logged-in account from one that is not"
}

test_verify_missing_claude_binary() {
  local case_dir config out status
  case_dir="$TMP_ROOT/verify-no-claude"
  config="$case_dir/config"
  mkdir -p "$config/work-dir"
  printf 'work %s\n' "$config/work-dir" > "$config/claude-accounts"
  # A bounded system-only PATH (same pattern as
  # test_pi_signed_missing_binary_refuses... in
  # sq-spawn-dispatch-profile.test.sh): enough for env/bash to run this
  # script, but without whatever directory holds the real installed claude.
  out=$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" run_account "$config" verify work)
  status=$?
  [ "$status" -ne 0 ] || fail "verify should fail when claude is not on PATH"
  assert_contains "$out" "claude executable not found on PATH" "refusal did not name the missing claude executable"
  pass "verify refuses when the claude CLI itself is unavailable"
}

# --- bin/sq-spawn.sh: --account ---------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${SQUAD_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'Squad\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${SQUAD_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$SQUAD_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  make_fake_claude "$fakebin"
  fm_fake_exit0 "$fakebin" fob
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="acct-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\necho done >> %s.status\n' "$home/data/$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "sq/$id"
  touch "$home/state/.last-sentry-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <launchlog> [extra sq-spawn args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5
  shift 5
  : > "$launchlog"
  SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$home" \
    SQUAD_STATE_OVERRIDE="$home/state" SQUAD_DATA_OVERRIDE="$home/data" \
    SQUAD_PROJECTS_OVERRIDE="$home/projects" SQUAD_CONFIG_OVERRIDE="$home/config" \
    SQUAD_SPAWN_NO_GUARD=1 SQUAD_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${SQUAD_TEST_CLAUDE_CONFIG_DIR:-}" \
    SQUAD_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_records_account_and_forwards_config_dir() {
  local rec case_dir home proj wt fakebin launchlog id out status meta launch
  rec=$(make_spawn_case selected)
  IFS='|' read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir -p "$home/config" "$home/config/work-dir"
  touch "$home/config/work-dir/logged-in-marker"
  printf 'work %s\n' "$home/config/work-dir" > "$home/config/claude-accounts"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" \
    "$id" "$proj" claude --account work --mode drill --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with a registered, logged-in --account should succeed: $out"

  meta="$home/state/$id.meta"
  assert_grep "account=work" "$meta" "meta did not record the selected account"

  launch=$(cat "$launchlog")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$home/config/work-dir'" \
    "launch did not forward the selected account's own config dir"
  pass "spawn --account records the selection and forwards its config dir onto the claude launch"
}

test_spawn_refuses_unknown_account() {
  local rec case_dir home proj wt fakebin launchlog id out status
  rec=$(make_spawn_case unknown)
  IFS='|' read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir -p "$home/config"
  printf 'work %s\n' "$home/config/work-dir" > "$home/config/claude-accounts"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" \
    "$id" "$proj" claude --account nope --mode drill --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse an unregistered --account label"
  assert_contains "$out" "unknown Claude account 'nope'" "spawn refusal did not name the unknown label"
  assert_absent "$home/state/$id.meta" "spawn created an endpoint before refusing the unknown account"
  pass "spawn refuses an unregistered --account label before creating an endpoint"
}

test_spawn_refuses_not_logged_in_account() {
  local rec case_dir home proj wt fakebin launchlog id out status
  rec=$(make_spawn_case notloggedin)
  IFS='|' read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir -p "$home/config" "$home/config/cold-dir"
  printf 'cold %s\n' "$home/config/cold-dir" > "$home/config/claude-accounts"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" \
    "$id" "$proj" claude --account cold --mode drill --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse an account whose config dir is not logged in"
  assert_contains "$out" "is not logged in" "spawn refusal did not say the account is not logged in"
  assert_absent "$home/state/$id.meta" "spawn created an endpoint before refusing the unauthenticated account"
  pass "spawn refuses a registered but unauthenticated --account before creating an endpoint"
}

test_spawn_refuses_account_on_non_claude_harness() {
  local rec case_dir home proj wt fakebin launchlog id out status
  rec=$(make_spawn_case wrongharness)
  IFS='|' read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir -p "$home/config" "$home/config/work-dir"
  touch "$home/config/work-dir/logged-in-marker"
  printf 'work %s\n' "$home/config/work-dir" > "$home/config/claude-accounts"
  fm_fake_exit0 "$fakebin" pi-signed

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" \
    "$id" "$proj" pi-signed --account work --mode drill --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse --account on a non-claude harness"
  assert_contains "$out" "--account applies only to harness=claude" "spawn refusal did not name the harness scope boundary"
  assert_absent "$home/state/$id.meta" "spawn created an endpoint before refusing the out-of-scope account selector"
  pass "spawn refuses --account for a harness other than claude"
}

test_spawn_without_account_is_unchanged() {
  local rec case_dir home proj wt fakebin launchlog id out status meta launch
  rec=$(make_spawn_case noaccount)
  IFS='|' read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir -p "$home/config"

  out=$(SQUAD_TEST_CLAUDE_CONFIG_DIR='' run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" \
    "$id" "$proj" claude --mode drill --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with no --account and no config/claude-accounts should behave as before: $out"

  meta="$home/state/$id.meta"
  assert_no_grep "account=" "$meta" "meta recorded an account= line with no --account passed"
  launch=$(cat "$launchlog")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "launch forwarded CLAUDE_CONFIG_DIR with no ambient value and no --account"
  pass "spawn with no --account keeps meta and launch byte-identical to before this axis existed"
}

test_spawn_no_account_still_forwards_ambient_config_dir() {
  local rec case_dir home proj wt fakebin launchlog id out status launch
  rec=$(make_spawn_case ambient)
  IFS='|' read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir -p "$home/config"

  out=$(SQUAD_TEST_CLAUDE_CONFIG_DIR="/Users/example/.claude-ambient" \
    run_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" \
    "$id" "$proj" claude --mode drill --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with an ambient CLAUDE_CONFIG_DIR and no --account should still succeed: $out"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/Users/example/.claude-ambient'" \
    "spawn stopped forwarding Squad's own ambient CLAUDE_CONFIG_DIR when --account is absent"
  pass "spawn preserves the pre-existing ambient CLAUDE_CONFIG_DIR forwarding when --account is not passed"
}

test_spawn_refuses_account_for_remote_xo() {
  local case_dir home fakebin out status id
  case_dir="$TMP_ROOT/remote-xo"
  home="$case_dir/home"
  id="remote-acct-x1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fakebin=$(fm_fakebin "$case_dir/fake")
  fm_fake_exit0 "$fakebin" tmux
  printf -- '- %s - remote route fixture (host: fake-host; root: /remote/root; home: /remote/home; scope: test; projects: alpha; added 2026-01-01)\n' "$id" \
    > "$home/data/XOs.md"

  out=$(SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$home" \
    SQUAD_STATE_OVERRIDE="$home/state" SQUAD_DATA_OVERRIDE="$home/data" \
    SQUAD_PROJECTS_OVERRIDE="$home/projects" SQUAD_CONFIG_OVERRIDE="$home/config" \
    SQUAD_SPAWN_NO_GUARD=1 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --xo --account work 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse --account for a registered remote XO route"
  assert_contains "$out" "not supported for a remote XO route" "refusal did not name the remote-route restriction"
  assert_absent "$home/state/$id.meta" "spawn created remote XO metadata before refusing --account"
  pass "spawn refuses --account for a remote XO route before any readiness or transport work"
}

test_list_and_resolve
test_resolve_unknown_label_is_actionable
test_resolve_absent_registry_is_actionable
test_registry_rejects_malformed_lines
test_verify_logged_in_and_not
test_verify_missing_claude_binary
test_spawn_records_account_and_forwards_config_dir
test_spawn_refuses_unknown_account
test_spawn_refuses_not_logged_in_account
test_spawn_refuses_account_on_non_claude_harness
test_spawn_without_account_is_unchanged
test_spawn_no_account_still_forwards_ambient_config_dir
test_spawn_refuses_account_for_remote_xo

echo "# all Claude account axis tests passed"
