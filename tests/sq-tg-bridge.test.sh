#!/usr/bin/env bash
# Behavior tests for the local Telegram bridge (bin/sq-tg-bridge.py): the
# connector contract Squad's relay client scripts speak (poll / answer /
# dismiss / followup / request-context), the Telegram update parsing, and the
# fail-closed security boundaries (bearer auth, sender whitelist, slug-safe
# request ids).
#
# Unlike the X-mode suite, which stubs the relay with a fakebin curl, this
# suite runs the REAL bridge on 127.0.0.1 with an ephemeral port and drives it
# with the REAL Squad client scripts (sq-x-poll.sh / sq-x-reply.sh /
# sq-x-dismiss.sh / sq-x-followup.sh) against a fake Telegram Bot API server
# (embedded below). That is the actual wiring a deployed bridge sees: the
# bridge is the relay, and the clients are Squad. Everything stays on
# localhost - no external network.
#
# The fake Telegram server serves getUpdates from a per-test updates file and
# records every outbound sendMessage/sendPhoto to a per-test log, so the tests
# assert on what the bridge actually posted to Telegram.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot sq-tg-bridge-tests)

TOKEN=test-token
OWNER_ID=111222333
STRANGER_ID=999888777
FAKE_PORT=
BRIDGE_URL=

FAKE_PIDS=()
BRIDGE_PIDS=()

