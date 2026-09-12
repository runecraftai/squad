#!/usr/bin/env bash
# Behavioral tests for bin/sq-review-pane.sh.
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_PANE="$ROOT/bin/sq-review-pane.sh"
TMP_ROOT=$(fm_test_tmproot sq-review-pane-tests)

make_case() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/fakebin"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/seed"
  printf 'base\n' > "$dir/seed/file"
  git -C "$dir/seed" add file
  git -C "$dir/seed" commit -qm base
  git -C "$dir/seed" push -q origin main
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main
  git -C "$dir/project" update-ref refs/remotes/origin/review-base refs/remotes/origin/main
  git -C "$dir/project" worktree add -q -b sq/task "$dir/wt" main
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  display-message) printf '%%1\n' ;;
  new-window) printf '%s\n' "$*" >> "$FAKE_TMUX_LOG" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"
  printf 'window=Squad:7\nworktree=%s\nproject=%s\n' "$dir/wt" "$dir/project" > "$dir/state/task.meta"
}

run_pane() {
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" SQUAD_ROOT_OVERRIDE="$ROOT" \
    SQUAD_STATE_OVERRIDE="$dir/state" FAKE_TMUX_LOG="$dir/tmux.log" \
    "$REVIEW_PANE" "$@"
}

test_missing_meta() {
  local dir="$TMP_ROOT/missing-meta" out status=0
  mkdir -p "$dir/state" "$dir/fakebin"
  set +e
  out=$(run_pane "$dir" task 2>&1) || status=$?
  set -e
  [ "$status" -ne 0 ] || fail "missing meta should fail"
  assert_contains "$out" 'no meta for task task' "missing meta error was unclear"
  pass "missing meta fails loudly"
}

test_missing_worktree() {
  local dir="$TMP_ROOT/missing-worktree" out status=0
  make_case "$dir"
  rm -rf "$dir/wt"
  set +e
  out=$(run_pane "$dir" task 2>&1) || status=$?
  set -e
  [ "$status" -ne 0 ] || fail "missing worktree should fail"
  assert_contains "$out" 'worktree for task task is missing' "missing worktree error was unclear"
  pass "missing worktree fails loudly"
}

test_base_and_print_command() {
  local dir="$TMP_ROOT/explicit-base" out
  make_case "$dir"
  out=$(run_pane "$dir" task --base origin/review-base --print-command 2>&1)
  assert_contains "$out" 'nvim' "print-command did not emit an editor invocation"
  assert_contains "$out" 'origin/review-base' "explicit base did not win"
  assert_contains "$out" "$dir/wt" "print-command omitted the worktree path"
  pass "explicit base wins and print-command emits the invocation"
}

test_opens_review_window() {
  local dir="$TMP_ROOT/open-window" out
  make_case "$dir"
  out=$(run_pane "$dir" task 2>&1)
  assert_contains "$out" 'worktree ref:' "normal invocation did not report the checked-out ref"
  assert_contains "$out" 'attach:' "normal invocation omitted the attach command"
  assert_contains "$(cat "$dir/tmux.log")" 'sq-task-review' "review window was not named correctly"
  pass "normal invocation opens a named review window and prints handoff commands"
}

test_missing_meta
test_missing_worktree
test_base_and_print_command
test_opens_review_window
