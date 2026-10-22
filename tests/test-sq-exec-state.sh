#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"
export SQUAD_STATE_OVERRIDE="$STATE"
EXEC="$ROOT/bin/sq-exec-state.sh"

assert_eq() {
  [ "$1" = "$2" ] || { printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }
}

# Legacy tasks have no sidecar and are unclaimed.
assert_eq "$("$EXEC" get legacy)" unclaimed

# Exercise the complete supported lifecycle, including retry and release.
assert_eq "$("$EXEC" claim task)" claimed
assert_eq "$("$EXEC" get task)" claimed
assert_eq "$("$EXEC" running task)" running
assert_eq "$("$EXEC" retry task)" retry_queued
[ -n "$(sed -n 's/^exec_next_retry_at=//p' "$STATE/task.exec")" ] || {
  echo 'retry did not schedule a deadline' >&2
  exit 1
}
assert_eq "$("$EXEC" claim task)" claimed
assert_eq "$(grep '^exec_next_retry_at=' "$STATE/task.exec")" 'exec_next_retry_at='
assert_eq "$("$EXEC" running task)" running
assert_eq "$(grep '^exec_next_retry_at=' "$STATE/task.exec")" 'exec_next_retry_at='
assert_eq "$("$EXEC" release task)" released
assert_eq "$("$EXEC" release task)" released

mkdir -p "$TMP/workspace-a" "$TMP/workspace-b"
printf 'worktree=%s\n' "$TMP/workspace-a" > "$STATE/workspace-history.meta"
assert_eq "$("$EXEC" claim workspace-history)" claimed
assert_eq "$("$EXEC" running workspace-history)" running
assert_eq "$("$EXEC" retry workspace-history)" retry_queued
printf 'worktree=%s\n' "$TMP/workspace-b" > "$STATE/workspace-history.meta"
assert_eq "$("$EXEC" claim workspace-history)" claimed
assert_eq "$("$EXEC" running workspace-history)" running
mapfile -t workspaces < <(sed -n 's/^exec_workspace=//p' "$STATE/workspace-history.exec")
assert_eq "${#workspaces[@]}" 2
assert_eq "${workspaces[0]}" "$TMP/workspace-a"
assert_eq "${workspaces[1]}" "$TMP/workspace-b"

# Two concurrent claims can produce at most one successful claim.
for n in $(seq 1 20); do
  ("$EXEC" claim atomic >"$TMP/claim-$n" 2>/dev/null && echo success >"$TMP/result-$n" || true) &
done
wait
[ "$(find "$TMP" -name 'result-*' | wc -l | tr -d ' ')" -eq 1 ]
assert_eq "$("$EXEC" get atomic)" claimed

# An old running heartbeat becomes retry_queued after the stale threshold.
"$EXEC" claim stale >/dev/null
"$EXEC" running stale >/dev/null
sed -i 's/^exec_last_activity=.*/exec_last_activity=1/' "$STATE/stale.exec"
SQUAD_EXEC_STALE_AFTER=1 "$EXEC" recover stale >/dev/null
assert_eq "$("$EXEC" get stale)" retry_queued

# A completed PR task with a stale running sidecar is released, and recovery
# cannot make it claimable again.
printf 'window=Squad\npr=https://github.com/o/r/pull/1\n' > "$STATE/finished.meta"
printf 'exec_state=running\nexec_attempt=2\nexec_last_activity=1\n' > "$STATE/finished.exec"
printf 'working: validating\ndone: PR https://github.com/o/r/pull/1 checks green\n' > "$STATE/finished.status"
SQUAD_EXEC_STALE_AFTER=1 "$EXEC" recover finished >/dev/null
assert_eq "$("$EXEC" get finished)" released
"$EXEC" recover-all >/dev/null
if "$EXEC" claim finished >/dev/null 2>&1; then
  echo 'finished attempt was claimable' >&2
  exit 1
fi

# A terminal failed task and a local-only done task are released without PR metadata.
for task in finished-failed finished-local; do
  printf 'window=Squad\n' > "$STATE/$task.meta"
  printf 'exec_state=claimed\nexec_attempt=1\nexec_last_activity=1\n' > "$STATE/$task.exec"
done
printf 'failed: validation could not proceed\n' > "$STATE/finished-failed.status"
printf 'done: recon report saved\n' > "$STATE/finished-local.status"
SQUAD_EXEC_STALE_AFTER=1 "$EXEC" recover finished-failed >/dev/null
SQUAD_EXEC_STALE_AFTER=1 "$EXEC" recover finished-local >/dev/null
assert_eq "$("$EXEC" get finished-failed)" released
assert_eq "$("$EXEC" get finished-local)" released

