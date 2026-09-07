#!/usr/bin/env bash
# Roll back a skill to a previous snapshot.
# Usage: sq-skill-rollback.sh <skill-name> [<timestamp>]
# Without timestamp: interactive picker showing available snapshots.
# With timestamp: restores that specific snapshot.
# Overwrites current skill files and prints what was restored.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
SQUAD_BASE=${SQUAD_BASE:-${SQUAD_HOME:-$SQUAD_ROOT}}
DATA=${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}
SNAPSHOTS=$DATA/skill-snapshots

usage() {
  printf 'Usage: %s <skill-name> [<timestamp>]\n' "$(basename "$0")" >&2
  printf 'Roll back a skill to a previous snapshot.\n' >&2
  printf '  Without timestamp: interactive picker.\n' >&2
  printf '  With timestamp: restores that specific snapshot.\n' >&2
}

if [ "${1:-}" = '--help' ] || [ "${1:-}" = '-h' ]; then
  usage
  exit 0
fi
if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  usage
  exit 1
fi

SKILL_NAME=$1
TIMESTAMP=${2:-}

case "$SKILL_NAME" in
  */*|*..*)
    printf 'error: invalid skill name (must not contain "/" or ".."): %s\n' "$SKILL_NAME" >&2
    exit 1
    ;;
esac

# Locate the skill directory: .agents/skills/ first, then skills/ (public).
find_skill_dir() {
  local candidate
  candidate=$SQUAD_BASE/.agents/skills/$SKILL_NAME
  if [ -d "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  candidate=$SQUAD_BASE/skills/$SKILL_NAME
  if [ -d "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

SKILL_DIR=$(find_skill_dir) || {
  printf 'error: skill not found: %s\n' "$SKILL_NAME" >&2
  exit 1
}

SNAP_ROOT=$SNAPSHOTS/$SKILL_NAME
if [ ! -d "$SNAP_ROOT" ]; then
  printf 'error: no snapshots found for %s\n' "$SKILL_NAME" >&2
  exit 1
fi

# List available snapshots (newest first).
list_snapshots() {
  find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | while IFS= read -r d; do
    basename "$d"
  done
}

# Resolve the target snapshot directory.
if [ -n "$TIMESTAMP" ]; then
  SNAP_DIR=$SNAP_ROOT/$TIMESTAMP
  if [ ! -d "$SNAP_DIR" ]; then
    printf 'error: snapshot not found: %s\n' "$TIMESTAMP" >&2
    printf 'available snapshots:\n' >&2
    list_snapshots | sed 's/^/  /' >&2
    exit 1
  fi
else
  # Interactive picker.
  mapfile -t snapshots < <(list_snapshots)
  if [ "${#snapshots[@]}" -eq 0 ]; then
    printf 'error: no snapshots available for %s\n' "$SKILL_NAME" >&2
    exit 1
  fi
  printf 'Available snapshots for %s (newest first):\n\n' "$SKILL_NAME"
  for i in "${!snapshots[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${snapshots[$i]}"
  done
  printf '\nSelect snapshot number [1-%d]: ' "${#snapshots[@]}" >&2
  read -r choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#snapshots[@]}" ]; then
    printf 'error: invalid selection: %s\n' "$choice" >&2
    exit 1
  fi
  SNAP_DIR=$SNAP_ROOT/${snapshots[$((choice - 1))]}
fi

# Clear current skill directory and restore from snapshot.
rm -rf "$SKILL_DIR"
mkdir -p "$SKILL_DIR"
# Restore skill files, excluding snapshot metadata.
(cd "$SNAP_DIR" && find . -type f -not -name 'manifest.tsv' -not -name 'metadata.json' -exec cp --parents {} "$SKILL_DIR" \;)

# Report what was restored.
printf 'restored %s from snapshot %s:\n' "$SKILL_NAME" "$(basename "$SNAP_DIR")"
find "$SKILL_DIR" -type f | sed "s|^$SKILL_DIR/||" | sort | while IFS= read -r f; do
  printf '  %s\n' "$f"
done

# Show what changed by comparing manifest if available.
manifest=$SNAP_DIR/manifest.tsv
if [ -f "$manifest" ]; then
  printf '\nmanifest (sha256):\n'
  while IFS=$'\t' read -r f sha; do
    printf '  %s  %s\n' "$sha" "$f"
  done < "$manifest"
fi
