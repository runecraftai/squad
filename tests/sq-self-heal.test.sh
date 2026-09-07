#!/usr/bin/env bash
# Behavior tests for sq-self-heal.sh
#
# Covers all five capabilities:
#   1. Stale worktree detection
#   2. Orphan status log cleanup
#   3. Broken symlink detection
#   4. Lock file cleanup
#   5. Learnings file repair
#
# Tests: detection scenarios, dry-run output, apply behavior, idempotency.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-self-heal-tests)
HEAL_BIN="$ROOT/bin/sq-self-heal.sh"
TEST_COUNT=0

# Helper: run sq-self-heal.sh with a custom SQUAD_BASE
run_heal() {
  local base=$1
  shift
  SQUAD_BASE="$base" "$HEAL_BIN" "$@"
}

# Helper: set up a minimal base directory structure
make_base() {
  local base=$1
  mkdir -p "$base"/{state,bin,data/.agents/skills,projects}
}

# === Capability 1: Stale worktree detection =================================

test_stale_worktree_dirty_detection() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/stale-wt-dirty"
  make_base "$base"

  # Create a repo with a worktree
  local repo="$base/projects/testrepo"
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b feature-wt "$base/state/wt-feature" 2>/dev/null
  # Make the worktree dirty
  echo "dirty" > "$base/state/wt-feature/dirty.txt"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "dirty worktree" "should detect dirty worktree"
}

test_stale_worktree_missing_path_detection() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/stale-wt-missing"
  make_base "$base"

  local repo="$base/projects/testrepo"
  fm_git_init_commit "$repo"
  # Create a worktree, then remove the working directory
  git -C "$repo" worktree add --quiet -b orphan-wt "$base/state/wt-orphan" 2>/dev/null
  rm -rf "$base/state/wt-orphan"

  # The worktree entry still exists in git's metadata but the path is gone
  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "stale worktree" "should detect missing worktree path"
}

test_stale_worktree_clean() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/stale-wt-clean"
  make_base "$base"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_not_contains "$output" "stale worktree:" "no repos = no stale worktree issue"
  assert_not_contains "$output" "dirty worktree:" "no repos = no dirty worktree issue"
}

# === Capability 2: Orphan status log cleanup =================================

test_orphan_status_detection() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/orphan-status"
  make_base "$base"

  # Create an orphan status file (no matching .meta)
  echo "working: doing stuff" > "$base/state/orphan-task.status"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "orphan status log:" "should detect orphan status file"
}

test_orphan_status_not_triggered_with_meta() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/orphan-status-meta"
  make_base "$base"

  echo "working: doing stuff" > "$base/state/real-task.status"
  echo "window=Squad:sq-real-task" > "$base/state/real-task.meta"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_not_contains "$output" "orphan status log:" "status+meta pair should not be orphan"
}

test_orphan_status_apply() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/orphan-status-apply"
  make_base "$base"

  echo "working: old stuff" > "$base/state/old-task.status"

  run_heal "$base" --apply >/dev/null 2>&1

  assert_absent "$base/state/old-task.status" "status file should be moved"
  assert_present "$base/state/archived/old-task.status" "status file should be archived"
}

test_orphan_status_dry_run_no_move() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/orphan-status-dryrun"
  make_base "$base"

  echo "working: stuff" > "$base/state/dry-task.status"

  run_heal "$base" >/dev/null 2>&1

  assert_present "$base/state/dry-task.status" "dry-run should not move files"
  assert_absent "$base/state/archived" "dry-run should not create archive dir"
}

test_orphan_status_idempotent() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/orphan-status-idem"
  make_base "$base"

  echo "working: first" > "$base/state/idem1.status"
  echo "working: second" > "$base/state/idem2.status"

  run_heal "$base" --apply >/dev/null 2>&1
  run_heal "$base" --apply >/dev/null 2>&1

  assert_absent "$base/state/idem1.status" "first apply removed it"
  assert_absent "$base/state/idem2.status" "second apply is no-op"
  assert_present "$base/state/archived/idem1.status" "archived correctly"
}

# === Capability 3: Broken symlink detection =================================

test_broken_symlink_detection() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/broken-symlink"
  make_base "$base"

  # Create a broken symlink in bin/
  ln -sf /nonexistent/path "$base/bin/broken-link"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "broken symlink" "should detect broken symlink"
}

