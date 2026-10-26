#!/usr/bin/env bash
# Behavior tests for the execution-playbook React filesystem-route rule.
# The rule's colocated node test owns the lint assertions; this wrapper runs it
# on the repo's tests/*.test.sh partition and exercises the installer that puts
# the authoritative rule files into an adopting project.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULES_DIR="$ROOT/.agents/skills/execution-playbooks/rules"
RULE_MJS="$RULES_DIR/no-filesystem-routes.mjs"
RULE_TEST="$RULES_DIR/no-filesystem-routes.test.mjs"
RULE_INSTALL="$ROOT/bin/sq-playbook-rule.sh"
TMP_ROOT=$(fm_test_tmproot sq-playbook-rule)

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the React filesystem-route rule test)"; exit 0; }

# The TAP summary is the runner's public output, so a passing exit code alone
# cannot hide a test file whose cases stopped being registered.
run_rule_tests() {  # <test-file> <failure-label>
  local test_file=$1 label=$2 out rc passed
  out=$(node --test --test-reporter=tap "$test_file" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$label"$'\n'"$out"
  fi
  passed=$(printf '%s\n' "$out" | awk '$1 == "#" && $2 == "pass" { print $3; exit }')
  if [ -z "$passed" ] || [ "$passed" -lt 1 ]; then
    fail "$label: the run reported no passing subtests"$'\n'"$out"
  fi
}

run_rule_tests "$RULE_TEST" "the React filesystem-route rule tests should pass"
pass "React filesystem-route rule: node tests pass under the repo test runner"

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT"

install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "installing the rule into a project should succeed"
for file in no-filesystem-routes.mjs no-filesystem-routes.test.mjs; do
  assert_present "$PROJECT/tools/oxlint/$file" "the installer did not create tools/oxlint/$file"
  cmp -s "$RULES_DIR/$file" "$PROJECT/tools/oxlint/$file" \
    || fail "tools/oxlint/$file is not the authoritative rule file"
done
assert_contains "$install_out" "installed: tools/oxlint/no-filesystem-routes.mjs" \
  "the install did not report the plugin copy"

install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "reinstalling the rule into the same project should succeed"
assert_contains "$install_out" "unchanged: tools/oxlint/no-filesystem-routes.mjs" \
  "a repeated install should report the plugin unchanged"

printf 'stale copy\n' > "$PROJECT/tools/oxlint/no-filesystem-routes.mjs"
install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "restoring a stale project copy should succeed"
cmp -s "$RULE_MJS" "$PROJECT/tools/oxlint/no-filesystem-routes.mjs" \
  || fail "the installer did not restore the authoritative plugin over a stale copy"

run_rule_tests "$PROJECT/tools/oxlint/no-filesystem-routes.test.mjs" \
  "the installed rule test should pass from the project layout"

out=$("$RULE_INSTALL" install "$TMP_ROOT/missing" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "installing into a missing project directory must fail"
assert_contains "$out" "not a project directory" "the missing-directory refusal must name the problem"

out=$("$RULE_INSTALL" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "installing without a project directory must fail"
assert_contains "$out" "usage: sq-playbook-rule.sh install" "the usage refusal must name the command form"
pass "React filesystem-route rule: the installer copies the authoritative files into a project"
