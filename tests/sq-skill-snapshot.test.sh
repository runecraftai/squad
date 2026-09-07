#!/usr/bin/env bash
# Behavior tests for sq-skill-snapshot.sh and sq-skill-rollback.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/sq-skill-snapshot.sh"
ROLLBACK="$ROOT/bin/sq-skill-rollback.sh"
TMP_ROOT=$(fm_test_tmproot sq-skill-snapshot)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

make_fixture() {
  local base=$TMP_ROOT/$1
  mkdir -p "$base/data" "$base/.agents/skills/testskill"
  printf '# Test Skill\n\nA test skill.\n' > "$base/.agents/skills/testskill/SKILL.md"
  printf 'extra file\n' > "$base/.agents/skills/testskill/extra.txt"
  printf '%s\n' "$base"
}

run_snap() {
  local base=$1
  shift
  SQUAD_BASE="$base" SQUAD_ROOT_OVERRIDE="$ROOT" \
    SQUAD_DATA_OVERRIDE="$base/data" \
    "$SNAPSHOT" "$@"
}

run_rollback() {
  local base=$1
  shift
  SQUAD_BASE="$base" SQUAD_ROOT_OVERRIDE="$ROOT" \
    SQUAD_DATA_OVERRIDE="$base/data" \
    "$ROLLBACK" "$@"
}

# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------

test_snapshot_creates_directory_and_manifest() {
  local base out snap_dir
  base=$(make_fixture snap-basic)
  out=$(run_snap "$base" testskill)
  assert_contains "$out" "snapshot created" "snapshot did not report success"

  snap_dir=$(find "$base/data/skill-snapshots/testskill" -mindepth 1 -maxdepth 1 -type d | head -1)
  assert_present "$snap_dir/SKILL.md" "SKILL.md not in snapshot"
  assert_present "$snap_dir/extra.txt" "extra.txt not in snapshot"
  assert_present "$snap_dir/manifest.tsv" "manifest.tsv not in snapshot"
  assert_present "$snap_dir/metadata.json" "metadata.json not in snapshot"
  assert_grep "SKILL.md" "$snap_dir/manifest.tsv" "SKILL.md not in manifest"
  assert_grep "extra.txt" "$snap_dir/manifest.tsv" "extra.txt not in manifest"
  pass "snapshot creates directory with files, manifest, and metadata"
}

