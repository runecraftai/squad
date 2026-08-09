#!/usr/bin/env bash
# tests/sq-backend-herdr-workspace-per-home-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the P3 "workspace-per-home" pass (AGENTS.md
# task herdr-sm-spaces-k4). Drives the REAL bin/sq-spawn.sh and
# bin/sq-teardown.sh (not just adapter primitives), because the requirement
# under test - a --xo spawn's tab landing in the XO's OWN
# herdr workspace, and an operator spawned FROM an XO home landing there
# too - only exists at sq-spawn.sh's own home-shadowing logic (the herdr case
# arm) and at fm_backend_herdr_workspace_label's SQUAD_HOME read; neither is
# exercised by the adapter-primitive smoke test.
#
# Mirrors tests/sq-backend-autodetect-smoke.test.sh's isolated-session
# convention: a private throwaway HERDR_SESSION (never the commander's
# default), scratch SQUAD_HOME(s), and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers, at minimum (per the task brief):
#   - a primary-shaped home (no .sq-xo-home marker) spawning a
#     operator into the "Squad" workspace
#   - an XO-shaped home (with .sq-xo-home) getting its own
#     labeled workspace when the PRIMARY spawns it (sq-spawn.sh's SQUAD_HOME
#     shadow for --xo)
#   - an operator spawned FROM that XO-shaped home (the XO
#     running its OWN sq-spawn.sh) landing in the XO's own workspace -
#     this exact path has never run before this test
#   - teardown closing the right tab (and no other)
#   - list-live recovery seeing only its own home's tabs, for both homes
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}
assert_not_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v fob >/dev/null 2>&1 || { echo "skip: fob not found (required by sq-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) for the same
# low-noise scratch fixture shape used by
# tests/sq-backend-autodetect-smoke.test.sh.
# sq-spawn no longer needs this as a symlink workaround: sq-spawn-symlink-guard-s8
# canonicalized project and backend cwd comparisons in the worktree-discovery
# poll.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/sq-herdr-e2e.XXXXXX")
SESSION="sq-lab-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
WT1=; WT2=
cleanup_all() {
  [ -n "$WT1" ] && command -v fob >/dev/null 2>&1 && fob return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v fob >/dev/null 2>&1 && fob return --force "$WT2" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/sq-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: a primary-shaped home, an XO-shaped home, two projects ---

# This test asserts the per-home FLAT workspace shape, so both homes opt out of
# the default-on presentation projection rather than depending on that default.
PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/cm1" "$PRIMARY_HOME/config"
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
printf 'trivial e2e primary operator brief: nothing to do.\n' > "$PRIMARY_HOME/data/cm1/brief.md"

SM_HOME="$TMP_ROOT/XO-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/cm2" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf 'off\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch XO home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.sq-xo-home"
printf 'trivial e2e XO charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
printf 'trivial e2e XO-owned operator brief: nothing to do.\n' > "$SM_HOME/data/cm2/brief.md"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Squad Tests' -c user.email='tests@example.invalid' commit -qm initial
}

PROJ1="$TMP_ROOT/scratch-project-1"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/scratch-project-2"; make_scratch_project "$PROJ2"

# --- 1. primary-shaped home: an operator spawns into the "Squad" space ---

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
SQUAD_SPAWN_NO_GUARD=1 SQUAD_HOME="$PRIMARY_HOME" SQUAD_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/sq-spawn.sh" cm1 "$PROJ1" "sh -c 'echo primary-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "primary-shaped operator spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"

CM1_META="$PRIMARY_HOME/state/cm1.meta"
[ -f "$CM1_META" ] || fail "no meta written for cm1"
assert_contains_local "$(cat "$CM1_META")" "backend=herdr" "cm1 meta missing backend=herdr"
WT1=$(grep '^worktree=' "$CM1_META" | cut -d= -f2-)
CM1_PANE=$(grep '^herdr_pane_id=' "$CM1_META" | cut -d= -f2-)
[ -n "$CM1_PANE" ] || fail "cm1 meta missing herdr_pane_id"
pass "real herdr E2E: a primary-shaped home spawns an operator on the herdr backend"

sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) || fail "capture failed on cm1's pane"
assert_contains_local "$CM1_CAPTURE" "primary-crew-ok" "cm1's raw launch command did not run in its herdr pane"