kill_runners() {
  local pid
  for pid in "${BRIDGE_PIDS[@]:-}" "${FAKE_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
# The INT/TERM traps matter: a timed-out or interrupted run must still reap
# the bridge and fake processes, or hundreds of orphaned getUpdates loops
# would pile up and starve the machine (lib.sh's own traps only clean the
# fixture dirs).
trap 'kill_runners; fm_test_cleanup; exit 130' INT
trap 'kill_runners; fm_test_cleanup; exit 143' TERM
trap 'kill_runners; fm_test_cleanup' EXIT

# ---------------------------------------------------------------------------
# Embedded fake Telegram Bot API server.
# ---------------------------------------------------------------------------
write_fake_telegram() {
  cat > "$TMP_ROOT/fake-tg.py" <<'PY'
#!/usr/bin/env python3
"""Fake Telegram Bot API server for sq-tg-bridge tests.

Serves getUpdates from <state>/updates.json ({"ok":true,"result":[...]},
empty when the file is absent) and records every sendMessage/sendPhoto to
<state>/sent.log as one JSON line each, with an incrementing message_id so the
bridge's reply chaining is observable. sendPhoto bodies are additionally
written raw to <state>/photo.body so tests can assert on the uploaded bytes.
"""
import argparse
import json
import os
import socket
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("--state-dir", required=True)
parser.add_argument("--port", type=int, default=0)
args = parser.parse_args()

counter = {"n": 1000}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self, entry):
        with open(args.state_dir + "/sent.log", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def do_GET(self):
        if "/getUpdates" in self.path:
            time.sleep(0.5)  # bound the poll rate like a real long-poll hold
            garbage = args.state_dir + "/garbage.response"
            if os.path.exists(garbage):
                with open(args.state_dir + "/garbage-hit", "a",
                          encoding="utf-8") as fh:
                    fh.write("hit\n")
                with open(garbage, "rb") as fh:
                    raw = fh.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return
            try:
                with open(args.state_dir + "/updates.json", encoding="utf-8") as fh:
                    result = json.load(fh).get("result", [])
            except (OSError, ValueError):
                result = []
            self._json({"ok": True, "result": result})
            return
        self._json({"ok": True, "result": {}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b""
        counter["n"] += 1
        mid = counter["n"]
        if "/sendMessage" in self.path:
            body = json.loads(raw.decode("utf-8"))
            if os.path.exists(args.state_dir + "/slow-sends"):
                time.sleep(1.0)
            if os.path.exists(args.state_dir + "/reset-sends"):
                with open(args.state_dir + "/reset-hit", "a",
                          encoding="utf-8") as fh:
                    fh.write("hit\n")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", "999")
                self.end_headers()
                try:
                    self.wfile.write(b'{"ok": true, "res')
                    self.wfile.flush()
                    self.connection.setsockopt(
                        socket.SOL_SOCKET, socket.SO_LINGER,
                        struct.pack("ii", 1, 0))
                finally:
                    self.connection.close()
                return
            if os.path.exists(args.state_dir + "/error-reset-sends"):
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", "999")
                self.end_headers()
                try:
                    self.wfile.write(b'{"ok": false, "desc')
                    self.wfile.flush()
                    self.connection.setsockopt(
                        socket.SOL_SOCKET, socket.SO_LINGER,
                        struct.pack("ii", 1, 0))
                finally:
                    self.connection.close()
                return
            self._record({
                "method": "sendMessage",
                "chat_id": body.get("chat_id"),
                "text": body.get("text"),
                "reply_to_message_id": body.get("reply_to_message_id"),
                "sent_message_id": mid,
            })
            self._json({"ok": True, "result": {
                "message_id": mid,
                "chat": {"id": body.get("chat_id")},
                "text": body.get("text"),
            }})
            return
        if "/sendPhoto" in self.path:
            with open(args.state_dir + "/photo.body", "wb") as fh:
                fh.write(raw)
            self._record({"method": "sendPhoto", "sent_message_id": mid})
            self._json({"ok": True, "result": {"message_id": mid}})
            return
        self._json({"ok": True, "result": {}})


server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
print("fake-telegram listening %d" % server.server_address[1], flush=True)
sys.stdout.flush()
server.serve_forever()
PY
}

# ---------------------------------------------------------------------------
# Shared fixture helpers.
# ---------------------------------------------------------------------------
setup_home() { # <home>: .env with the shared token + bridge env with whitelist
  mkdir -p "$1/config"
  printf 'SQX_PAIRING_TOKEN=%s\n' "$TOKEN" > "$1/.env"
  printf 'TG_BOT_TOKEN=12345:TESTBOT\nTG_ALLOWED_CHAT_IDS=%s\n' "$OWNER_ID" \
    > "$1/config/telegram-bridge.env"
}

start_fake_tg() { # <state-dir>: sets FAKE_PORT
  local dir=$1 out pid port
  mkdir -p "$dir"
  python3 "$TMP_ROOT/fake-tg.py" --state-dir "$dir" --port 0 > "$dir/fake.out" 2>&1 &
  pid=$!
  FAKE_PIDS+=("$pid")
  local deadline=$(( $(date +%s) + 10 ))
  while ! grep -q "fake-telegram listening" "$dir/fake.out" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "fake telegram did not start"
    sleep 0.2
  done
  port=$(sed -n 's/.*listening \([0-9][0-9]*\)$/\1/p' "$dir/fake.out" | tail -1)
  [ -n "$port" ] || fail "fake telegram did not report a port"
  FAKE_PORT=$port
}

start_bridge() { # <home> <fake_port> [env...]: sets BRIDGE_URL
  local home=$1 fake_port=$2 out pid port
  shift 2
  out="$home/bridge.out"
  env "$@" SQUAD_HOME="$home" python3 "$ROOT/bin/sq-tg-bridge.py" --port 0 \
    --telegram-api-url "http://127.0.0.1:$fake_port" \
    --state-file "$home/bridge-state.json" > "$out" 2>&1 &
  pid=$!
  BRIDGE_PIDS+=("$pid")
  local deadline=$(( $(date +%s) + 10 ))
  while ! grep -q "listening on http" "$out" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      fail "bridge did not start (out: $(cat "$out" 2>/dev/null))"
    }
    sleep 0.2
  done
  port=$(sed -n 's|.*listening on http://127.0.0.1:\([0-9][0-9]*\).*|\1|p' \
    "$out" | tail -1)
  [ -n "$port" ] || fail "bridge did not report a port"
  BRIDGE_URL="http://127.0.0.1:$port"
}

stop_bridge() { # kill the last-started bridge so a test can restart it
  local pid
  if [ "${#BRIDGE_PIDS[@]}" -gt 0 ]; then
    pid=${BRIDGE_PIDS[-1]}
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    BRIDGE_PIDS=("${BRIDGE_PIDS[@]:0:${#BRIDGE_PIDS[@]}-1}")
  fi
}

bridge_poll() { # <base_url> <outfile>: echoes the HTTP code
  curl -s -m 5 -o "$2" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" "$1/connector/poll"
}

bridge_post() { # <base_url> <endpoint> <json>: echoes the HTTP code
  curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "$3" "$1/connector/$2"
}

wait_for_request() { # <base_url> <outfile>: poll until 200 with a request
  local deadline=$(( $(date +%s) + 10 )) code
  while :; do
    code=$(bridge_poll "$1" "$2")
    [ "$code" = 200 ] && return 0
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never offered a request"
    sleep 0.2
  done
}

feed_updates() { # <fake_dir> <updates-doc>
  printf '%s\n' "$2" > "$1/updates.json"
}

one_update() { # <update_id> <message_id> <from_id> <text> [text|caption] [reply_to_json]
  local reply="${6:-null}"
  printf '{"ok":true,"result":[{"update_id":%s,"message":{' "$1"
  printf '"message_id":%s,"from":{"id":%s},"chat":{"id":%s},' "$2" "$3" "$3"
  if [ "${5:-}" = caption ]; then
    printf '"caption":"%s"' "$4"
  else
    printf '"text":"%s"' "$4"
  fi
  printf ',"reply_to_message":%s}}]}' "$reply"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_connector_requires_bearer_token() {
  local home fake_dir fake_port url body
  home="$TMP_ROOT/auth-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/auth-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  body="$home/body.json"
  expect_code 401 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url/connector/poll")" \
    "poll without token must be 401"
  expect_code 401 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' \
    -H 'Authorization: Bearer wrong-token' "$url/connector/poll")" \
    "poll with a wrong token must be 401"
  expect_code 204 "$(bridge_poll "$url" "$body")" "poll with the shared token"
  [ ! -s "$body" ] || fail "a 204 poll must have an empty body"
  pass "connector calls require the exact shared bearer token"
}

test_non_whitelisted_sender_is_ignored() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/whitelist-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/whitelist-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 1 10 "$STRANGER_ID" 'intruso')"
  sleep 1
  local code; code=$(bridge_poll "$url" "$home/body.json")
  expect_code 204 "$code" "stranger message must never be offered"
  [ ! -s "$fake_dir/sent.log" ] || fail "stranger message must not trigger any send"
  assert_grep "non-whitelisted" "$home/bridge.out" \
    "the bridge must log the rejected sender for the operator"
  pass "messages from non-whitelisted senders are ignored and never offered"
}

test_start_command_greets_without_request() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/start-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/start-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 2 11 "$OWNER_ID" '/start')"
  local deadline=$(( $(date +%s) + 10 ))
  while [ ! -s "$fake_dir/sent.log" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never sent the greeting"
    sleep 0.2
  done
  expect_code 204 "$(bridge_poll "$url" "$home/body.json")" \
    "/start must not create a request"
  assert_grep "Squad bridge online" "$fake_dir/sent.log" \
    "the greeting must be sent to the chat"
  pass "/start is greeted directly and never queued for Squad"
}