test_snapshot_dedup_on_identical_content() {
  local base out1 out2
  base=$(make_fixture snap-dedup)
  out1=$(run_snap "$base" testskill)
  assert_contains "$out1" "snapshot created" "first snapshot did not succeed"

  # Snapshot again without changes.
  out2=$(run_snap "$base" testskill)
  assert_contains "$out2" "no changes since last snapshot" "identical snapshot was not skipped"

  # Only one snapshot directory should exist.
  count=$(find "$base/data/skill-snapshots/testskill" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "expected 1 snapshot after dedup, got $count"
  pass "identical snapshot is skipped via hash dedup"
}

test_snapshot_dedup_on_different_content() {
  local base out1 out2
  base=$(make_fixture snap-dedup-change)
  out1=$(run_snap "$base" testskill)
  assert_contains "$out1" "snapshot created" "first snapshot did not succeed"

  # Modify the skill.
  sleep 1
  printf 'modified\n' > "$base/.agents/skills/testskill/SKILL.md"

  out2=$(run_snap "$base" testskill)
  assert_contains "$out2" "snapshot created" "modified snapshot was not created"

  count=$(find "$base/data/skill-snapshots/testskill" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "expected 2 snapshots after change, got $count"
  pass "modified skill creates a new snapshot"
}

test_snapshot_prunes_oldest() {
  local base snap_dir i
  base=$(make_fixture snap-prune)
  for i in $(seq 1 12); do
    printf "version %d\n" "$i" > "$base/.agents/skills/testskill/SKILL.md"
    sleep 1
    run_snap "$base" testskill >/dev/null
  done

  count=$(find "$base/data/skill-snapshots/testskill" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$count" = 10 ] || fail "expected 10 snapshots after pruning, got $count"

  # Newest snapshot should have the last version.
  snap_dir=$(find "$base/data/skill-snapshots/testskill" -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)
  assert_grep "version 12" "$snap_dir/SKILL.md" "newest snapshot does not have latest version"
  pass "oldest snapshots are pruned when exceeding max"
}

test_snapshot_rejects_missing_skill() {
  local base out
  base=$(make_fixture snap-missing)
  set +e
  out=$(run_snap "$base" nonexistent 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing skill did not cause error"
  assert_contains "$out" "skill not found" "error message did not mention skill not found"
  pass "missing skill name is rejected with error"
}

test_rollback_restores_files() {
  local base snap_dir
  base=$(make_fixture snap-restore)
  run_snap "$base" testskill >/dev/null

  # Modify the skill.
  printf 'new version\n' > "$base/.agents/skills/testskill/SKILL.md"
  rm -f "$base/.agents/skills/testskill/extra.txt"

  # Get the snapshot timestamp.
  snap_dir=$(find "$base/data/skill-snapshots/testskill" -mindepth 1 -maxdepth 1 -type d | head -1)
  ts=$(basename "$snap_dir")

  out=$(run_rollback "$base" testskill "$ts")
  assert_contains "$out" "restored testskill" "rollback did not report restoration"
  assert_contains "$out" "SKILL.md" "restored file list missing SKILL.md"
  assert_contains "$out" "extra.txt" "restored file list missing extra.txt"

  # Verify the skill directory was restored.
  assert_grep "A test skill" "$base/.agents/skills/testskill/SKILL.md" "SKILL.md was not restored"
  assert_present "$base/.agents/skills/testskill/extra.txt" "extra.txt was not restored"
  pass "rollback restores files from specified snapshot"
}

test_rollback_rejects_missing_snapshot() {
  local base out
  base=$(make_fixture snap-rollback-miss)
  run_snap "$base" testskill >/dev/null

  set +e
  out=$(run_rollback "$base" testskill "20990101T000000" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing snapshot did not cause error"
  assert_contains "$out" "snapshot not found" "error did not mention snapshot not found"
  assert_contains "$out" "available snapshots" "error did not list available snapshots"
  pass "rollback with missing snapshot shows error and available options"
}

test_rollback_rejects_no_snapshots() {
  local base out
  base=$(make_fixture snap-rollback-empty)

  set +e
  out=$(run_rollback "$base" testskill "20250101T000000" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "no snapshots did not cause error"
  assert_contains "$out" "no snapshots found" "error did not mention no snapshots"
  pass "rollback with no snapshots at all shows error"
}

test_rollback_rejects_missing_skill() {
  local base out
  base=$(make_fixture snap-rollback-noskill)

  set +e
  out=$(run_rollback "$base" ghostskill "20250101T000000" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing skill did not cause error"
  assert_contains "$out" "skill not found" "error did not mention skill not found"
  pass "rollback for nonexistent skill is rejected"
}

test_public_skill_snapshot() {
  local base snap_dir
  base=$(make_fixture snap-public)
  mkdir -p "$base/skills/pubskill"
  printf '# Public Skill\n' > "$base/skills/pubskill/SKILL.md"

  out=$(run_snap "$base" pubskill)
  assert_contains "$out" "snapshot created" "public skill snapshot did not succeed"

  snap_dir=$(find "$base/data/skill-snapshots/pubskill" -mindepth 1 -maxdepth 1 -type d | head -1)
  assert_present "$snap_dir/SKILL.md" "SKILL.md not in public skill snapshot"
  pass "snapshot works for skills/ public directory"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

test_snapshot_creates_directory_and_manifest
test_snapshot_dedup_on_identical_content
test_snapshot_dedup_on_different_content
test_snapshot_prunes_oldest
test_snapshot_rejects_missing_skill
test_rollback_restores_files
test_rollback_rejects_missing_snapshot
test_rollback_rejects_no_snapshots
test_rollback_rejects_missing_skill
test_public_skill_snapshot
