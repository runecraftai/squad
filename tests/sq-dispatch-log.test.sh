#!/usr/bin/env bash
# Behavior tests for private, best-effort dispatch history and lifecycle hooks.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-dispatch-log)
fm_git_identity fmtest fmtest@example.invalid

make_case() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/data/task" "$dir/state" "$dir/config" "$dir/projects"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" fob drill notify-send
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$SQUAD_FAKE_PANE_PATH" ;;
  *"#{session_name}:#{window_name}"*) printf 'Squad:sq-task\n' ;;
  display-message*) printf 'Squad\n' ;;
esac
exit 0
SH
  cat > "$fakebin/sq-gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pr merge '*) exit "${SQ_TEST_MERGE_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/sq-gh"
  fm_git_worktree "$dir/project" "$dir/wt" "sq/$1"
  printf 'PRIVATE_BRIEF_SENTINEL\necho done >> "%s/state/task.status"\n' "$dir" > "$dir/data/task/brief.md"
  touch "$dir/state/task.status" "$dir/state/.last-sentry-beat"
  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1 script=$2
  shift 2
  SQUAD_BASE="$dir" SQUAD_ROOT_OVERRIDE="$ROOT" \
    SQUAD_STATE_OVERRIDE="$dir/state" SQUAD_DATA_OVERRIDE="$dir/data" \
    SQUAD_CONFIG_OVERRIDE="$dir/config" SQUAD_PROJECTS_OVERRIDE="$dir/projects" \
    SQUAD_SPAWN_NO_GUARD=1 SQUAD_FAKE_PANE_PATH="$dir/wt" TMUX=fake,1,0 \
    XDG_STATE_HOME="$dir/cache" CLAUDE_CONFIG_DIR='' \
    SQ_NOTIFY_VERBS=blocked SQ_TEST_MERGE_RC="${SQ_TEST_MERGE_RC:-0}" \
    ANTHROPIC_API_KEY=PRIVATE_SECRET_SENTINEL PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/$script" "$@"
}

spawn() {
  local dir=$1
  shift
  run_case "$dir" sq-spawn.sh task "$dir/project" --harness claude --model haiku \
    --effort low --mode local-only --yolo off "$@"
}

dir=$(make_case lifecycle)
spawn "$dir" --decision-profile closed-scope \
  --quota-summary '{"remaining_percent":80,"reset_seconds":3600}' \
  > "$dir/spawn.out" 2> "$dir/spawn.err" || fail 'fixture spawn failed'
run_case "$dir" sq-teardown.sh task > "$dir/teardown.out" 2> "$dir/teardown.err" \
  || fail 'fixture teardown failed'
assert_absent "$dir/state/task.meta" 'teardown did not release fixture'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, os, stat, sys
path = sys.argv[1]
raw = open(path).read()
rows = [json.loads(line) for line in raw.splitlines()]
assert [row['event'] for row in rows] == ['decision', 'spawn', 'outcome'], rows
assert rows[0]['quota_summary'] == {'remaining_percent': 80, 'reset_seconds': 3600}
assert rows[0]['profile'] == 'closed-scope'
assert rows[1]['harness'] == 'claude' and rows[1]['model'] == 'haiku' and rows[1]['effort'] == 'low'
assert rows[2]['source'] == 'teardown' and rows[2]['result'] == 'released'
assert all(row['id'] == 'task' and row['timestamp'] for row in rows)
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
assert 'PRIVATE_BRIEF_SENTINEL' not in raw and 'PRIVATE_SECRET_SENTINEL' not in raw
PY
pass 'decision, actual spawn and teardown outcome survive cleanup privately without brief or secrets'

cp "$dir/data/task/dispatch.jsonl" "$dir/first.jsonl"
chmod 644 "$dir/data/task/dispatch.jsonl"
run_case "$dir" sq-dispatch-log.sh task decision --harness pi --model gpt-5 --effort high \
  --reason 'Explicit override' > "$dir/decision.out"
python3 - "$dir/data/task/dispatch.jsonl" "$dir/first.jsonl" <<'PY'
import json, os, stat, sys
raw = open(sys.argv[1]).read()
assert raw.startswith(open(sys.argv[2]).read())
rows = [json.loads(line) for line in raw.splitlines()]
assert len(rows) == 4 and rows[-1]['reason'] == 'Explicit override'
assert rows[-1]['quota_summary'] == {'status': 'unknown'}
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
pass 'a second decision appends without altering history and restores private mode'