test_textless_message_is_ignored() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/textless-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/textless-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "{\"ok\":true,\"result\":[{\"update_id\":3,\"message\":{\"message_id\":12,\"from\":{\"id\":$OWNER_ID},\"chat\":{\"id\":$OWNER_ID}}}]}"
  sleep 1
  expect_code 204 "$(bridge_poll "$url" "$home/body.json")" \
    "text-less message must not create a request"
  pass "messages without text or caption are ignored (Squad only wakes on text)"
}

test_update_parses_request_with_reply_context() {
  local home fake_dir fake_port url body
  home="$TMP_ROOT/parse-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/parse-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  local parent='{"message_id":41,"from":{"id":'"$OWNER_ID"',"username":"com"},"text":"mensagem anterior"}'
  feed_updates "$fake_dir" "$(one_update 4 42 "$OWNER_ID" 'ola comandante' text "$parent")"
  body="$home/body.json"
  wait_for_request "$url" "$body"
  local rid
  rid=$(jq -r '.request_id' "$body")
  [ "$rid" = "tg-$OWNER_ID-42" ] || fail "stable request_id expected tg-$OWNER_ID-42 (got: $rid)"
  [ "$(jq -r '.text' "$body")" = "ola comandante" ] || fail "poll must carry the message text"
  [ "$(jq -r '.platform' "$body")" = "discord" ] || fail "poll must carry the client-resolved platform"
  [ "$(jq -r '.reply_max_chars' "$body")" = "4096" ] || fail "poll must carry Telegram's 4096 budget"
  [ "$(jq -r '.in_reply_to.author_handle' "$body")" = "com" ] || fail "reply author handle must be the username"
  [ "$(jq -r '.in_reply_to.text' "$body")" = "mensagem anterior" ] || fail "reply text must be preserved"
  expect_code 200 "$(bridge_poll "$url" "$home/body2.json")" \
    "a pending request must be re-offered on the next poll"
  [ "$(jq -r '.request_id' "$home/body2.json")" = "$rid" ] \
    || fail "re-offer must keep the same request_id"
  pass "Telegram updates parse into stable requests with reply context and platform budget"
}

test_caption_only_message_uses_caption_as_text() {
  local home fake_dir fake_port url body
  home="$TMP_ROOT/caption-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/caption-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 5 43 "$OWNER_ID" 'legenda da foto' caption)"
  body="$home/body.json"
  wait_for_request "$url" "$body"
  [ "$(jq -r '.text' "$body")" = "legenda da foto" ] || fail "caption must become the request text"
  pass "a photo caption is used as the request text"
}

test_poll_wakes_squad_client_once_and_records_context() {
  local home fake_dir fake_port url out rid
  home="$TMP_ROOT/wake-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/wake-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 6 50 "$OWNER_ID" 'qual o status?')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" "$ROOT/bin/sq-x-poll.sh")
    case "$out" in
      x-mention*) break ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail "squad poll never woke on the mention"
    sleep 0.2
  done
  rid=${out#x-mention }
  [ "$rid" = "tg-$OWNER_ID-50" ] || fail "wake must name the bridge request_id (got: $out)"
  [ "$(jq -r '.platform' "$home/state/x-inbox/$rid.json")" = "discord" ] \
    || fail "the stashed inbox payload must keep the platform"
  [ "$(jq -r '.in_reply_to' "$home/state/x-inbox/$rid.json")" = "null" ] \
    || fail "a fresh mention must round-trip in_reply_to as null"
  [ "$(jq -r '.reply_max_chars' "$home/state/x-context/$rid.json")" = "4096" ] \
    || fail "the durable reply context must record Telegram's budget"
  [ "$(jq -r '.platform' "$home/state/x-context/$rid.json")" = "discord" ] \
    || fail "the durable reply context must record the client-resolved platform"
  out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" "$ROOT/bin/sq-x-poll.sh")
  [ -z "$out" ] || fail "a re-offer must stay silent after the durable claim (got: $out)"
  pass "the real poll client wakes exactly once and records the reply context"
}

test_answer_posts_to_telegram_via_squad_client() {
  local home fake_dir fake_port url out
  home="$TMP_ROOT/answer-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/answer-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 7 60 "$OWNER_ID" 'verifique o PR')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" "$ROOT/bin/sq-x-poll.sh")
    case "$out" in
      x-mention*) break ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail "squad poll never woke on the mention"
    sleep 0.2
  done
  local rid=${out#x-mention }
  out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" \
    "$ROOT/bin/sq-x-reply.sh" "$rid" "roger, verificando")
  expect_code 0 "$?" "squad answer exit"
  [ "$out" = "$rid" ] || fail "answer must echo the request_id (got: $out)"
  assert_grep '"chat_id": '"$OWNER_ID" "$fake_dir/sent.log" "answer must reach the chat"
  assert_grep '"text": "roger, verificando"' "$fake_dir/sent.log" "answer must carry the reply text"
  assert_grep '"reply_to_message_id": 60' "$fake_dir/sent.log" \
    "answer must reply to the commander's original message"
  expect_code 204 "$(bridge_poll "$url" "$home/body.json")" \
    "an answered request must stop being offered"
  pass "the real reply client answers through the bridge into Telegram"
}

