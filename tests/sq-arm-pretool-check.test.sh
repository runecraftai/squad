#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2088
# Behavior tests for the sentry-arm PreToolUse seatbelt (docs/arm-pretool-check.md).
#
# bin/sq-arm-command-policy.mjs is the single owner of command classification.
# This suite drives the stable shell transport through all five harness entry
# forms and asserts the per-harness wiring contract without spawning a harness.
# Empirical harness evidence lives in docs/arm-pretool-check.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/sq-arm-pretool-check.sh"
POLICY="$ROOT/bin/sq-arm-command-policy.mjs"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

matrix_case A01 allow 'bin/sq-sentry-arm.sh'
matrix_case A02 allow './bin/sq-sentry-arm.sh --restart'
matrix_case A03 allow 'exec bin/sq-sentry-arm.sh'
matrix_case A04 allow 'bin/sq-sentry-checkpoint.sh --seconds 180'
matrix_case A05 allow 'exec bin/sq-sentry-checkpoint.sh --seconds 180'
matrix_case A06 allow "$ROOT/bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case A07 allow "cd '$ROOT'; exec bin/sq-sentry-arm.sh"
matrix_case A08 allow "cd '../Squad'; bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case A09 allow "export SQUAD_HOME='$ROOT'; bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case A10 allow 'source config/x-mode.env; bin/sq-sentry-checkpoint.sh --seconds 180'
matrix_case A11 allow "source 'config/x-mode.env'; bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case A12 allow "source './config/x-mode.env'; bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case A13 allow "source '$ROOT/config/x-mode.env'; bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case A14 allow "[ -f 'config/x-mode.env' ] && source 'config/x-mode.env'; exec bin/sq-sentry-arm.sh"
matrix_case A15 allow "cd $ROOT && exec bin/sq-sentry-arm.sh"
matrix_case A16 allow "export SQUAD_HOME=$ROOT && bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case A17 allow $'source "config/x-mode.env"\nbin/sq-sentry-checkpoint.sh --seconds 180'

matrix_case R01 allow "pgrep -fl '/bin/sq-sentry.sh' || true"
matrix_case R02 allow "ps aux | rg '/bin/sq-sentry.sh'"
matrix_case R03 allow "rg -n 'sq-sentry-arm.sh &' docs tests"
matrix_case R04 allow "rg -n 'bin/sq-sentry-arm.sh; echo bad' docs"
matrix_case R05 allow "git grep 'sq-sentry-checkpoint.sh && echo bad'"
matrix_case R06 allow "sed -n '/sq-sentry-checkpoint.sh/p' docs/arm-pretool-check.md"
matrix_case R07 allow 'assert_contains "$content" '\''sq-sentry-arm.sh &'\'''
matrix_case R08 allow "printf '%s\\n' 'bin/sq-sentry-checkpoint.sh --seconds 180 >/tmp/out'"
matrix_case R09 allow "tmux send-keys -t isolated-pi-lab 'bin/sq-sentry-arm.sh &' Enter"
matrix_case R10 allow "tmux send-keys -t isolated-pi-lab \"printf '%s\\n' 'bin/sq-sentry-arm.sh &'\"; tmux send-keys -t isolated-pi-lab Enter"
matrix_case R11 allow "python3 -c 'print(\"bin/sq-sentry-arm.sh; echo data\")'"
matrix_case R12 allow "bash -lc \"rg -n 'sq-sentry-arm.sh &' docs\""
matrix_case R13 allow "echo 'pkill -f sq-sentry'"
matrix_case R14 allow "rg -n 'pkill -f sq-sentry' docs tests"
matrix_case R15 allow "echo ok # bin/sq-sentry-arm.sh &"
matrix_case R16 allow $'# bin/sq-sentry-arm.sh &\necho ok'
matrix_case R17 allow "printf '%s\\n' 'sq-sentry.sh; a && b || c > out' | sed -n '1p'"
matrix_case R18 allow "sh -c 'tmux send-keys -t lab \"bin/sq-sentry-arm.sh &\" Enter'"
matrix_case R19 allow "eval 'printf \"%s\\n\" \"bin/sq-sentry-arm.sh &\"'"