# Status history is baselined; terminal appends are logged even when desktop
# notifications are filtered or the task window is focused. Never copy its text.
fm_write_meta "$dir/state/task.meta" 'window=Squad:sq-task' "worktree=$dir/wt" \
  "project=$dir/project" 'kind=strike' 'mode=local-only'
touch "$dir/state/task.status"
run_case "$dir" sq-status-notify.sh scan "$dir"
printf 'done: PRIVATE_BRIEF_SENTINEL\nfailed: PRIVATE_SECRET_SENTINEL\n' >> "$dir/state/task.status"
run_case "$dir" sq-status-notify.sh scan "$dir"
run_case "$dir" sq-status-notify.sh scan "$dir"
run_case "$dir" sq-pr-merge.sh task https://github.com/example/repo/pull/1 > "$dir/merge.out" 2> "$dir/merge.err"
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
rows = [json.loads(line) for line in raw.splitlines()]
assert [(r['source'], r['result']) for r in rows[4:]] == [
    ('status-notify', 'done'), ('status-notify', 'failed'), ('pr-merge', 'landed')]
assert 'PRIVATE_BRIEF_SENTINEL' not in raw and 'PRIVATE_SECRET_SENTINEL' not in raw
PY
# A failed merge must retain its exact exit code and must not log a landing.
rc=0
SQ_TEST_MERGE_RC=7 run_case "$dir" sq-pr-merge.sh task https://github.com/example/repo/pull/1 \
  > "$dir/failed-merge.out" 2> "$dir/failed-merge.err" || rc=$?
expect_code 7 "$rc" 'merge failure must propagate'
[ "$(wc -l < "$dir/data/task/dispatch.jsonl")" -eq 7 ] || fail 'failed merge logged landing'
pass 'terminal notifications and successful landing append outcomes, not status text or failed landings'

# Squad accepts model ids with printable variant punctuation (for example the
# [1m] context suffix); they must be recorded verbatim rather than dropped.
run_case "$dir" sq-dispatch-log.sh task decision --harness claude \
  --model 'claude-opus-4-8[1m]' --effort high --reason 'Variant model' > "$dir/variant.out"
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows[-1]['model'] == 'claude-opus-4-8[1m]'
assert rows[-1]['reason'] == 'Variant model'
PY
pass 'printable model variant ids are recorded verbatim'

# Reject symlink/hardlink destinations without touching their targets, unsafe
# ids and raw credentials in quota payloads. Every failure is one generic warning.
for unsafe in symlink hardlink directory invalid-id raw-quota; do
  bad="$TMP_ROOT/$unsafe"
  mkdir -p "$bad/data/task"
  printf 'untouched\n' > "$bad/target"
  chmod 644 "$bad/target"
  id=task
  quota='{}'
  case "$unsafe" in
    symlink) ln -s "$bad/target" "$bad/data/task/dispatch.jsonl" ;;
    hardlink) ln "$bad/target" "$bad/data/task/dispatch.jsonl" ;;
    directory) mkdir "$bad/data/task/dispatch.jsonl" ;;
    invalid-id) id=../escape ;;
    raw-quota) quota='{"token":"PRIVATE_SECRET_SENTINEL"}' ;;
  esac
  SQUAD_BASE="$bad" SQUAD_DATA_OVERRIDE="$bad/data" "$ROOT/bin/sq-dispatch-log.sh" "$id" decision \
    --harness claude --model haiku --effort low --reason policy --quota-summary "$quota" \
    > "$bad/out" 2> "$bad/err" || fail 'logging failure changed exit code'
  [ ! -s "$bad/out" ] || fail 'logging failure produced stdout'
  [ "$(wc -l < "$bad/err")" -eq 1 ] || fail 'logging failure must issue exactly one warning'
  assert_no_grep PRIVATE_SECRET_SENTINEL "$bad/err" 'warning leaked payload'
  [ "$(< "$bad/target")" = untouched ] || fail 'unsafe log changed target'
  python3 - "$bad/target" <<'PY'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o644
PY
done
pass 'unsafe destinations and payloads are skipped with one non-sensitive warning'