test_broken_symlink_not_triggered_when_valid() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/good-symlink"
  make_base "$base"

  # Create a valid symlink
  ln -sf /bin/sh "$base/bin/good-link"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_not_contains "$output" "broken symlink:" "valid symlink should not be flagged"
}

test_broken_symlink_in_skills() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/broken-symlink-skills"
  mkdir -p "$base"/{state,bin,data,projects,.agents/skills}

  ln -sf /nonexistent "$base/.agents/skills/missing-skill"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "broken symlink" "should detect broken symlink in skills"
}

# === Capability 4: Lock file cleanup ========================================

test_stale_lock_detection() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/stale-lock"
  make_base "$base"

  # Create a lock file and backdate it to 2 hours ago
  touch "$base/state/.sentry.lock"
  local two_hours_ago
  two_hours_ago=$(date -d '2 hours ago' +%s 2>/dev/null || date -v-2H +%s 2>/dev/null)
  touch -t "$(date -d @"$two_hours_ago" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$two_hours_ago" +%Y%m%d%H%M.%S 2>/dev/null)" "$base/state/.sentry.lock" 2>/dev/null || \
    TZ=UTC touch -d "@$two_hours_ago" "$base/state/.sentry.lock" 2>/dev/null || true

  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "stale lock" "should detect stale lock"
}

test_stale_lock_not_triggered_when_recent() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/fresh-lock"
  make_base "$base"

  # Create a recent lock file (just touched)
  touch "$base/state/.sentry.lock"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_not_contains "$output" "stale lock:" "recent lock should not be flagged"
}

test_stale_lock_apply() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/stale-lock-apply"
  make_base "$base"

  # Create a lock and backdate it
  touch "$base/state/.handoff-queue.lock"
  local two_hours_ago
  two_hours_ago=$(date -d '2 hours ago' +%s 2>/dev/null || date -v-2H +%s 2>/dev/null)
  TZ=UTC touch -d "@$two_hours_ago" "$base/state/.handoff-queue.lock" 2>/dev/null || true

  run_heal "$base" --apply >/dev/null 2>&1

  assert_absent "$base/state/.handoff-queue.lock" "stale lock should be removed"
}

test_stale_lock_dry_run_no_remove() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/stale-lock-dryrun"
  make_base "$base"

  touch "$base/state/.sentry.lock"
  local two_hours_ago
  two_hours_ago=$(date -d '2 hours ago' +%s 2>/dev/null || date -v-2H +%s 2>/dev/null)
  TZ=UTC touch -d "@$two_hours_ago" "$base/state/.sentry.lock" 2>/dev/null || true

  run_heal "$base" >/dev/null 2>&1

  assert_present "$base/state/.sentry.lock" "dry-run should not remove locks"
}

test_stale_lock_idempotent() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/stale-lock-idem"
  make_base "$base"

  touch "$base/state/.sentry.lock"
  local two_hours_ago
  two_hours_ago=$(date -d '2 hours ago' +%s 2>/dev/null || date -v-2H +%s 2>/dev/null)
  TZ=UTC touch -d "@$two_hours_ago" "$base/state/.sentry.lock" 2>/dev/null || true

  run_heal "$base" --apply >/dev/null 2>&1
  run_heal "$base" --apply >/dev/null 2>&1

  assert_absent "$base/state/.sentry.lock" "first apply removes it"
}

# === Capability 5: Learnings file repair ====================================

test_empty_learnings_detection() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/empty-learnings"
  make_base "$base"

  : > "$base/data/learnings.md"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "empty learnings" "should detect empty learnings"
}

test_corrupted_learnings_detection() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/corrupt-learnings"
  make_base "$base"

  printf '\x00\x01\x02\x03' > "$base/data/learnings.md"

  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "corrupted learnings" "should detect corrupted learnings"
}

test_valid_learnings_not_flagged() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/valid-learnings"
  make_base "$base"

  cat > "$base/data/learnings.md" <<'EOF'
# Operational Learnings

- First lesson learned.
EOF

  local output
  output=$(run_heal "$base" 2>&1)
  assert_not_contains "$output" "empty learnings:" "valid learnings should not be flagged"
  assert_not_contains "$output" "corrupted learnings:" "valid learnings should not be flagged"
}