matrix_case D01 deny 'bin/sq-sentry-arm.sh &'
matrix_case D02 deny 'nohup bin/sq-sentry-arm.sh'
matrix_case D03 deny 'bin/sq-sentry-arm.sh & disown'
matrix_case D04 deny '(bin/sq-sentry-arm.sh) &'
matrix_case D05 deny "bash -lc 'bin/sq-sentry-arm.sh &'"
matrix_case D06 deny '$(bin/sq-sentry-arm.sh)'
matrix_case D07 deny 'echo "$(bin/sq-sentry-checkpoint.sh --seconds 180)"'
matrix_case D08 deny 'cat <(bin/sq-sentry-arm.sh)'
matrix_case D09 deny 'bin/sq-sentry-arm.sh >/tmp/out'
matrix_case D10 deny 'bin/sq-sentry-checkpoint.sh --seconds 180 </dev/null'
matrix_case D11 deny 'bin/sq-sentry-arm.sh 2>&1 | head -2'
matrix_case D12 deny 'bin/sq-sentry-arm.sh | cat'
matrix_case D13 deny 'bin/sq-sentry-checkpoint.sh --seconds 180 | timeout 1 cat'
matrix_case D14 deny 'echo before; bin/sq-sentry-arm.sh'
matrix_case D15 deny 'bin/sq-sentry-checkpoint.sh --seconds 180; echo after'
matrix_case D16 deny 'true && bin/sq-sentry-arm.sh'
matrix_case D17 deny 'bin/sq-sentry-checkpoint.sh --seconds 180 || true'
matrix_case D18 deny $'bin/sq-sentry-arm.sh\nbin/sq-sentry-checkpoint.sh --seconds 180'
matrix_case D19 deny "pkill -f '/bin/sq-sentry.sh'"
matrix_case D20 deny "command pkill -f '/bin/sq-sentry.sh'"
matrix_case D21 deny "/usr/bin/pkill -f '/bin/sq-sentry.sh'"
matrix_case D22 deny "sudo pkill -f '/bin/sq-sentry.sh'"
matrix_case D23 deny 'kill "$(pgrep -f '\''/bin/sq-sentry.sh'\'')"'
matrix_case D24 deny $'bin/sq-watc\\\nh-arm.sh &'
matrix_case D25 deny 'sudo -u root bin/sq-sentry-arm.sh &'
matrix_case D26 deny 'env -u PATH bin/sq-sentry-arm.sh &'
matrix_case D27 deny "bash -c \$'bin/sq-sentry-arm.sh &'"
matrix_case D28 deny $'bash <<\'EOF\'\nbin/sq-sentry-arm.sh &\nEOF'
matrix_case D29 deny "WATCHER='bin/sq-sentry-arm.sh &' bash -c 'eval \"\$WATCHER\"'"
matrix_case D30 deny "p=\$(pgrep -f '/bin/sq-sentry.sh'); kill \"\$p\""
matrix_case D31 deny "env -S 'bin/sq-sentry-arm.sh &'"
matrix_case D32 deny "env --split-string='$ROOT/bin/sq-sentry-arm.sh &'"
matrix_case D33 deny 'bin/sq-"sentry-arm.sh" &'
matrix_case D34 deny "WATCHER='bin/sq-sentry-arm.sh'; \"\$WATCHER\" &"
matrix_case D35 deny "bash -c -- 'bin/sq-sentry-arm.sh &'"
matrix_case D36 deny 'bash bin/sq-sentry-arm.sh &'
matrix_case D37 deny '. bin/sq-sentry-arm.sh &'
matrix_case D38 deny "bash <<< 'bin/sq-sentry-arm.sh &'"
matrix_case D39 deny "eval 'true;' 'bin/sq-sentry-arm.sh &'"
matrix_case D40 deny 'timeout 30 bin/sq-sentry-arm.sh &'
matrix_case D41 deny 'gtimeout 30 bin/sq-sentry-arm.sh &'
matrix_case D42 deny 'bin/sq-sentry-{arm,checkpoint}.sh &'
matrix_case D43 deny 'bin/sq-sentry-arm.sh* &'
matrix_case D44 deny "pattern='sq-sentry'; pkill -f \"\$pattern\""
matrix_case D45 deny "p=\$(pgrep -f '/bin/sq-sentry.sh'); q=\$p; kill \$q"
matrix_case D46 deny '$SQUAD_HOME/bin/sq-sentry-arm.sh &'
matrix_case D47 deny '$HOME/Squad/bin/sq-sentry-arm.sh | cat'
matrix_case D48 deny '~/Squad/bin/sq-sentry-arm.sh &'
matrix_case D49 deny 'bin/sq-sentry.sh'
matrix_case D50 deny '$SQUAD_HOME/bin/sq-sentry.sh'
matrix_case D51 deny '~/Squad/bin/sq-sentry.sh --restart'
matrix_case D52 deny "bin/sq-\$'\x77'atch-arm.sh &"
matrix_case D53 deny 'bin/sq-$"watch"-arm.sh &'
matrix_case D54 deny 'bin/sq-sentry-$"arm".sh &'
matrix_case D55 deny 'while true; do pkill -f sq-sentry; done'
matrix_case D56 deny 'for x in 1; do pkill -f sq-sentry; done'
matrix_case D57 deny 'case x in x) pkill -f sq-sentry ;; esac'
matrix_case D58 deny 'until false; do kill $(pgrep -f sq-sentry); done'

