#!/usr/bin/env bash
# Behavior tests for the execution-playbook React filesystem-route rule.
# The rule's colocated node check owns the lint assertions; this wrapper runs it
# on the repo's tests/*.test.sh partition, provisions the pinned oxlint it needs,
# and exercises the installer, its package/CI wiring, and the installed
# verification command against a project's own source files.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULES_DIR="$ROOT/.agents/skills/execution-playbooks/rules"
RULE_INSTALL="$ROOT/bin/sq-playbook-rule.sh"
OXLINT_INSTALL="$ROOT/bin/sq-install-oxlint.sh"
RULE_FILES="no-filesystem-routes.mjs no-filesystem-routes.node-check.mjs no-filesystem-routes.oxlintrc.json verify-no-filesystem-routes.mjs"
TMP_ROOT=$(fm_test_tmproot sq-playbook-rule)

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the React filesystem-route rule test)"; exit 0; }

REQUIRED_OXLINT_VERSION=$("$OXLINT_INSTALL" --required-version 2>/dev/null) \
  || fail "bin/sq-install-oxlint.sh --required-version failed, so the oxlint pin cannot be verified"
[ -n "$REQUIRED_OXLINT_VERSION" ] \
  || fail "bin/sq-install-oxlint.sh --required-version returned an empty version, so the oxlint pin cannot be verified"

oxlint_matches_pin() {  # <binary>
  local binary=$1 output
  [ -x "$binary" ] || return 1
  output=$("$binary" --version 2>/dev/null) || return 1
  case "$output" in
    *"$REQUIRED_OXLINT_VERSION"*) return 0 ;;
    *) return 1 ;;
  esac
}

find_oxlint() {
  local candidate
  for candidate in "${OXLINT_BIN:-}" "$ROOT/node_modules/.bin/oxlint" "$(command -v oxlint 2>/dev/null || true)"; do
    [ -n "$candidate" ] || continue
    if oxlint_matches_pin "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

OXLINT_BIN=$(find_oxlint) || OXLINT_BIN=
if [ -z "$OXLINT_BIN" ]; then
  if ! install_out=$("$OXLINT_INSTALL" "$TMP_ROOT/oxlint" 2>&1); then
    fail "the pinned oxlint install failed, so the route-rule acceptance proof cannot run"$'\n'"$install_out"
  fi
  OXLINT_BIN="$TMP_ROOT/oxlint/oxlint"
  oxlint_matches_pin "$OXLINT_BIN" || fail "the pinned oxlint install did not report version $REQUIRED_OXLINT_VERSION"
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
  if [ -z "$passed" ] || [ "$passed" -lt 12 ]; then
    fail "$label: expected at least 12 passing subtests"$'\n'"$out"
  fi
  if printf '%s\n' "$out" | grep -q '# SKIP'; then
    fail "$label: an acceptance case was skipped instead of executed"$'\n'"$out"
  fi
}

package_script() {  # <directory> <name>
  node -e 'const p = require(process.argv[1]); process.stdout.write(p.scripts?.[process.argv[2]] ?? "")' \
    "$1/package.json" "$2"
}

