#!/usr/bin/env bash
# tests/sq-queue-pilot.test.sh - the away queue pilot's guard matrix.
#
# One test per guard in bin/sq-queue-pilot.sh's header table, plus the happy
# path, the effect boundary, and the capacity refusals. Every test drives the
# real executable in a sandbox base with the real sq-tasks markdown backend; only
# the launch command, the memory sample, and the endpoint classifier are seams,
# and the assertions are on the executable's own output and on what the launch
# and effect shims recorded.
#
# Every guard test fails when its guard is removed: removing the guard's refusal
# call leaves the refusal line unprinted and lets the effect happen.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PILOT="$ROOT/bin/sq-queue-pilot.sh"
TMP_ROOT=$(fm_test_tmproot sq-queue-pilot)

refuse_mutation='refused: task mutation is outside pilot authority'
refuse_no_task_id='refused: no filed task id in the absence record'
refuse_field='refused: field not covered by the intent'
refuse_identity='refused: intent does not match this base, generation and task'
refuse_not_durable='refused: intent not durable'
refuse_spent='refused: intent already spent'
refuse_no_absence='refused: no absence record is open'
refuse_not_ready='refused: task is not ready'
refuse_base='refused: base not bound'
refuse_census='refused: census mismatch'
refuse_admitted='refused: admitted id changed'
refuse_delivery='refused: delivery unproven'
refuse_force='refused: backend would force'
refuse_memory='refused: memory budget'
refuse_cap='refused: mission cap'
refuse_posture='refused: posture not satisfied'
refuse_effect='refused: effect outside pilot authority'

# --- fixtures ---------------------------------------------------------------

# write_record <base> [key=value|+key ...] writes the open absence record. A
# `+key` argument drops that named field, and `+prose` adds a line that names the
# task id in prose only.
write_record() {
  local base=$1 record generation task project repo mode yolo harness model effort cap expires prose kv
  shift
  generation=abs-gen-1
  task=pilot-task
  project=$base/../proj
  repo=demo
  mode=direct-PR
  yolo=on
  harness=claude
  model=-
  effort=-
  cap=3
  expires=$(($(date +%s) + 3600))
  prose='The commander said: pull the tasks, start pilot-task when it is ready.'
  for kv in "$@"; do
    case $kv in
      +task) task='' ;;
      +generation) generation='' ;;
      +expires) expires='' ;;
      +prose) prose='The commander said: pull the tasks, start pilot-task when it is ready.' ;;
      generation=*) generation=${kv#*=} ;;
      task=*) task=${kv#*=} ;;
      project=*) project=${kv#*=} ;;
      repo=*) repo=${kv#*=} ;;
      mode=*) mode=${kv#*=} ;;
      yolo=*) yolo=${kv#*=} ;;
      harness=*) harness=${kv#*=} ;;
      model=*) model=${kv#*=} ;;
      effort=*) effort=${kv#*=} ;;
      cap=*) cap=${kv#*=} ;;
      expires=*) expires=${kv#*=} ;;
    esac
  done
  record="$base/data/absence-2026-11-24-0100.md"
  {
    printf '# Ausencia do comandante - 2026-11-24\n\n'
    printf '## Ordem\n\n'
    printf '"siga com as missoes pois vou ficar afk; merges autorizados; me deixa ausente"\n\n'
    [ -z "$prose" ] || printf '%s\n\n' "$prose"
    printf '## Piloto\n\n'
    [ -z "$generation" ] || printf 'pilot-generation: %s\n' "$generation"
    [ -z "$task" ] || printf 'pilot-task: %s\n' "$task"
    printf 'pilot-project: %s\n' "$project"
    printf 'pilot-repo: %s\n' "$repo"
    printf 'pilot-mode: %s\n' "$mode"
    printf 'pilot-yolo: %s\n' "$yolo"
    printf 'pilot-harness: %s\n' "$harness"
    printf 'pilot-model: %s\n' "$model"
    printf 'pilot-effort: %s\n' "$effort"
    printf 'pilot-max-missions: %s\n' "$cap"
    [ -z "$expires" ] || printf 'pilot-expires: %s\n' "$expires"
  } >"$record"
}