# PR metadata and decision/wait/progress lines alone are not completion evidence.
for task in pr-working pr-decision pr-blocked pr-paused pr-resolved; do
  printf 'window=Squad\npr=https://github.com/o/r/pull/1\n' > "$STATE/$task.meta"
  printf 'exec_state=running\nexec_attempt=1\nexec_last_activity=1\n' > "$STATE/$task.exec"
done
printf 'working: still validating\n' > "$STATE/pr-working.status"
printf 'needs-decision [key=x]: choose\n' > "$STATE/pr-decision.status"
printf 'blocked: waiting\n' > "$STATE/pr-blocked.status"
printf 'paused: external wait\n' > "$STATE/pr-paused.status"
printf 'resolved: answered\n' > "$STATE/pr-resolved.status"
for task in pr-working pr-decision pr-blocked pr-paused pr-resolved; do
  SQUAD_EXEC_STALE_AFTER=9999999999 "$EXEC" recover "$task" >/dev/null
  assert_eq "$("$EXEC" get "$task")" running
done

# A retry_queued terminal record is retired by recovery, and claim itself is a
# final safety check when recovery has not run first.
for task in queued-done queued-direct; do
  printf 'window=Squad\npr=https://github.com/o/r/pull/2\n' > "$STATE/$task.meta"
  printf 'exec_state=retry_queued\nexec_attempt=3\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/$task.exec"
  printf 'done: PR checks green\n' > "$STATE/$task.status"
done
"$EXEC" recover queued-done >/dev/null
assert_eq "$("$EXEC" get queued-done)" released
if "$EXEC" claim queued-direct >/dev/null 2>&1; then
  echo 'terminal retry_queued attempt was claimable without recovery' >&2
  exit 1
fi
assert_eq "$("$EXEC" get queued-direct)" released

# A queued retry outlives the previous attempt's ended run: the terminal run
# drives the `get` reporting projection, not the dispatch decision, so claim,
# recover, and recover-all resume the attempt instead of parking it.
resume_wt="$TMP/resume-wt"
mkdir -p "$resume_wt"
git -C "$resume_wt" init -q
git -C "$resume_wt" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
git -C "$resume_wt" checkout -q -b sq/resume
resume_head=$(git -C "$resume_wt" rev-parse HEAD)
mkdir -p "$TMP/resume-bin"
cat > "$TMP/resume-bin/drill" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  axi)
    [ "\${2:-}" = status ] && printf 'run:\n  branch: sq/resume\n  status: failed\n  outcome: failed\n  head: "%s"\n' "$resume_head"
    ;;
  runs)
    printf 'failed sq/resume %.7s 2026-10-21\n' "$resume_head"
    ;;
esac
exit 0
EOF
chmod +x "$TMP/resume-bin/drill"
printf 'window=Squad\nworktree=%s\nkind=strike\n' "$resume_wt" > "$STATE/resume.meta"
printf 'exec_state=retry_queued\nexec_attempt=2\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/resume.exec"
printf 'working: stall interrupted; retry scheduled for 1\n' > "$STATE/resume.status"
assert_eq "$(PATH="$TMP/resume-bin:$PATH" "$EXEC" get resume)" released
assert_eq "$(PATH="$TMP/resume-bin:$PATH" "$EXEC" claim resume)" claimed
assert_eq "$(PATH="$TMP/resume-bin:$PATH" "$EXEC" get-recorded resume)" claimed
printf 'exec_state=retry_queued\nexec_attempt=2\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/resume.exec"
assert_eq "$(PATH="$TMP/resume-bin:$PATH" "$EXEC" recover resume)" retry_queued
PATH="$TMP/resume-bin:$PATH" "$EXEC" recover-all >/dev/null
assert_eq "$(PATH="$TMP/resume-bin:$PATH" "$EXEC" get-recorded resume)" retry_queued

# A gate-parked run keeps the attempt while its recorded owner endpoint is
# alive, and only an authoritatively gone owner lets the retry path resume.
parked_wt="$TMP/parked-wt"
mkdir -p "$parked_wt"
git -C "$parked_wt" init -q
git -C "$parked_wt" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
git -C "$parked_wt" checkout -q -b sq/parked
parked_head=$(git -C "$parked_wt" rev-parse HEAD)
mkdir -p "$TMP/parked-bin"
cat > "$TMP/parked-bin/drill" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  axi)
    [ "\${2:-}" = status ] && printf 'run:\n  id: "01PARK"\n  branch: sq/parked\n  status: awaiting_approval\n  awaiting_agent: parked 2m10s\n  head: "%s"\n  findings: none\ngate: review\n' "$parked_head"
    ;;
  runs)
    printf 'running sq/parked %.7s 2026-10-21\n' "$parked_head"
    ;;
