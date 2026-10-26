#!/usr/bin/env bash
# Runner wrapper for the execution-playbook React filesystem-route rule.
# The rule's colocated node test owns the assertions; this wrapper puts that run
# on the repo's tests/*.test.sh partition so bin/sq-test-run.sh and CI execute it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULE_TEST="$ROOT/.agents/skills/execution-playbooks/rules/no-filesystem-routes.test.mjs"

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the React filesystem-route rule test)"; exit 0; }

out=$(node --test --test-reporter=tap "$RULE_TEST" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "the React filesystem-route rule tests should pass"$'\n'"$out"
fi

# A node test file with no test cases still exits 0, so require a passing
# subtest count from the TAP summary instead of trusting the exit code alone.
passed=$(printf '%s\n' "$out" | awk '$1 == "#" && $2 == "pass" { print $3; exit }')
if [ -z "$passed" ] || [ "$passed" -lt 1 ]; then
  fail "the React filesystem-route rule test run reported no passing subtests"$'\n'"$out"
fi

pass "React filesystem-route rule: node tests pass under the repo test runner"