test_answer_splits_long_thread_chained() {
  local home fake_dir fake_port url out long
  home="$TMP_ROOT/thread-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/thread-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 8 70 "$OWNER_ID" 'relatorio longo')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" "$ROOT/bin/sq-x-poll.sh")
    case "$out" in
      x-mention*) break ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail "squad poll never woke on the mention"
    sleep 0.2
  done
  local rid=${out#x-mention }
  long=$(printf 'a%.0s' $(seq 1 9000))
  SQUAD_HOME="$home" SQX_RELAY_URL="$url" \
    "$ROOT/bin/sq-x-reply.sh" "$rid" --text-file <(printf '%s\n' "$long") >/dev/null
  expect_code 0 "$?" "long answer exit"
  local count
  count=$(jq -s 'length' "$fake_dir/sent.log")
  [ "$count" -ge 2 ] || fail "a 9000-char reply must split into at least 2 messages (got $count)"
  [ "$(jq -s '.[0].reply_to_message_id' "$fake_dir/sent.log")" = 70 ] \
    || fail "the thread opener must reply to the original message"
  [ "$(jq -s '.[1].reply_to_message_id' "$fake_dir/sent.log")" \
      = "$(jq -s '.[0].sent_message_id' "$fake_dir/sent.log")" ] \
    || fail "the second chunk must reply to the first sent message"
  assert_grep '(1/'"$count"')' "$fake_dir/sent.log" "chunks must be numbered in thread"
  pass "long answers split into a chained numbered thread"
}

test_answer_unknown_request_is_404() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/unknown-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/unknown-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  expect_code 404 "$(bridge_post "$url" answer \
    '{"request_id":"tg-1-1","text":"oi"}')" "answer for an unknown request must be 404"
  pass "answers for unknown request ids fail loudly"
}

test_dismiss_drops_pending_request() {
  local home fake_dir fake_port url out
  home="$TMP_ROOT/dismiss-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/dismiss-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 9 80 "$OWNER_ID" 'obrigado')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" "$ROOT/bin/sq-x-poll.sh")
    case "$out" in
      x-mention*) break ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail "squad poll never woke on the mention"
    sleep 0.2
  done
  local rid=${out#x-mention }
  out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" \
    "$ROOT/bin/sq-x-dismiss.sh" "$rid")
  expect_code 0 "$?" "squad dismiss exit"
  [ "$out" = "$rid" ] || fail "dismiss must echo the request_id (got: $out)"
  expect_code 204 "$(bridge_poll "$url" "$home/body.json")" \
    "a dismissed request must stop being offered"
  expect_code 204 "$(bridge_poll "$url" "$home/body2.json")" \
    "a dismissed request must stay dropped"
  [ ! -s "$fake_dir/sent.log" ] || fail "dismiss must never post to Telegram"
  pass "the real dismiss client drops a request without posting"
}

test_followup_posts_within_cap_then_409() {
  local home fake_dir fake_port url n
  home="$TMP_ROOT/followup-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/followup-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 10 90 "$OWNER_ID" 'faça a tarefa')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    bridge_poll "$url" "$home/body.json" | grep -q 200 && break
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never offered the request"
    sleep 0.2
  done
  local rid="tg-$OWNER_ID-90"
  expect_code 200 "$(bridge_post "$url" answer \
    "{\"request_id\":\"$rid\",\"text\":\"na ativa\"}")" "answer must bind the request"
  local n
  for n in 1 2 3; do
    expect_code 200 "$(bridge_post "$url" followup \
      "{\"request_id\":\"$rid\",\"text\":\"marco $n\"}")" \
      "follow-up $n within the cap must post"
  done
  local body4
  body4=$(curl -s -m 5 -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"$rid\",\"text\":\"marco 4\"}" \
    "$url/connector/followup")
  [ "$(printf '%s' "$body4" | jq -r '.error')" = "followup_unavailable" ] \
    || fail "the 4th follow-up must carry the followup_unavailable marker"
  local count
  count=$(jq -s 'length' "$fake_dir/sent.log")
  expect_code 4 "$count" "exactly the answer plus 3 follow-ups may reach Telegram"
  feed_updates "$fake_dir" "$(one_update 11 91 "$OWNER_ID" 'outra tarefa')"
  sleep 1
  expect_code 409 "$(bridge_post "$url" followup \
    '{"request_id":"tg-'"$OWNER_ID"'-91","text":"sem binding"}')" \
    "a follow-up without an answer binding must be 409"
  pass "follow-ups respect the 3-post cap and reject without a binding"
}

test_followup_window_expiry_survives_restart() {
  local home fake_dir fake_port url answered_at now override
  home="$TMP_ROOT/window-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/window-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 12 100 "$OWNER_ID" 'abre a investigação')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    bridge_poll "$url" "$home/body.json" | grep -q 200 && break
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never offered the request"
    sleep 0.2
  done
  local rid="tg-$OWNER_ID-100"
  expect_code 200 "$(bridge_post "$url" answer \
    "{\"request_id\":\"$rid\",\"text\":\"em andamento\"}")" "answer must bind"
  answered_at=$(jq -r '.requests["'"$rid"'"].answered_at' "$home/bridge-state.json")
  [ -n "$answered_at" ] || fail "state must record the answer binding timestamp"
  stop_bridge
  override=$((answered_at + 7 * 24 * 3600 + 60))
  start_bridge "$home" "$fake_port" TG_BRIDGE_NOW_OVERRIDE="$override"; url=$BRIDGE_URL
  expect_code 409 "$(bridge_post "$url" followup \
    "{\"request_id\":\"$rid\",\"text\":\"muito tarde\"}")" \
    "a follow-up past the 7-day window must be 409"
  [ "$(jq -r '.requests["'"$rid"'"]' "$home/bridge-state.json")" = "null" ] \
    || fail "an expired binding must be pruned from the state file"
  pass "follow-ups respect the 7-day window and the binding survives restarts"
}

