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
assert_eq "$("$EXEC" claim task)" claimed
assert_eq "$("$EXEC" running task)" running
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