CM1_WSID=$(herdr pane get "$CM1_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$CM1_WSID" ] || fail "could not read cm1's pane workspace_id"
CM1_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$CM1_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$CM1_WS_LABEL" = "Squad" ] || fail "a primary-shaped home's operator should land in the 'Squad' workspace, got '$CM1_WS_LABEL'"
pass "real herdr E2E: the primary-shaped home's operator landed in the 'Squad' workspace"

# --- 2. the PRIMARY spawns an XO: its tab lands in the XO's own space ---
# (sq-spawn.sh's herdr case arm shadows SQUAD_HOME to the XO's home for
# exactly this call - AGENTS.md task herdr-sm-spaces-k4, requirement 3.)

SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
SQUAD_SPAWN_NO_GUARD=1 SQUAD_HOME="$PRIMARY_HOME" SQUAD_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/sq-spawn.sh" e2esm1 "$SM_HOME" "sh -c 'echo XO-launch-ok'" --xo --backend herdr \
  >"$SM_OUT" 2>"$SM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "the primary's --xo spawn of e2esm1 failed"$'\n'"--- stdout ---"$'\n'"$(cat "$SM_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$SM_ERR")"

SM_META="$PRIMARY_HOME/state/e2esm1.meta"
[ -f "$SM_META" ] || fail "no meta written for e2esm1 (recorded in the PRIMARY's own state dir, since the primary did the spawning)"
assert_contains_local "$(cat "$SM_META")" "kind=xo" "e2esm1 meta missing kind=xo"
assert_contains_local "$(cat "$SM_META")" "backend=herdr" "e2esm1 meta missing backend=herdr"
assert_contains_local "$(cat "$SM_META")" "home=$SM_HOME" "e2esm1 meta does not record its own home"
SM_PANE=$(grep '^herdr_pane_id=' "$SM_META" | cut -d= -f2-)
[ -n "$SM_PANE" ] || fail "e2esm1 meta missing herdr_pane_id"
pass "real herdr E2E: the primary spawns a --xo task on the herdr backend"