# Unwritable log destination: none of the existing successful lifecycle paths
# become failures merely because the optional history cannot be appended.
dir=$(make_case best-effort)
mkdir "$dir/data/task/dispatch.jsonl"
spawn "$dir" > "$dir/spawn.out" 2> "$dir/spawn.err" || fail 'log failure blocked spawn'
run_case "$dir" sq-pr-merge.sh task https://github.com/example/repo/pull/2 \
  > "$dir/merge.out" 2> "$dir/merge.err" || fail 'log failure blocked merge'
run_case "$dir" sq-status-notify.sh scan "$dir"
printf 'done: finished\n' >> "$dir/state/task.status"
run_case "$dir" sq-status-notify.sh scan "$dir" 2> "$dir/status.err" || fail 'log failure blocked notification'
run_case "$dir" sq-teardown.sh task > "$dir/teardown.out" 2> "$dir/teardown.err" \
  || fail 'log failure blocked teardown'
assert_absent "$dir/state/task.meta" 'log failure prevented release'
for stage in spawn merge status teardown; do
  assert_grep 'sq-dispatch-log: could not append dispatch event' "$dir/$stage.err" \
    "missing $stage warning: $(< "$dir/$stage.err")"
done
pass 'logging failure never blocks spawn, landing, terminal notification or teardown'

# A lock held by a concurrent writer is waited out within the bounded budget.
# A brief hold must still append; a hold past the budget must return promptly
# with one warning and no append.
lock_case() {
  local name=$1 hold=$2 reason=$3 expect=$4
  local dir="$TMP_ROOT/lock-$name" holder before after rc=0 start elapsed
  mkdir -p "$dir/data/task"
  run_case "$dir" sq-dispatch-log.sh task decision --harness claude --model haiku \
    --effort low --reason seed > /dev/null 2>&1
  python3 - "$dir/data/task/dispatch.jsonl" "$dir/lock.ready" "$hold" <<'PY' &
import fcntl, sys, time
with open(sys.argv[1], 'a') as log:
    fcntl.flock(log, fcntl.LOCK_EX)
    open(sys.argv[2], 'w').close()
    time.sleep(float(sys.argv[3]))
PY
  holder=$!
  for _ in $(seq 500); do [ -e "$dir/lock.ready" ] && break; sleep 0.01; done
  before=$(wc -l < "$dir/data/task/dispatch.jsonl")
  start=$(python3 -c 'import time; print(int(time.monotonic() * 1000))')
  run_case "$dir" sq-dispatch-log.sh task decision --harness claude --model haiku \
    --effort low --reason "$reason" > "$dir/lock.out" 2> "$dir/lock.err" || rc=$?
  elapsed=$(( $(python3 -c 'import time; print(int(time.monotonic() * 1000))') - start ))
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  after=$(wc -l < "$dir/data/task/dispatch.jsonl")
  expect_code 0 "$rc" "$name: logging must not fail"
  [ ! -s "$dir/lock.out" ] || fail "$name: logging produced stdout"
  if [ "$expect" = appended ]; then
    [ "$after" -eq $((before + 1)) ] || fail "$name: event dropped inside lock budget"
    [ ! -s "$dir/lock.err" ] || fail "$name: unexpected warning inside lock budget"
  else
    [ "$after" -eq "$before" ] || fail "$name: event appended past lock budget"
    [ "$(wc -l < "$dir/lock.err")" -eq 1 ] || fail "$name: expected exactly one warning"
    assert_grep 'sq-dispatch-log: could not append dispatch event' "$dir/lock.err" \
      "$name: missing lock warning"
    [ "$elapsed" -lt 1000 ] || fail "$name: lock wait exceeded budget (${elapsed}ms)"
  fi
}

lock_case brief-hold 0.2 'Brief lock' appended
lock_case over-budget 3 'Over budget lock' dropped
pass 'briefly held lock appends after release; over-budget lock returns promptly with one warning'

# Intake: a spawn carrying the decision records it once, immediately before the
# spawn event, with the same harness, model and effort, and never the brief text.
dir=$(make_case intake-profile)
run_case "$dir" sq-spawn.sh task "$dir/project" --harness claude --model haiku \
  --effort low --mode local-only --yolo off --decision-profile closed-scope \
  --quota-summary '{"remaining_percent":80,"reset_seconds":3600}' \
  > "$dir/intake.out" 2> "$dir/intake.err" || fail 'intake spawn with profile failed'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, os, stat, sys
