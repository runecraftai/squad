#!/usr/bin/env bash
# Behavior tests for the chat-to-Telegram mirror helper (bin/sq-tg-notify.sh):
# the same contract the bridge suite's clients pin - fail-closed on missing
# config, the exact sendMessage call to the Bot API, and stdin/text argument
# handling. The network is stubbed with a fakebin `curl` that records its argv
# and answers 200, so the suite is hermetic: no ports, no external network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot sq-tg-notify-tests)

BASE_PATH=${SQUAD_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A fakebin `curl` that records its argv to FAKE_CURL_LOG and prints the exact
# `-w` format the helper relies on, so tests assert on what the helper actually
# posted (URL, chat id, text) without any network.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
{
  echo "argv=$*"
} >> "${FAKE_CURL_LOG:?}"
printf 'telegram HTTP 200\n'
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

setup_env() { # <home>: bridge env with token + whitelist, as the bridge uses
  mkdir -p "$1/config"
  printf 'TG_BOT_TOKEN=12345:TESTBOT\nTG_ALLOWED_CHAT_IDS=%s\n' "111222333" \
    > "$1/config/telegram-bridge.env"
}

# ---------------------------------------------------------------------------

test_no_config_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/no-config"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" SQUAD_BASE="$home" \
    "$ROOT/bin/sq-tg-notify.sh" "ola" 2>"$home/err"); rc=$?
  expect_code 1 "$rc" "missing config exit"
  assert_grep "no $home/config/telegram-bridge.env" "$home/err" \
    "missing config must name the file it looked for"
  [ -z "$out" ] || fail "missing config must send nothing (got: $out)"
  pass "sq-tg-notify fails closed without the bridge env file"
}

test_missing_token_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/no-token"; mkdir -p "$home/config"
  fakebin=$(make_fake_curl "$home")
  printf 'TG_ALLOWED_CHAT_IDS=111222333\n' > "$home/config/telegram-bridge.env"
  out=$(PATH="$fakebin:$BASE_PATH" SQUAD_BASE="$home" \
    "$ROOT/bin/sq-tg-notify.sh" "ola" 2>"$home/err"); rc=$?
  expect_code 1 "$rc" "missing token exit"
  assert_grep "TG_BOT_TOKEN missing" "$home/err" "missing token must be named"
  pass "sq-tg-notify fails closed without TG_BOT_TOKEN"
}

test_missing_chat_fails_closed() {
  local home fakebin rc
  home="$TMP_ROOT/no-chat"; mkdir -p "$home/config"
  fakebin=$(make_fake_curl "$home")
  printf 'TG_BOT_TOKEN=12345:TESTBOT\n' > "$home/config/telegram-bridge.env"
  PATH="$fakebin:$BASE_PATH" SQUAD_BASE="$home" \
    "$ROOT/bin/sq-tg-notify.sh" "ola" 2>"$home/err"; rc=$?
  expect_code 1 "$rc" "missing chat exit"
  assert_grep "TG_ALLOWED_CHAT_IDS missing" "$home/err" "missing chat must be named"
  pass "sq-tg-notify fails closed without TG_ALLOWED_CHAT_IDS"
}

test_text_arg_posts_sendmessage() {
  local home fakebin log out rc
  home="$TMP_ROOT/arg-post"; setup_env "$home"
  fakebin=$(make_fake_curl "$home"); log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" SQUAD_BASE="$home" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/sq-tg-notify.sh" "resposta do chat"); rc=$?
  expect_code 0 "$rc" "text arg exit"
  [ "$out" = "telegram HTTP 200" ] || fail "must report the Bot API status (got: $out)"
  assert_grep "https://api.telegram.org/bot12345:TESTBOT/sendMessage" "$log" \
    "the mirror must hit sendMessage with the configured bot token"
  assert_grep "chat_id=111222333" "$log" \
    "the mirror must target the first allowed chat id"
  assert_grep "text=resposta do chat" "$log" \
    "the mirror must post the given text"
  pass "sq-tg-notify posts the text argument to the commander's chat"
}

test_stdin_dash_reads_message() {
  local home fakebin log out rc
  home="$TMP_ROOT/stdin-post"; setup_env "$home"
  fakebin=$(make_fake_curl "$home"); log="$home/curl.log"
  out=$(printf 'mensagem longa via stdin\n' | PATH="$fakebin:$BASE_PATH" \
    SQUAD_BASE="$home" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/sq-tg-notify.sh" -); rc=$?
  expect_code 0 "$rc" "stdin dash exit"
  [ "$out" = "telegram HTTP 200" ] || fail "stdin dash must report the status (got: $out)"
  assert_grep "text=mensagem longa via stdin" "$log" \
    "the mirror must post the stdin message"
  pass "sq-tg-notify reads the message from stdin with '-'"
}

test_repo_root_fallback_resolution() {
  local fakebin out rc
  # No SQUAD_BASE/SQUAD_HOME: the helper must fall back to this repo root and
  # fail closed there (the env file is gitignored, so the worktree has none).
  fakebin=$(fm_fakebin "$TMP_ROOT/root-fallback")
  out=$(PATH="$fakebin:$BASE_PATH" env -u SQUAD_BASE -u SQUAD_HOME \
    "$ROOT/bin/sq-tg-notify.sh" "ola" 2>"$TMP_ROOT/root-fallback.err"); rc=$?
  expect_code 1 "$rc" "repo-root fallback exit"
  assert_grep "no $ROOT/config/telegram-bridge.env" "$TMP_ROOT/root-fallback.err" \
    "without a base env the helper must resolve config against the repo root"
  pass "sq-tg-notify resolves the base home like the other sq-* scripts"
}

test_squad_base_wins_over_squad_home() {
  local home other fakebin log out rc
  home="$TMP_ROOT/base-wins"; setup_env "$home"
  other="$TMP_ROOT/home-ignored"; mkdir -p "$other/config"
  printf 'TG_BOT_TOKEN=000:OTHER\nTG_ALLOWED_CHAT_IDS=999\n' \
    > "$other/config/telegram-bridge.env"
  fakebin=$(make_fake_curl "$home"); log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" SQUAD_BASE="$home" SQUAD_HOME="$other" \
    FAKE_CURL_LOG="$log" "$ROOT/bin/sq-tg-notify.sh" "ola"); rc=$?
  expect_code 0 "$rc" "SQUAD_BASE precedence exit"
  assert_grep "bot12345:TESTBOT/sendMessage" "$log" \
    "SQUAD_BASE must win over the legacy SQUAD_HOME"
  pass "sq-tg-notify honors SQUAD_BASE over the legacy SQUAD_HOME"
}

# ---------------------------------------------------------------------------

test_no_config_fails_closed
test_missing_token_fails_closed
test_missing_chat_fails_closed
test_text_arg_posts_sendmessage
test_stdin_dash_reads_message
test_repo_root_fallback_resolution
test_squad_base_wins_over_squad_home
