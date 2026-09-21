#!/usr/bin/env bash
# Tests for sq-learnings-consolidate.sh — dedup, age-based stale removal, archive, trim, backup, dry-run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSOLIDATE="$ROOT/bin/sq-learnings-consolidate.sh"
TMP_ROOT=$(fm_test_tmproot sq-learnings-consolidate)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

make_learnings() {
  local file=$1
  shift
  : > "$file"
  printf '# Learnings (home-local)\n\n' > "$file"
  while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" >> "$file"
    shift
  done
}

run_consolidate() {
  local home=$1
  shift
  SQUAD_BASE="$home" SQUAD_ROOT_OVERRIDE="$ROOT" \
    SQUAD_DATA_OVERRIDE="$home/data" \
    "$CONSOLIDATE" "$@"
}

# --- duplicate detection ----------------------------------------------------

test_exact_duplicate_removal() {
  local home output
  home=$(make_home dedup-exact)
  make_learnings "$home/data/learnings.md" \
    '- **Test lesson (2026-09-01):** This is a test lesson about something useful.' \
    '- **Test lesson (2026-09-01):** This is a test lesson about something useful.'

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "Entries to remove: 1" "should detect one duplicate"
  assert_contains "$output" "duplicate of entry" "should label as duplicate"
  pass "exact duplicates are detected"
}

test_near_duplicate_removal() {
  local home output
  home=$(make_home dedup-near)
  # These share >80% contiguous content
  make_learnings "$home/data/learnings.md" \
    '- **Drill note (2026-09-01):** Operators must never edit drill config or restart the shared daemon.' \
    '- **Drill note (2026-09-02):** Operators must never edit drill config or restart the shared daemon; report issues as blockers.'

  output=$(run_consolidate "$home" 2>&1)
  # The second line should be detected as near-duplicate
  assert_contains "$output" "Entries to remove: 1" "should detect one near-duplicate"
  pass "near-duplicates (>80% overlap) are detected"
}

test_different_entries_preserved() {
  local home output
  home=$(make_home dedup-diff)
  make_learnings "$home/data/learnings.md" \
    '- **Security (2026-09-01):** Never expose secrets in code or logs.' \
    '- **Performance (2026-09-01):** Cache expensive API calls to reduce latency.'

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "No changes needed" "distinct entries should not be flagged"
  pass "distinct entries are preserved"
}

# --- age-based removal (60-day threshold) -----------------------------------

test_stale_entry_retired() {
  local home output
  home=$(make_home stale-retire)
  # Entry dated 100 days ago → should be retired
  make_learnings "$home/data/learnings.md" \
    '- **Old lesson (2025-05-28):** This lesson is old and should be retired.'

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "Entries to remove: 1" "should remove stale entry"
  assert_contains "$output" "stale" "should label as stale"
  pass "entries >= 60 days old are retired"
}

test_recent_entry_preserved() {
  local home output
  home=$(make_home stale-recent)
  make_learnings "$home/data/learnings.md" \
    '- **Recent lesson (2026-09-01):** This is recent and should stay.'

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "No changes needed" "recent entries should not be removed"
  pass "entries < 60 days old are preserved"
}

test_undated_entry_exempt() {
  local home output
  home=$(make_home stale-undated)
  make_learnings "$home/data/learnings.md" \
    '- **No date entry:** This has no date and should be exempt from retirement.'

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "No changes needed" "undated entries should be exempt"
  pass "undated entries are exempt from age-based retirement"
}

test_boundary_entry_exactly_60_days() {
  local home output
  home=$(make_home stale-boundary)
  # Entry dated exactly 60 days ago should be retired
  local sixty_days_ago
  sixty_days_ago=$(date -d '60 days ago' '+%Y-%m-%d')
  make_learnings "$home/data/learnings.md" \
    "- **Boundary lesson ($sixty_days_ago):** Entry at exactly the 60-day boundary."

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "Entries to remove: 1" "entries at exactly 60 days should be retired"
  pass "entries at exactly 60 days are retired"
}

test_important_entry_not_retired() {
  local home output
  home=$(make_home stale-important)
  make_learnings "$home/data/learnings.md" \
    '- **Critical lesson (2020-01-01):** CRITICAL: This must never be archived.'

  output=$(run_consolidate "$home" 2>&1)
  assert_not_contains "$output" "Entries to remove" "CRITICAL entries should not be retired"
  pass "CRITICAL entries are exempt from retirement"
}

