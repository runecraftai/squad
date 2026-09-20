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
