#!/usr/bin/env bash
# Behavioral coverage for the opt-in away queue pilot: arm, one launch, refusal
# authority, the memory and mission gates, the durable one-use intent, and the
# daemon side of the outcome ledger.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PILOT="$ROOT/bin/sq-queue-pilot.sh"
TMP_ROOT=$(fm_test_tmproot sq-queue-pilot)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
TASK=pilot-once-t1
PRED=pilot-pred-t2
RECORD=absence-2026-11-24-0100.md
GEN=absence-2026-11-24-0100

# --- fixtures --------------------------------------------------------------

# A fake backlog backend behind the real sq-tasks CLI surface this pilot reads:
# readiness comes from SQ_FAKE_READY, one task record per id from
# SQ_FAKE_RECORDS/<id>.show, and `start` records the transition. The probes that
# bin/sq-tasks-lib.sh runs for compatibility are answered too.
cat > "$FAKEBIN/sq-tasks" <<'SH'
#!/usr/bin/env bash
records=${SQ_FAKE_RECORDS:?}
case "${1:-}" in
  --version) printf '0.2.4\n' ;;
  update) printf '%s\n' 'usage: sq-tasks update <id> [--archive-body]' ;;
  mv) printf 'usage: sq-tasks mv <id> [<id>...]\n' ;;
  ready)
    ids=$(cat "${SQ_FAKE_READY:?}" 2>/dev/null || true)
    count=$(printf '%s\n' "$ids" | grep -c . || true)
    printf 'count: %s\n' "$count"
    printf 'ready[%s]{id,state,kind,repo,title}:\n' "$count"
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      printf '  %s,queued,task,proj,a title\n' "$id"
    done <<EOF2
$ids
EOF2
    printf 'ready_public_followups: 0 delivery-ready obligations\n'
    printf 'help[1]:\n  - Run `sq-tasks start`
'
    ;;
  show)
    id=${2:-}
    [ -f "$records/$id.show" ] || exit 1
    cat "$records/$id.show"
    ;;
  start)
    printf '%s\n' "${2:-}" >> "${SQ_FAKE_STARTED:?}"
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/sq-tasks"

# PATH stubs for the operations the pilot must never perform. Each records its
# invocation, so "never merges" is a behavior assertion rather than a promise.
cat > "$FAKEBIN/sq-gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SQ_FAKE_FORBIDDEN_LOG:?}"
exit 0
SH
chmod +x "$FAKEBIN/sq-gh"

# The spawn seam: record the exact argv, publish task metadata, and move the
# attempt to running exactly as bin/sq-spawn.sh does.
cat > "$FAKEBIN/fake-spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SQ_FAKE_SPAWN_LOG:?}"
id=$1
printf 'window=Squad:sq-%s\nbackend=tmux\nproject=%s\nkind=strike\n' "$id" "${2:-}" \
  > "${SQ_FAKE_STATE:?}/$id.meta"
SQUAD_STATE_OVERRIDE="$SQ_FAKE_STATE" "$SQ_FAKE_EXEC_STATE" claim "$id" >/dev/null 2>&1
SQUAD_STATE_OVERRIDE="$SQ_FAKE_STATE" "$SQ_FAKE_EXEC_STATE" running "$id" >/dev/null 2>&1
printf 'spawned %s harness=fake window=Squad:sq-%s\n' "$id" "$id"
SH
chmod +x "$FAKEBIN/fake-spawn"

new_base() {  # <name>
  BASE="$TMP_ROOT/$1"
  STATE="$BASE/state"
  DATA="$BASE/data"
  rm -rf "$BASE"
  mkdir -p "$STATE" "$DATA" "$BASE/config" "$BASE/fake-records"
  cat > "$BASE/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '8000\n' > "$BASE/config/startup-memory-budget"
  : > "$DATA/commander.md"
  : > "$DATA/commander-shared.md"
  : > "$DATA/learnings.md"
  : > "$DATA/backlog.md"
  : > "$STATE/.afk"
  export SQ_FAKE_RECORDS="$BASE/fake-records"
  export SQ_FAKE_READY="$BASE/fake-records/ready"
  export SQ_FAKE_STARTED="$BASE/fake-records/started"
  export SQ_FAKE_SPAWN_LOG="$BASE/fake-records/spawn.log"
  export SQ_FAKE_FORBIDDEN_LOG="$BASE/fake-records/forbidden.log"
  export SQ_FAKE_STATE="$STATE"
  export SQ_FAKE_EXEC_STATE="$ROOT/bin/sq-exec-state.sh"
  : > "$SQ_FAKE_READY"
  : > "$SQ_FAKE_STARTED"
  : > "$SQ_FAKE_SPAWN_LOG"
  : > "$SQ_FAKE_FORBIDDEN_LOG"
}

