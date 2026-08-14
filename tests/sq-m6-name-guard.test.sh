#!/usr/bin/env bash
# tests/sq-m6-name-guard.test.sh - M6 name-surface guard (umbrella design.md §10).
#
# Executed as the final gate of M6 (T-M6-U6) and enforced in CI afterwards.
# Scans the name surfaces for the old tool names that M6 renamed away:
#   gh-axi, chrome-devtools-axi, lavish-axi, quota-axi, sq-tasks-axi
# The names-only boundary (commander decision CD-M6-03) was the M6 rule; the
# rebrand item (roadmap-futuro-rebrand-completo-de-menco-31) has since retired
# every packages/ hit, including the sq-browser bridge log prefix that used to
# be pinned below, and the 2026-08-14 purge decision retired the deferred-prose
# keep-lists: bin/ and tests/ no longer carry any of the five old names, in
# prose or in messages. (The plain `tasks-axi` protocol-alias name is NOT a
# guarded pattern: bin/sq-tasks-lib.sh documents where the runtime still
# requires it for PATH shadowing, test stubs, and the CI alias.)
# .specs/ is exempt (the planning corpus names origins, per M1 §8) and this
# file is exempt (it legitimately contains the forbidden patterns as the grep
# expressions).
#
# Surfaces (0 hits except the documented keep-list):
#   1. packages/*/package.json, packages/*/bin, packages/*/release-please-config.json,
#      packages/*/plugin.json, .github/workflows/ci.yml
#   2. bin/*.sh
#   3. tests/*.test.sh
#   4. positive: packages/ has sq-gh sq-browser sq-quota sq-report sq-tasks and
#      no tasks-axi directory
#
# Status: drafted at T-M6-U6; runs green at the M6 full-suite gate; the
# 2026-08-14 purge emptied the deferred-prose keep-lists. All guards report the
# FULL remaining hit list together.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OLD_NAMES='(gh-axi|chrome-devtools-axi|lavish-axi|quota-axi|sq-tasks-axi)'

# Files to scan: tracked content, excluding .specs/ and this guard file.
tracked_files() {
  git -C "$ROOT" ls-files -z | tr '\0' '\n' \
    | grep -v '^\.specs/' \
    | grep -v '^tests/sq-m6-name-guard.test.sh$'
}

# Violations accumulate across all guards so the gate reports the FULL
# remaining hit list in one run instead of stopping at the first guard.
GUARD_FAILURES=""

record_failure() {  # <label> <detail>
  printf -v GUARD_FAILURES '%s-- %s --\n%s\n' "$GUARD_FAILURES" "$1" "$2"
}

# guard_no_match <label> <pattern> <file-list>
# Records a violation if ANY file in the list matches the pattern.
guard_no_match() {
  local label=$1 pattern=$2 list=$3 file hits
  while IFS= read -r file; do
    hits=$(grep -I -H -n -E -e "$pattern" -- "$ROOT/$file" 2>/dev/null | sed "s|^$ROOT/||")
    [ -z "$hits" ] || record_failure "$label" "$hits"
  done <<< "$list"
}

# Guard 1: hard name surfaces - the packaging name surfaces must be clean.
# The M6-era bridge log-prefix exception was retired by the rebrand item, so
# the pin below no longer exists and the guard is a plain no-match scan.
test_guard_package_name_surfaces() {
  local list
  list=$(tracked_files | grep -E '^packages/[^/]+/(package\.json|bin/|release-please-config\.json|plugin\.json)' || true)
  guard_no_match "M6 guard 1: no old tool names in package name surfaces" "$OLD_NAMES" "$list"
}

# Guard 2: .github/workflows/ci.yml must be clean (job names, install paths,
# aliases all renamed).
test_guard_ci_workflow() {
  guard_no_match "M6 guard 2: no old tool names in .github/workflows/ci.yml" \
    "$OLD_NAMES" ".github/workflows/ci.yml"
}

# Guard 3: bin/*.sh executable name references must be renamed; the
# deferred-prose keep-list was retired by the 2026-08-14 purge, so the guard is
# a plain no-match scan.
test_guard_bin_scripts() {
  local list
  list=$(tracked_files | grep '^bin/.*\.sh$' || true)
  guard_no_match "M6 guard 3: no old tool names in bin/ scripts" \
    "$OLD_NAMES" "$list"
}

# Guard 4: tests/*.test.sh executable name references must be renamed; the
# deferred-prose keep-list was retired by the 2026-08-14 purge, so the guard is
# a plain no-match scan.
test_guard_tests() {
  local list
  list=$(tracked_files | grep '^tests/.*\.test\.sh$' || true)
  guard_no_match "M6 guard 4: no old tool names in tests/" \
    "$OLD_NAMES" "$list"
}

# Guard 5: positive layout - the five Squad tool names exist under packages/
# and the old tasks-axi directory is gone.
test_guard_package_layout() {
  local missing="" stale=""
  for p in sq-gh sq-browser sq-quota sq-report sq-tasks; do
    [ -d "$ROOT/packages/$p" ] || missing="$missing $p"
  done
  [ -d "$ROOT/packages/tasks-axi" ] && stale="packages/tasks-axi still exists"
  if [ -n "$missing$stale" ]; then
    record_failure "M6 guard 5: package layout" "missing:$missing $stale"
  fi
}

test_guard_package_name_surfaces
test_guard_ci_workflow
test_guard_bin_scripts
test_guard_tests
test_guard_package_layout

if [ -n "$GUARD_FAILURES" ]; then
  printf '%s\n' "$GUARD_FAILURES"
  exit 1
fi
pass "M6 name-surface guard: all surfaces clean"