test_never_entry_not_retired() {
  local home output
  home=$(make_home stale-never)
  make_learnings "$home/data/learnings.md" \
    '- **Never lesson (2020-01-01):** NEVER do this under any circumstances.'

  output=$(run_consolidate "$home" 2>&1)
  assert_not_contains "$output" "Entries to remove" "NEVER entries should not be retired"
  pass "NEVER entries are exempt from retirement"
}

# --- archive behavior -------------------------------------------------------

test_archive_created_on_apply() {
  local home
  home=$(make_home archive-create)
  make_learnings "$home/data/learnings.md" \
    '- **Old lesson (2025-05-28):** This should go to archive.'

  run_consolidate "$home" --apply >/dev/null 2>&1
  assert_present "$home/data/learnings.md.archive" "archive file should be created"
  assert_contains "$(<"$home/data/learnings.md.archive")" "Old lesson" "archive should contain retired entry"
  pass "archive is created with retired entries"
}

test_archive_appends_to_existing() {
  local home
  home=$(make_home archive-append)
  # Pre-create archive with existing content
  printf '# Learnings Archive\n\n' > "$home/data/learnings.md.archive"
  printf -- '- **Prior archived (2020-01-01):** Already archived.\n' >> "$home/data/learnings.md.archive"

  make_learnings "$home/data/learnings.md" \
    '- **New stale (2025-05-28):** New entry to archive.'

  run_consolidate "$home" --apply >/dev/null 2>&1
  assert_contains "$(<"$home/data/learnings.md.archive")" "Prior archived" "should preserve existing archive"
  assert_contains "$(<"$home/data/learnings.md.archive")" "New stale" "should append new archive entry"
  pass "archive appends to existing archive file"
}

test_no_archive_in_dryrun() {
  local home
  home=$(make_home archive-dryrun)
  make_learnings "$home/data/learnings.md" \
    '- **Old lesson (2025-05-28):** Should not be archived in dry run.'

  run_consolidate "$home" >/dev/null 2>&1
  assert_absent "$home/data/learnings.md.archive" "archive should not exist in dry run"
  pass "archive is not created during dry run"
}

# --- trim behavior ----------------------------------------------------------

test_long_entry_trimmed() {
  local home output
  home=$(make_home trim-long)
  # Create a line longer than 500 chars
  long_text=$(printf 'x%.0s' {1..600})
  make_learnings "$home/data/learnings.md" \
    "- **Long entry (2026-09-01):** $long_text"

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "Entries to trim: 1" "should flag long entry"
  assert_contains "$output" "trimmed from" "should report original length"
  pass "entries over 500 chars are flagged for trimming"
}

test_long_entry_applied_trim() {
  local home
  home=$(make_home trim-apply)
  long_text=$(printf 'y%.0s' {1..600})
  make_learnings "$home/data/learnings.md" \
    "- **Long entry (2026-09-01):** $long_text"

  run_consolidate "$home" --apply >/dev/null 2>&1
  local result_line
  result_line=$(grep '^-' "$home/data/learnings.md")
  [ "${#result_line}" -le 500 ] || fail "trimmed line should be <=500 chars, got ${#result_line}"
  pass "applied trim produces lines <= 500 chars"
}

test_important_entry_not_trimmed() {
  local home output
  home=$(make_home trim-important)
  important_text=$(printf 'z%.0s' {1..550})
  make_learnings "$home/data/learnings.md" \
    "- **Important (2026-09-01):** CRITICAL: $important_text"

  output=$(run_consolidate "$home" 2>&1)
  assert_not_contains "$output" "Entries to trim" "important entries should not be flagged"
  pass "entries containing CRITICAL are never trimmed"
}

test_never_entry_not_trimmed() {
  local home output
  home=$(make_home trim-never)
  never_text=$(printf 'w%.0s' {1..550})
  make_learnings "$home/data/learnings.md" \
    "- **Important (2026-09-01):** NEVER do this: $never_text"

  output=$(run_consolidate "$home" 2>&1)
  assert_not_contains "$output" "Entries to trim" "NEVER entries should not be flagged"
  pass "entries containing NEVER are never trimmed"
}

# --- backup creation --------------------------------------------------------