path = sys.argv[1]
raw = open(path).read()
rows = [json.loads(line) for line in raw.splitlines()]
assert [row['event'] for row in rows] == ['decision', 'spawn'], rows
decision = rows[0]
assert decision['profile'] == 'closed-scope' and 'reason' not in decision, decision
assert decision['harness'] == 'claude' and decision['model'] == 'haiku' and decision['effort'] == 'low'
assert decision['quota_summary'] == {'remaining_percent': 80, 'reset_seconds': 3600}
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
assert 'PRIVATE_BRIEF_SENTINEL' not in raw and 'PRIVATE_SECRET_SENTINEL' not in raw
PY
pass 'intake spawn records one profile decision before the spawn event, privately'

dir=$(make_case intake-reason)
run_case "$dir" sq-spawn.sh task "$dir/project" --harness claude --model haiku \
  --effort low --mode local-only --yolo off --decision-reason 'No profile matched' \
  > "$dir/intake.out" 2> "$dir/intake.err" || fail 'intake spawn with reason failed'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row['event'] for row in rows] == ['decision', 'spawn'], rows
assert rows[0]['reason'] == 'No profile matched' and 'profile' not in rows[0]
assert rows[0]['quota_summary'] == {'status': 'unknown'}
PY
pass 'intake spawn with a reason and no quota summary records an unknown quota'

# A refused decision payload is a logging failure: the spawn still launches and
# only its spawn row is kept. The warning must not echo the rejected payload.
dir=$(make_case intake-bad-quota)
run_case "$dir" sq-spawn.sh task "$dir/project" --harness claude --model haiku \
  --effort low --mode local-only --yolo off --decision-profile closed-scope \
  --quota-summary '{"token":"PRIVATE_SECRET_SENTINEL"}' \
  > "$dir/intake.out" 2> "$dir/intake.err" || fail 'rejected decision blocked spawn'
[ -f "$dir/state/task.meta" ] || fail 'spawn did not publish task meta'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
rows = [json.loads(line) for line in raw.splitlines()]
assert [row['event'] for row in rows] == ['spawn'], rows
assert 'PRIVATE_SECRET_SENTINEL' not in raw
PY
assert_no_grep PRIVATE_SECRET_SENTINEL "$dir/intake.err" 'warning leaked rejected quota payload'
pass 'a rejected decision never blocks spawn and never echoes its payload'

dir=$(make_case intake-secret-reason)
run_case "$dir" sq-spawn.sh task "$dir/project" --harness claude --model haiku \
  --effort low --mode local-only --yolo off --decision-reason 'api_key=PRIVATE_REASON_SENTINEL' \
  > "$dir/intake.out" 2> "$dir/intake.err" || fail 'credential-shaped reason blocked spawn'
[ -f "$dir/state/task.meta" ] || fail 'spawn with credential-shaped reason did not publish task meta'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
rows = [json.loads(line) for line in raw.splitlines()]
assert [row['event'] for row in rows] == ['spawn'], rows
assert 'PRIVATE_REASON_SENTINEL' not in raw
PY
assert_no_grep PRIVATE_REASON_SENTINEL "$dir/intake.err" 'warning leaked credential-shaped reason'
pass 'a credential-shaped decision reason is refused and never stored'

# Every operator spawn records its intake decision without a caller reason: the
# reason comes from the harness source, and the quota snapshot passes through.
dir=$(make_case intake-derived)
run_case "$dir" sq-spawn.sh task "$dir/project" --harness claude --model haiku \
  --effort low --mode local-only --yolo off \
  --quota-summary '{"remaining_percent":55}' > "$dir/intake.out" 2> "$dir/intake.err" \
  || fail 'derived-decision spawn failed'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, os, stat, sys
path = sys.argv[1]
raw = open(path).read()
rows = [json.loads(line) for line in raw.splitlines()]
assert [row['event'] for row in rows] == ['decision', 'spawn'], rows
decision = rows[0]
assert decision['reason'] == 'explicit harness argument' and 'profile' not in decision, decision
assert decision['harness'] == 'claude' and decision['model'] == 'haiku' and decision['effort'] == 'low'
assert decision['quota_summary'] == {'remaining_percent': 55}
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
assert 'PRIVATE_BRIEF_SENTINEL' not in raw and 'PRIVATE_SECRET_SENTINEL' not in raw
PY
pass 'plain operator spawn records one derived intake decision privately'