test_restart_does_not_duplicate_and_offset_advances() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/restart-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/restart-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 20 200 "$OWNER_ID" 'primeira')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    bridge_poll "$url" "$home/body.json" | grep -q 200 && break
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never offered the first request"
    sleep 0.2
  done
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-$OWNER_ID-200" ] \
    || fail "first request must be offered"
  stop_bridge
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  sleep 1
  expect_code 200 "$(bridge_poll "$url" "$home/body.json")" \
    "the pending request must still be offered after restart"
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-$OWNER_ID-200" ] \
    || fail "restart must not re-ingest the old update into a second request"
  assert_no_grep "ingested tg-$OWNER_ID-200" "$home/bridge.out" \
    "restart must not re-ingest the old update"
  feed_updates "$fake_dir" "$(one_update 21 201 "$OWNER_ID" 'segunda')"
  local deadline2=$(( $(date +%s) + 10 ))
  while :; do
    grep -F -- "ingested tg-$OWNER_ID-201" "$home/bridge.out" >/dev/null && break
    [ "$(date +%s)" -lt "$deadline2" ] || fail "new update never ingested after restart"
    sleep 0.2
  done
  assert_grep "ingested tg-$OWNER_ID-201" "$home/bridge.out" \
    "the newer update must be ingested after restart"
  expect_code 200 "$(bridge_post "$url" answer \
    '{"request_id":"tg-'"$OWNER_ID"'-200","text":"ok"}')" "answer the first request"
  local deadline3=$(( $(date +%s) + 10 ))
  while :; do
    bridge_poll "$url" "$home/body.json" | grep -q 200 || {
      [ "$(date +%s)" -lt "$deadline3" ] || fail "bridge stopped offering"
      sleep 0.2
      continue
    }
    [ "$(jq -r '.request_id' "$home/body.json" 2>/dev/null)" = "tg-$OWNER_ID-201" ] \
      && break
    [ "$(date +%s)" -lt "$deadline3" ] || fail "answered request not replaced by the next pending one"
    sleep 0.2
  done
  pass "restart keeps the offset, never duplicates a request, and keeps pending work"
}

test_state_file_with_wrong_shape_records_starts_clean() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/badstate-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/badstate-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  cat > "$home/bridge-state.json" <<EOF
{"offset": 900, "requests": {
  "tg-1-1": {"chat_id": 1, "message_id": 1, "text": "ok", "created_at": 100, "status": "pending", "answered_at": null, "followups": 0},
  "tg-1-2": {"status": "pending"},
  "tg-1-3": {"chat_id": "1", "message_id": 3, "text": "x", "status": "answered", "answered_at": 100, "followups": 0},
  "tg-1-4": {"chat_id": 1, "message_id": 4, "text": "x", "created_at": "ontem", "status": "pending", "answered_at": null, "followups": 0},
  "tg-1-5": {"chat_id": 1, "message_id": 5, "text": "x", "created_at": 100, "status": "answered", "answered_at": $(date +%s), "followups": "abc"}
}}
EOF
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  expect_code 200 "$(bridge_poll "$url" "$home/body.json")" \
    "poll must not crash on a non-integer created_at"
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-1-1" ] \
    || fail "poll must offer only the well-shaped record"
  expect_code 404 "$(bridge_post "$url" answer '{"request_id":"tg-1-2","text":"oi"}')" \
    "a record without chat_id must be dropped at load time"
  expect_code 404 "$(bridge_post "$url" answer '{"request_id":"tg-1-3","text":"oi"}')" \
    "a record with a non-integer chat_id must be dropped at load time"
  expect_code 404 "$(bridge_post "$url" answer '{"request_id":"tg-1-4","text":"oi"}')" \
    "a record with a non-integer created_at must be dropped at load time"
  expect_code 409 "$(bridge_post "$url" followup '{"request_id":"tg-1-5","text":"oi"}')" \
    "a record with a non-integer followups must be dropped at load time"
  expect_code 200 "$(bridge_post "$url" answer '{"request_id":"tg-1-1","text":"oi"}')" \
    "a well-shaped record must still answer"
  pass "wrong-shape state records are dropped at load instead of crashing handlers"
}

test_null_created_at_does_not_crash_poll() {
  local home fake_dir fake_port url rid
  home="$TMP_ROOT/nullcreated-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/nullcreated-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  cat > "$home/bridge-state.json" <<EOF
{"offset": 900, "requests": {
  "tg-1-1": {"chat_id": 1, "message_id": 1, "text": "recente", "created_at": null, "status": "pending", "answered_at": null, "followups": 0},
  "tg-1-2": {"chat_id": 1, "message_id": 2, "text": "antiga", "created_at": 100, "status": "pending", "answered_at": null, "followups": 0}
}}
EOF
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  expect_code 200 "$(bridge_poll "$url" "$home/body.json")" \
    "poll must not crash when a pending record has an explicitly null created_at"
  rid=$(jq -r '.request_id' "$home/body.json")
  case "$rid" in
    tg-1-1|tg-1-2) : ;;
    *) fail "poll must offer one of the loaded pending records, got $rid" ;;
  esac
  expect_code 200 "$(bridge_post "$url" answer "{\"request_id\":\"$rid\",\"text\":\"oi\"}")" \
    "a record loaded alongside a null created_at must still answer"
  pass "an explicitly null created_at sorts safely and does not crash poll"
}