esac
exit 0
EOF
chmod +x "$TMP/parked-bin/drill"
printf 'window=sq-parked:win\nworktree=%s\nkind=strike\n' "$parked_wt" > "$STATE/parked.meta"
printf 'exec_state=retry_queued\nexec_attempt=1\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/parked.exec"
printf 'working: stall interrupted; retry scheduled for 1\n' > "$STATE/parked.status"
assert_eq "$(PATH="$TMP/parked-bin:$PATH" "$EXEC" get parked)" running
set +e
PATH="$TMP/parked-bin:$PATH" SQUAD_EXEC_OWNER_STATE=alive "$EXEC" claim parked >/dev/null 2>&1
claim_rc=$?
set -e
assert_eq "$claim_rc" 3
assert_eq "$(PATH="$TMP/parked-bin:$PATH" "$EXEC" get-recorded parked)" retry_queued
assert_eq "$(PATH="$TMP/parked-bin:$PATH" SQUAD_EXEC_OWNER_STATE=alive "$EXEC" recover parked)" running
assert_eq "$(PATH="$TMP/parked-bin:$PATH" "$EXEC" get-recorded parked)" running

# An authoritatively gone owner: the queued retry keeps its deadline instead of
# being adopted, and the claim that resumes it succeeds.
printf 'exec_state=retry_queued\nexec_attempt=1\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/parked.exec"
assert_eq "$(PATH="$TMP/parked-bin:$PATH" SQUAD_EXEC_OWNER_STATE=dead "$EXEC" recover parked)" retry_queued
assert_eq "$(grep '^exec_next_retry_at=' "$STATE/parked.exec")" 'exec_next_retry_at=1'
assert_eq "$(PATH="$TMP/parked-bin:$PATH" SQUAD_EXEC_OWNER_STATE=dead "$EXEC" claim parked)" claimed
assert_eq "$(PATH="$TMP/parked-bin:$PATH" "$EXEC" get-recorded parked)" claimed

# An unverifiable owner read stays fail-closed so no duplicate is launched.
printf 'exec_state=retry_queued\nexec_attempt=1\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/parked.exec"
set +e
PATH="$TMP/parked-bin:$PATH" SQUAD_EXEC_OWNER_STATE=ambiguous "$EXEC" claim parked >/dev/null 2>&1
claim_rc=$?
set -e
assert_eq "$claim_rc" 3

# Adopting a live bound run is a continuation, not a new attempt: the stall's
# queued retry keeps its counter, attempt number, and pinned workflow version,
# so one stall cycle spends exactly one retry.
after_wf="$TMP/after-run-WORKFLOW.md"
mkdir -p "$TMP/project"
cat > "$after_wf" <<'EOF'
---
schema_version: "1.0.0"
hooks:
  after_run:
    command: ["bash", "-c", "printf '%s\\n' \"$EXEC_ATTEMPT\" >> attempt.log"]
    timeout_ms: 5000
---
EOF
printf 'window=sq-parked:win\nworktree=%s\nkind=strike\nworkflow=%s\nproject=%s\n' \
  "$parked_wt" "$after_wf" "$TMP/project" > "$STATE/parked.meta"
printf 'exec_state=retry_queued\nexec_attempt=2\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\nexec_workflow_version=wf-pinned\n' > "$STATE/parked.exec"
assert_eq "$(PATH="$TMP/parked-bin:$PATH" SQUAD_EXEC_OWNER_STATE=alive "$EXEC" recover parked)" running
assert_eq "$(sed -n 's/^exec_attempt=//p' "$STATE/parked.exec")" 2
assert_eq "$(sed -n 's/^exec_retry_count=//p' "$STATE/parked.exec")" 1
assert_eq "$(sed -n 's/^exec_workflow_version=//p' "$STATE/parked.exec")" wf-pinned
assert_eq "$(sed -n 's/^exec_next_retry_at=//p' "$STATE/parked.exec")" ''
assert_eq "$(PATH="$TMP/parked-bin:$PATH" "$EXEC" get-recorded parked)" running
PATH="$TMP/parked-bin:$PATH" "$EXEC" after_run parked >/dev/null
assert_eq "$(cat "$parked_wt/attempt.log")" 2

# Only a genuine fresh claim spends retry budget: the next claim moves the
# counters forward exactly once from where the adoption left them.
printf 'exec_state=retry_queued\nexec_attempt=2\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/parked.exec"
assert_eq "$(PATH="$TMP/parked-bin:$PATH" SQUAD_EXEC_OWNER_STATE=dead "$EXEC" claim parked)" claimed
assert_eq "$(sed -n 's/^exec_attempt=//p' "$STATE/parked.exec")" 3
assert_eq "$(sed -n 's/^exec_retry_count=//p' "$STATE/parked.exec")" 2