# workflow_jobs <file>: the job keys defined under jobs:, one per line.
workflow_jobs() {
  awk '
    /^jobs:[[:space:]]*$/ { inside = 1; next }
    inside && /^[^[:space:]#]/ { exit }
    inside && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { line = $0; sub(/:.*/, "", line); sub(/^  /, "", line); print line }
  ' "$1"
}

# workflow_job_runs <file> <job>: the run: commands of one job, one per line.
workflow_job_runs() {
  awk -v job="$2" '
    $0 == "  " job ":" { inside = 1; next }
    inside && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    inside && /^ *(- )?run: / { sub(/^ *(- )?run: /, ""); print }
  ' "$1"
}

run_rule_check "$RULES_DIR/no-filesystem-routes.node-check.mjs" "the React filesystem-route rule checks should pass"
pass "React filesystem-route rule: node checks pass under the repo test runner against the real rule"

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/src/app/routes" "$PROJECT/.github/workflows"
cat >"$PROJECT/package.json" <<'JSON'
{
  "name": "route-fixture",
  "private": true,
  "scripts": {
    "build": "node -e \"console.log('build ran')\"",
    "lint": "echo lint"
  }
}
JSON
cat >"$PROJECT/.github/workflows/ci.yml" <<'YAML'
name: CI

on:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo existing
YAML

install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "installing the rule into a project should succeed"
for file in $RULE_FILES; do
  assert_present "$PROJECT/tools/oxlint/$file" "the installer did not create tools/oxlint/$file"
  cmp -s "$RULES_DIR/$file" "$PROJECT/tools/oxlint/$file" \
    || fail "tools/oxlint/$file is not the authoritative rule file"
done
assert_absent "$PROJECT/tools/oxlint/no-filesystem-routes.check.mjs" \
  "the installer must not copy the Node check under a name a project test runner can collect"
assert_contains "$install_out" "installed: tools/oxlint/no-filesystem-routes.mjs" \
  "the install did not report the plugin copy"
assert_contains "$install_out" "updated: package.json scripts.verify:routes and scripts.prebuild" \
  "the install did not wire the package scripts"
assert_contains "$install_out" "updated: .github/workflows/ci.yml filesystem-routes job" \
  "the install did not add the CI step to the existing workflow"
assert_contains "$install_out" "verification command: node tools/oxlint/verify-no-filesystem-routes.mjs" \
  "the install did not name the verification command it wired"
pass "React filesystem-route rule: the installer copies the authoritative files and wiring into a project"

workflow_runs=$(workflow_job_runs "$PROJECT/.github/workflows/ci.yml" filesystem-routes)
assert_contains "$(workflow_jobs "$PROJECT/.github/workflows/ci.yml")" "test" \
  "the installer must preserve the project's existing CI job"
assert_contains "$workflow_runs" "npm run verify:routes" \
  "the added CI job must run the project's verification script"
[ "$(package_script "$PROJECT" verify:routes)" = "node tools/oxlint/verify-no-filesystem-routes.mjs" ] \
  || fail "the installer did not add the verify:routes package script"
assert_contains "$(package_script "$PROJECT" prebuild)" "node tools/oxlint/verify-no-filesystem-routes.mjs" \
  "the installer did not connect the verifier to the build script"

install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "reinstalling the rule into the same project should succeed"
assert_contains "$install_out" "unchanged: tools/oxlint/no-filesystem-routes.mjs" \
  "a repeated install should report the plugin unchanged"
assert_contains "$install_out" "unchanged: package.json scripts.verify:routes and scripts.prebuild" \
  "a repeated install should report the package scripts unchanged"
assert_contains "$install_out" "unchanged: .github/workflows/ci.yml filesystem-routes job" \
  "a repeated install should report the CI job unchanged"
[ "$(workflow_jobs "$PROJECT/.github/workflows/ci.yml" | awk '$0 == "filesystem-routes" { count++ } END { print count + 0 }')" -eq 1 ] \
  || fail "a repeated install must not duplicate the filesystem-routes CI job"

for file in $RULE_FILES; do
  printf 'stale copy\n' > "$PROJECT/tools/oxlint/$file"
done
printf 'stale copy\n' > "$PROJECT/tools/oxlint/no-filesystem-routes.check.mjs"
node -e 'const fs = require("node:fs"); const file = process.argv[1]; const p = JSON.parse(fs.readFileSync(file, "utf8")); p.scripts.prebuild = "echo stale"; fs.writeFileSync(file, JSON.stringify(p, null, 2) + "\n");' \
  "$PROJECT/package.json"
install_out=$("$RULE_INSTALL" install "$PROJECT" 2>&1); status=$?
expect_code 0 "$status" "restoring stale project copies should succeed"
assert_contains "$install_out" "removed: tools/oxlint/no-filesystem-routes.check.mjs" \
  "the installer did not remove the legacy collectable check copy"
assert_absent "$PROJECT/tools/oxlint/no-filesystem-routes.check.mjs" \
  "the installer must remove the legacy collectable check copy"
for file in $RULE_FILES; do
  cmp -s "$RULES_DIR/$file" "$PROJECT/tools/oxlint/$file" \
    || fail "the installer did not restore the authoritative $file over a stale copy"
done
[ "$(package_script "$PROJECT" verify:routes)" = "node tools/oxlint/verify-no-filesystem-routes.mjs" ] \
  || fail "the installer did not restore the verify:routes package script"
assert_contains "$(package_script "$PROJECT" prebuild)" "node tools/oxlint/verify-no-filesystem-routes.mjs" \
  "the installer did not restore the verifier in the build script"

run_rule_check "$PROJECT/tools/oxlint/no-filesystem-routes.node-check.mjs" \
  "the installed rule check should pass from the project layout"

verify_command="tools/oxlint/verify-no-filesystem-routes.mjs"
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

printf 'import { createFileRoute } from "@tanstack/react-router";\nexport const Route = createFileRoute("/")({ component: () => null });\n' > "$route_file"
if command -v npm >/dev/null 2>&1; then
  out=$(cd "$PROJECT" && npm run verify:routes --silent 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "npm run verify:routes must fail project source that uses createFileRoute"$'\n'"$out"
  assert_contains "$out" "no-filesystem-routes" "the verify:routes script failure did not name the rule"

  out=$(cd "$PROJECT" && npm run build --silent 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "npm run build must fail project source that uses createFileRoute"$'\n'"$out"
  assert_contains "$out" "no-filesystem-routes" "the build failure did not name the rule"
  assert_not_contains "$out" "build ran" "the project build must not run after the route gate fails"

  printf 'import { createRootRoute, createRoute } from "@tanstack/react-router";\nconst rootRoute = createRootRoute();\nexport const Route = createRoute({ getParentRoute: () => rootRoute, path: "/" });\n' > "$route_file"
  out=$(cd "$PROJECT" && npm run build --silent 2>&1); status=$?
  expect_code 0 "$status" "npm run build must pass a code-based route tree"$'\n'"$out"
  assert_contains "$out" "build ran" "the project build must run after the route gate passes"
fi
pass "React filesystem-route rule: the installed command, package script, and build gate fail filesystem routing and pass code-based routes"

mkdir -p "$TMP_ROOT/no-package"
out=$("$RULE_INSTALL" install "$TMP_ROOT/no-package" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "installing into a project without package.json must fail"
assert_contains "$out" "no package.json" "the missing-package refusal must name the missing project script surface"

mkdir -p "$TMP_ROOT/no-workflow"
cat >"$TMP_ROOT/no-workflow/package.json" <<'JSON'
{ "name": "no-workflow", "private": true }
JSON
install_out=$("$RULE_INSTALL" install "$TMP_ROOT/no-workflow" 2>&1); status=$?
expect_code 0 "$status" "installing into a project without workflows should create a CI check"
assert_contains "$install_out" "created: .github/workflows/no-filesystem-routes.yml" \
  "the installer did not report its dedicated workflow"
assert_contains "$(workflow_job_runs "$TMP_ROOT/no-workflow/.github/workflows/no-filesystem-routes.yml" filesystem-routes)" \
  "npm run verify:routes" "the created workflow must run the project's verification script"

mkdir -p "$TMP_ROOT/deploy-only/.github/workflows"
cat >"$TMP_ROOT/deploy-only/package.json" <<'JSON'
{ "name": "deploy-only", "private": true }
JSON
cat >"$TMP_ROOT/deploy-only/.github/workflows/deploy.yml" <<'YAML'
name: Deploy

on:
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo deploy
YAML
install_out=$("$RULE_INSTALL" install "$TMP_ROOT/deploy-only" 2>&1); status=$?
expect_code 0 "$status" "installing into a project with only a manual workflow should succeed"
assert_contains "$install_out" "created: .github/workflows/no-filesystem-routes.yml" \
  "the installer must not append the gate to a workflow that never runs on push or pull_request"
assert_not_contains "$(workflow_jobs "$TMP_ROOT/deploy-only/.github/workflows/deploy.yml")" "filesystem-routes" \
  "a manual-only workflow must not receive the route gate job"
assert_contains "$(workflow_job_runs "$TMP_ROOT/deploy-only/.github/workflows/no-filesystem-routes.yml" filesystem-routes)" \
  "npm run verify:routes" "the dedicated workflow must run the project's verification script"

mkdir -p "$TMP_ROOT/wide-package"
cat >"$TMP_ROOT/wide-package/package.json" <<'JSON'
{
    "name": "wide-package",
    "private": true,
    "scripts": {
        "build": "echo build"
    }
}
JSON
"$RULE_INSTALL" install "$TMP_ROOT/wide-package" >/dev/null 2>&1 \
  || fail "installing into a four-space-indented package.json should succeed"
assert_grep '    "name": "wide-package",' "$TMP_ROOT/wide-package/package.json" \
  "the installer must preserve the project's four-space indentation"
[ "$(tail -c 1 "$TMP_ROOT/wide-package/package.json" | od -An -tx1 | tr -d ' \n')" = "0a" ] \
  || fail "the installer must preserve the package.json trailing newline"
[ "$(package_script "$TMP_ROOT/wide-package" verify:routes)" = "node tools/oxlint/verify-no-filesystem-routes.mjs" ] \
  || fail "the installer did not add verify:routes to the four-space package.json"

mkdir -p "$TMP_ROOT/conflict"
cat >"$TMP_ROOT/conflict/package.json" <<'JSON'
{
  "name": "conflict",
  "private": true,
  "scripts": {
    "verify:routes": "tsx tools/check-routes.ts"
  }
}
JSON
out=$("$RULE_INSTALL" install "$TMP_ROOT/conflict" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "installing over a different project verify:routes script must fail"
assert_contains "$out" "already defines scripts.verify:routes" \
  "the conflicting-script refusal must name the existing script"
[ "$(package_script "$TMP_ROOT/conflict" verify:routes)" = "tsx tools/check-routes.ts" ] \
  || fail "the installer must not overwrite the project's existing verify:routes command"

out=$("$RULE_INSTALL" install "$TMP_ROOT/missing" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "installing into a missing project directory must fail"
assert_contains "$out" "not a project directory" "the missing-directory refusal must name the problem"

out=$("$RULE_INSTALL" 2>&1); status=$?
[ "$status" -ne 0 ] || fail "installing without a project directory must fail"
assert_contains "$out" "usage: sq-playbook-rule.sh install" "the usage refusal must name the command form"
pass "React filesystem-route rule: the installer enforces the verifier through package scripts and CI"