write_backlog() {  # <base> [extra queued lines ...]
  local base=$1 line
  shift
  {
    printf '# Backlog\n\n## Queued\n'
    printf -- '- [ ] pilot-task - the filed task (repo: demo)\n'
    printf -- '- [ ] other-task - a later ready task (repo: demo)\n'
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } >"$base/data/backlog.md"
}

make_spawn_shim() {  # <sandbox>
  local sb=$1
  cat >"$sb/fakebin/spawn-shim" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
printf '%s\n' "$*" >>"$PILOT_TEST_SPAWN_LOG"
state=$PILOT_TEST_STATE
{
  printf 'window=Squad:sq-%s\n' "$id"
  printf 'endpoint_task_id=%s\n' "$id"
  printf 'worktree=%s/wt-%s\n' "$PILOT_TEST_PROJECT" "$id"
  printf 'harness=claude\n'
  printf 'kind=strike\n'
} >"$state/$id.meta"
printf 'schema=sq-exec.v1\nexec_state=claimed\n' >"$state/$id.exec"
if [ "${PILOT_TEST_NO_STATUS:-0}" != 1 ]; then
  printf 'working: brief read, worktree checked\n' >"$state/$id.status"
fi
exit 0
SH
  chmod +x "$sb/fakebin/spawn-shim"
}

# make_runner <sandbox>: the executable under test with the documented seams.
# Every squawk-free seam lives in this file rather than in a subshell export.
make_runner() {
  local sb=$1
  cat >"$sb/run-pilot" <<SH
#!/usr/bin/env bash
set -u
export SQUAD_QUEUE_PILOT_SPAWN="\${SQUAD_QUEUE_PILOT_SPAWN:-$sb/fakebin/spawn-shim}"
export SQUAD_QUEUE_PILOT_MEMINFO="\${SQUAD_QUEUE_PILOT_MEMINFO:-$sb/meminfo}"
export SQUAD_QUEUE_PILOT_AGENT_STATE="\${SQUAD_QUEUE_PILOT_AGENT_STATE:-alive}"
export SQUAD_QUEUE_PILOT_DELIVERY_WAIT="\${SQUAD_QUEUE_PILOT_DELIVERY_WAIT:-0}"
export SQUAD_BACKEND="\${SQUAD_BACKEND:-tmux}"
export PILOT_TEST_SPAWN_LOG="$sb/spawn.log"
export PILOT_TEST_EFFECT_LOG="$sb/effect.log"
export PILOT_TEST_STATE="$sb/base/state"
export PILOT_TEST_PROJECT="$sb/proj"
export PATH="$sb/fakebin:\$PATH"
exec "$PILOT" "\$@"
SH
  chmod +x "$sb/run-pilot"
  # effect-call <command...>: sources the pilot and calls its effect boundary, so
  # the boundary itself is exercised rather than only the commands that use it.
  cat >"$sb/effect-call" <<SH
#!/usr/bin/env bash
set -u
export PILOT_TEST_EFFECT_LOG="$sb/effect.log"
export PATH="$sb/fakebin:\$PATH"
# shellcheck source=bin/sq-queue-pilot.sh
. "$PILOT"
pilot_effect "\$@"
SH
  chmod +x "$sb/effect-call"
}

# effect_shim <sandbox> <name>: a recording stub no pilot path may ever run.
effect_shim() {
  local sb=$1 name=$2
  cat >"$sb/fakebin/$name" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$PILOT_TEST_EFFECT_LOG"
exit 0
SH
  chmod +x "$sb/fakebin/$name"
}

new_sandbox() {  # echoes the sandbox root; arm already passes in it
  local sb base
  sb=$(mktemp -d "$TMP_ROOT/sb.XXXXXX") || fail "could not create a sandbox"
  base="$sb/base"
  mkdir -p "$base/state" "$base/data" "$base/bin" "$sb/proj" "$sb/fakebin"
  : >"$base/bin/sq-spawn.sh"
  : >"$sb/spawn.log"
  : >"$base/state/.afk"
  make_runner "$sb"
  printf 'MemAvailable: 16777216 kB\nMemTotal: 33554432 kB\n' >"$sb/meminfo"
  printf -- '- demo [direct-PR] - demo project\n' >"$base/data/projects.md"
  write_backlog "$base"
  write_record "$base" +prose
  make_spawn_shim "$sb"
  printf '%s\n' "$sb"
}

