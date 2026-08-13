#!/usr/bin/env bash
# Real Pi/Herdr end-to-end regression for the 2026-07-14 two-owner incident.
#
# Opt-in because it launches a real interactive Pi primary, a real away daemon,
# and a real isolated Herdr lab session. Every explicit and production-adapter
# Herdr call is routed through sq-herdr-lab.sh. The scenario proves:
#   - a live blocked status is classified and durably queued while away;
#   - a pending Pi composer refuses injection and receives no forced Enter;
#   - the existing wedge alarm remains observable and deduped;
#   - clearing the draft makes the genuinely idle Pi composer injectable;
#   - verified submit preserves the terminal-safe marker and clears delivery state;
#   - an unmarked return request opens the catch-up gate before Sitrep;
#   - remediation/resolution clears the gate, and re-entry is idempotent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/sq-supervise-daemon.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/sq-backend.sh"

if [ "${SQUAD_AFK_PI_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set SQUAD_AFK_PI_HERDR_E2E=1 to run the real Pi/Herdr away-return regression"
  exit 0
fi

for tool in herdr jq pi python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/sq-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name sq-afk-pi-return-e2e)
TMP_ROOT=$(fm_test_tmproot sq-afk-pi-return-e2e)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
FAKEBIN="$TMP_ROOT/fakebin"
CAPTURE="$TMP_ROOT/pi-prompts.jsonl"
NOTIFY_LOG="$TMP_ROOT/wedge-notify.log"
ORIGINAL_PATH=$PATH
PRIMARY_PANE=
CHILD_PANE=
PRIMARY_TARGET=
DAEMON_STARTED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$DAEMON_STARTED" -eq 1 ]; then
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$STATE" \
      SQUAD_SUPERVISOR_BACKEND=herdr SQUAD_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
      "$ROOT/bin/sq-afk-launch.sh" stop >/dev/null 2>&1 || true
  fi
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT" "$PI_DIR" "$FAKEBIN"
printf '# Synthetic isolated Squad primary\n' > "$PROJECT/AGENTS.md"

# A task-local extension grants session-only trust, captures exact prompt bytes,
# and aborts before provider work. No production supervision extension is loaded
# in this synthetic primary, so nothing except the test can mutate unit state.
# Herdr still observes Pi's real idle->working transition, so production submit
# verification is exercised without making a model request.
CAPTURE_EXT="$TMP_ROOT/capture-extension.ts"
cat > "$CAPTURE_EXT" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";
const capturePath = process.env.SQUAD_PI_CAPTURE_PATH!;
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync(capturePath, `${JSON.stringify({ prompt: event.prompt, hex: Buffer.from(event.prompt, "utf8").toString("hex") })}\n`);
    ctx.abort();
  });
}
EOF

# Route production adapter invocations through the guarded helper too. The shim
# removes only the adapter's validated trailing pair, then the helper appends it.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$TMP_ROOT/wedge-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> '$NOTIFY_LOG'
EOF
chmod +x "$TMP_ROOT/wedge-recorder"

cat > "$TMP_ROOT/daemon-entry" <<EOF
#!/usr/bin/env bash
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export HERDR_SESSION='$SESSION'
export SQUAD_STATE_OVERRIDE='$STATE'
export SQUAD_ESCALATE_BATCH_SECS=0
export SQUAD_HOUSEKEEPING_TICK=1
export SQUAD_POLL=1
export SQUAD_SIGNAL_GRACE=1
export SQUAD_HEARTBEAT=999999
export SQUAD_CHECK_INTERVAL=999999
export SQUAD_MAX_DEFER_SECS=3
export SQUAD_STALE_ESCALATE_SECS=999999
export SQUAD_WEDGE_ALARM_EXEC='$TMP_ROOT/wedge-recorder'
exec '$ROOT/bin/sq-afk-start.sh'
EOF
chmod +x "$TMP_ROOT/daemon-entry"

PRIMARY_OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label synthetic-primary --no-focus)
WORKSPACE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.workspace.workspace_id')
PRIMARY_PANE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.root_pane.pane_id')
PRIMARY_TARGET="$SESSION:$PRIMARY_PANE"
EXT="$CAPTURE_EXT"
PI_CMD=$(printf 'exec env PI_CODING_AGENT_DIR=%q SQUAD_BASE=%q SQUAD_PI_CAPTURE_PATH=%q pi -e %q --no-context-files --no-session' "$PI_DIR" "$HOME_DIR" "$CAPTURE" "$EXT")
"$LAB_HELPER" run "$SESSION" pane run "$PRIMARY_PANE" "$PI_CMD" >/dev/null

wait_for_idle() {
  local stable=0 status _
  for _ in $(seq 1 240); do
    status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done|blocked) stable=$((stable + 1)); [ "$stable" -ge 4 ] && return 0 ;;
      *) stable=0 ;;
    esac
    sleep 0.25
  done
  return 1
}

