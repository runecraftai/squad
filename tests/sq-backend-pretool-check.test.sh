#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Contract tests for the primary-only raw session-provider CLI guard.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot sq-backend-pretool-check)

install_scripts() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  cp "$ROOT/bin/sq-backend-pretool-check.sh" "$dir/bin/"
  cp "$ROOT/bin/sq-backend-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/sq-arm-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/sq-primary-scope-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/sq-backend-pretool-check.sh"
}

make_primary() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
}

PRIMARY=$TMP_ROOT/primary
make_primary "$PRIMARY"
CHECK="$PRIMARY/bin/sq-backend-pretool-check.sh"

run_check() {
  local command=$1 out err rc
  out=$(SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" \
    "$CHECK" --command "$command" 2>"$TMP_ROOT/err")
  rc=$?
  err=$(cat "$TMP_ROOT/err")
  printf '%s\n%s\n' "$rc" "$err"
}

for backend in tmux herdr zellij orca cmux; do
  result=$(run_check "$backend lifecycle-control --target task")
  expect_code 2 "${result%%$'\n'*}" "blocks raw $backend CLI"
  assert_contains "$result" "backend-raw-session-control" "reports raw backend guard code for $backend"
  assert_not_contains "$result" "$backend" "backend guard message stays backend-agnostic for $backend"
done

for command in \
  'tmux list-windows -t Squad' \
  'zellij action write-chars x' \
  'orca send-keys task Enter' \
  'cmux send-text task x' \
  'herdr pane close task' \
  'command tmux send-keys task x' \
  'env -- tmux new-session -d' \
  'bash -lc '\''tmux kill-window -t Squad:task'\''' \
  '(tmux send-keys task x)' \
  '{ tmux send-keys task x; }' \
  'env bash -lc '\''tmux kill-window -t Squad:task'\''' \
  'printf '\''%s'\'' "$(zellij action list-clients)"'; do
  result=$(run_check "$command")
  expect_code 2 "${result%%$'\n'*}" "blocks raw backend lifecycle form: $command"
done

for command in \
  'echo tmux send-keys' \
  'printf "%s" "zellij action"' \
  'grep herdr README.md' \
  'git -C projects/foo status' \
  'bin/sq-send.sh task "use the backend wrapper"' \
  'tmuxy send-keys task x' \
  '' \
  'bash -lc '\''echo "cmux send-text"'\'''; do
  result=$(run_check "$command")
  expect_code 0 "${result%%$'\n'*}" "allows backend names in data or Squad wrappers: $command"
done

# Transport accepts both Claude/Codex and Grok payload spellings and emits the
# established deny shape while keeping stdout empty for --claude.
for payload in \
  '{"toolInput":{"command":"tmux send-keys task x"}}' \
  '{"tool_input":{"command":"cmux send-text task x"}}'; do
  out=$(printf '%s' "$payload" | SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" 2>"$TMP_ROOT/err")
  rc=$?
  expect_code 2 "$rc" "denies JSON payload"
  assert_contains "$out" '"decision":"deny"' "emits Grok decision JSON"
  assert_contains "$(cat "$TMP_ROOT/err")" '"permissionDecision":"deny"' "emits Claude-shaped stderr"
done
out=$(printf '%s' '{"toolInput":{"command":"tmux send-keys task x"}}' | \
  SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" --claude 2>"$TMP_ROOT/err")
rc=$?
expect_code 2 "$rc" "denies Claude payload"
[ -z "$out" ] || fail "Claude mode must keep stdout empty"
out=$(SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" \
  --command='orca terminal create task' 2>"$TMP_ROOT/err")
expect_code 2 "$?" "accepts the OpenCode/Pi equals-form CLI"

# Malformed and unavailable transport dependencies fail open.
for payload in '' '{not-json}' '{"toolInput":{"command":42}}'; do
  out=$(printf '%s' "$payload" | SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" 2>"$TMP_ROOT/err")
  expect_code 0 "$?" "malformed or empty payload fails open"
  [ -z "$out" ] || fail "malformed payload produced output"
done
mkdir -p "$TMP_ROOT/fakebin"
printf '#!/usr/bin/env bash\nexit 127\n' > "$TMP_ROOT/fakebin/node"
chmod +x "$TMP_ROOT/fakebin/node"
out=$(PATH="$TMP_ROOT/fakebin:/usr/bin:/bin" SQUAD_BASE="$PRIMARY" \
  SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" --command 'tmux send-keys task x' 2>"$TMP_ROOT/err")
expect_code 0 "$?" "missing node fails open"
[ -z "$out" ] || fail "missing node produced output"
mv "$PRIMARY/bin/sq-backend-command-policy.mjs" "$TMP_ROOT/policy.saved"
out=$(SQUAD_BASE="$PRIMARY" SQUAD_ROOT_OVERRIDE="$PRIMARY" "$CHECK" --command 'tmux send-keys task x' 2>"$TMP_ROOT/err")
expect_code 0 "$?" "missing policy fails open"
mv "$TMP_ROOT/policy.saved" "$PRIMARY/bin/sq-backend-command-policy.mjs"

# A linked task worktree and a non-Squad repository are inert.
CHILD=$TMP_ROOT/child
git -C "$PRIMARY" worktree add -q -b guard-child "$CHILD" HEAD
: > "$CHILD/AGENTS.md"
install_scripts "$CHILD"
mkdir -p "$CHILD/state"
out=$(SQUAD_BASE="$CHILD" SQUAD_ROOT_OVERRIDE="$CHILD" "$CHILD/bin/sq-backend-pretool-check.sh" \
  --command 'tmux send-keys task x' 2>"$TMP_ROOT/err")
expect_code 0 "$?" "linked task worktree is inert"
[ -z "$out" ] || fail "linked task worktree produced output"
NON_SQUAD=$TMP_ROOT/non-squad
make_primary "$NON_SQUAD"
rm -f "$NON_SQUAD/AGENTS.md"
out=$(SQUAD_BASE="$NON_SQUAD" SQUAD_ROOT_OVERRIDE="$NON_SQUAD" \
  "$NON_SQUAD/bin/sq-backend-pretool-check.sh" --command 'tmux send-keys task x' 2>"$TMP_ROOT/err")
expect_code 0 "$?" "non-Squad repository is inert"

pass "raw backend CLI guard contract"