test_request_context_endpoint() {
  local home fake_dir fake_port url body
  home="$TMP_ROOT/ctx-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/ctx-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 30 300 "$OWNER_ID" 'contexto')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    bridge_poll "$url" "$home/body.json" | grep -q 200 && break
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never offered the request"
    sleep 0.2
  done
  body=$(curl -s -m 5 -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"request_id":"tg-'"$OWNER_ID"'-300"}' \
    "$url/connector/request-context")
  [ "$(printf '%s' "$body" | jq -r '.platform')" = "discord" ] \
    || fail "request-context must resolve the recorded platform"
  [ "$(printf '%s' "$body" | jq -r '.reply_max_chars')" = "4096" ] \
    || fail "request-context must resolve the recorded budget"
  expect_code 404 "$(bridge_post "$url" request-context \
    '{"request_id":"tg-1-1"}')" "request-context for an unknown request must be 404"
  pass "request-context resolves the recorded platform and budget"
}

test_image_answer_posts_sendphoto() {
  local home fake_dir fake_port url out
  home="$TMP_ROOT/image-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/image-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 31 310 "$OWNER_ID" 'manda a imagem')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" "$ROOT/bin/sq-x-poll.sh")
    case "$out" in
      x-mention*) break ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail "squad poll never woke on the mention"
    sleep 0.2
  done
  local rid=${out#x-mention }
  printf '\211PNG\r\n\032\nSquad-test-png' > "$home/test.png"
  SQUAD_HOME="$home" SQX_RELAY_URL="$url" \
    "$ROOT/bin/sq-x-reply.sh" "$rid" --image "$home/test.png" "aqui está" >/dev/null
  expect_code 0 "$?" "image answer exit"
  assert_grep 'sendPhoto' "$fake_dir/sent.log" "the image must be posted as a photo"
  [ -s "$fake_dir/photo.body" ] || fail "the photo upload must reach Telegram"
  grep -a -q 'PNG' "$fake_dir/photo.body" || fail "the uploaded photo must carry the PNG bytes"
  [ "$(jq -s '.[1].reply_to_message_id' "$fake_dir/sent.log")" \
      = "$(jq -s '.[0].sent_message_id' "$fake_dir/sent.log")" ] \
    || fail "the text must chain onto the photo message"
  pass "answers with an image ride a sendPhoto whose text chains after it"
}

test_followup_flow_via_squad_client() {
  local home fake_dir fake_port url out meta
  home="$TMP_ROOT/client-followup-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/client-followup-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 32 320 "$OWNER_ID" 'investigue a falha')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" "$ROOT/bin/sq-x-poll.sh")
    case "$out" in
      x-mention*) break ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail "squad poll never woke on the mention"
    sleep 0.2
  done
  local rid=${out#x-mention }
  mkdir -p "$home/state"
  printf 'window=w\nworktree=/wt\nkind=strike\nmode=drill\nyolo=off\n' \
    > "$home/state/task-f.meta"
  SQUAD_HOME="$home" "$ROOT/bin/sq-x-link.sh" task-f "$rid" >/dev/null
  expect_code 0 "$?" "link exit"
  meta="$home/state/task-f.meta"
  assert_grep "x_platform=discord" "$meta" \
    "the link must record the bridge's client-resolved platform"
  assert_grep "x_reply_max_chars=4096" "$meta" \
    "the link must record Telegram's budget"
  SQUAD_HOME="$home" SQX_RELAY_URL="$url" \
    "$ROOT/bin/sq-x-reply.sh" "$rid" "recebido, na investigação" >/dev/null
  expect_code 0 "$?" "acknowledgement exit"
  rm -f "$home/state/x-inbox/$rid.json"
  out=$(SQUAD_HOME="$home" SQX_RELAY_URL="$url" \
    "$ROOT/bin/sq-x-followup.sh" task-f - <<<"achado o culpado")
  expect_code 0 "$?" "follow-up exit"
  [ "$out" = "$rid" ] || fail "follow-up must echo the request_id (got: $out)"
  assert_grep '"text": "achado o culpado"' "$fake_dir/sent.log" \
    "the follow-up must reach Telegram"
  assert_grep "x_followups=1" "$meta" "the follow-up counter must advance"
  pass "the full client flow - link, answer, follow-up - resolves platform and budget end to end"
}

test_malformed_telegram_response_does_not_kill_poller() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/garbage-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/garbage-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  printf 'not-json' > "$fake_dir/garbage.response"
  local deadline=$(( $(date +%s) + 10 ))
  while ! grep -q "getUpdates failed" "$home/bridge.out" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never hit the malformed response"
    sleep 0.2
  done
  rm -f "$fake_dir/garbage.response"
  feed_updates "$fake_dir" "$(one_update 40 400 "$OWNER_ID" 'apos a falha')"
  local deadline2=$(( $(date +%s) + 15 ))
  while :; do
    bridge_poll "$url" "$home/body.json" | grep -q 200 && break
    [ "$(date +%s)" -lt "$deadline2" ] || fail "poller never recovered after a malformed response"
    sleep 0.2
  done
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-$OWNER_ID-400" ] \
    || fail "a malformed response must not lose later updates"
  pass "a malformed Telegram response backs off instead of killing the poller"
}

test_concurrent_answers_post_exactly_once() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/race-answer-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/race-answer-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 41 410 "$OWNER_ID" 'corrida')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    bridge_poll "$url" "$home/body.json" | grep -q 200 && break
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never offered the request"
    sleep 0.2
  done
  local rid="tg-$OWNER_ID-410" c1pid c2pid
  touch "$fake_dir/slow-sends"
  (curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"$rid\",\"text\":\"resposta\"}" \
    "$url/connector/answer" > "$home/c1.code") & c1pid=$!
  (curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"$rid\",\"text\":\"resposta\"}" \
    "$url/connector/answer" > "$home/c2.code") & c2pid=$!
  wait "$c1pid" "$c2pid"
  rm -f "$fake_dir/slow-sends"
  expect_code 200 "$(cat "$home/c1.code")" "first concurrent answer"
  expect_code 200 "$(cat "$home/c2.code")" "second concurrent answer must be the idempotent 2xx"
  local count
  count=$(jq -s 'length' "$fake_dir/sent.log")
  expect_code 1 "$count" "concurrent answers to one pending request must post exactly one thread"
  pass "concurrent answers cannot double-post a thread"
}