matrix_case E01 allow "bin/sq-sentry-checkpoint.sh --seconds '180;still-one-arg'"
matrix_case E02 allow "bin/sq-sentry-checkpoint.sh --label 'sq-sentry-arm.sh; literal argument'"
matrix_case E03 allow 'bin/sq-sentry-arm.sh # output > file &'
matrix_case E04 allow $'# setup comment with sq-sentry.sh; && >\nsource "config/x-mode.env"\nbin/sq-sentry-checkpoint.sh --seconds 180'
matrix_case E05 deny "SQUAD_HOME=$ROOT bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case E06 deny "env SQUAD_HOME=$ROOT bin/sq-sentry-arm.sh"
matrix_case E07 deny "source '/tmp/not-Squad/config/x-mode.env'; bin/sq-sentry-checkpoint.sh --seconds 180"
matrix_case E08 deny "bash -lc 'bin/sq-sentry-checkpoint.sh --seconds 180'"
matrix_case E09 deny '(bin/sq-sentry-checkpoint.sh --seconds 180)'
matrix_case E10 deny "eval 'bin/sq-sentry-arm.sh &'"
matrix_case E11 deny "exec bash -lc 'bin/sq-sentry-arm.sh &'"
matrix_case E12 allow 'bash -lc "$WATCHER_COMMAND" # sq-sentry-arm.sh'
matrix_case E13 allow "printf '%s\\n' 'argument has ; and sq-sentry-arm.sh and &&'"
matrix_case E14 allow '$SQUAD_HOME/bin/sq-teardown.sh &'
matrix_case E15 allow '$SQUAD_HOME/bin/sq-sentry-arm.sh'
matrix_case E16 allow '~/Squad/bin/sq-sentry-checkpoint.sh --seconds 180'
matrix_case E17 allow 'for f in 1; do echo sq-sentry; done'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sq-arm-policy-matrix.XXXXXX")
SQUAD_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")
trap fm_test_cleanup EXIT

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[(sentry-(background|pipeline|redirection|bundled|nested|direct)|broad-sentry-kill|unclassifiable-protected-command)\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a stable reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
    pass "matrix ${MATRIX_IDS[$i]}: ${MATRIX_EXPECTED[$i]} through all five entry forms"
  done
}

assert_policy() {
  local id=$1 expected=$2 command=$3 output
  output=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$command") \
    || fail "$id direct policy invocation failed"
  case "$output" in
    "$expected"|"$expected"$'\t'*) : ;;
    *) fail "$id direct policy expected $expected, got: $output" ;;
  esac
  pass "direct policy $id: $expected"
}

