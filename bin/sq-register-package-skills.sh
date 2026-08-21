#!/usr/bin/env bash
# Register package-provided public skills into the Squad skill surface.
#
# Usage: sq-register-package-skills.sh [--check]
#   --check   Report which skills would be registered without modifying anything.
#
# This script discovers skills from installed packages and makes them available
# from the Squad skill surface by creating symlinks in skills/. It preserves
# internal/public skill boundaries and does not install hidden internal skills.
#
# Package-provided skills are discovered from:
#   1. packages/*/skills/*/SKILL.md (conventional directory)
#   2. packages with "pi": {"skills": [...]} in package.json
#
# The script is idempotent: existing symlinks are left alone, and stale ones
# are cleaned up only when the target is missing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKILLS_DIR="$SQUAD_ROOT/skills"
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    *) echo "usage: sq-register-package-skills.sh [--check]" >&2; exit 1 ;;
  esac
  shift
done

# Discover skills from packages/*/skills/*/SKILL.md
discover_conventional_skills() {
  local pkg_dir skill_dir skill_name
  for skill_dir in "$SQUAD_ROOT"/packages/*/skills/*/SKILL.md; do
    [ -f "$skill_dir" ] || continue
    # Extract the skill name from the path: packages/<pkg>/skills/<name>/SKILL.md
    skill_name=$(basename "$(dirname "$skill_dir")")
    pkg_dir=$(basename "$(dirname "$(dirname "$(dirname "$skill_dir")")")")
    echo "$skill_name|$skill_dir|$pkg_dir"
  done
}

# Discover skills from package.json "pi" key
discover_pi_manifest_skills() {
  local pkg_json pkg_dir pi_skills skill_path skill_name
  for pkg_json in "$SQUAD_ROOT"/packages/*/package.json; do
    [ -f "$pkg_json" ] || continue
    pkg_dir=$(dirname "$pkg_json")
    # Check if package.json has "pi": {"skills": [...]}
    if command -v node >/dev/null 2>&1; then
      pi_skills=$(node -e "
        const pkg = require('$pkg_json');
        const skills = pkg.pi && pkg.pi.skills ? pkg.pi.skills : [];
        skills.forEach(s => console.log(s));
      " 2>/dev/null) || continue
      while IFS= read -r skill_path; do
        [ -n "$skill_path" ] || continue
        # Resolve relative to package directory
        skill_path="$pkg_dir/$skill_path"
        if [ -d "$skill_path" ] && [ -f "$skill_path/SKILL.md" ]; then
          skill_name=$(basename "$skill_path")
          echo "$skill_name|$skill_path/SKILL.md|$(basename "$pkg_dir")"
        fi
      done <<< "$pi_skills"
    fi
  done
}

# Main registration logic
register_skills() {
  local skill_name skill_path pkg_dir target_link created=0 skipped=0 cleaned=0

  # Ensure skills directory exists
  if [ ! -d "$SKILLS_DIR" ]; then
    if [ "$CHECK_ONLY" = 0 ]; then
      mkdir -p "$SKILLS_DIR"
    fi
  fi

  # Discover all skills
  local all_skills
  all_skills=$(discover_conventional_skills; discover_pi_manifest_skills)

  # Process each discovered skill
  while IFS='|' read -r skill_name skill_path pkg_dir; do
    [ -n "$skill_name" ] || continue
    target_link="$SKILLS_DIR/$skill_name"

    if [ -L "$target_link" ]; then
      # Existing symlink: check if it points to the right place
      local current_target
      current_target=$(readlink "$target_link" 2>/dev/null) || true
      if [ "$current_target" = "$skill_path" ]; then
        skipped=$((skipped + 1))
        continue
      fi
      # Stale symlink: clean up
      if [ "$CHECK_ONLY" = 0 ]; then
        rm -f "$target_link"
        cleaned=$((cleaned + 1))
      fi
    elif [ -d "$target_link" ]; then
      # Existing directory: skip (don't overwrite user-created skills)
      skipped=$((skipped + 1))
      continue
    fi

    # Create symlink to the directory (not the file)
    local skill_dir
    skill_dir=$(dirname "$skill_path")
    if [ "$CHECK_ONLY" = 0 ]; then
      ln -s "$skill_dir" "$target_link"
      created=$((created + 1))
    else
      echo "would register: $skill_name (from $pkg_dir)"
    fi
  done <<< "$all_skills"

  # Report results
  if [ "$CHECK_ONLY" = 1 ]; then
    return 0
  fi

  if [ "$created" -gt 0 ] || [ "$cleaned" -gt 0 ]; then
    echo "registered $created skill(s), cleaned $cleaned stale symlink(s)"
  fi
  return 0
}

register_skills
