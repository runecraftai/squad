#!/usr/bin/env bash
# Guarded live TUIOS verification in a uniquely named, private disposable lab.
# Usage: SQUAD_TUIOS_AFK_LIVE=1 bin/sq-afk-tuios-lab.sh probe-env|lifecycle
set -u
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "${SQUAD_TUIOS_AFK_LIVE:-}" = 1 ] || { echo 'error: explicit live-test authorization required' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 2; }
# shellcheck source=bin/sq-backend.sh
. "$LAB_DIR/sq-backend.sh"
fm_backend_source tuios || exit 2
fm_backend_tuios_cli_check || exit 2
BIN=$(fm_backend_tuios_bin)
VERSION=$("$BIN" --version 2>/dev/null | head -1) || exit 2
ROOT=$(cd "$LAB_DIR/.." && pwd)

TEMP=$(mktemp -d "${TMPDIR:-/tmp}/sq-afk-tuios-lab.XXXXXX") || exit 2
chmod 700 "$TEMP" || exit 2
mkdir -m 700 "$TEMP/base" "$TEMP/base/state" "$TEMP/runtime" "$TEMP/config" "$TEMP/state" || exit 2
export XDG_RUNTIME_DIR="$TEMP/runtime" XDG_CONFIG_HOME="$TEMP/config" XDG_STATE_HOME="$TEMP/state"
export SQUAD_POLL="${SQUAD_POLL:-1}" SQUAD_WEDGE_ALARM_EXEC=discard
DAEMON_PID=
MOCK_PID=
SESSION="sq-afk-lab-$(printf '%s' "$TEMP" | cksum | cut -d' ' -f1)-$$-${RANDOM:-0}"
SESSION_ID=
BOOT_WINDOW=
WINDOWS=()
KEEP_TEMP=0
sessions() {
  local json
  json=$("$BIN" list-sessions --json 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e 'type=="array" and all(.[];type=="object" and (.name|type=="string") and (.id|type=="string") and (.attached|type=="boolean") and (.windows|type=="array") and all(.windows[];type=="object" and (.id|type=="string")))' >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}
cleanup() {
  local inventory ids backend target extra daemon_session daemon_window
  if [ -n "$MOCK_PID" ]; then
    kill -TERM "$MOCK_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 "$MOCK_PID" 2>/dev/null; then wait "$MOCK_PID" 2>/dev/null || true; MOCK_PID=; break; fi
      sleep 0.1
    done
    [ -z "$MOCK_PID" ] || { echo "private mock provider $MOCK_PID remains alive; preserving $TEMP" >&2; return; }
  fi
  if [ -n "$SESSION_ID" ]; then
    inventory=$(sessions) || { echo "preserving private TUIOS lab $TEMP: inventory unreadable" >&2; return; }
    ids=$(printf '%s\n' "${WINDOWS[@]}" | jq -Rsc 'split("\n")[:-1]') || return
    printf '%s' "$inventory" | jq -e --arg n "$SESSION" --arg id "$SESSION_ID" --argjson ids "$ids" '[.[]|select(.name==$n and .id==$id)] as $s|($s|length)==1 and $s[0].attached==false and ([$s[0].windows[].id]|sort)==($ids|sort)' >/dev/null 2>&1 || { echo "preserving private lab $SESSION: attachment or exact ownership changed" >&2; return; }
    if [ -f "$TEMP/base/state/.afk-daemon-terminal" ]; then
      IFS=$'\t' read -r backend target extra < "$TEMP/base/state/.afk-daemon-terminal" || return
      daemon_session=${target%%:*}; daemon_window=${target#*:}
      [ "$backend" = tuios ] && [ -n "$extra" ] && [ -n "$daemon_session" ] && [ "$daemon_session" != "$target" ] || { echo "preserving malformed daemon record in $TEMP" >&2; return; }
      printf '%s' "$inventory" | jq -e --arg lab "$SESSION" --arg labid "$SESSION_ID" --argjson ids "$ids" --arg d "$daemon_session" --arg did "$extra" --arg w "$daemon_window" '[.[]|select(.name==$lab and .id==$labid and .attached==false)] as $p | [.[]|select(.name==$d and .id==$did and .attached==false)] as $d | length==2 and ($p|length)==1 and ($d|length)==1 and ([$p[0].windows[].id]|sort)==($ids|sort) and ($d[0].windows|length)==1 and $d[0].windows[0].id==$w' >/dev/null 2>&1 || { echo "preserving private lab $TEMP: daemon ownership not proven" >&2; return; }
      "$BIN" kill-session "$daemon_session" >/dev/null 2>&1 || { echo "preserving private daemon session $daemon_session" >&2; return; }
      inventory=$(sessions) || return
      printf '%s' "$inventory" | jq -e --arg n "$daemon_session" 'any(.[];.name==$n)' >/dev/null 2>&1 && { echo "private daemon session $daemon_session remains" >&2; return; }
    fi
    "$BIN" kill-session "$SESSION" >/dev/null 2>&1 || { echo "preserving private lab $SESSION: session cleanup failed" >&2; return; }
    inventory=$(sessions) || return
    printf '%s' "$inventory" | jq -e 'length==0' >/dev/null 2>&1 || { echo "preserving private lab $TEMP: unexpected sessions remain" >&2; return; }
  fi
  if [ -n "$DAEMON_PID" ]; then
    "$BIN" kill-server >/dev/null 2>&1 || { echo "private TUIOS daemon $DAEMON_PID did not accept shutdown; preserving $TEMP" >&2; return; }
    for _ in $(seq 1 50); do
      if ! kill -0 "$DAEMON_PID" 2>/dev/null; then wait "$DAEMON_PID" 2>/dev/null || true; DAEMON_PID=; break; fi
      sleep 0.1
    done
    [ -z "$DAEMON_PID" ] || { echo "private TUIOS daemon remains alive; preserving $TEMP" >&2; return; }
  fi
  [ "$KEEP_TEMP" = 1 ] && return
  case "$TEMP" in "${TMPDIR:-/tmp}"/sq-afk-tuios-lab.*) rm -rf -- "$TEMP" ;; *) echo "refusing unexpected lab path: $TEMP" >&2 ;; esac
}
trap cleanup EXIT