# run_pilot <sandbox> <command...>: the real executable with the documented
# seams, through the sandbox's own runner file.
run_pilot() {
  local sb=$1
  shift
  "$sb/run-pilot" "$@"
}

spawn_count() {  # <sandbox>
  [ -f "$1/spawn.log" ] || {
    printf '0\n'
    return 0
  }
  awk 'NF { n++ } END { print n + 0 }' "$1/spawn.log"
}

arm_ok() {  # <sandbox>
  local sb=$1 out
  out=$(run_pilot "$sb" arm --base "$sb/base") || fail "arm refused unexpectedly: $out"
  case $out in
    armed\ *) ;;
    *) fail "arm did not report the intent: $out" ;;
  esac
}

# rewrite_intent <sandbox> <key> <value>: rewrite one intent line in place.
rewrite_intent() {  # <sandbox> <key> <value>
  local intent
  intent="$1/base/state/queue-pilot.intent"
  awk -v k="$2" -v v="$3" -F= '
    BEGIN { OFS = "=" }
    $1 == k { print k, v; next }
    { print }
  ' "$intent" >"$intent.rewrite" && mv "$intent.rewrite" "$intent"
}

expect_refusal() {  # <expected line> <output> <exit code> <label>
  local want=$1 out=$2 rc=$3 label=$4
  expect_code 1 "$rc" "$label"
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = "$want" ] ||
    fail "$label: expected the exact refusal '$want', got '$out'"
  [ "$(printf '%s\n' "$out" | awk 'NF { n++ } END { print n + 0 }')" = 1 ] ||
    fail "$label: the refusal must be the only output, got '$out'"
}

# --- guard 1: no task mutation ---------------------------------------------

test_guard1_no_task_mutation() {
  local sb out rc verb verbs
  verbs='add start done reopen update rm block unblock hold unhold mv prune setup'
  sb=$(new_sandbox)
  effect_shim "$sb" sq-tasks
  for verb in $verbs; do
    out=$("$sb/effect-call" sq-tasks "$verb" some-task) && rc=0 || rc=$?
    expect_code 1 "$rc" "pilot_effect accepted the mutating verb '$verb'"
    [ "$out" = "$refuse_mutation" ] || fail "verb '$verb' produced '$out'"
  done
  assert_absent "$sb/effect.log" "a mutating backlog verb reached the executable"
  pass "guard 1: every mutating backlog verb is refused and none runs"
}

# --- guard 2: authority from the record's named field ---------------------

test_guard2_task_id_from_the_named_field() {
  local sb out rc
  sb=$(new_sandbox)
  write_record "$sb/base" +task
  out=$(run_pilot "$sb" arm --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_no_task_id" "$out" "$rc" "guard 2 without the named field"
  assert_absent "$sb/base/state/queue-pilot.intent" "a prose mention produced an intent"

  write_record "$sb/base" +prose
  arm_ok "$sb"
  assert_present "$sb/base/state/queue-pilot.intent" "the named field produced no intent"
  pass "guard 2: only the record's named field supplies the task id"
}

# --- guard 3: no forwarded authority -------------------------------------

test_guard3_no_forwarded_authority() {
  local sb out rc intent
  sb=$(new_sandbox)
  arm_ok "$sb"
  intent="$sb/base/state/queue-pilot.intent"

  printf 'force=on\n' >>"$intent"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_field" "$out" "$rc" "guard 3 with an undeclared field"
  [ "$(spawn_count "$sb")" = 0 ] || fail "an undeclared field still launched"

  grep -v '^harness=' "$intent" >"$intent.rewrite" && mv "$intent.rewrite" "$intent"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_field" "$out" "$rc" "guard 3 with a missing launch field"

  rm -f "$intent"
  arm_ok "$sb"
  rewrite_intent "$sb" effort turbo
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_field" "$out" "$rc" "guard 3 with a malformed value"
  [ "$(spawn_count "$sb")" = 0 ] || fail "a malformed intent still launched"
  pass "guard 3: the intent schema is closed and every launch field is validated"
}

# --- guard 4: intent identity ---------------------------------------------

test_guard4_intent_identity() {
  local sb out rc
  sb=$(new_sandbox)
  arm_ok "$sb"
  write_record "$sb/base" +prose generation=abs-gen-2
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_identity" "$out" "$rc" "guard 4 across a generation change"
  [ "$(spawn_count "$sb")" = 0 ] || fail "a stale intent still launched"

  write_record "$sb/base" +prose
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 4 with a matching identity: $out"
  case $out in
    dispatched\ *) ;;
    *) fail "a matching identity did not dispatch: $out" ;;
  esac
  pass "guard 4: base, generation and task must all match before launch"
}

