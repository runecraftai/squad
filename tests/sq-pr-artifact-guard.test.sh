#!/usr/bin/env bash
# Behavior tests for reporting task-owned Squad artifacts in PR file lists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/sq-pr-artifact-guard.sh"

matches=$(printf '%s\n' \
  'src/main.sh' \
  'data/task-a/artifacts/checklist.md' \
  'data/task-a/report.md' \
  'data/other-task/artifacts/checklist.md' \
  | "$GUARD" task-a 2>&1)
assert_contains "$matches" 'data/task-a/artifacts/checklist.md' 'guard omitted the task checklist path'
assert_contains "$matches" 'data/task-a/report.md' 'guard omitted another task-owned artifact path'
assert_not_contains "$matches" 'data/other-task/' 'guard reported artifacts belonging to another task'

clean=$(printf '%s\n' 'src/main.sh' 'data/task-ab/readme.md' | "$GUARD" task-a 2>&1)
[ -z "$clean" ] || fail "guard should be silent for a clean PR list, got: $clean"

pass "sq-pr-artifact-guard.sh: reports task-owned artifact paths and stays silent for clean PRs"
