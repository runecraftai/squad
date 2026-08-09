#!/usr/bin/env bash
# tests/sq-rebrand-guard.test.sh - repo-wide rebrand guards (design.md §8).
#
# Executed as the final gate of M1 (T-M1-12) and enforced in CI afterwards.
# Scans git-tracked content EXCLUDING .specs/ (the planning corpus is the only
# place allowed to name the fork origin and the legal caveat, RISK-01).
#
# Guards (design.md §8.1-8.7):
#   1. no "firstmate"/"first mate"/"Firstmate" tokens
#   2. no upstream author identities: kunchenguid / Kun Chen / @kunchenguid
#   3. no \bfm- or \bfmx- prefixes (fmx- escapes \bfm- and is grepped explicitly)
#   4. no \bFM_ env prefix
#   5. no mapped-sense vocabulary: captain, crewmate, fleet, secondmate,
#      treehouse, ahoy, bearings, stow, wake-queue, "ship task", "scout task",
#      "scout worktree", "the watch", watch.sh, watcher-continuity
#      (natural-English watch/ship/scout outside these patterns is ALLOWED -
#      the allowlist is this exact pattern list, never bare-word greps)
#   6. keep-list asserts: AGENTS.md exists, CLAUDE.md is a symlink to it,
#      .tasks.toml and .no-mistakes.yaml exist, .claude/skills symlink intact
#   7. .specs/ is the only location allowed to mention the fork origin/legal
#      caveat (enforced by construction: every guard excludes .specs/)
#
# Status: skeleton drafted at T-M1-01; intentionally RED until the M1 sweep
# completes. Runs green only at T-M1-12 (full-suite gate). All guards run in
# one pass and report the FULL remaining hit list together.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Files to scan: tracked content, excluding .specs/ and binary assets.
tracked_files() {
  git -C "$ROOT" ls-files -z | tr '\0' '\n' \
    | grep -v '^\.specs/' \
    | grep -v '\.png$' \
    | grep -v '\.gif$'
}

# Violations accumulate across all guards so the sweep gate reports the FULL
# remaining hit list in one run instead of stopping at the first guard.
GUARD_FAILURES=""

record_failure() {  # <label> <detail>
  printf -v GUARD_FAILURES '%s-- %s --\n%s\n' "$GUARD_FAILURES" "$1" "$2"
}

# guard_no_match <label> <grep-flags> <pattern>...
# Records a violation if ANY tracked file matches ANY pattern.
guard_no_match() {
  local label=$1; shift
  local flags=$1; shift
  local pattern
  local matches
  matches=$(tracked_files | while IFS= read -r file; do
    for pattern in "$@"; do
      grep -I -H -n $flags -e "$pattern" -- "$ROOT/$file" 2>/dev/null \
        | sed "s|^$ROOT/||"
    done
  done)
  if [ -n "$matches" ]; then
    record_failure "$label" "$matches"
  else
    pass "$label"
  fi
}

test_guard_no_firstmate_tokens() {
  guard_no_match "rebrand guard 1: no firstmate tokens (excluding .specs/)" \
    -E 'firstmate|first mate|Firstmate'
}

test_guard_no_upstream_authors() {
  guard_no_match "rebrand guard 2: no upstream author identities (excluding .specs/)" \
    -E 'kunchenguid|Kun Chen|@kunchenguid'
}

test_guard_no_fm_prefix() {
  guard_no_match "rebrand guard 3: no \bfm- or \bfmx- prefixes (excluding .specs/)" \
    -E '\bfm-|\bfmx-'
}

test_guard_no_fm_env_prefix() {
  guard_no_match "rebrand guard 4: no \bFM_ env prefix (excluding .specs/)" \
    -E '\bFM_'
}

test_guard_no_mapped_vocabulary() {
  guard_no_match \
    "rebrand guard 5: no mapped-sense vocabulary (excluding .specs/)" \
    -E \
    '\bcaptain\b' \
    '\bcrewmate\b' \
    '\bfleet\b' \
    '\bsecondmate\b' \
    '\btreehouse\b' \
    '\bahoy\b' \
    '\bbearings\b' \
    '\bstow\b' \
    '\bwake-queue\b' \
    '\bship task\b' \
    '\bscout task\b' \
    '\bscout worktree\b' \
    '\bthe watch\b' \
    'watch\.sh' \
    'watcher-continuity'
}

test_guard_keep_list() {
  [ -f "$ROOT/AGENTS.md" ] || record_failure "rebrand guard 6: keep-list" "AGENTS.md missing"
  [ -L "$ROOT/CLAUDE.md" ] || record_failure "rebrand guard 6: keep-list" "CLAUDE.md is not a symlink"
  { [ -L "$ROOT/CLAUDE.md" ] && [ "$(readlink "$ROOT/CLAUDE.md")" = AGENTS.md ]; } \
    || record_failure "rebrand guard 6: keep-list" "CLAUDE.md does not point at AGENTS.md"
  [ -f "$ROOT/.tasks.toml" ] || record_failure "rebrand guard 6: keep-list" ".tasks.toml missing"
  [ -f "$ROOT/.no-mistakes.yaml" ] || record_failure "rebrand guard 6: keep-list" ".no-mistakes.yaml missing"
  [ -L "$ROOT/.claude/skills" ] || record_failure "rebrand guard 6: keep-list" ".claude/skills is not a symlink"
  if [ -z "$GUARD_FAILURES" ]; then
    pass "rebrand guard 6: keep-list asserts (AGENTS.md, CLAUDE.md symlink, .tasks.toml, .no-mistakes.yaml, .claude/skills symlink)"
  fi
}

test_guard_no_firstmate_tokens
test_guard_no_upstream_authors
test_guard_no_fm_prefix
test_guard_no_fm_env_prefix
test_guard_no_mapped_vocabulary
test_guard_keep_list

if [ -n "$GUARD_FAILURES" ]; then
  printf 'not ok - rebrand guards: %s violation(s) remain (excluding .specs/)\n' \
    "$(printf '%s' "$GUARD_FAILURES" | grep -c '^-- ')" >&2
  printf '%s' "$GUARD_FAILURES" >&2
  exit 1
fi
exit 0