SM_WSID=$(herdr pane get "$SM_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ -n "$SM_WSID" ] || fail "could not read e2esm1's pane workspace_id"
[ "$SM_WSID" != "$CM1_WSID" ] || fail "the XO's tab must NOT land in the primary's workspace, but it shares $CM1_WSID"
SM_WS_LABEL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$SM_WS_LABEL" = "2ndmate-e2esm1" ] || fail "a --xo spawn should land in '2ndmate-<id>', got '$SM_WS_LABEL'"
pass "real herdr E2E: a --xo spawn by the PRIMARY lands in the XO's own labeled workspace, distinct from the primary's"

# --- 3. an operator spawned FROM the XO-shaped home lands in the SAME
# XO workspace (this exact path has never run before this test) -----

CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
SQUAD_SPAWN_NO_GUARD=1 SQUAD_HOME="$SM_HOME" SQUAD_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/sq-spawn.sh" cm2 "$PROJ2" "sh -c 'echo sm-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "an operator spawned FROM the XO-shaped home failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM2_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM2_ERR")"

CM2_META="$SM_HOME/state/cm2.meta"
[ -f "$CM2_META" ] || fail "no meta written for cm2 (recorded in the XO's own state dir - it did its own spawning)"
assert_contains_local "$(cat "$CM2_META")" "backend=herdr" "cm2 meta missing backend=herdr"
WT2=$(grep '^worktree=' "$CM2_META" | cut -d= -f2-)
CM2_PANE=$(grep '^herdr_pane_id=' "$CM2_META" | cut -d= -f2-)
[ -n "$CM2_PANE" ] || fail "cm2 meta missing herdr_pane_id"
pass "real herdr E2E: an operator spawns successfully FROM an XO-shaped home's own sq-spawn.sh process"

sleep 1
CM2_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM2_PANE" 30) || fail "capture failed on cm2's pane"
assert_contains_local "$CM2_CAPTURE" "sm-crew-ok" "cm2's raw launch command did not run in its herdr pane"

CM2_WSID=$(herdr pane get "$CM2_PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
[ "$CM2_WSID" = "$SM_WSID" ] || fail "an operator spawned FROM the XO home should land in the SAME workspace as the XO's own task ($SM_WSID), got '$CM2_WSID'"
[ "$CM2_WSID" != "$CM1_WSID" ] || fail "an operator spawned FROM the XO home must NOT land in the primary's workspace"
pass "real herdr E2E: an operator spawned FROM the XO-shaped home lands in the XO's OWN workspace - falls out of per-home resolution, no glue needed"

# --- 4. list-live recovery: each home sees only its own tabs ---------------

PRIMARY_LIVE=$(SQUAD_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_LIVE" "sq-cm1" "the primary home's list_live did not see its own task"
assert_not_contains_local "$PRIMARY_LIVE" "sq-e2esm1" "the primary home's list_live must not see the XO's own task"
assert_not_contains_local "$PRIMARY_LIVE" "sq-cm2" "the primary home's list_live must not see the XO-owned operator's task"
pass "real herdr E2E: list_live from the primary's own context sees only the primary's own task"

SM_LIVE=$(SQUAD_HOME="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$SM_LIVE" "sq-e2esm1" "the XO home's list_live did not see its own task"
assert_contains_local "$SM_LIVE" "sq-cm2" "the XO home's list_live did not see the operator spawned from it"
assert_not_contains_local "$SM_LIVE" "sq-cm1" "the XO home's list_live must not see the primary's task"
pass "real herdr E2E: list_live from the XO's own context sees only tasks in the XO's own workspace (both its own tab and its operator's)"

# --- 5. teardown closes the RIGHT tab, and no other ------------------------

TD1_OUT="$TMP_ROOT/td1.out"
SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_STATE_OVERRIDE="$PRIMARY_HOME/state" SQUAD_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  SQUAD_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/sq-teardown.sh" cm1 >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "sq-teardown.sh failed for the primary-shaped operator cm1"$'\n'"$(cat "$TD1_OUT")"
[ -f "$CM1_META" ] && fail "sq-teardown.sh did not remove cm1's meta"
if herdr pane get "$CM1_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "sq-teardown.sh did not close cm1's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed the XO's OWN pane (wrong tab closed)"
fi
if ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm1 must not have closed cm2's pane (wrong tab closed)"
fi
WT1=
pass "real herdr E2E: tearing down cm1 closes only its own tab - the XO's and cm2's tabs survive untouched"

TD2_OUT="$TMP_ROOT/td2.out"
SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_STATE_OVERRIDE="$SM_HOME/state" SQUAD_DATA_OVERRIDE="$SM_HOME/data" \
  SQUAD_CONFIG_OVERRIDE="$SM_HOME/config" \
  "$ROOT/bin/sq-teardown.sh" cm2 >"$TD2_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "sq-teardown.sh failed for the XO-owned operator cm2"$'\n'"$(cat "$TD2_OUT")"
[ -f "$CM2_META" ] && fail "sq-teardown.sh did not remove cm2's meta"
if herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "sq-teardown.sh did not close cm2's pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down cm2 must not have closed the XO's OWN pane (wrong tab closed)"
fi
WT2=
pass "real herdr E2E: tearing down cm2 closes only its own tab - the XO's own tab (same workspace) survives untouched"

fm_backend_herdr_kill "$SESSION:$SM_PANE"

cleanup_all
trap - EXIT
