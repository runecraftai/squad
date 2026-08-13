#!/usr/bin/env bash
# tests/sq-m6-name-guard.test.sh - M6 name-surface guard (umbrella design.md §10).
#
# Executed as the final gate of M6 (T-M6-U6) and enforced in CI afterwards.
# Scans the name surfaces for the old tool names that M6 renamed away:
#   gh-axi, chrome-devtools-axi, lavish-axi, quota-axi, sq-tasks-axi
# The names-only boundary (commander decision CD-M6-03) was the M6 rule; the
# rebrand item (roadmap-futuro-rebrand-completo-de-menco-31) has since retired
# every packages/ hit, including the sq-browser bridge log prefix that used to
# be pinned below.
# .specs/ is exempt (the planning corpus names origins, per M1 §8) and this
# file is exempt (it legitimately contains the forbidden patterns as the grep
# expressions).
#
# Surfaces (0 hits except the documented keep-list):
#   1. packages/*/package.json, packages/*/bin, packages/*/release-please-config.json,
#      packages/*/plugin.json, .github/workflows/ci.yml
#   2. bin/*.sh (deferred-prose keep-list below)
#   3. tests/*.test.sh (deferred-prose keep-list below)
#   4. positive: packages/ has sq-gh sq-browser sq-quota sq-report sq-tasks and
#      no tasks-axi directory
#
# Keep-list (documented deferred prose):
#   bin/sq-bootstrap.sh
#     - header comment describing the axi-family floor policy (prose)
#   bin/sq-brief.sh
#     - operator instructions "Use gh-axi for GitHub operations and
#       chrome-devtools-axi for browser operations" (prose, deferred)
#   bin/sq-pr-merge.sh
#     - header/usage comments naming the gh-axi invocation shape (prose)
#   bin/sq-procevent-lavish.sh
#     - usage comment + "lavish-axi is not installed" die message (prose)
#   bin/sq-procevent-lib.sh
#     - comment mentioning `lavish-axi poll` (prose)
#   bin/sq-project-mode.sh
#     - comment "push + PR via gh-axi" (prose)
#   bin/sq-public-followup.sh
#     - die message "install the sq-tasks-axi fork or legacy tasks-axi" (prose)
#   bin/sq-session-start.sh
#     - header comments naming the tool checks (prose)
#   bin/sq-teardown.sh
#     - comments naming the gh-axi PR resolution path (prose)
#   bin/sq-vendor-auth-probe.sh
#     - comments naming the quota-axi data source (prose)
#   tests/sq-backend-orca.test.sh, tests/sq-backend.test.sh, tests/sq-backend-zellij.test.sh,
#   tests/sq-decision-hold-lifecycle.test.sh, tests/sq-public-followup.test.sh
#     - skip messages/comments naming the forked sq-tasks-axi (prose)
#   tests/sq-bootstrap.test.sh
#     - header comment pinning the pre-M6 MISSING lines + row labels (prose)
#   tests/sq-on.test.sh
#     - comment naming the fork-first resolver fixtures (prose)
#   tests/sq-pr-check-security.test.sh
#     - fail message naming the called tool (prose)
#   tests/sq-pr-merge.test.sh
#     - header comments naming the gh-axi mock (prose)
#   tests/sq-procevent.test.sh
#     - comment describing the `lavish-axi poll` stand-in (prose)
#   tests/sq-sitrep-snapshot.test.sh
#     - comments/fail messages naming the gh-axi fakebin (prose)
#   tests/sq-teardown.test.sh
#     - comments naming the default gh-axi mock (prose)
#   tests/sq-vendor-auth-probe.test.sh
#     - comment/fail message naming the quota-axi fakebin (prose)
#
# Status: drafted at T-M6-U6; runs green at the M6 full-suite gate. All guards
# report the FULL remaining hit list together.

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

# Guard 3: bin/*.sh executable name references must be renamed; only the
# documented deferred-prose keep-list may still carry old names in comments
# and user-facing messages.
test_guard_bin_scripts() {
  local list keep
  list=$(tracked_files | grep '^bin/.*\.sh$' || true)
  keep=$(printf '%s\n' \
    'bin/sq-bootstrap.sh' \
    'bin/sq-brief.sh' \
    'bin/sq-pr-merge.sh' \
    'bin/sq-procevent-lavish.sh' \
    'bin/sq-procevent-lib.sh' \
    'bin/sq-project-mode.sh' \
    'bin/sq-public-followup.sh' \
    'bin/sq-session-start.sh' \
    'bin/sq-teardown.sh' \
    'bin/sq-vendor-auth-probe.sh' \
    | sed '/^$/d')
  list=$(printf '%s\n%s\n' "$list" "$keep" | grep -vxF -f <(printf '%s\n' "$keep") || true)
  guard_no_match "M6 guard 3: no old tool names in bin/ scripts (keep-list: deferred prose)" \
    "$OLD_NAMES" "$list"
}

# Guard 4: tests/*.test.sh executable references must be renamed; only the
# documented deferred-prose keep-list may carry old names in comments, skip
# messages, and assertion prose.
test_guard_tests() {
  local list keep
  list=$(tracked_files | grep '^tests/.*\.test\.sh$' || true)
  keep=$(printf '%s\n' \
    'tests/sq-backend-orca.test.sh' \
    'tests/sq-backend.test.sh' \
    'tests/sq-backend-zellij.test.sh' \
    'tests/sq-bootstrap.test.sh' \
    'tests/sq-decision-hold-lifecycle.test.sh' \
    'tests/sq-on.test.sh' \
    'tests/sq-pr-check-security.test.sh' \
    'tests/sq-pr-merge.test.sh' \
    'tests/sq-procevent.test.sh' \
    'tests/sq-public-followup.test.sh' \
    'tests/sq-sitrep-snapshot.test.sh' \
    'tests/sq-teardown.test.sh' \
    'tests/sq-vendor-auth-probe.test.sh' \
    | sed '/^$/d')
  list=$(printf '%s\n%s\n' "$list" "$keep" | grep -vxF -f <(printf '%s\n' "$keep") || true)
  guard_no_match "M6 guard 4: no old tool names in tests/ (keep-list: deferred prose)" \
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
pass "M6 name-surface guard: all surfaces clean (documented deferred-prose keep-list excluded)"