test_direct_policy_contract() {
  local heredoc_data heredoc_sentry
  assert_policy direct-data-pkill allow "echo 'pkill -f sq-sentry'"
  assert_policy direct-broad-pkill $'deny\tbroad-sentry-kill' "pkill -f '/bin/sq-sentry.sh'"
  assert_policy direct-loop-broad-pkill $'deny\tbroad-sentry-kill' 'while true; do pkill -f sq-sentry; done'
  assert_policy direct-loop-broad-kill-pgrep $'deny\tbroad-sentry-kill' 'until false; do kill $(pgrep -f sq-sentry); done'
  assert_policy direct-loop-no-kill-allowed allow 'for f in 1; do echo sq-sentry; done'
  assert_policy direct-pipeline $'deny\tsentry-pipeline' 'bin/sq-sentry-arm.sh | cat'
  assert_policy direct-leading-redirection $'deny\tsentry-redirection' '>/tmp/out bin/sq-sentry-arm.sh'
  assert_policy direct-unclassifiable $'deny\tunclassifiable-protected-command' "bin/sq-sentry-arm.sh 'unterminated"
  assert_policy direct-unsupported $'deny\tunclassifiable-protected-command' 'if true; then bin/sq-sentry-arm.sh; fi'
  assert_policy direct-constructed-payload $'deny\tsentry-nested' "WATCHER='bin/sq-sentry-arm.sh &'; bash -lc \"\$WATCHER\""
  assert_policy direct-parameter-export allow 'export SQUAD_HOME=${HOME}; bin/sq-sentry-checkpoint.sh --seconds 180'
  assert_policy direct-expanded-arm-blessed allow '$SQUAD_HOME/bin/sq-sentry-arm.sh'
  assert_policy direct-expanded-arm-background $'deny\tsentry-background' '$SQUAD_HOME/bin/sq-sentry-arm.sh &'
  assert_policy direct-expanded-arm-pipeline $'deny\tsentry-pipeline' '$HOME/Squad/bin/sq-sentry-arm.sh | cat'
  assert_policy direct-watch-not-blessed $'deny\tsentry-direct' 'bin/sq-sentry.sh'
  assert_policy direct-watch-expanded $'deny\tsentry-direct' '$SQUAD_HOME/bin/sq-sentry.sh'
  assert_policy direct-watch-safe-shape $'deny\tsentry-direct' 'cd /tmp; bin/sq-sentry.sh'
  heredoc_data=$'cat <<\'EOF\'\nbin/sq-sentry-arm.sh &\nEOF'
  heredoc_sentry=$'bin/sq-sentry-arm.sh <<\'EOF\'\ndata only\nEOF'
  assert_policy direct-heredoc-data allow "$heredoc_data"
  assert_policy direct-heredoc-sentry $'deny\tsentry-redirection' "$heredoc_sentry"
}

# --- CLI parsing -------------------------------------------------------------

test_command_equals_form() {
  "$CHECK" --command='bin/sq-sentry-arm.sh &' >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "--command=<val> form must parse the same as --command <val>"
  pass "--command=<val> equals-form parses correctly"
}

test_background_flag_accepted_and_non_gating() {
  local rc_bg rc_nobg
  "$CHECK" --command 'exec bin/sq-sentry-arm.sh' --background true >/dev/null 2>&1
  rc_bg=$?
  "$CHECK" --command 'exec bin/sq-sentry-arm.sh' >/dev/null 2>&1
  rc_nobg=$?
  [ "$rc_bg" -eq 0 ] || fail "--background true must not change the allow decision on its own, got exit $rc_bg"
  [ "$rc_bg" -eq "$rc_nobg" ] || fail "--background flag must be accepted without altering the decision"
  pass "--background is accepted for interface parity and is never itself a deny signal"
}

test_unknown_flag_errors() {
  "$CHECK" --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero, not silently allow"
  pass "unknown CLI flag is rejected"
}