dir=$(make_case intake-config-default)
printf 'claude\n' > "$dir/config/crew-harness"
run_case "$dir" sq-spawn.sh task "$dir/project" --model haiku --effort low \
  --mode local-only --yolo off > "$dir/intake.out" 2> "$dir/intake.err" \
  || fail 'config-default spawn failed'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row['event'] for row in rows] == ['decision', 'spawn'], rows
assert rows[0]['reason'] == 'config/crew-harness default' and rows[0]['harness'] == 'claude'
PY
pass 'spawn without a harness argument derives its reason from config/crew-harness'

dir=$(make_case intake-config-absent)
# Own-harness detection must not depend on the host's process tree: a CI runner
# has no harness ancestor, so pin the verified claude env marker for this case.
CLAUDECODE=1 run_case "$dir" sq-spawn.sh task "$dir/project" --model haiku --effort low \
  --mode local-only --yolo off > "$dir/intake.out" 2> "$dir/intake.err" \
  || fail 'unpinned spawn failed'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row['event'] for row in rows] == ['decision', 'spawn'], rows
assert rows[0]['reason'] == 'detected own harness (no config/crew-harness pin)', rows[0]
assert rows[0]['harness'] == rows[1]['harness'] and rows[0]['harness']
PY
pass 'spawn with no config/crew-harness pin labels its reason as detected, not as the pin'

# A failure after the intake decision still keeps the choice that was made: the
# missing project is refused only after harness, model and effort resolve.
dir=$(make_case intake-failed-dispatch)
rc=0
run_case "$dir" sq-spawn.sh task "$dir/missing-project" --harness claude --model haiku \
  --effort low --mode local-only --yolo off --decision-reason 'Failed dispatch' \
  > "$dir/intake.out" 2> "$dir/intake.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'spawn of a missing project succeeded'
python3 - "$dir/data/task/dispatch.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row['event'] for row in rows] == ['decision'], rows
assert rows[0]['reason'] == 'Failed dispatch' and rows[0]['harness'] == 'claude'
PY
pass 'a dispatch that fails after resolution keeps its intake decision without a spawn row'

# A batch writes one decision per pair, each carrying its own derived reason.
dir=$(make_case intake-batch)
for task in alpha beta; do
  mkdir -p "$dir/data/$task"
  cp "$dir/data/task/brief.md" "$dir/data/$task/brief.md"
done
run_case "$dir" sq-spawn.sh alpha="$dir/project" beta="$dir/project" --harness claude \
  --model haiku --effort low --mode local-only --yolo off \
  > "$dir/batch.out" 2> "$dir/batch.err" || fail 'batch intake spawn failed'
python3 - "$dir/data" <<'PY'
import json, sys
for task in ('alpha', 'beta'):
    rows = [json.loads(line) for line in open(f'{sys.argv[1]}/{task}/dispatch.jsonl')]
    assert [row['event'] for row in rows] == ['decision', 'spawn'], (task, rows)
    assert rows[0]['reason'] == 'explicit harness argument' and rows[0]['id'] == task
PY
pass 'batch spawn records one derived decision for each pair'

# Usage refusals happen before any endpoint exists: batch and --xo spawns cannot
# carry a per-task decision, decisions cannot be doubled, and a quota summary
# cannot be attached to an XO, which records no decision.
dir=$(make_case intake-refusals)
refuse() {
  local expect=$1 rc=0
  shift
  run_case "$dir" sq-spawn.sh "$@" > "$dir/refuse.out" 2> "$dir/refuse.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "accepted refused intake flags: $*"
  assert_grep "$expect" "$dir/refuse.err" "wrong refusal for: $*"
  [ ! -e "$dir/data/task/dispatch.jsonl" ] || fail "refused intake wrote a decision: $*"
  [ ! -e "$dir/state/task.meta" ] || fail "refused intake published task meta: $*"
}
refuse 'per task' "task=$dir/project" --mode local-only --yolo off --decision-reason batch
refuse 'per task' "task=$dir/project" --mode local-only --yolo off --quota-summary '{}'
refuse 'operator and recon spawns' task "$dir/project" --xo --decision-reason xo
refuse 'operator and recon spawns' task "$dir/project" --xo --quota-summary '{}'
refuse 'pass only one of' task "$dir/project" --mode local-only --yolo off \
  --decision-profile a --decision-reason b
pass 'batch, XO, and doubled decision flags are refused before any spawn'
