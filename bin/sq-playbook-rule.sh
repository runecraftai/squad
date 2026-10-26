#!/usr/bin/env bash
# Install the react@1 filesystem-route lint rule into an adopting project.
# The Squad copy under the playbook registry stays authoritative: this copies the
# oxlint plugin, its colocated acceptance check, the rule-only oxlint config, and
# the verification command into the project's tools/oxlint/ directory so the
# project's mandatory verification command runs the real rule over its own source
# files instead of a path that only exists in the Squad base.
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

install_one no-filesystem-routes.mjs
install_one no-filesystem-routes.check.mjs
install_one no-filesystem-routes.oxlintrc.json
install_one verify-no-filesystem-routes.mjs
printf 'playbook rule installed: %s\n' "$DEST"
printf 'verification command: node tools/oxlint/verify-no-filesystem-routes.mjs\n'