# All TUIOS commands use fresh XDG paths; never connect to or adopt an existing daemon.
"$BIN" daemon --no-restore >"$TEMP/daemon.log" 2>&1 &
DAEMON_PID=$!
ready=
for _ in $(seq 1 50); do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then echo 'error: private TUIOS daemon exited during startup' >&2; KEEP_TEMP=1; exit 2; fi
  if find "$TEMP/runtime" -type s -print -quit | grep -q .; then
    if inventory=$(sessions) && [ "$(printf '%s' "$inventory" | jq 'length')" = 0 ]; then ready=1; break; fi
  fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "error: private daemon identity not proven; evidence=$TEMP" >&2; KEEP_TEMP=1; exit 2; }
"$BIN" new --detach "$SESSION" >/dev/null 2>&1 || { echo 'error: failed to create detached session on private daemon' >&2; exit 2; }
record=$(sessions | jq -er --arg n "$SESSION" '[.[]|select(.name==$n)]|if length==1 and .[0].attached==false and (.[0].windows|length)==1 then .[0] else empty end' 2>/dev/null) || { echo "error: detached lab identity unproven; evidence=$TEMP" >&2; KEEP_TEMP=1; exit 2; }
SESSION_ID=$(printf '%s' "$record" | jq -r '.id')
BOOT_WINDOW=$(printf '%s' "$record" | jq -r '.windows[0].id')
[ -n "$SESSION_ID" ] && [ -n "$BOOT_WINDOW" ] || { KEEP_TEMP=1; exit 2; }
WINDOWS=("$BOOT_WINDOW")