wait_for_prompt() {  # <jq predicate>
  local predicate=$1 _
  for _ in $(seq 1 240); do
    if [ -s "$CAPTURE" ] && jq -s -e "$predicate" "$CAPTURE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_idle || fail "real Pi primary did not become stably idle"

assert_blocker_open() {
  local at=$1 open
  open=$(status_open_decisions "$STATE/repair-task.status")
  printf '%s' "$open" | grep -F $'synthetic-dependency\tblocked\t' >/dev/null \
    || fail "live blocked decision disappeared $at: status=$(cat "$STATE/repair-task.status" 2>/dev/null)"
}

CHILD_OUT=$("$LAB_HELPER" run "$SESSION" tab create --workspace "$WORKSPACE" --cwd "$PROJECT" --label sq-repair-task --no-focus)
CHILD_PANE=$(printf '%s' "$CHILD_OUT" | jq -r '.result.root_pane.pane_id')
CHILD_TARGET="$SESSION:$CHILD_PANE"
cat > "$STATE/repair-task.meta" <<EOF
window=$CHILD_TARGET
backend=herdr
kind=strike
mode=drill
worktree=$PROJECT
project=synthetic-project
EOF
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight
- [ ] repair-task - Repair the synthetic dependency (repo: synthetic-project, since 2026-07-14)

## Queued

## Done
EOF

PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$STATE" \
  SQUAD_SUPERVISOR_BACKEND=herdr SQUAD_SUPERVISOR_TARGET="$PRIMARY_TARGET" SQUAD_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/sq-afk-launch.sh" start >/dev/null
DAEMON_STARTED=1
for _ in $(seq 1 100); do [ -s "$STATE/.supervise-daemon.pid" ] && break; sleep 0.1; done
[ -s "$STATE/.supervise-daemon.pid" ] || fail "away daemon did not start"

# Pending input is never an injection target. Leave a real draft in Pi before
# the live child emits blocked:, then wait through max-defer.
"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" 'privacy safe human draft' >/dev/null
sleep 0.5
composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" fm_backend_composer_state herdr "$PRIMARY_TARGET")
[ "$composer" = pending ] || fail "real Pi draft did not classify pending (got $composer)"
CHILD_CMD=$(printf "printf 'blocked [key=synthetic-dependency]: Squad can refresh the synthetic token\\n' >> %q; exec sleep 120" "$STATE/repair-task.status")
"$LAB_HELPER" run "$SESSION" pane run "$CHILD_PANE" "$CHILD_CMD" >/dev/null
for _ in $(seq 1 160); do [ -s "$STATE/.subsuper-inject-wedged" ] && break; sleep 0.1; done
[ -s "$STATE/.subsuper-inject-wedged" ] || fail "persistently pending real Pi composer did not raise the defense-in-depth alarm"
[ -s "$STATE/.subsuper-escalations" ] || fail "pending real Pi composer lost the buffered blocker"
[ ! -s "$CAPTURE" ] || fail "daemon submitted into Pi while the real human draft was pending"
plain=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 200)
printf '%s' "$plain" | grep -F 'privacy safe human draft' >/dev/null || fail "pending Pi draft was modified or forcibly submitted"
for _ in $(seq 1 50); do [ -s "$NOTIFY_LOG" ] && break; sleep 0.1; done
[ -s "$NOTIFY_LOG" ] || fail "wedge alarm marker appeared but its active notifier did not finish"
[ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" -eq 1 ] || fail "wedge alarm was not observed exactly once before recovery"
assert_blocker_open 'while the Pi composer was pending'
pass "real Pi/Herdr pending composer refuses injection without forced submit and raises one observable fallback"

# Clear, never submit, the synthetic human draft. The same exact target now has
# native idle state plus a complete Pi separator composer and must accept quickly.
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" ctrl+c >/dev/null
wait_for_idle || fail "real Pi did not return idle after clearing the draft"
for _ in $(seq 1 80); do
  composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" fm_backend_composer_state herdr "$PRIMARY_TARGET")
  [ "$composer" = empty ] && break
  sleep 0.1
done
[ "$composer" = empty ] || fail "genuinely idle Pi separator composer did not classify empty (got $composer)"
wait_for_prompt 'any(.[]; .prompt | startswith("\u2063Supervisor escalate"))' \
  || fail "real Pi did not receive the buffered escalation after becoming safely idle"
INJECT_HEX=$(jq -r 'select(.prompt | startswith("\u2063Supervisor escalate")) | .hex' "$CAPTURE" | tail -1)
case "$INJECT_HEX" in e281a3*) ;; *) fail "real Pi escalation lost the terminal-safe marker: $INJECT_HEX" ;; esac
for _ in $(seq 1 80); do [ ! -s "$STATE/.subsuper-escalations" ] && break; sleep 0.1; done
[ ! -s "$STATE/.subsuper-escalations" ] || fail "confirmed real Pi delivery did not clear the escalation buffer"
[ ! -e "$STATE/.subsuper-inject-wedged" ] || fail "confirmed real Pi delivery did not clear the old wedge marker"
sleep 4
[ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" -eq 1 ] || fail "successful delivery emitted a duplicate wedge alert"
INJECT_PROMPT=$(jq -r 'select(.prompt | startswith("\u2063Supervisor escalate")) | .prompt' "$CAPTURE" | tail -1)
message_is_injection "$INJECT_PROMPT" || fail "terminal-delivered Pi escalation was not recognized as an internal marker"
assert_blocker_open 'after successful marked injection'
pass "real idle Pi/Herdr accepts one marked escalation promptly, verifies submit, clears wedge state, and emits no duplicate alert"

# The commander returns with an ordinary unmarked Sitrep request. The request is
# captured byte-exact, then the public return owner must gate it on the blocker.
wait_for_idle || fail "real Pi did not settle after the injected catch-up"
for _ in $(seq 1 80); do
  composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" fm_backend_composer_state herdr "$PRIMARY_TARGET")
  [ "$composer" = empty ] && break
  sleep 0.1
done
[ "$composer" = empty ] || fail "real Pi composer was not ready for the unmarked return request"
"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" 'Synthetic Sitrep request' >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" enter >/dev/null
wait_for_prompt 'any(.[]; .prompt == "Synthetic Sitrep request")' || fail "real Pi did not receive the unmarked return request"
RETURN_PROMPT=$(jq -r 'select(.prompt == "Synthetic Sitrep request") | .prompt' "$CAPTURE" | tail -1)
should_exit_afk "$STATE" "$RETURN_PROMPT" || fail "unmarked Pi return request did not trigger the away exit contract"
assert_blocker_open 'before return catch-up'
[ -f "$STATE/repair-task.meta" ] || fail "live blocker metadata disappeared before return catch-up"

set +e
RETURN_OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" SQUAD_ROOT_OVERRIDE="$PROJECT" SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$STATE" \
  SQUAD_SUPERVISOR_BACKEND=herdr SQUAD_SUPERVISOR_TARGET="$PRIMARY_TARGET" "$ROOT/bin/sq-afk-return.sh" begin 2>&1)