test_backup_created_on_apply() {
  local home backup
  home=$(make_home backup-test)
  # Use duplicate entries so there are changes to apply
  make_learnings "$home/data/learnings.md" \
    '- **Lesson (2026-09-01):** Test lesson about topic X.' \
    '- **Lesson (2026-09-01):** Test lesson about topic X.'

  run_consolidate "$home" --apply >/dev/null 2>&1
  backup="$home/data/learnings.md.bak"
  assert_present "$backup" "backup should be created"
  assert_contains "$(<"$backup")" "Test lesson" "backup should contain original content"
  pass "backup is created before applying changes"
}

test_apply_preserves_surviving_content() {
  local home result
  home=$(make_home apply-survival)
  make_learnings "$home/data/learnings.md" \
    '- **Keep (2026-09-01):** This surviving fact must remain after apply.' \
    '- **Remove (2026-09-01):** This duplicate is removed.' \
    '- **Remove (2026-09-01):** This duplicate is removed.'

  run_consolidate "$home" --apply >/dev/null 2>&1
  result=$(<"$home/data/learnings.md")
  assert_contains "$result" "This surviving fact must remain" \
    "--apply should preserve surviving content"
  [ "$(printf '%s\n' "$result" | grep -c 'This duplicate is removed')" = 1 ] || \
    fail "--apply should retain exactly one copy of a duplicate entry"
  pass "applied consolidation preserves surviving content"
}

test_backup_not_created_in_dryrun() {
  local home
  home=$(make_home backup-dryrun)
  # Use duplicate entries so the script reports changes (but doesn't apply them)
  make_learnings "$home/data/learnings.md" \
    '- **Lesson (2026-09-01):** Test lesson about topic X.' \
    '- **Lesson (2026-09-01):** Test lesson about topic X.'

  run_consolidate "$home" >/dev/null 2>&1
  assert_absent "$home/data/learnings.md.bak" "backup should not exist in dry-run"
  pass "backup is not created during dry-run"
}

# --- dry-run output ---------------------------------------------------------

test_dryrun_shows_report() {
  local home output
  home=$(make_home dryrun-report)
  make_learnings "$home/data/learnings.md" \
    '- **Lesson A (2026-09-01):** This is lesson A about topic X.' \
    '- **Lesson A (2026-09-01):** This is lesson A about topic X.'

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "# Learnings Consolidation Report" "should print report header"
  assert_contains "$output" "Dry run" "should label as dry-run"
  assert_not_contains "$output" "Changes applied" "should not apply in dry-run"
  # Original file should be unchanged
  local count
  count=$(grep -c '^-' "$home/data/learnings.md")
  [ "$count" = 2 ] || fail "dry-run should not modify file, got $count entries"
  pass "dry-run shows report without modifying file"
}

test_no_changes_outputs_clean() {
  local home output
  home=$(make_home dryrun-clean)
  make_learnings "$home/data/learnings.md" \
    '- **Unique (2026-09-01):** Only one entry here.'

  output=$(run_consolidate "$home" 2>&1)
  assert_contains "$output" "No changes needed" "should report clean file"
  pass "clean file reports no changes needed"
}

# --- error handling ---------------------------------------------------------

test_missing_file_errors() {
  local home output rc
  home=$(make_home missing-file)
  mkdir -p "$home/data"
  set +e
  output=$(SQUAD_BASE="$home" SQUAD_DATA_OVERRIDE="$home/data" \
    "$CONSOLIDATE" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing file should exit non-zero"
  assert_contains "$output" "not found" "should report file not found"
  pass "missing learnings file exits with error"
}

test_help_flag() {
  local output
  output=$("$CONSOLIDATE" --help 2>&1)
  assert_contains "$output" "Usage" "should show usage"
  pass "--help flag shows usage"
}

# --- run all tests ----------------------------------------------------------

test_exact_duplicate_removal
test_near_duplicate_removal
test_different_entries_preserved
test_stale_entry_retired
test_recent_entry_preserved
test_undated_entry_exempt
test_boundary_entry_exactly_60_days
test_important_entry_not_retired
test_never_entry_not_retired
test_archive_created_on_apply
test_archive_appends_to_existing
test_no_archive_in_dryrun
test_long_entry_trimmed
test_long_entry_applied_trim
test_important_entry_not_trimmed
test_never_entry_not_trimmed
test_backup_created_on_apply
test_apply_preserves_surviving_content
test_backup_not_created_in_dryrun
test_dryrun_shows_report
test_no_changes_outputs_clean
test_missing_file_errors
test_help_flag
printf '# all sq-learnings-consolidate tests passed\n'