test_learnings_apply_from_backup() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/learnings-backup"
  make_base "$base"

  # Write backup, then corrupt the main file
  cat > "$base/data/learnings.md.bak" <<'EOF'
# Operational Learnings

- This is the backup.
EOF
  : > "$base/data/learnings.md"

  run_heal "$base" --apply >/dev/null 2>&1

  # Verify restored from backup
  grep -q "backup" "$base/data/learnings.md" || fail "should restore from backup"
  assert_present "$base/data/learnings.md.bak" "backup should still exist"
}

test_learnings_apply_scaffold() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/learnings-scaffold"
  make_base "$base"

  # No backup, empty file
  : > "$base/data/learnings.md"

  run_heal "$base" --apply >/dev/null 2>&1

  # Should have recreated with scaffold
  head -1 "$base/data/learnings.md" | grep -qE '^#' || fail "should have scaffold header"
}

test_learnings_idempotent() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/learnings-idem"
  make_base "$base"

  : > "$base/data/learnings.md"

  run_heal "$base" --apply >/dev/null 2>&1
  run_heal "$base" --apply >/dev/null 2>&1

  head -1 "$base/data/learnings.md" | grep -qE '^#' || fail "should remain valid after two runs"
}

# === Check mode =============================================================

test_check_mode_clean() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/check-clean"
  make_base "$base"

  local exit_code=0
  run_heal "$base" --check >/dev/null 2>&1 || exit_code=$?
  expect_code 0 "$exit_code" "clean base should exit 0"
}

test_check_mode_dirty() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/check-dirty"
  make_base "$base"

  echo "orphan" > "$base/state/orphan.status"

  local exit_code=0
  run_heal "$base" --check >/dev/null 2>&1 || exit_code=$?
  expect_code 1 "$exit_code" "base with issues should exit 1"
}

# === Usage / argument handling ==============================================

test_help_flag() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local output
  output=$("$HEAL_BIN" --help 2>&1)
  assert_contains "$output" "Usage" "should print usage"
}

test_invalid_flag() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local exit_code=0
  "$HEAL_BIN" --bogus >/dev/null 2>&1 || exit_code=$?
  expect_code 1 "$exit_code" "invalid flag should exit 1"
}

# === Projects directory not touched =========================================

test_projects_never_modified() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/projects-safe"
  make_base "$base"

  # Create something in projects that shouldn't be touched
  mkdir -p "$base/projects/myproject"
  echo "important" > "$base/projects/myproject/data.txt"

  # Also create orphan status files
  echo "old" > "$base/state/abandoned.status"

  run_heal "$base" --apply >/dev/null 2>&1

  assert_present "$base/projects/myproject/data.txt" "projects/ should never be modified"
}

# === No state directory edge case ===========================================

test_no_state_dir() {
  TEST_COUNT=$((TEST_COUNT + 1))
  local base="$TMP_ROOT/no-state"
  mkdir -p "$base"/{bin,data,projects}

  local output
  output=$(run_heal "$base" 2>&1)
  assert_contains "$output" "all clean" "base with no state/ should be clean"
}

# === Run all tests ==========================================================

test_stale_worktree_dirty_detection
test_stale_worktree_missing_path_detection
test_stale_worktree_clean

test_orphan_status_detection
test_orphan_status_not_triggered_with_meta
test_orphan_status_apply
test_orphan_status_dry_run_no_move
test_orphan_status_idempotent

test_broken_symlink_detection
test_broken_symlink_not_triggered_when_valid
test_broken_symlink_in_skills

test_stale_lock_detection
test_stale_lock_not_triggered_when_recent
test_stale_lock_apply
test_stale_lock_dry_run_no_remove
test_stale_lock_idempotent

test_empty_learnings_detection
test_corrupted_learnings_detection
test_valid_learnings_not_flagged
test_learnings_apply_from_backup
test_learnings_apply_scaffold
test_learnings_idempotent

test_check_mode_clean
test_check_mode_dirty

test_help_flag
test_invalid_flag

test_projects_never_modified
test_no_state_dir

printf 'all %d self-heal tests passed\n' "$TEST_COUNT"
