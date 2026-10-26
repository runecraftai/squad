#!/usr/bin/env bash
# Install the react@1 filesystem-route lint rule into an adopting project.
# The Squad copy under the playbook registry stays authoritative: this copies the
# oxlint plugin, its colocated acceptance check, the rule-only oxlint config, and
# the verification command into the project's tools/oxlint/ directory, then edits
# the project's package scripts and CI so the verification command runs as an
# enforced project check instead of a path that only exists in the Squad base.
# Usage: sq-playbook-rule.sh install <project-dir>
set -eu

usage() {
  echo "usage: sq-playbook-rule.sh install <project-dir>" >&2
}

case "${1:-}" in
  install) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 1 ;;
esac
[ "$#" -eq 2 ] || { usage; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$ROOT/.agents/skills/execution-playbooks/rules"
TARGET=$2
[ -d "$TARGET" ] || { echo "error: not a project directory: $TARGET" >&2; exit 1; }
TARGET=$(cd "$TARGET" && pwd -P)
DEST="$TARGET/tools/oxlint"
PACKAGE="$TARGET/package.json"
WORKFLOW_DIR="$TARGET/.github/workflows"
WORKFLOW_FILE="$WORKFLOW_DIR/no-filesystem-routes.yml"
RULE_COMMAND="node tools/oxlint/verify-no-filesystem-routes.mjs"

command -v node >/dev/null 2>&1 || { echo "error: node is required to install the route gate" >&2; exit 1; }
[ -f "$PACKAGE" ] || {
  echo "error: $TARGET has no package.json; the route gate is enforced through a project script and CI" >&2
  exit 1
}

mkdir -p "$DEST"

install_one() {  # <file>
  local file=$1 source target
  source="$SOURCE_DIR/$file"
  target="$DEST/$file"
  [ -f "$source" ] || { echo "error: missing authoritative rule file: $source" >&2; exit 1; }
  if [ -f "$target" ] && cmp -s "$source" "$target"; then
    printf 'unchanged: tools/oxlint/%s\n' "$file"
    return 0
  fi
  cp "$source" "$target"
  printf 'installed: tools/oxlint/%s\n' "$file"
}

install_package_scripts() {
  node - "$PACKAGE" "$RULE_COMMAND" <<'NODE'
const fs = require("node:fs");
const [file, command] = process.argv.slice(2);
const packageJson = JSON.parse(fs.readFileSync(file, "utf8"));
packageJson.scripts = packageJson.scripts ?? {};
const previous = JSON.stringify(packageJson.scripts);
packageJson.scripts["verify:routes"] = command;
const prebuild = packageJson.scripts.prebuild;
if (typeof prebuild !== "string") {
  packageJson.scripts.prebuild = command;
} else if (!prebuild.includes(command)) {
  packageJson.scripts.prebuild = `${prebuild} && ${command}`;
}
if (JSON.stringify(packageJson.scripts) === previous) {
  console.log("unchanged: package.json scripts.verify:routes and scripts.prebuild");
} else {
  fs.writeFileSync(file, `${JSON.stringify(packageJson, null, 2)}\n`);
  console.log("updated: package.json scripts.verify:routes and scripts.prebuild");
}
NODE
}

workflow_job() {
  cat <<'JOB'
  filesystem-routes:
    name: Filesystem route gate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: lts/*
      - name: Install project dependencies
        run: |
          set -eu
          if [ -f pnpm-lock.yaml ]; then
            corepack enable
            pnpm install --frozen-lockfile
          elif [ -f yarn.lock ]; then
            corepack enable
            yarn install --frozen-lockfile
          elif [ -f bun.lockb ] || [ -f bun.lock ]; then
            npm install -g bun
            bun install --frozen-lockfile
          elif [ -f package-lock.json ]; then
            npm ci
          else
            npm install
          fi
      - name: Verify code-based TanStack routes
        run: npm run verify:routes
JOB
}

workflow_takes_job() {  # <file>
  awk '
    /^jobs:[[:space:]]*$/ { jobs = 1; next }
    jobs && /^[^[:space:]#]/ { exit 1 }
    END { if (!jobs) exit 1 }
  ' "$1"
}

install_ci_check() {
  local candidate
  mkdir -p "$WORKFLOW_DIR"
  for candidate in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
    [ -f "$candidate" ] || continue
    if grep -q '^  filesystem-routes:[[:space:]]*$' "$candidate"; then
      printf 'unchanged: %s filesystem-routes job\n' "${candidate#"$TARGET"/}"
      return 0
    fi
    workflow_takes_job "$candidate" || continue
    {
      printf '\n'
      workflow_job
    } >>"$candidate"
    printf 'updated: %s filesystem-routes job\n' "${candidate#"$TARGET"/}"
    return 0
  done
  if [ -f "$WORKFLOW_FILE" ] && grep -q '^  filesystem-routes:[[:space:]]*$' "$WORKFLOW_FILE"; then
    printf 'unchanged: %s\n' "${WORKFLOW_FILE#"$TARGET"/}"
    return 0
  fi
  {
    printf '%s\n' 'name: Filesystem route gate' '' 'on:' '  push:' '  pull_request:' '' 'permissions:' '  contents: read' '' 'jobs:'
    workflow_job
  } >"$WORKFLOW_FILE"
  printf 'created: %s\n' "${WORKFLOW_FILE#"$TARGET"/}"
}

install_one no-filesystem-routes.mjs
install_one no-filesystem-routes.node-check.mjs
install_one no-filesystem-routes.oxlintrc.json
install_one verify-no-filesystem-routes.mjs
if [ -f "$DEST/no-filesystem-routes.check.mjs" ]; then
  rm "$DEST/no-filesystem-routes.check.mjs"
  printf 'removed: tools/oxlint/no-filesystem-routes.check.mjs\n'
fi
install_package_scripts
install_ci_check
printf 'playbook rule installed: %s\n' "$DEST"
printf 'verification command: %s\n' "$RULE_COMMAND"
