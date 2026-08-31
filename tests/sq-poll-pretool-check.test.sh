#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Contract tests for the narrow state/ hand-polling guard.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot sq-poll-pretool-check)

make_primary() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/sq-poll-pretool-check.sh" "$dir/bin/"
  cp "$ROOT/bin/sq-poll-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/sq-arm-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/sq-primary-scope-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/sq-poll-pretool-check.sh"
}

PRIMARY=$TMP_ROOT/primary
make_primary "$PRIMARY"
CHECK="$PRIMARY/bin/sq-poll-pretool-check.sh"

run_check() {
  local command=$1 out err rc
  out=$(SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" \
    "$CHECK" --command "$command" 2>"$TMP_ROOT/err")
  rc=$?
  err=$(cat "$TMP_ROOT/err")
  printf '%s\n%s\n' "$rc" "$err"
}

# BLOCK: an actual sleep/while construct is combined with a state/ read.
for command in \
  'sleep 1; cat state/task.status' \
  'sleep 1; grep -q done "$SQUAD_BASE/state/task.status"' \
  'while true; do cat state/task.status; done' \
  'while [ -f state/task.status ]; do sleep 1; done' \
  'while true; do sleep 1; tail -n 1 ./state/task.status; done' \
  'bash -lc '\''while true; do sleep 1; cat /tmp/state/task.status; done'\'''; do
  result=$(run_check "$command")
  expect_code 2 "${result%%$'\n'*}" "blocks state poll loop: $command"
  assert_contains "$result" "state-poll-loop" "reports state poll code: $command"
  assert_not_contains "$result" "state/task" "does not echo the task path in the reason"
done

# ALLOW: the guard is deliberately narrow and does not replace ordinary reads,
# one-shot sleeps, loops without state reads, or safe Squad commands.
for command in \
  'sleep 1' \
  'while true; do echo ready; done' \
  'while true; do echo state/task.status; done' \
  'sleep 1; printf "%s" state/task.status' \
  'cat state/task.status' \
  'tail -n 1 state/task.status' \
  'bin/sq-stand-to-drain.sh' \
  'bin/sq-status-notify.sh watch'; do
  result=$(run_check "$command")
  expect_code 0 "${result%%$'\n'*}" "allows non-poll command: $command"
done

# Shell data and malformed syntax do not produce a block.
for command in \
  'echo "sleep 1; cat state/task.status"' \
  'printf "%s" "while true; do cat state/task.status; done"' \
  'sleep 1; cat '\''state/task.status' \
  'sleep 1; cat '\''state/task.status'; do
  result=$(run_check "$command")
  expect_code 0 "${result%%$'\n'*}" "allows quoted or malformed non-executed text: $command"
done

for payload in \
  '{"toolInput":{"command":"sleep 1; cat state/task.status"}}' \
  '{"tool_input":{"command":"while true; do grep done state/task.status; done"}}'; do
  out=$(printf '%s' "$payload" | SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" 2>"$TMP_ROOT/err")
  rc=$?
  expect_code 2 "$rc" "denies JSON state poll payload"
  assert_contains "$out" '"decision":"deny"' "emits Grok decision JSON for state poll"
  assert_contains "$(cat "$TMP_ROOT/err")" '"permissionDecision":"deny"' "emits Claude-shaped stderr for state poll"
done

# Malformed input, missing node, missing policy, and missing scope are all
# silent allows.
for payload in '' '{not-json}' '{"toolInput":{"command":42}'; do
  out=$(printf '%s' "$payload" | SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" 2>"$TMP_ROOT/err")
  expect_code 0 "$?" "malformed state transport fails open"
done
mkdir -p "$TMP_ROOT/fakebin"
printf '#!/usr/bin/env bash\nexit 127\n' > "$TMP_ROOT/fakebin/node"
chmod +x "$TMP_ROOT/fakebin/node"
out=$(PATH="$TMP_ROOT/fakebin:/usr/bin:/bin" SQUAD_BASE="$PRIMARY" \
  SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" --command 'sleep 1; cat state/task.status' 2>"$TMP_ROOT/err")
expect_code 0 "$?" "missing node fails open for state guard"
mv "$PRIMARY/bin/sq-poll-command-policy.mjs" "$TMP_ROOT/policy.saved"
out=$(SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" \
  --command 'sleep 1; cat state/task.status' 2>"$TMP_ROOT/err")
expect_code 0 "$?" "missing state policy fails open"
mv "$TMP_ROOT/policy.saved" "$PRIMARY/bin/sq-poll-command-policy.mjs"

CHILD=$TMP_ROOT/child
git -C "$PRIMARY" worktree add -q -b poll-child "$CHILD" HEAD
: > "$CHILD/AGENTS.md"
mkdir -p "$CHILD/bin" "$CHILD/state"
cp "$ROOT/bin/sq-poll-pretool-check.sh" "$CHILD/bin/"
cp "$ROOT/bin/sq-poll-command-policy.mjs" "$CHILD/bin/"
cp "$ROOT/bin/sq-arm-command-policy.mjs" "$CHILD/bin/"
cp "$ROOT/bin/sq-primary-scope-lib.sh" "$CHILD/bin/"
out=$(SQUAD_BASE="$CHILD" SQUAD_ROOT_OVERRIDE="$CHILD" "$CHILD/bin/sq-poll-pretool-check.sh" \
  --command 'sleep 1; cat state/task.status' 2>"$TMP_ROOT/err")
expect_code 0 "$?" "linked task worktree is inert for state guard"

pass "state poll loop guard contract"
