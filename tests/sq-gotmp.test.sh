#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (sq-gotmp).
#
# sq-spawn gives each task a temp root /tmp/sq-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the operator pane, and records tasktmp= in the task's
# meta. sq-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise sq-teardown directly as a subprocess against a fake SQUAD_HOME/SQUAD_ROOT
# built so the real script resolves into it, with stub helper scripts.
# The isolated sq-spawn subprocess in sq-kimi-harness.test.sh covers temp-root creation,
# metadata publication, and the pane environment export.
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/sq-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export SQUAD_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/sq-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sq-gotmp-tests.XXXXXX")

# Build a fake SQUAD_HOME/SQUAD_ROOT so the real sq-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts sq-teardown calls so no
# live tmux/fob/unit state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/sq-teardown.sh"
  # sq-backend.sh + its tmux adapter: symlink the REAL files (teardown sources
  # sq-backend.sh unconditionally, and dispatches the kill call through the
  # tmux adapter; both are unchanged by this suite's fixture, just newly
  # required siblings since the P1 backend extraction).
  ln -s "$ROOT/bin/sq-backend.sh" "$fake/bin/sq-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/sq-tmux-lib.sh" "$fake/bin/sq-tmux-lib.sh"
  ln -s "$ROOT/bin/sq-composer-lib.sh" "$fake/bin/sq-composer-lib.sh"
  ln -s "$ROOT/bin/sq-nm-run-lib.sh" "$fake/bin/sq-nm-run-lib.sh"
  # sq-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/sq-lock-lib.sh" "$fake/bin/sq-lock-lib.sh"
  # sq-gate-refuse-lib.sh: teardown sources it before any unit mutation.
  ln -s "$ROOT/bin/sq-gate-refuse-lib.sh" "$fake/bin/sq-gate-refuse-lib.sh"
  # sq-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/sq-pr-lib.sh" "$fake/bin/sq-pr-lib.sh"
  # sq-public-followup-lib.sh (and the sq-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/sq-public-followup-lib.sh" "$fake/bin/sq-public-followup-lib.sh"
  ln -s "$ROOT/bin/sq-x-lib.sh" "$fake/bin/sq-x-lib.sh"
  ln -s "$ROOT/bin/sq-xo-registry-lib.sh" "$fake/bin/sq-xo-registry-lib.sh"
  ln -s "$ROOT/bin/sq-xo-parent-lib.sh" "$fake/bin/sq-xo-parent-lib.sh"
  # sq-stand-to-lib.sh: teardown sources it for serialized XO lifecycle locks.
  ln -s "$ROOT/bin/sq-stand-to-lib.sh" "$fake/bin/sq-stand-to-lib.sh"
  # sq-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/sq-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/sq-guard.sh"
  # sq-unit-sync.sh: stub (called for non-recon/non-local-only teardowns).
  cat > "$fake/bin/sq-unit-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/sq-unit-sync.sh"
  # sq-tasks-lib.sh: stub (teardown sources it). Report no backend so
  # backlog_refresh_reminder takes the plain-message path; no tasks-axi here.
  cat > "$fake/bin/sq-tasks-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  # Meta with a nonexistent worktree so the dirty/fob blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:sq-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=strike
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- sq-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/sq-$id"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  SQUAD_HOME="$fake" bash "$fake/bin/sq-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "sq-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state"
  ln -s "$TEARDOWN" "$fake/bin/sq-teardown.sh"
  ln -s "$ROOT/bin/sq-backend.sh" "$fake/bin/sq-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/sq-tmux-lib.sh" "$fake/bin/sq-tmux-lib.sh"
  ln -s "$ROOT/bin/sq-composer-lib.sh" "$fake/bin/sq-composer-lib.sh"
  ln -s "$ROOT/bin/sq-nm-run-lib.sh" "$fake/bin/sq-nm-run-lib.sh"
  ln -s "$ROOT/bin/sq-lock-lib.sh" "$fake/bin/sq-lock-lib.sh"
  # sq-gate-refuse-lib.sh: teardown sources it before any unit mutation.
  ln -s "$ROOT/bin/sq-gate-refuse-lib.sh" "$fake/bin/sq-gate-refuse-lib.sh"
  # sq-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/sq-pr-lib.sh" "$fake/bin/sq-pr-lib.sh"
  # sq-public-followup-lib.sh (and the sq-x-lib.sh it sources): teardown sources
  # it for the relay-activation gate on the promised-public-reply check. Neither
  # does anything in this fixture, which has no .env, but both are real siblings
  # teardown now requires.
  ln -s "$ROOT/bin/sq-public-followup-lib.sh" "$fake/bin/sq-public-followup-lib.sh"
  ln -s "$ROOT/bin/sq-x-lib.sh" "$fake/bin/sq-x-lib.sh"
  ln -s "$ROOT/bin/sq-xo-registry-lib.sh" "$fake/bin/sq-xo-registry-lib.sh"
  ln -s "$ROOT/bin/sq-xo-parent-lib.sh" "$fake/bin/sq-xo-parent-lib.sh"
  ln -s "$ROOT/bin/sq-stand-to-lib.sh" "$fake/bin/sq-stand-to-lib.sh"
  cat > "$fake/bin/sq-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/sq-guard.sh"
  cat > "$fake/bin/sq-unit-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/sq-unit-sync.sh"
  cat > "$fake/bin/sq-tasks-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:sq-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=strike
mode=no-mistakes
yolo=off
META
  SQUAD_HOME="$fake" bash "$fake/bin/sq-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "sq-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-sq-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  SQUAD_HOME="$fake" bash "$fake/bin/sq-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "sq-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