# --- guard 5: atomic intent ----------------------------------------------

test_guard5_atomic_intent() {
  local sb out rc leftover
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  chmod 500 "$sb/base/state"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  chmod 700 "$sb/base/state"
  expect_refusal "$refuse_not_durable" "$out" "$rc" "guard 5 with an unwritable state dir"
  [ "$(spawn_count "$sb")" = 0 ] || fail "an unpublishable intent still launched"
  assert_no_grep 'arm_state=spent' "$sb/base/state/queue-pilot.intent" \
    "the intent was spent without a durable write"
  leftover=0
  for leftover in "$sb/base/state"/queue-pilot.intent.tmp.*; do
    [ -e "$leftover" ] || continue
    fail "guard 5 left a temporary intent sibling behind: $leftover"
  done
  pass "guard 5: the intent is published by rename and revalidated before any effect"
}

# --- guard 6: spent intent -----------------------------------------------

test_guard6_spent_intent() {
  local sb out rc
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  out=$(run_pilot "$sb" check --base "$sb/base") || fail "the only admission did not dispatch: $out"
  assert_grep 'arm_state=spent' "$sb/base/state/queue-pilot.intent" "the intent was not spent"
  [ "$(spawn_count "$sb")" = 1 ] || fail "the first trigger did not launch exactly once"

  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_spent" "$out" "$rc" "guard 6 on a second trigger"
  [ "$(spawn_count "$sb")" = 1 ] || fail "a second trigger launched again"

  out=$(run_pilot "$sb" arm --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_spent" "$out" "$rc" "guard 6 on a second arm"
  assert_grep 'arm_state=spent' "$sb/base/state/queue-pilot.intent" "a second arm rewrote the spent intent"
  pass "guard 6: a spent intent launches nothing and cannot be re-armed"
}

# --- guard 7: the absence flag, not the return gate ----------------------

test_guard7_open_absence_flag() {
  local sb out rc
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  rm -f "$sb/base/state/.afk"
  printf 'schema\tsq-afk-return.v1\nphase\tstopping-and-draining\n' >"$sb/base/state/.afk-return-catchup"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_no_absence" "$out" "$rc" "guard 7 without the absence flag"
  [ "$(spawn_count "$sb")" = 0 ] || fail "a return gate admitted a launch"

  : >"$sb/base/state/.afk"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 7 with the absence flag present: $out"
  case $out in
    dispatched\ *) ;;
    *) fail "the absence flag did not admit the launch: $out" ;;
  esac

  sb=$(new_sandbox)
  write_record "$sb/base" +prose expires=$(($(date +%s) - 60))
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_no_absence" "$out" "$rc" "guard 7 on an expired grant"
  pass "guard 7: the absence flag admits, and neither the return gate nor an expiry does"
}

# --- guard 8: ready and unblocked ---------------------------------------

test_guard8_ready_and_unblocked() {
  local sb out rc
  sb=$(new_sandbox)
  arm_ok "$sb"
  printf -- '- [ ] other-task - a later ready task (repo: demo)\n' >"$sb/base/data/backlog.md"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_not_ready" "$out" "$rc" "guard 8 with the task removed"

  printf -- '- [ ] pilot-task - the filed task (repo: demo) (hold: commander decision pending) (hold-kind: commander)\n' >"$sb/base/data/backlog.md"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_not_ready" "$out" "$rc" "guard 8 with the task held"

  write_backlog "$sb/base"
  printf -- '- [ ] predecessor-task - not finished yet (repo: demo)\n- [ ] pilot-task - the filed task (repo: demo) blocked-by: predecessor-task\n' >"$sb/base/data/backlog.md"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_not_ready" "$out" "$rc" "guard 8 with an unfinished predecessor"

  printf -- '- [ ] pilot-task - the filed task (repo: demo) blocked-by: ghost-task\n' >"$sb/base/data/backlog.md"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_not_ready" "$out" "$rc" "guard 8 with a missing predecessor"

  printf '# Backlog\n\n## Queued\n- [ ] pilot-task - the filed task (repo: demo) blocked-by: predecessor-task\n\n## Done\n- [x] predecessor-task - finished (repo: demo)\n' >"$sb/base/data/backlog.md"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 8 with a finished predecessor: $out"
  pass "guard 8: the live ready set, holds and every named predecessor must clear"
}