case "${1:-}" in
  probe-env)
    probe="$TEMP/probe.sh"; output="$TEMP/env.json"
    cat > "$probe" <<'PROBE'
#!/usr/bin/env sh
jq -n --arg a "${TUIOS_ENV-}" --arg b "${TUIOS_SESSION-}" --arg c "${TUIOS_PANE_ID-}" --arg d "${TUIOS_WINDOW_ID-}" --arg e "${TMUX_PANE-}" --arg f "${HERDR_ENV-}" --arg g "${HERDR_SESSION-}" --arg h "${HERDR_PANE_ID-}" '{TUIOS_ENV:$a,TUIOS_SESSION:$b,TUIOS_PANE_ID:$c,TUIOS_WINDOW_ID:$d,TMUX_PANE:$e,HERDR_ENV:$f,HERDR_SESSION:$g,HERDR_PANE_ID:$h}' > "$SQUAD_TUIOS_AFK_PROBE"
exec sleep 60
PROBE
    chmod 700 "$probe"
    response=$("$BIN" new-window --json --session "$SESSION" --no-focus --cwd "$TEMP" "sq-afk-probe-$$" -- env "SQUAD_TUIOS_AFK_PROBE=$output" /bin/sh "$probe" 2>/dev/null) || { echo 'error: failed to create probe window' >&2; exit 1; }
    probe_window=$(printf '%s' "$response" | jq -r '.window_id // .result.window_id // empty')
    [ -n "$probe_window" ] || { echo "error: probe window identity missing; evidence=$TEMP" >&2; KEEP_TEMP=1; exit 1; }
    WINDOWS+=("$probe_window")
    for _ in $(seq 1 50); do [ -s "$output" ] && break; sleep 0.1; done
    [ -s "$output" ] || { echo 'error: TUIOS probe did not report environment' >&2; exit 1; }
    printf '{"tuios_version":"%s","lab_session":"%s","environment":%s}\n' "$VERSION" "$SESSION" "$(jq -c . "$output")"
    ;;
  lifecycle)
    PI_BIN=$(command -v pi) || { echo 'error: installed pi is required for the live lifecycle check' >&2; exit 2; }
    command -v node >/dev/null 2>&1 || { echo 'error: node is required for the loopback-only Pi model stub' >&2; exit 2; }
    mkdir -m 700 "$TEMP/home" "$TEMP/pi-config"
    cat > "$TEMP/mock-openai.mjs" <<'MOCK_PROVIDER'
import { appendFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
const [portFile, requestsFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    if (req.method !== "POST" || !req.url?.endsWith("/chat/completions") || req.headers.authorization !== "Bearer squad-test") {
      res.writeHead(404).end();
      return;
    }
    appendFileSync(requestsFile, "request\n");
    let body = {};
    try { body = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch {}
    const id = "chatcmpl-squad-away-test";
    const created = Math.floor(Date.now() / 1000);
    const model = body.model || "squad-smoke";
    if (body.stream === false) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ id, object: "chat.completion", created, model, choices: [{ index: 0, message: { role: "assistant", content: "ACK" }, finish_reason: "stop" }] }));
      return;
    }
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
    for (const chunk of [
      { id, object: "chat.completion.chunk", created, model, choices: [{ index: 0, delta: { role: "assistant", content: "ACK" }, finish_reason: null }] },
      { id, object: "chat.completion.chunk", created, model, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
    ]) res.write(`data: ${JSON.stringify(chunk)}\n\n`);
    res.end("data: [DONE]\n\n");
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
MOCK_PROVIDER
    node "$TEMP/mock-openai.mjs" "$TEMP/mock-openai-port" "$TEMP/mock-openai-requests" >"$TEMP/mock-openai.log" 2>&1 &
    MOCK_PID=$!
    for _ in $(seq 1 50); do [ -s "$TEMP/mock-openai-port" ] && break; sleep 0.1; done
    [ -s "$TEMP/mock-openai-port" ] || { echo "error: loopback-only mock provider did not start; evidence=$TEMP/mock-openai.log" >&2; KEEP_TEMP=1; exit 1; }
    mock_port=$(cat "$TEMP/mock-openai-port")
    jq -n --arg url "http://127.0.0.1:$mock_port/v1" '{providers:{"squad-test":{baseUrl:$url,api:"openai-completions",apiKey:"squad-test",models:[{id:"squad-smoke",name:"Squad smoke model",contextWindow:8192,maxTokens:256}]}}}' > "$TEMP/pi-config/models.json"
    chmod 600 "$TEMP/pi-config/models.json"
    mkdir -m 700 "$TEMP/modal"
    # Test-only probe: opens a real Pi confirm dialog on command and closes it
    # when the hold file disappears. It exists so the live check can prove the
    # production extension's positive modal guard, not merely its idle/draft
    # guards. It is generated into the disposable lab and never shipped.
    cat > "$TEMP/pi-modal-probe.ts" <<'PI_MODAL_PROBE'
import { existsSync, writeFileSync } from "node:fs";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const dir = process.env.SQUAD_LAB_MODAL_DIR;
if (!dir) throw new Error("SQUAD_LAB_MODAL_DIR is required for the modal probe");

export default function (pi: ExtensionAPI): void {
  let context: ExtensionContext | null = null;
  let open = false;
  pi.on?.("session_start", (_event, ctx) => {
    context = ctx;
    const timer = setInterval(() => void tick(), 100);
    timer.unref?.();
  });
  const tick = async (): Promise<void> => {
    if (!context || open || !existsSync(`${dir}/open`)) return;
    open = true;
    writeFileSync(`${dir}/idle-at-open`, context.isIdle() ? "true" : "false");
    writeFileSync(`${dir}/showing`, "1");
    const controller = new AbortController();
    const watcher = setInterval(() => {
      if (!existsSync(`${dir}/open`)) controller.abort();
    }, 100);
    watcher.unref?.();
    try {
      await context.ui.confirm("Squad lab modal", "holds away-mode delivery", { signal: controller.signal });
    } catch {
      // The hold was released and the dialog was cancelled.
    } finally {
      clearInterval(watcher);
      writeFileSync(`${dir}/closed`, "1");
      open = false;
    }
  };
}
PI_MODAL_PROBE
    cat > "$TEMP/pi-launch.sh" <<'PI_LAUNCH'
#!/usr/bin/env sh
[ "${TUIOS_ENV-}" = 1 ] || { echo 'TUIOS did not provide its environment marker' >&2; exit 1; }
session=${TUIOS_SESSION:?TUIOS did not provide a session identity}
[ "$session" = "$9" ] || { echo 'TUIOS supplied a different session identity' >&2; exit 1; }
pane=${TUIOS_PANE_ID:?TUIOS did not provide a pane identity}
window=${TUIOS_WINDOW_ID:-$pane}
exec env -i "PATH=$1" "HOME=$2" "TERM=$3" TUIOS_ENV=1 "TUIOS_SESSION=$session" "TUIOS_PANE_ID=$pane" "TUIOS_WINDOW_ID=$window" "SQUAD_BASE=$4" SQUAD_STATE_OVERRIDE=state "SQUAD_ROOT_OVERRIDE=$5" "PI_CODING_AGENT_DIR=$6" "SQUAD_LAB_MODAL_DIR=${11}" PI_OFFLINE=1 "$7" --offline --approve --no-session --no-tools --no-context-files --no-skills --no-prompt-templates --no-themes --provider squad-test --model squad-smoke --no-extensions --extension "$8" --extension "${10}"
PI_LAUNCH
    chmod 700 "$TEMP/pi-launch.sh"
    pi_out=$("$BIN" new-window --json --session "$SESSION" --no-focus --cwd "$ROOT" "sq-afk-pi-lab-$$" -- /bin/sh "$TEMP/pi-launch.sh" "$PATH" "$TEMP/home" "${TERM:-xterm-256color}" "$TEMP/base" "$ROOT" "$TEMP/pi-config" "$PI_BIN" "$ROOT/.pi/extensions/sq-primary-away-handoff.ts" "$SESSION" "$TEMP/pi-modal-probe.ts" "$TEMP/modal" 2>/dev/null) || { echo 'error: could not launch isolated Pi in the TUIOS lab' >&2; exit 1; }
    pi_window=$(printf '%s' "$pi_out" | jq -r '.window_id // .result.window_id // empty')
    [ -n "$pi_window" ] || { echo "error: isolated Pi window id missing; evidence=$TEMP" >&2; KEEP_TEMP=1; exit 1; }
    WINDOWS+=("$pi_window")
    inventory=$(sessions) || { echo 'error: cannot validate Pi lab window inventory' >&2; KEEP_TEMP=1; exit 1; }
    printf '%s' "$inventory" | jq -e --arg n "$SESSION" --arg id "$SESSION_ID" --arg a "$BOOT_WINDOW" --arg b "$pi_window" '[.[]|select(.name==$n and .id==$id and .attached==false)] as $s|($s|length)==1 and ([$s[0].windows[].id]|sort)==([$a,$b]|sort)' >/dev/null 2>&1 || { echo 'error: Pi lab target is attached or not exactly owned' >&2; KEEP_TEMP=1; exit 1; }
    export SQUAD_BASE="$TEMP/base" SQUAD_STATE_OVERRIDE="$TEMP/base/state" SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_DAEMON_DIR="$ROOT/bin" SQUAD_SUPERVISOR_BACKEND=tuios SQUAD_TUIOS_BIN="$BIN"
    # shellcheck source=bin/sq-backend.sh
    . "$ROOT/bin/sq-backend.sh"
    # shellcheck source=bin/sq-stand-to-lib.sh
    . "$ROOT/bin/sq-stand-to-lib.sh"
    # shellcheck source=bin/sq-afk-pi-handoff.sh
    . "$ROOT/bin/sq-afk-pi-handoff.sh"
    target="$SESSION:$pi_window"
    ready=
    for _ in $(seq 1 100); do
      if fm_afk_pi_handoff_ready "$TEMP/base/state" "$target" >/dev/null 2>&1; then ready=1; break; fi
      sleep 0.1
    done
    if [ "$ready" != 1 ]; then
      fm_backend_tuios_capture "$target" 100 > "$TEMP/pi-pane.txt" 2>/dev/null || true
      fm_backend_tuios_window_info "$SESSION" "$pi_window" > "$TEMP/pi-window.json" 2>/dev/null || true
      echo "error: installed Pi extension did not publish exact ready identity; pane=$TEMP/pi-pane.txt window=$TEMP/pi-window.json state=$TEMP/base/state" >&2
      KEEP_TEMP=1
      exit 1
    fi
    export SQUAD_SUPERVISOR_TARGET="$target"
    # shellcheck source=bin/sq-supervise-daemon.sh
    . "$ROOT/bin/sq-supervise-daemon.sh"
    : > "$TEMP/base/state/.afk"
    handoff_message='isolated TUIOS/Pi delivery verification'
    if inject_msg "$handoff_message" "$TEMP/base/state"; then handoff_rc=0; else handoff_rc=$?; fi
    [ "$handoff_rc" -le 1 ] || { echo "error: production injection path rejected the live Pi target (rc=$handoff_rc); evidence=$TEMP/base/state" >&2; KEEP_TEMP=1; exit 1; }
    delivered=
    for _ in $(seq 1 200); do
      if [ "$(jq -r '.status // empty' "$TEMP/base/state/.pi-away-handoff/result.json" 2>/dev/null)" = handled ]; then delivered=1; break; fi
      sleep 0.1
    done
    if [ "$delivered" != 1 ]; then
      fm_backend_tuios_capture "$target" 100 > "$TEMP/pi-pane.txt" 2>/dev/null || true
      echo "error: Pi did not acknowledge consuming the live handoff; pane=$TEMP/pi-pane.txt evidence=$TEMP/base/state" >&2
      KEEP_TEMP=1
      exit 1
    fi
    # The consumption acknowledgement lands at before_agent_start, one step
    # before the provider call, so allow the model request to arrive.
    model_seen=
    for _ in $(seq 1 100); do
      [ -s "$TEMP/mock-openai-requests" ] && { model_seen=1; break; }
      sleep 0.1
    done
    if [ "$model_seen" != 1 ]; then
      fm_backend_tuios_capture "$target" 100 > "$TEMP/pi-pane.txt" 2>/dev/null || true
      echo "error: Pi handoff acknowledgement was not followed by a loopback model request; pane=$TEMP/pi-pane.txt evidence=$TEMP" >&2
      KEEP_TEMP=1
      exit 1
    fi
    # --- positive modal proof -------------------------------------------
    # Open a real Pi dialog while the primary is idle, then prove the
    # escalation is queued but held until the dialog closes. The probe records
    # isIdle() at open time so the deferral is attributable to the prompt guard
    # rather than the idle guard.
    handoff_dir="$TEMP/base/state/.pi-away-handoff"
    : > "$TEMP/modal/open"
    modal_seen=
    for _ in $(seq 1 150); do
      prompts=$(jq -r '.prompts // 0' "$handoff_dir/ready.json" 2>/dev/null)
      case "$prompts" in ''|*[!0-9]*) prompts=0 ;; esac
      if [ -s "$TEMP/modal/showing" ] && [ "$prompts" -ge 1 ]; then modal_seen=1; break; fi
      sleep 0.1
    done
    if [ "$modal_seen" != 1 ]; then
      fm_backend_tuios_capture "$target" 100 > "$TEMP/pi-pane.txt" 2>/dev/null || true
      echo "error: Pi did not open a probe dialog or the extension did not report the open prompt; pane=$TEMP/pi-pane.txt modal=$TEMP/modal" >&2
      KEEP_TEMP=1
      exit 1
    fi
    if [ "$(cat "$TEMP/modal/idle-at-open" 2>/dev/null)" != true ]; then
      echo 'error: the probe dialog opened while Pi was not idle, so the modal guard cannot be isolated' >&2
      KEEP_TEMP=1
      exit 1
    fi
    requests_before=$(wc -l < "$TEMP/mock-openai-requests")
    if inject_msg 'modal hold verification' "$TEMP/base/state"; then modal_rc=0; else modal_rc=$?; fi
    [ "$modal_rc" -le 1 ] || { echo "error: production injection path rejected the held escalation (rc=$modal_rc)" >&2; KEEP_TEMP=1; exit 1; }
    modal_id=$(jq -r '.id // empty' "$handoff_dir/request.json" 2>/dev/null)
    case "$modal_id" in
      *[!a-f0-9]*|'') echo 'error: the held escalation did not publish a durable request id' >&2; KEEP_TEMP=1; exit 1 ;;
    esac
    for _ in $(seq 1 30); do
      status=$(jq -r '.status // empty' "$handoff_dir/result.json" 2>/dev/null)
      id=$(jq -r '.id // empty' "$handoff_dir/result.json" 2>/dev/null)
      if [ "$id" = "$modal_id" ] && { [ "$status" = handled ] || [ "$status" = queued ]; }; then
        fm_backend_tuios_capture "$target" 100 > "$TEMP/pi-pane.txt" 2>/dev/null || true
        echo "error: escalation was delivered while a Pi prompt was open; pane=$TEMP/pi-pane.txt state=$TEMP/base/state" >&2
        KEEP_TEMP=1
        exit 1
      fi
      sleep 0.1
    done
    if [ "$(wc -l < "$TEMP/mock-openai-requests")" != "$requests_before" ]; then
      echo 'error: modal hold did not suppress the model request' >&2
      KEEP_TEMP=1
      exit 1
    fi
    rm -f "$TEMP/modal/open"
    modal_delivered=
    for _ in $(seq 1 200); do
      status=$(jq -r '.status // empty' "$handoff_dir/result.json" 2>/dev/null)
      id=$(jq -r '.id // empty' "$handoff_dir/result.json" 2>/dev/null)
      if [ "$id" = "$modal_id" ] && [ "$status" = handled ]; then modal_delivered=1; break; fi
      sleep 0.1
    done
    if [ "$modal_delivered" != 1 ] || [ "$(wc -l < "$TEMP/mock-openai-requests")" -le "$requests_before" ]; then
      fm_backend_tuios_capture "$target" 100 > "$TEMP/pi-pane.txt" 2>/dev/null || true
      echo "error: releasing the Pi prompt did not deliver the held escalation; pane=$TEMP/pi-pane.txt state=$TEMP/base/state" >&2
      KEEP_TEMP=1
      exit 1
    fi
    rm -f "$TEMP/modal/showing" "$TEMP/modal/closed" "$TEMP/modal/idle-at-open"
    start=$(SQUAD_BASE="$TEMP/base" SQUAD_STATE_OVERRIDE="$TEMP/base/state" SQUAD_TUIOS_BIN="$BIN" SQUAD_SUPERVISOR_BACKEND=tuios SQUAD_SUPERVISOR_TARGET="$target" "$LAB_DIR/sq-afk-launch.sh" start 2>&1) || { echo "error: guarded start failed: $start; evidence=$TEMP/base" >&2; KEEP_TEMP=1; exit 1; }
    status=$(SQUAD_BASE="$TEMP/base" SQUAD_STATE_OVERRIDE="$TEMP/base/state" SQUAD_TUIOS_BIN="$BIN" "$LAB_DIR/sq-afk-launch.sh" status 2>&1) || { echo "error: guarded status failed: $status; evidence=$TEMP/base" >&2; KEEP_TEMP=1; exit 1; }
    stop=$(SQUAD_BASE="$TEMP/base" SQUAD_STATE_OVERRIDE="$TEMP/base/state" SQUAD_TUIOS_BIN="$BIN" "$LAB_DIR/sq-afk-launch.sh" stop 2>&1) || { echo "error: guarded stop refused: $stop; evidence=$TEMP/base" >&2; KEEP_TEMP=1; exit 1; }
    [ ! -e "$TEMP/base/state/.afk" ] && [ ! -e "$TEMP/base/state/.afk-daemon-terminal" ] || { echo "error: guarded stop left lifecycle state behind; evidence=$TEMP/base" >&2; KEEP_TEMP=1; exit 1; }
    inventory=$(sessions) || exit 1
    printf '%s' "$inventory" | jq -e --arg n "$SESSION" --arg id "$SESSION_ID" --argjson ids "$(printf '%s\n' "${WINDOWS[@]}" | jq -Rsc 'split("\n")[:-1]')" '[.[]|select(.name==$n and .id==$id and .attached==false)] as $s|($s|length)==1 and ([$s[0].windows[].id]|sort)==($ids|sort)' >/dev/null 2>&1 || { echo 'error: guarded lifecycle changed the exact test-owned target session' >&2; exit 1; }
    printf '{"tuios_version":"%s","lab_session":"%s","target":"%s","start":"%s","status":"%s","modal":"held-until-closed","stop":"clean"}\n' "$VERSION" "$SESSION" "$target" "${start//\"/\\\"}" "${status//\"/\\\"}"
    ;;
  *) echo 'usage: SQUAD_TUIOS_AFK_LIVE=1 bin/sq-afk-tuios-lab.sh probe-env|lifecycle' >&2; exit 2 ;;
esac