# The production endpoint read (no SQUAD_EXEC_OWNER_STATE override) resolves the
# recorded window through the backend adapter: an authoritatively absent window
# lets the queued retry resume, and a live harness in that window still blocks
# the claim.
mkdir -p "$TMP/tmux-bin"
cat > "$TMP/tmux-bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    if [ -f "${SQUAD_TEST_LIVE_WINDOW:-/nonexistent}" ]; then
      printf 'win\n'
      exit 0
    fi
    printf "can't find session: %s\n" "${3:-sq-stub}" >&2
    exit 1
    ;;
  display-message)
    case "${5:-}" in
      '#{pane_current_command}')
        if [ -f "${SQUAD_TEST_LIVE_WINDOW:-/nonexistent}" ]; then printf 'claude\n'; fi
        ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$TMP/tmux-bin/tmux"
printf 'exec_state=retry_queued\nexec_attempt=1\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/parked.exec"
assert_eq "$(PATH="$TMP/parked-bin:$TMP/tmux-bin:$PATH" "$EXEC" claim parked)" claimed
printf 'exec_state=retry_queued\nexec_attempt=1\nexec_retry_count=1\nexec_last_activity=1\nexec_next_retry_at=1\n' > "$STATE/parked.exec"
touch "$TMP/live-window"
set +e
PATH="$TMP/parked-bin:$TMP/tmux-bin:$PATH" SQUAD_TEST_LIVE_WINDOW="$TMP/live-window" "$EXEC" claim parked >/dev/null 2>&1
claim_rc=$?
set -e
assert_eq "$claim_rc" 3
assert_eq "$(PATH="$TMP/parked-bin:$TMP/tmux-bin:$PATH" SQUAD_TEST_LIVE_WINDOW="$TMP/live-window" "$EXEC" get-recorded parked)" retry_queued
rm -f "$STATE"/parked.*

# recover-all skips run attribution for a fresh running record with no terminal
# event, and still attributes one that carries a terminal event.
rm -f "$STATE"/*.exec "$STATE"/*.meta "$TMP/drill-calls.log"
mkdir -p "$TMP/probe-bin"
cat > "$TMP/probe-bin/drill" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$PWD")" "\$*" >> "$TMP/drill-calls.log"
exit 0
EOF
chmod +x "$TMP/probe-bin/drill"
probe_now=$(date +%s)
for task in probe-fresh probe-done; do
  probe_wt="$TMP/$task-wt"
  mkdir -p "$probe_wt"
  git -C "$probe_wt" init -q
  git -C "$probe_wt" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
  git -C "$probe_wt" checkout -q -b "sq/$task"
  printf 'window=Squad\nworktree=%s\nkind=strike\n' "$probe_wt" > "$STATE/$task.meta"
  printf 'exec_state=running\nexec_attempt=1\nexec_last_activity=%s\n' "$probe_now" > "$STATE/$task.exec"
done
printf 'working: still validating\n' > "$STATE/probe-fresh.status"
printf 'done: delivered\n' > "$STATE/probe-done.status"
PATH="$TMP/probe-bin:$PATH" "$EXEC" recover-all >/dev/null
assert_eq "$(PATH="$TMP/probe-bin:$PATH" "$EXEC" get-recorded probe-fresh)" running
assert_eq "$(PATH="$TMP/probe-bin:$PATH" "$EXEC" get-recorded probe-done)" released
probe_calls=$(wc -l < "$TMP/drill-calls.log" | tr -d ' ')
assert_eq "$probe_calls" 1
grep -q '^probe-done-wt ' "$TMP/drill-calls.log" || {
  echo 'recover-all attributed the wrong record' >&2
  exit 1
}

# recover-all removes orphaned exec files (meta absent) but preserves live ones.
printf 'exec_state=running\nexec_attempt=1\n' > "$STATE/orphan.exec"
printf 'window=Squad\n' > "$STATE/live-task.meta"
NOW=$(date +%s)
printf 'exec_state=claimed\nexec_attempt=2\nexec_last_activity=%s\n' "$NOW" > "$STATE/live-task.exec"
[ -f "$STATE/orphan.exec" ] || { echo 'setup: orphan.exec missing' >&2; exit 1; }
[ -f "$STATE/live-task.exec" ] || { echo 'setup: live-task.exec missing' >&2; exit 1; }
"$EXEC" recover-all >/dev/null || true
[ ! -f "$STATE/orphan.exec" ] || { echo 'fail: orphan.exec was not removed by recover-all' >&2; exit 1; }
[ -f "$STATE/live-task.exec" ] || { echo 'fail: live-task.exec was incorrectly removed by recover-all' >&2; exit 1; }
assert_eq "$("$EXEC" get live-task)" claimed

printf 'test-sq-exec-state: ok\n'
