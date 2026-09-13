#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the drill-task manual-push PreToolUse guard.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot sq-push-pretool-check)
BASE="$TMP_ROOT/base"
TASK="$TMP_ROOT/task"
PRIMARY="$TMP_ROOT/primary"
PIPELINE="$TMP_ROOT/pipeline"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
git init -q "$BASE"
git -C "$BASE" commit -q --allow-empty -m init
fm_git_worktree "$BASE" "$TASK" sq/push-guard-task
fm_git_worktree "$BASE" "$PIPELINE" sq/pipeline-push
mkdir -p "$PRIMARY/bin"
cp "$ROOT/bin/sq-push-pretool-check.sh" "$PRIMARY/bin/"
cp "$ROOT/bin/sq-push-command-policy.mjs" "$PRIMARY/bin/"
cp "$ROOT/bin/sq-arm-command-policy.mjs" "$PRIMARY/bin/"
chmod +x "$PRIMARY/bin/sq-push-pretool-check.sh" "$PRIMARY/bin/sq-push-command-policy.mjs"

write_meta() {
  local mode=$1
  printf 'kind=strike\nmode=%s\nworktree=%s\n' "$mode" "$TASK" > "$HOME_DIR/state/task.meta"
}

run_check() {
  local command=$1 out err rc
  out=$(cd "$TASK" && SQUAD_BASE="$HOME_DIR" "$PRIMARY/bin/sq-push-pretool-check.sh" --command "$command" 2>"$TMP_ROOT/err")
  rc=$?
  err=$(cat "$TMP_ROOT/err")
  printf '%s\n%s\n%s\n' "$rc" "$out" "$err"
}

write_meta drill
result=$(run_check 'git push -u origin sq/task'); rc=${result%%$'\n'*}
expect_code 2 "$rc" "manual branch push from drill task is denied"
assert_contains "$result" '[drill-push]' "manual push denial has the drill-push reason"
assert_contains "$result" 'run the validation instead' "manual push denial explains the required action"
assert_contains "$result" 'publishes the branch and opens the PR' "manual push denial explains validation delivery"

result=$(run_check 'echo "git push -u origin sq/task"'); rc=${result%%$'\n'*}
expect_code 0 "$rc" "git push in quoted data is allowed"

result=$(run_check "bash -lc 'git push origin sq/task'"); rc=${result%%$'\n'*}
expect_code 2 "$rc" "wrapped manual branch push from drill task is denied"

result=$(cd "$PIPELINE" && SQUAD_BASE="$HOME_DIR" "$PRIMARY/bin/sq-push-pretool-check.sh" --command 'git push origin sq/task' 2>"$TMP_ROOT/err"); rc=$?
expect_code 0 "$rc" "pipeline worktree push is allowed"
[ -z "$result" ] || fail "pipeline worktree push produced output: $result"

write_meta direct-PR
result=$(run_check 'git push -u origin sq/task'); rc=${result%%$'\n'*}
expect_code 0 "$rc" "direct-PR branch push is allowed"

write_meta local-only
result=$(run_check 'git push -u origin sq/task'); rc=${result%%$'\n'*}
expect_code 0 "$rc" "local-only branch push is unaffected"

write_meta drill
result=$(cd "$PRIMARY" && SQUAD_BASE="$HOME_DIR" "$PRIMARY/bin/sq-push-pretool-check.sh" --command 'git push origin main' 2>"$TMP_ROOT/err"); rc=$?
expect_code 0 "$rc" "Squad primary merge push is allowed"
[ -z "$result" ] || fail "primary merge push produced output: $result"

# Exercise the five tracked transport shapes used by Claude, Codex, Grok,
# OpenCode, and Pi without spawning any harness.
write_meta drill
for entry in codex claude grok opencode pi; do
  case "$entry" in
    codex|claude) payload=$(jq -cn '{tool_input:{command:"git push origin sq/task"}}');;
    grok) payload=$(jq -cn '{toolInput:{command:"git push origin sq/task"}}');;
    opencode|pi) payload=;;
  esac
  if [ "$entry" = opencode ] || [ "$entry" = pi ]; then
    out=$(cd "$TASK" && SQUAD_BASE="$HOME_DIR" "$PRIMARY/bin/sq-push-pretool-check.sh" --command 'git push origin sq/task' 2>"$TMP_ROOT/$entry.err")
  elif [ "$entry" = claude ]; then
    out=$(cd "$TASK" && printf '%s' "$payload" | SQUAD_BASE="$HOME_DIR" "$PRIMARY/bin/sq-push-pretool-check.sh" --claude 2>"$TMP_ROOT/$entry.err")
  else
    out=$(cd "$TASK" && printf '%s' "$payload" | SQUAD_BASE="$HOME_DIR" "$PRIMARY/bin/sq-push-pretool-check.sh" 2>"$TMP_ROOT/$entry.err")
  fi
  rc=$?
  expect_code 2 "$rc" "$entry transport denies drill push"
  assert_contains "$(cat "$TMP_ROOT/$entry.err")" '[drill-push]' "$entry transport reports drill-push reason"
  if [ "$entry" = claude ]; then
    [ -z "$out" ] || fail "Claude deny must keep stdout empty"
  fi
done

pass "drill push guard acceptance and delivery-mode matrix"