write_record() {  # <task-id> <state> [held] [deps]
  cat > "$SQ_FAKE_RECORDS/$1.show" <<EOF
task:
  id: $1
  title: a title
  state: ${2:-queued}
  blocked: no
  blocked_by: none
  held: ${3:-no}
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  kind: task
  repo: proj
  deps: "${4:-none}"
EOF
}

write_absence() {  # <record-name> <task-mention>
  cat > "$DATA/$1" <<EOF
# Ausencia do comandante

## Ordem

"siga com as missoes; merges autorizados"

## Fila planejada

1. \`$2\` - a task the commander approved before departure.
EOF
}

write_brief() {  # <task-id> <mode>
  mkdir -p "$DATA/$1"
  cat > "$DATA/$1/brief.md" <<EOF
# Task

${3:-do the thing}

# Definition of done
Delivery contract: mode=$2
EOF
}

ready_task() {  # <task-id>
  printf '%s\n' "$1" >> "$SQ_FAKE_READY"
}

arm_grant() {  # [extra arm args...]
  run_pilot "$BASE" arm --task "$TASK" --project "$BASE" --repo proj \
    --mode direct-PR --yolo on --harness pi --model openai-codex/fake \
    --max-missions 2 --expires "$(( $(date +%s) + 3600 ))" \
    --authority "merge autorizado" "$@"
}

run_pilot() {  # <base> <command...>
  local base=$1
  shift
  SQUAD_BASE="$base" SQUAD_STATE_OVERRIDE="$base/state" SQUAD_DATA_OVERRIDE="$base/data" \
    "$PILOT" "$@"
}

# The default seams: a live-looking endpoint, ample host memory, and the fake
# spawn. Cases override the memory or agent-state seam as they need.
export SQUAD_QUEUE_PILOT_SPAWN="$FAKEBIN/fake-spawn"
export SQUAD_QUEUE_PILOT_AGENT_STATE=alive
export SQUAD_QUEUE_PILOT_AVAILABLE_MB=8000
export PATH="$FAKEBIN:$PATH"

# --- happy path: exactly one launch ---------------------------------------

new_base happy
write_record "$TASK" queued
write_record "$PRED" "done"
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR

out=$(arm_grant 2>&1) || fail "arm failed: $out"
assert_contains "$out" "armed: task=$TASK generation=$GEN" "arm names the task and generation"
assert_present "$STATE/queue-pilot.grant" "the grant is durable"
assert_grep "task=$TASK" "$STATE/queue-pilot.grant" "the grant records the exact task"
assert_grep "brief_sha256=" "$STATE/queue-pilot.grant" "the grant binds the prepared brief"

out=$(run_pilot "$BASE" check 2>&1)
expect_code 0 $? "check exits zero"
assert_contains "$out" "routine|queue-pilot: dispatched $TASK" "the happy path dispatches the named task"
assert_contains "$out" "endpoint=alive" "delivery verification is quoted"
assert_contains "$out" "marked in flight" "the start transition is reported"
[ "$(wc -l < "$SQ_FAKE_SPAWN_LOG")" -eq 1 ] || fail "exactly one spawn invocation"
assert_grep "$TASK $BASE --mode direct-PR --yolo on --harness pi" "$SQ_FAKE_SPAWN_LOG" \
  "the launch carries the resolved mode, yolo and lane"
assert_grep "outcome=dispatched" "$STATE/queue-pilot.intent" "the intent records the outcome"
assert_grep "state=spent" "$STATE/queue-pilot.intent" "the intent is spent"
assert_grep "$TASK" "$SQ_FAKE_STARTED" "the task is marked in flight"
[ ! -s "$SQ_FAKE_FORBIDDEN_LOG" ] || fail "no forge or GitHub operation ran"

# --- a second trigger finds the intent spent ------------------------------

out=$(run_pilot "$BASE" check 2>&1)
expect_code 0 $? "a repeated check exits zero"
assert_contains "$out" "refused: intent-spent:task=$TASK" "a repeated trigger reports the spent intent"
[ "$(wc -l < "$SQ_FAKE_SPAWN_LOG")" -eq 1 ] || fail "a repeated trigger launches nothing"
[ "$(wc -l < "$SQ_FAKE_STARTED")" -eq 1 ] || fail "a repeated trigger records no second start"

# An unchanged refusal is not recorded twice.
out=$(run_pilot "$BASE" check 2>&1)
[ -z "$out" ] || fail "an unchanged refusal is not repeated: $out"

# --- no absence record: no action ----------------------------------------

new_base noabsence
write_record "$TASK" queued
ready_task "$TASK"
write_brief "$TASK" direct-PR
out=$(run_pilot "$BASE" arm --task "$TASK" --project "$BASE" --repo proj \
  --mode direct-PR --yolo on --harness pi --max-missions 2 \
  --expires "$(( $(date +%s) + 3600 ))" --authority "x" 2>&1)
expect_code 2 $? "arm refuses with no open absence record"
assert_contains "$out" "exactly one open absence record (found 0)" "arm names the missing record"

# An armed grant whose record closes refuses with a recorded reason.
new_base closed
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed before the record closes"
printf '\n## Retorno: 2026-11-24 (comandante voltou)\n' >> "$DATA/$RECORD"
out=$(run_pilot "$BASE" check 2>&1)
expect_code 0 $? "check without an open absence record exits zero"
assert_contains "$out" "refused: no-open-absence-record" "no open absence record means no action"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "no absence record must not launch"

# --- authority guards -----------------------------------------------------

# A task id the absence record never names.
new_base unnamed
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "some-other-task-a1"
write_brief "$TASK" direct-PR
out=$(run_pilot "$BASE" arm --task "$TASK" --project "$BASE" --repo proj \
  --mode direct-PR --yolo on --harness pi --max-missions 2 \
  --expires "$(( $(date +%s) + 3600 ))" --authority "x" 2>&1)
expect_code 2 $? "arm refuses an id the record does not name"
assert_contains "$out" "does not name $TASK" "arm names the unnamed id"
[ ! -e "$STATE/queue-pilot.grant" ] || fail "no grant is written for an unnamed id"

# The record changes after arming, so the check itself refuses.
new_base unauth
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed while the record names the task"
write_absence "$RECORD" "unrelated-now-b2"
out=$(run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: task-not-named-in-absence-record:$TASK" "the check re-reads the authority record"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "an unnamed id must not launch"

# Blockers not cleared: the task is not in the ready group and records blocked.
new_base blocked
cat > "$SQ_FAKE_RECORDS/$TASK.show" <<'EOF'
task:
  id: pilot-once-t1
  title: a title
  state: queued
  blocked: yes
  blocked_by: pilot-pred-t2
  held: no
  hold_reason: "-"
  hold_kind: "-"
  kind: task
  repo: proj
  deps: "blocked-by:pilot-pred-t2"
EOF
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed while the task is queued"
out=$(run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: blockers-uncleared:pilot-pred-t2" "an uncleared blocker is refused"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "a blocked task must not launch"

# A dependency that is absent from the backlog is a missing predecessor, never
# inferred as resolved.
new_base noskips
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed"
write_record "$TASK" queued no "blocked-by:ghost-pred-c3"
out=$(run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: predecessor-missing:ghost-pred-c3" "a missing predecessor is refused"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "a missing predecessor must not launch"

# --- census, memory and cap gates ----------------------------------------

# A census that cannot attribute an endpoint is ambiguity, and ambiguity means
# no action.
new_base ambiguous
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed"
printf 'window=zz:1\nbackend=zellij\nkind=strike\n' > "$STATE/other-task-d4.meta"
out=$(env -u SQUAD_QUEUE_PILOT_AGENT_STATE SQUAD_BASE="$BASE" \
  SQUAD_STATE_OVERRIDE="$BASE/state" SQUAD_DATA_OVERRIDE="$BASE/data" "$PILOT" check 2>&1)
assert_contains "$out" "refused: census-ambiguous:" "an unverified endpoint refuses the census"
assert_contains "$out" "other-task-d4=unverified" "the refusal names the ambiguous record"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "an ambiguous census must not launch"

# The measured host memory floor.
new_base lowmem
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed"
out=$(SQUAD_QUEUE_PILOT_AVAILABLE_MB=1024 run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: low-memory:available=1024MiB required=4096MiB slot=1" \
  "the measured memory floor is enforced"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "a low-memory host must not launch"

# The third mission needs the larger floor.
new_base lowmem3
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant --max-missions 3 >/dev/null 2>&1 || fail "arm should accept a three-mission ceiling"
for other in seat-one-e5 seat-two-f6; do
  printf 'window=Squad:sq-%s\nbackend=tmux\nkind=strike\n' "$other" > "$STATE/$other.meta"
  SQUAD_STATE_OVERRIDE="$STATE" "$ROOT/bin/sq-exec-state.sh" claim "$other" >/dev/null
  SQUAD_STATE_OVERRIDE="$STATE" "$ROOT/bin/sq-exec-state.sh" running "$other" >/dev/null
done
out=$(SQUAD_QUEUE_PILOT_AVAILABLE_MB=5000 SQUAD_QUEUE_PILOT_AGENT_STATE=missing \
  run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: low-memory:available=5000MiB required=9216MiB slot=3" \
  "the third mission requires the larger floor"

# The three-mission cap.
new_base cap
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed"
for other in seat-one-e5 seat-two-f6; do
  printf 'window=Squad:sq-%s\nbackend=tmux\nkind=strike\n' "$other" > "$STATE/$other.meta"
  SQUAD_STATE_OVERRIDE="$STATE" "$ROOT/bin/sq-exec-state.sh" claim "$other" >/dev/null
  SQUAD_STATE_OVERRIDE="$STATE" "$ROOT/bin/sq-exec-state.sh" running "$other" >/dev/null
done
out=$(SQUAD_QUEUE_PILOT_AGENT_STATE=missing run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: mission-cap:occupied=2" "the three-mission cap is enforced"
assert_contains "$out" "max=2" "the refusal quotes the recorded ceiling"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "a full unit must not launch"

# The startup prompt budget, not just its exit code.
new_base budget
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed"
yes x | head -400 | tr -d '\n' > "$DATA/commander.md"
printf '1\n' > "$BASE/config/startup-memory-budget"
out=$(run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: prompt-budget:" "an over-budget prompt estimate is refused"
assert_contains "$out" "prompt-budget over-budget" "the refusal quotes the budget status"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "an over-budget host must not launch"

# --- prepared brief and grant lifecycle ----------------------------------

# A brief edited after arming is drift, never a silent launch of other work.
new_base drift
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed"
printf '\nnew acceptance criterion\n' >> "$DATA/$TASK/brief.md"
out=$(run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: brief-drift:" "an edited brief is refused"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "a drifted brief must not launch"

new_base revoked
write_record "$TASK" queued
ready_task "$TASK"
write_absence "$RECORD" "$TASK"
write_brief "$TASK" direct-PR
arm_grant >/dev/null 2>&1 || fail "arm should succeed"
out=$(run_pilot "$BASE" revoke 2>&1)
[ "$out" = revoked ] || fail "revoke reports its outcome: $out"
out=$(run_pilot "$BASE" check 2>&1)
assert_contains "$out" "refused: grant-revoked" "a revoked grant never launches"
[ ! -s "$SQ_FAKE_SPAWN_LOG" ] || fail "a revoked grant must not launch"

# No grant at all: the check is silent so an idle pilot writes nothing.
new_base idle
out=$(run_pilot "$BASE" check 2>&1)
[ -z "$out" ] || fail "an unarmed pilot is silent: $out"

status=$(run_pilot "$BASE" status 2>&1)
assert_contains "$status" "grant: none" "status reports no armed grant"
assert_contains "$status" "intent: unspent" "status reports an unspent intent"

# --- the daemon side of the outcome ledger -------------------------------

# The daemon owns the ledger format: the pilot only prints one line, and the
# daemon appends it to the away-mode routine buffer when it reaps the child.
(
  # shellcheck source=bin/sq-supervise-daemon.sh
  SQUAD_DAEMON_DIR="$ROOT/bin" . "$ROOT/bin/sq-supervise-daemon.sh"

  new_base daemonreap
  printf '%s\n' "$$" > "$STATE/.queue-pilot.pid"
  printf 'routine|queue-pilot: dispatched %s\n' "$TASK" > "$STATE/.queue-pilot.outcome"
  # A live pid means the check is still in flight: nothing is ledgered yet.
  queue_pilot_reap "$STATE"
  [ ! -e "$STATE/.subsuper-routine" ] || fail "an in-flight check ledgered early"

  # A dead pid releases the outcome into the ledger exactly once.
  printf '%s\n' 999999 > "$STATE/.queue-pilot.pid"
  queue_pilot_reap "$STATE"
  assert_grep "routine|queue-pilot: dispatched $TASK" "$STATE/.subsuper-routine" \
    "the daemon ledgers the pilot outcome"
  queue_pilot_reap "$STATE"
  [ "$(wc -l < "$STATE/.subsuper-routine")" -eq 1 ] || fail "the outcome is ledgered once"

  # An escalation outcome goes to the commander-relevant buffer.
  printf '%s\n' 999999 > "$STATE/.queue-pilot.pid"
  printf 'escalation|queue-pilot: launched %s but delivery is unverified\n' "$TASK" \
    > "$STATE/.queue-pilot.outcome"
  queue_pilot_reap "$STATE"
  assert_grep "escalation|queue-pilot: launched" "$STATE/.subsuper-escalations" \
    "an ambiguous launch is escalated, not absorbed"
)

# With no armed grant the trigger never starts a check, so an idle pilot costs
# no subprocess.
(
  # shellcheck source=bin/sq-supervise-daemon.sh
  SQUAD_DAEMON_DIR="$ROOT/bin" . "$ROOT/bin/sq-supervise-daemon.sh"
  new_base daemonidle
  queue_pilot_trigger "$STATE"
  assert_absent "$STATE/.queue-pilot.pid" "no grant means no check is started"
)

pass "away queue pilot"