# --- guard 9: base binding ---------------------------------------------

test_guard9_base_binding() {
  local sb out rc
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  out=$(cd "$sb/base" && run_pilot "$sb" check) && rc=0 || rc=$?
  expect_refusal "$refuse_base" "$out" "$rc" "guard 9 without an explicit base"
  out=$(cd "$sb/base" && run_pilot "$sb" check --base .) && rc=0 || rc=$?
  expect_refusal "$refuse_base" "$out" "$rc" "guard 9 with a relative base"
  out=$(run_pilot "$sb" check --base "$sb/not-a-base") && rc=0 || rc=$?
  expect_refusal "$refuse_base" "$out" "$rc" "guard 9 with a directory that is not a base"
  [ "$(spawn_count "$sb")" = 0 ] || fail "an unbound base admitted a launch"
  out=$(cd / && run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 9 with an explicit absolute base: $out"
  pass "guard 9: readiness is bound to the explicit base, never the current directory"
}

# --- guard 10: census ---------------------------------------------------

test_guard10_census() {
  local sb out rc
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  printf 'schema=sq-exec.v1\nexec_state=running\n' >"$sb/base/state/ghost.exec"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_census" "$out" "$rc" "guard 10 with an orphan attempt record"
  rm -f "$sb/base/state/ghost.exec"

  printf 'endpoint_task_id=broken-task\nworktree=%s/wt\n' "$sb/proj" >"$sb/base/state/broken-task.meta"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_census" "$out" "$rc" "guard 10 with an endpoint-less task record"
  rm -f "$sb/base/state/broken-task.meta"
  [ "$(spawn_count "$sb")" = 0 ] || fail "an uncountable census admitted a launch"
  pass "guard 10: task records, attempt records and endpoints must agree"
}

# --- guard 11: the admitted id is the intent's --------------------------

test_guard11_admitted_id() {
  local sb out rc
  sb=$(new_sandbox)
  printf '# Backlog\n\n## Queued\n- [ ] earlier-task - ahead in the queue (repo: demo)\n- [ ] pilot-task - the filed task (repo: demo)\n' >"$sb/base/data/backlog.md"
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_admitted" "$out" "$rc" "guard 11 with another task at the head"
  [ "$(spawn_count "$sb")" = 0 ] || fail "the pilot skipped ahead of the queue"

  write_backlog "$sb/base"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 11 with the filed task at the head: $out"
  case $(head -1 "$sb/spawn.log") in
    *'pilot-task '*) ;;
    *) fail "the launched id was not the intent's: $(cat "$sb/spawn.log")" ;;
  esac
  pass "guard 11: the launched id comes from the intent and the queue head must be it"
}

# --- guard 12: delivery evidence ---------------------------------------