test_concurrent_followups_respect_the_cap() {
  local home fake_dir fake_port url n
  home="$TMP_ROOT/race-followup-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/race-followup-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 42 420 "$OWNER_ID" 'maratona')"
  local deadline=$(( $(date +%s) + 10 ))
  while :; do
    bridge_poll "$url" "$home/body.json" | grep -q 200 && break
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never offered the request"
    sleep 0.2
  done
  local rid="tg-$OWNER_ID-420" c1pid c2pid
  expect_code 200 "$(bridge_post "$url" answer \
    "{\"request_id\":\"$rid\",\"text\":\"na ativa\"}")" "answer must bind the request"
  for n in 1 2; do
    expect_code 200 "$(bridge_post "$url" followup \
      "{\"request_id\":\"$rid\",\"text\":\"marco $n\"}")" \
      "follow-up $n must post"
  done
  touch "$fake_dir/slow-sends"
  (curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"$rid\",\"text\":\"marco 3\"}" \
    "$url/connector/followup" > "$home/c1.code") & c1pid=$!
  (curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"$rid\",\"text\":\"marco 4\"}" \
    "$url/connector/followup" > "$home/c2.code") & c2pid=$!
  wait "$c1pid" "$c2pid"
  rm -f "$fake_dir/slow-sends"
  local codes
  codes=$(printf '%s %s\n' "$(cat "$home/c1.code")" "$(cat "$home/c2.code")" \
    | tr ' ' '\n' | sort -n | tr '\n' ' ')
  [ "$codes" = "200 409 " ] \
    || fail "concurrent follow-ups at the cap must yield one 200 and one 409 (got: $codes)"
  local count
  count=$(jq -s 'length' "$fake_dir/sent.log")
  expect_code 4 "$count" "answer plus at most 3 follow-ups may reach Telegram"
  pass "concurrent follow-ups cannot exceed the 3-post contract"
}

test_midread_reset_on_answer_returns_502_and_stays_pending() {
  local home fake_dir fake_port url rid
  home="$TMP_ROOT/reset-answer-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/reset-answer-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 51 510 "$OWNER_ID" 'rede caiu')"
  wait_for_request "$url" "$home/body.json"
  rid="tg-$OWNER_ID-510"
  touch "$fake_dir/reset-sends"
  local code
  code=$(curl -s -m 20 -o "$home/answer.body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"$rid\",\"text\":\"resposta\"}" \
    "$url/connector/answer")
  rm -f "$fake_dir/reset-sends"
  expect_code 502 "$code" \
    "a mid-read network failure on send must surface as the 502 contract"
  jq -e '.error == "telegram_send_failed"' "$home/answer.body" > /dev/null \
    || fail "the 502 body must carry telegram_send_failed"
  expect_code 200 "$(bridge_poll "$url" "$home/body.json")" \
    "the failed answer must leave the request pending"
  [ "$(jq -r '.request_id' "$home/body.json")" = "$rid" ] \
    || fail "the same request must be re-offered after the failed answer"
  expect_code 200 "$(bridge_post "$url" answer \
    "{\"request_id\":\"$rid\",\"text\":\"resposta\"}")" \
    "a retry after the network failure must post"
  local count
  count=$(jq -s 'length' "$fake_dir/sent.log")
  expect_code 1 "$count" "only the successful retry may reach Telegram"
  pass "a mid-read network failure on send returns 502 and keeps the request pending"
}

test_midread_reset_on_greeting_does_not_kill_poller() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/reset-greet-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/reset-greet-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  touch "$fake_dir/reset-sends"
  feed_updates "$fake_dir" "$(one_update 52 520 "$OWNER_ID" '/start')"
  local deadline=$(( $(date +%s) + 10 ))
  while [ ! -f "$fake_dir/reset-hit" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "greeting send never hit the reset path"
    sleep 0.2
  done
  rm -f "$fake_dir/reset-sends"
  feed_updates "$fake_dir" "$(one_update 53 530 "$OWNER_ID" 'sobreviveu')"
  wait_for_request "$url" "$home/body.json"
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-$OWNER_ID-530" ] \
    || fail "a mid-read failure on the greeting must not kill the poller"
  pass "a mid-read network failure on the greeting send leaves the poller alive"
}

test_non_object_json_response_does_not_kill_poller() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/notobject-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/notobject-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  printf '[]' > "$fake_dir/garbage.response"
  local deadline=$(( $(date +%s) + 10 ))
  while ! grep -q "getUpdates failed" "$home/bridge.out" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never hit the non-object response"
    sleep 0.2
  done
  rm -f "$fake_dir/garbage.response"
  feed_updates "$fake_dir" "$(one_update 61 610 "$OWNER_ID" 'apos o corpo invalido')"
  wait_for_request "$url" "$home/body.json"
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-$OWNER_ID-610" ] \
    || fail "a non-object JSON body must not lose later updates"
  pass "a JSON body that is not an object backs off instead of killing the poller"
}