RETURN_RC=$?
set -e
DAEMON_STARTED=0
[ "$RETURN_RC" -eq 3 ] || fail "return catch-up did not gate the still-live blocker (rc=$RETURN_RC): $RETURN_OUT"
assert_contains "$RETURN_OUT" 'Squad-actionable blocker: repair-task [key=synthetic-dependency]' "return gate did not assign remediation"
set +e
BEARINGS_OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" SQUAD_ROOT_OVERRIDE="$PROJECT" SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/sq-sitrep-snapshot.sh" --json 2>&1)
BEARINGS_RC=$?
set -e
[ "$BEARINGS_RC" -eq 3 ] || fail "Sitrep bypassed the return gate (rc=$BEARINGS_RC): $BEARINGS_OUT"
pass "real unmarked Pi return opens catch-up and blocks Sitrep before the unresolved blocker can be deferred"

printf 'resolved [key=synthetic-dependency]: refreshed the synthetic token and resumed the task\n' >> "$STATE/repair-task.status"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" SQUAD_ROOT_OVERRIDE="$PROJECT" SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/sq-afk-return.sh" check >/dev/null || fail "remediated blocker did not clear return catch-up"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" SQUAD_ROOT_OVERRIDE="$PROJECT" SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$STATE" \
  "$ROOT/bin/sq-sitrep-snapshot.sh" --json >/dev/null || fail "Sitrep remained gated after blocker remediation"

# A clean re-entry creates no stale delivery or alert, and an immediate return is
# idempotently clear because the keyed blocker is resolved.
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$STATE" \
  SQUAD_SUPERVISOR_BACKEND=herdr SQUAD_SUPERVISOR_TARGET="$PRIMARY_TARGET" SQUAD_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/sq-afk-launch.sh" start >/dev/null
DAEMON_STARTED=1
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" SQUAD_ROOT_OVERRIDE="$PROJECT" SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$STATE" \
  SQUAD_SUPERVISOR_BACKEND=herdr SQUAD_SUPERVISOR_TARGET="$PRIMARY_TARGET" "$ROOT/bin/sq-afk-return.sh" begin >/dev/null \
  || fail "clean away re-entry/return was not idempotent"
DAEMON_STARTED=0
[ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" -eq 1 ] || fail "clean re-entry duplicated the historical wedge alert"
pass "resolved return catch-up allows Sitrep and a clean idempotent away re-entry"

printf 'evidence: herdr=%s pi=%s target=%s inject-hex-prefix=%s notifier-count=1\n' \
  "$(herdr --version)" "$(pi --version)" "$PRIMARY_TARGET" "${INJECT_HEX:0:6}"