# --- stdin JSON mode ----------------------------------------------------------

test_stdin_grok_schema_deny() {
  local out rc
  out=$(printf '%s' '{"toolInput":{"command":"bin/sq-sentry-arm.sh &","background":false},"toolName":"run_terminal_command"}' | "$CHECK" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "grok toolInput.command schema must be read and denied, got exit $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 || fail "stdout must carry Grok's {\"decision\":\"deny\",...} shape: $out"
  pass "stdin grok schema (toolInput.command): denied with Grok-shaped stdout JSON"
}

test_stdin_claude_codex_schema_allow() {
  local rc
  printf '%s' '{"tool_input":{"command":"exec bin/sq-sentry-arm.sh"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "claude/codex tool_input.command schema must be read and allowed for the blessed shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): blessed shape allowed"
}

test_stdin_claude_codex_schema_deny() {
  local rc
  printf '%s' '{"tool_input":{"command":"bin/sq-sentry-arm.sh &"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "claude/codex tool_input.command schema must be denied for the backgrounded shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): backgrounded shape denied"
}

test_stdin_unrelated_command_allowed() {
  local rc
  printf '%s' '{"tool_input":{"command":"ls -la"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "an unrelated command must pass through allowed, got exit $rc"
  pass "stdin: unrelated command is a fast allow"
}

test_prefilter_is_strict_superset() {
  local rc
  # A command with no sq-sentry substring is fast-allowed by the transport
  # prefilter without ever invoking the classifier.
  "$CHECK" --command 'ls -la /bin && echo done' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a command with no sq-sentry substring must be fast-allowed, got exit $rc"
  # A deniable protected execution carries the sq-sentry bytes, so the prefilter
  # must delegate to the classifier and the deny must survive.
  "$CHECK" --command 'bin/sq-sentry-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a deniable sq-sentry command, not fast-allow it, got exit $rc"
  # A broad sentry kill also contains the sq-sentry bytes and must still deny.
  "$CHECK" --command "pkill -f '/bin/sq-sentry.sh'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a broad sentry kill, not fast-allow it, got exit $rc"
  # Obfuscated protected paths lose the literal sq-sentry bytes (a line
  # continuation or a quote splits them), yet the classifier reconstructs them.
  # The prefilter normalizes those bytes first, so both must still delegate and
  # deny rather than slip through as a fast allow.
  "$CHECK" --command "$(printf 'bin/sq-watc\\\nh-arm.sh &')" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a line-continuation-split protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/sq-"sentry-arm.sh" &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a quote-split protected path, not fast-allow it, got exit $rc"
  # A quoting-decoder marker ($' ANSI-C or $" locale) hides the sq-sentry bytes
  # from the cheap byte strip but the classifier reconstructs them, so the
  # prefilter must delegate on the marker rather than fast-allow. Without this
  # the byte strip loses the encoded character and slips the command through.
  "$CHECK" --command "bin/sq-\$'\x77'atch-arm.sh &" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate an ANSI-C-encoded protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/sq-$"watch"-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a locale-string-encoded protected path, not fast-allow it, got exit $rc"
  # The marker is specifically $ followed by a quote, not any $ expansion: an
  # ordinary $VAR that is not a sentry reference still takes the fast path.
  "$CHECK" --command '$SQUAD_HOME/bin/sq-teardown.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$VAR non-sentry command must still fast-allow, got exit $rc"
  "$CHECK" --command 'echo "$HOME/scratch" && ls -la' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$HOME command must still fast-allow, got exit $rc"
  # A benign command that only mentions sq-sentry as data still reaches the
  # classifier and is allowed there, proving the prefilter owns no verdict.
  "$CHECK" --command "echo 'pkill -f sq-sentry'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign sq-sentry-substring command must be classified and allowed, got exit $rc"
  pass "transport prefilter is a strict superset: non-sq-sentry fast-allows, every sq-sentry and quoting-decoder-marker command reaches the classifier"
}

# --- fail-open ----------------------------------------------------------------

test_failopen_empty_stdin() {
  local rc
  printf '' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "empty stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: empty stdin"
}

test_failopen_garbage_stdin() {
  local rc
  printf 'not json at all {{{' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "unparseable stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: unparseable JSON on stdin"
}

test_failopen_missing_jq() {
  local dir fakebin rc real
  dir=$(fm_test_tmproot sq-arm-pretool-check)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  local tool
  for tool in bash grep sed tr; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" bash -c "printf '%s' '{\"tool_input\":{\"command\":\"bin/sq-sentry-arm.sh &\"}}' | '$CHECK'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must fail open (exit 0) rather than crash-deny, got exit $rc"
  pass "fail-open: missing jq on stdin path"
}

test_failopen_missing_node() {
  local dir fakebin rc real tool
  dir=$(fm_test_tmproot sq-arm-pretool-node)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for tool in bash dirname; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" "$CHECK" --command 'bin/sq-sentry-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing node must fail open (exit 0), got exit $rc"
  pass "fail-open: missing classifier runtime"
}

# --- --claude output shaping ---------------------------------------------------

test_claude_mode_stdout_empty_on_deny() {
  local out err rc stderr_file
  # Keep stderr capture under TMPDIR so concurrent isolation-proof workers do
  # not share a fixed global /tmp path.
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/sq-arm-pretool-check-claude-stderr.XXXXXX")
  out=$("$CHECK" --claude --command 'bin/sq-sentry-arm.sh &' 2>"$stderr_file")
  rc=$?
  err=$(cat "$stderr_file" 2>/dev/null)
  rm -f "$stderr_file"
  [ "$rc" -eq 2 ] || fail "--claude deny must still exit 2, got $rc"
  [ -z "$out" ] || fail "--claude deny must leave stdout EMPTY (Claude Code only honors a stderr-only deny), got: $out"
  printf '%s' "$err" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || fail "--claude deny must put hookSpecificOutput.permissionDecision=deny on stderr: $err"
  pass "--claude: stdout empty, stderr carries hookSpecificOutput deny JSON"
}

test_default_mode_stdout_has_grok_json_on_deny() {
  local out rc
  out=$("$CHECK" --command 'bin/sq-sentry-arm.sh &' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "default deny must exit 2, got $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 \
    || fail "default (non-claude) deny must put Grok's decision JSON on stdout: $out"
  pass "default mode: stdout carries Grok-shaped decision JSON on deny"
}

test_allow_is_silent_both_modes() {
  local out1 out2
  out1=$("$CHECK" --command 'exec bin/sq-sentry-arm.sh' 2>&1)
  out2=$("$CHECK" --claude --command 'exec bin/sq-sentry-arm.sh' 2>&1)
  [ -z "$out1" ] || fail "default allow must be silent, got: $out1"
  [ -z "$out2" ] || fail "--claude allow must be silent, got: $out2"
  pass "allow is silent on both stdout and stderr in default and --claude mode"
}

# --- harness wiring: each adapter invokes the shared checker -----------------

# --- shellcheck (belt-and-suspenders; CI/CONTRIBUTING.md also runs this) -----

test_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$CHECK" >/dev/null 2>&1 || fail "bin/sq-arm-pretool-check.sh is not shellcheck-clean"
  pass "bin/sq-arm-pretool-check.sh is shellcheck-clean"
}

test_full_acceptance_matrix
test_direct_policy_contract
test_command_equals_form
test_background_flag_accepted_and_non_gating
test_unknown_flag_errors
test_stdin_grok_schema_deny
test_stdin_claude_codex_schema_allow
test_stdin_claude_codex_schema_deny
test_stdin_unrelated_command_allowed
test_prefilter_is_strict_superset
test_failopen_empty_stdin
test_failopen_garbage_stdin
test_failopen_missing_jq
test_failopen_missing_node
test_claude_mode_stdout_empty_on_deny
test_default_mode_stdout_has_grok_json_on_deny
test_allow_is_silent_both_modes
test_shellcheck_clean