test_non_string_text_does_not_kill_poller() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/nonstring-text-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/nonstring-text-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "{\"ok\":true,\"result\":[{\"update_id\":71,\"message\":{\"message_id\":710,\"from\":{\"id\":$OWNER_ID},\"chat\":{\"id\":$OWNER_ID},\"text\":42}},{\"update_id\":72,\"message\":{\"message_id\":720,\"from\":{\"id\":{\"malformed\":true}},\"chat\":{\"id\":$OWNER_ID},\"text\":\"oi\"}}]}"
  local deadline=$(( $(date +%s) + 10 ))
  while [ "$(jq -r '.offset' "$home/bridge-state.json" 2>/dev/null)" != "72" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never processed the malformed updates"
    sleep 0.2
  done
  feed_updates "$fake_dir" "$(one_update 73 730 "$OWNER_ID" 'apos o texto invalido')"
  wait_for_request "$url" "$home/body.json"
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-$OWNER_ID-730" ] \
    || fail "a non-string text or sender id must not kill the poller or create a request"
  pass "non-string text and sender id fields are ignored and the poller stays alive"
}

test_non_list_result_does_not_kill_poller() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/nonlist-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/nonlist-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  printf '{"ok":true,"result":42}' > "$fake_dir/garbage.response"
  local deadline=$(( $(date +%s) + 10 ))
  while [ ! -f "$fake_dir/garbage-hit" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "bridge never hit the non-list result"
    sleep 0.2
  done
  rm -f "$fake_dir/garbage.response"
  feed_updates "$fake_dir" "$(one_update 65 650 "$OWNER_ID" 'apos o result invalido')"
  wait_for_request "$url" "$home/body.json"
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-$OWNER_ID-650" ] \
    || fail "a non-list getUpdates result must not lose later updates"
  pass "a non-list getUpdates result leaves the poller alive"
}

test_error_status_with_reset_body_returns_502_and_stays_pending() {
  local home fake_dir fake_port url rid code
  home="$TMP_ROOT/error-reset-answer-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/error-reset-answer-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  feed_updates "$fake_dir" "$(one_update 62 620 "$OWNER_ID" 'erro 500')"
  wait_for_request "$url" "$home/body.json"
  rid="tg-$OWNER_ID-620"
  touch "$fake_dir/error-reset-sends"
  code=$(curl -s -m 20 -o "$home/answer.body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"$rid\",\"text\":\"resposta\"}" \
    "$url/connector/answer")
  rm -f "$fake_dir/error-reset-sends"
  expect_code 502 "$code" \
    "an unreadable error-status body on send must surface as the 502 contract"
  jq -e '.error == "telegram_send_failed"' "$home/answer.body" > /dev/null \
    || fail "the 502 body must carry telegram_send_failed"
  expect_code 200 "$(bridge_poll "$url" "$home/body.json")" \
    "the failed answer must leave the request pending"
  [ "$(jq -r '.request_id' "$home/body.json")" = "$rid" ] \
    || fail "the same request must be re-offered after the failed answer"
  expect_code 200 "$(bridge_post "$url" answer \
    "{\"request_id\":\"$rid\",\"text\":\"resposta\"}")" \
    "a retry after the failed send must post"
  local count
  count=$(jq -s 'length' "$fake_dir/sent.log")
  expect_code 1 "$count" "only the successful retry may reach Telegram"
  pass "an unreadable error-status body returns 502 and keeps the request pending"
}

test_error_status_with_reset_body_on_greeting_does_not_kill_poller() {
  local home fake_dir fake_port url
  home="$TMP_ROOT/error-reset-greet-home"; setup_home "$home"
  fake_dir="$TMP_ROOT/error-reset-greet-fake"; start_fake_tg "$fake_dir"; fake_port=$FAKE_PORT
  start_bridge "$home" "$fake_port"; url=$BRIDGE_URL
  touch "$fake_dir/error-reset-sends"
  feed_updates "$fake_dir" "$(one_update 63 630 "$OWNER_ID" '/start')"
  local deadline=$(( $(date +%s) + 10 ))
  while ! grep -q "greeting send failed" "$home/bridge.out" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "greeting send never hit the failed error body"
    sleep 0.2
  done
  rm -f "$fake_dir/error-reset-sends"
  feed_updates "$fake_dir" "$(one_update 64 640 "$OWNER_ID" 'sobreviveu')"
  wait_for_request "$url" "$home/body.json"
  [ "$(jq -r '.request_id' "$home/body.json")" = "tg-$OWNER_ID-640" ] \
    || fail "a failed greeting send must not kill the poller"
  pass "an unreadable error body on the greeting leaves the poller alive"
}

# ---------------------------------------------------------------------------

write_fake_telegram

test_connector_requires_bearer_token
test_non_whitelisted_sender_is_ignored
test_start_command_greets_without_request
test_textless_message_is_ignored
test_update_parses_request_with_reply_context
test_caption_only_message_uses_caption_as_text
test_poll_wakes_squad_client_once_and_records_context
test_answer_posts_to_telegram_via_squad_client
test_answer_splits_long_thread_chained
test_answer_unknown_request_is_404
test_dismiss_drops_pending_request
test_followup_posts_within_cap_then_409
test_followup_window_expiry_survives_restart
test_restart_does_not_duplicate_and_offset_advances
test_state_file_with_wrong_shape_records_starts_clean
test_null_created_at_does_not_crash_poll
test_request_context_endpoint
test_image_answer_posts_sendphoto
test_followup_flow_via_squad_client
test_malformed_telegram_response_does_not_kill_poller
test_concurrent_answers_post_exactly_once
test_concurrent_followups_respect_the_cap
test_midread_reset_on_answer_returns_502_and_stays_pending
test_midread_reset_on_greeting_does_not_kill_poller
test_non_object_json_response_does_not_kill_poller
test_non_list_result_does_not_kill_poller
test_non_string_text_does_not_kill_poller
test_error_status_with_reset_body_returns_502_and_stays_pending
test_error_status_with_reset_body_on_greeting_does_not_kill_poller
