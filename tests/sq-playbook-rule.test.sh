#!/usr/bin/env bash
# Behavior tests for the execution-playbook React filesystem-route rule.
# The rule's colocated node check owns the lint assertions; this wrapper runs it
# on the repo's tests/*.test.sh partition, provisions the pinned oxlint it needs,
# and exercises the installer and the installed verification command against a
# project's own source files.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULES_DIR="$ROOT/.agents/skills/execution-playbooks/rules"
RULE_INSTALL="$ROOT/bin/sq-playbook-rule.sh"
OXLINT_INSTALL="$ROOT/bin/sq-install-oxlint.sh"
RULE_FILES="no-filesystem-routes.mjs no-filesystem-routes.check.mjs no-filesystem-routes.oxlintrc.json verify-no-filesystem-routes.mjs"
TMP_ROOT=$(fm_test_tmproot sq-playbook-rule)

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the React filesystem-route rule test)"; exit 0; }

find_oxlint() {
  if [ -n "${OXLINT_BIN:-}" ] && [ -x "$OXLINT_BIN" ]; then
    printf '%s\n' "$OXLINT_BIN"
    return 0
  fi
  if [ -x "$ROOT/node_modules/.bin/oxlint" ]; then
    printf '%s\n' "$ROOT/node_modules/.bin/oxlint"
    return 0
  fi
  command -v oxlint 2>/dev/null
}

OXLINT_BIN=$(find_oxlint) || OXLINT_BIN=
if [ -z "$OXLINT_BIN" ]; then
  if ! install_out=$("$OXLINT_INSTALL" "$TMP_ROOT/oxlint" 2>&1); then
    fail "the pinned oxlint install failed, so the route-rule acceptance proof cannot run"$'\n'"$install_out"
  fi
  OXLINT_BIN="$TMP_ROOT/oxlint/oxlint"
fi
export OXLINT_BIN

# The TAP summary is the runner's public output, so a passing exit code alone
# cannot hide a test file whose cases stopped being registered or were skipped:
# the route proof must execute, never report an untested green.
run_rule_check() {  # <check-file> <failure-label>
  local check_file=$1 label=$2 out rc passed
  out=$(node --test --test-reporter=tap "$check_file" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$label"$'\n'"$out"
  fi
  passed=$(printf '%s\n' "$out" | awk '$1 == "#" && $2 == "pass" { print $3; exit }')
  if [ -z "$passed" ] || [ "$passed" -lt 11 ]; then
    fail "$label: expected at least 11 passing subtests"$'\n'"$out"
  fi
  if printf '%s\n' "$out" | grep -q '# SKIP'; then
    fail "$label: an acceptance case was skipped instead of executed"$'\n'"$out"
  fi
}

run_rule_check "$RULES_DIR/no-filesystem-routes.check.mjs" "the React filesystem-route rule checks should pass"
pass "React filesystem-route rule: node checks pass under the repo test runner against the real rule"

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT"

install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "installing the rule into a project should succeed"
for file in $RULE_FILES; do
  assert_present "$PROJECT/tools/oxlint/$file" "the installer did not create tools/oxlint/$file"
  cmp -s "$RULES_DIR/$file" "$PROJECT/tools/oxlint/$file" \
    || fail "tools/oxlint/$file is not the authoritative rule file"
done
assert_contains "$install_out" "installed: tools/oxlint/no-filesystem-routes.mjs" \
  "the install did not report the plugin copy"
assert_contains "$install_out" "verification command: node tools/oxlint/verify-no-filesystem-routes.mjs" \
  "the install did not name the verification command it wired"

install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "reinstalling the rule into the same project should succeed"
assert_contains "$install_out" "unchanged: tools/oxlint/no-filesystem-routes.mjs" \
  "a repeated install should report the plugin unchanged"

for file in $RULE_FILES; do
  printf 'stale copy\n' > "$PROJECT/tools/oxlint/$file"
done
install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "restoring stale project copies should succeed"
for file in $RULE_FILES; do
  cmp -s "$RULES_DIR/$file" "$PROJECT/tools/oxlint/$file" \
    || fail "the installer did not restore the authoritative $file over a stale copy"
done

run_rule_check "$PROJECT/tools/oxlint/no-filesystem-routes.check.mjs" \
  "the installed rule check should pass from the project layout"

verify_command="tools/oxlint/verify-no-filesystem-routes.mjs"
mkdir -p "$PROJECT/src/app/routes"
git init -q "$PROJECT" || fail "the project fixture repository should initialize"
route_file="$PROJECT/src/app/routes/index.tsx"

printf 'import { createFileRoute } from "@tanstack/react-router";\nexport const Route = createFileRoute("/")({ component: () => null });\n' > "$route_file"
out=$(cd "$PROJECT" && node "$verify_command" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "the installed verification command must fail project source that uses createFileRoute"$'\n'"$out"
assert_contains "$out" "no-filesystem-routes" "the createFileRoute failure did not name the rule"

printf 'import { routeTree } from "./routeTree.gen";\nexport const tree = routeTree;\n' > "$route_file"
out=$(cd "$PROJECT" && node "$verify_command" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "the installed verification command must fail project source that imports the generated routeTree"$'\n'"$out"
assert_contains "$out" "no-filesystem-routes" "the generated routeTree failure did not name the rule"

printf 'import { tanstackRouter } from "@tanstack/router-plugin/vite";\nexport const plugin = tanstackRouter();\n' > "$route_file"
out=$(cd "$PROJECT" && node "$verify_command" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "the installed verification command must fail project source that configures the filesystem-route plugin"$'\n'"$out"
assert_contains "$out" "no-filesystem-routes" "the filesystem plugin failure did not name the rule"

printf 'import { createRootRoute, createRoute } from "@tanstack/react-router";\nconst rootRoute = createRootRoute();\nexport const Route = createRoute({ getParentRoute: () => rootRoute, path: "/" });\n' > "$route_file"
out=$(cd "$PROJECT" && node "$verify_command" 2>&1); status=$?
expect_code 0 "$status" "the installed verification command must pass a code-based project route tree"$'\n'"$out"
assert_contains "$out" "no filesystem routing found" "the passing verification did not report its result"
pass "React filesystem-route rule: the installed command fails filesystem routing in project sources and passes code-based routes"

out=$("$RULE_INSTALL" install "$TMP_ROOT/missing" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "installing into a missing project directory must fail"
assert_contains "$out" "not a project directory" "the missing-directory refusal must name the problem"

out=$("$RULE_INSTALL" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "installing without a project directory must fail"
assert_contains "$out" "usage: sq-playbook-rule.sh install" "the usage refusal must name the command form"
pass "React filesystem-route rule: the installer copies the authoritative files and verification command into a project"