test_guard12_delivery_evidence() {
  local sb out rc
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  out=$(PILOT_TEST_NO_STATUS=1 run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_delivery" "$out" "$rc" "guard 12 without the worker's own status line"
  [ "$(spawn_count "$sb")" = 1 ] || fail "the delivery check did not follow one launch"

  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 12 with worker status and a live endpoint: $out"
  assert_contains "$out" 'endpoint tmux Squad:sq-pilot-task' "the endpoint proof was not quoted"
  assert_contains "$out" 'attempt claimed' "the attempt evidence was not quoted"
  assert_contains "$out" 'worker-status working-line present' "the status evidence was not quoted"
  pass "guard 12: delivery needs the worker's own status, not just a live endpoint"
}

# --- guard 13: no force -----------------------------------------------

test_guard13_no_force() {
  local sb out rc
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  out=$(SQUAD_BACKEND=tuios run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_force" "$out" "$rc" "guard 13 with a force-cleanup backend"
  out=$(SQUAD_BACKEND=orca run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_force" "$out" "$rc" "guard 13 with an orca backend"
  [ "$(spawn_count "$sb")" = 0 ] || fail "a force-capable backend launched"

  out=$("$sb/effect-call" "$sb/fakebin/spawn-shim" forced-task --force) && rc=0 || rc=$?
  expect_code 1 "$rc" "guard 13 with a force flag"
  [ "$out" = "$refuse_force" ] || fail "a force flag produced '$out'"
  [ "$(spawn_count "$sb")" = 0 ] || fail "a force flag reached the launch command"
  pass "guard 13: no force flag and no force-cleanup backend is selectable"
}

# --- guard 14: memory ceiling -----------------------------------------

test_guard14_memory_ceiling() {
  local sb out rc fakebin
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  printf 'MemAvailable: 1024000 kB\n' >"$sb/meminfo"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_memory" "$out" "$rc" "guard 14 below the first-slot floor"
  [ "$(spawn_count "$sb")" = 0 ] || fail "a low-memory host launched"

  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  printf 'endpoint_task_id=busy-one\nwindow=Squad:sq-busy-one\nworktree=%s/w1\n' "$sb/proj" >"$sb/base/state/busy-one.meta"
  printf 'schema=sq-exec.v1\nexec_state=claimed\n' >"$sb/base/state/busy-one.exec"
  printf 'endpoint_task_id=busy-two\nwindow=Squad:sq-busy-two\nworktree=%s/w2\n' "$sb/proj" >"$sb/base/state/busy-two.meta"
  printf 'schema=sq-exec.v1\nexec_state=running\n' >"$sb/base/state/busy-two.exec"
  printf 'MemAvailable: 5120000 kB\n' >"$sb/meminfo"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_memory" "$out" "$rc" "guard 14 at the third-slot floor"
  printf 'MemAvailable: 16777216 kB\n' >"$sb/meminfo"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 14 with the third-slot floor satisfied: $out"
  assert_contains "$out" 'slot=3' "the third slot was not measured"

  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  fakebin="$sb/fakebin"
  cat >"$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
case ${2:-} in
  hw.pagesize) printf '16384\n' ;;
  *) exit 1 ;;
esac
SH
  cat >"$fakebin/vm_stat" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               400000.
Pages active:                            2000000.
Pages inactive:                           300000.
Pages speculative:                         20000.
OUT
SH
  chmod +x "$fakebin/sysctl" "$fakebin/vm_stat"
  out=$(SQUAD_QUEUE_PILOT_MEMINFO="$sb/no-such-meminfo" run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 14 on a host without /proc/meminfo: $out"
  assert_contains "$out" 'dispatched pilot-task' "the portable memory sample did not admit the launch"
  pass "guard 14: the measured memory ceiling refuses before launch and is portable"
}

# --- guard 15: mission cap --------------------------------------------

test_guard15_mission_cap() {
  local sb out rc
  sb=$(new_sandbox)
  write_record "$sb/base" +prose cap=1
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  printf 'endpoint_task_id=busy-one\nwindow=Squad:sq-busy-one\nworktree=%s/w1\n' "$sb/proj" >"$sb/base/state/busy-one.meta"
  printf 'schema=sq-exec.v1\nexec_state=claimed\n' >"$sb/base/state/busy-one.exec"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_cap" "$out" "$rc" "guard 15 at the recorded ceiling"
  [ "$(spawn_count "$sb")" = 0 ] || fail "a launch went past the recorded ceiling"

  sb=$(new_sandbox)
  write_record "$sb/base" +prose cap=3
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  printf 'endpoint_task_id=busy-one\nwindow=Squad:sq-busy-one\nworktree=%s/w1\n' "$sb/proj" >"$sb/base/state/busy-one.meta"
  printf 'schema=sq-exec.v1\nexec_state=claimed\n' >"$sb/base/state/busy-one.exec"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 15 with room inside the ceiling: $out"
  pass "guard 15: the mission cap comes from the record and is enforced before launch"
}

# --- guard 16: delivery posture ---------------------------------------

test_guard16_delivery_posture() {
  local sb out rc
  sb=$(new_sandbox)
  printf -- '- demo [local-only] - demo project\n' >"$sb/base/data/projects.md"
  out=$(run_pilot "$sb" arm --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_posture" "$out" "$rc" "guard 16 for a local-only project"
  write_record "$sb/base" +prose mode=local-only yolo=on
  out=$(run_pilot "$sb" arm --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_posture" "$out" "$rc" "guard 16 for local-only with autonomy on"
  write_record "$sb/base" +prose mode=local-only yolo=off
  out=$(run_pilot "$sb" arm --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 16 for a local-only project with autonomy off: $out"

  sb=$(new_sandbox)
  printf -- '- demo [drill-prod-only] - demo project\n' >"$sb/base/data/projects.md"
  out=$(run_pilot "$sb" arm --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_posture" "$out" "$rc" "guard 16 for drill-prod-only with direct-PR"
  write_record "$sb/base" +prose mode=drill
  out=$(run_pilot "$sb" arm --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "guard 16 for drill-prod-only delivered through drill: $out"

  sb=$(new_sandbox)
  printf -- '- something-else [drill] - another project\n' >"$sb/base/data/projects.md"
  out=$(run_pilot "$sb" arm --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_posture" "$out" "$rc" "guard 16 for an unregistered project"
  pass "guard 16: each project's recorded mode and autonomy are respected, local-only included"
}

# --- the effect boundary beyond task mutation ------------------------

test_no_code_path_merges_or_registers_a_pr() {
  local sb out rc name
  sb=$(new_sandbox)
  for name in sq-pr-merge.sh sq-pr-check.sh sq-merge-local.sh sq-send.sh sq-teardown.sh sq-promote.sh gh glab git; do
    effect_shim "$sb" "$name"
    out=$("$sb/effect-call" "$sb/fakebin/$name" pr 42) && rc=0 || rc=$?
    expect_code 1 "$rc" "the effect boundary admitted $name"
    [ "$out" = "$refuse_effect" ] || fail "$name produced '$out'"
  done
  assert_absent "$sb/effect.log" "a merge, PR-registration or steer command reached the executable"
  pass "no code path can merge or register a pull request: the effect boundary refuses them"
}

# --- the happy path -----------------------------------------------------

test_happy_path_dispatches_exactly_once() {
  local sb out rc launched
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  arm_ok "$sb"
  assert_grep 'key=' "$sb/base/state/queue-pilot.intent" "the intent carries no identity key"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_code 0 "$rc" "the happy path did not dispatch: $out"
  launched=$(head -1 "$sb/spawn.log")
  assert_contains "$out" 'dispatched pilot-task' "the dispatch was not reported"
  assert_contains "$out" 'endpoint tmux Squad:sq-pilot-task' "the endpoint was not reported"
  assert_contains "$out" 'worktree ' "the worktree was not reported"
  assert_contains "$out" 'attempt claimed' "the attempt state was not reported"
  assert_contains "$out" 'worker-status working-line present' "the worker status evidence was not reported"
  assert_contains "$launched" 'pilot-task' "the launch argv named another id"
  assert_contains "$launched" '--mode direct-PR' "the launch argv lost the delivery mode"
  assert_contains "$launched" '--yolo on' "the launch argv lost the autonomy posture"
  assert_contains "$launched" '--harness claude' "the launch argv lost the harness"
  assert_contains "$launched" '--backend tmux' "the launch argv lost the reviewed backend"
  [ "$(spawn_count "$sb")" = 1 ] || fail "the happy path launched $(spawn_count "$sb") times"
  pass "the happy path dispatches the filed task once with the intent's fields"
}

# --- the vocabulary on the unarmed and unknown-command paths ---------

test_unarmed_and_unknown_command_paths() {
  local sb out rc
  sb=$(new_sandbox)
  : >"$sb/base/state/.afk"
  out=$(run_pilot "$sb" check --base "$sb/base") && rc=0 || rc=$?
  expect_refusal "$refuse_no_task_id" "$out" "$rc" "an unarmed base"
  out=$(run_pilot "$sb" nonsense --base "$sb/base" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown command"
  pass "an unarmed base refuses with the filed-id line and an unknown command exits 2"
}

test_guard1_no_task_mutation
test_guard2_task_id_from_the_named_field
test_guard3_no_forwarded_authority
test_guard4_intent_identity
test_guard5_atomic_intent
test_guard6_spent_intent
test_guard7_open_absence_flag
test_guard8_ready_and_unblocked
test_guard9_base_binding
test_guard10_census
test_guard11_admitted_id
test_guard12_delivery_evidence
test_guard13_no_force
test_guard14_memory_ceiling
test_guard15_mission_cap
test_guard16_delivery_posture
test_no_code_path_merges_or_registers_a_pr
test_happy_path_dispatches_exactly_once
test_unarmed_and_unknown_command_paths
