#!/usr/bin/env bash
# Snapshot a skill's current state before an update.
# Usage: sq-skill-snapshot.sh <skill-name>
# Captures the skill directory into a timestamped snapshot under
# data/skill-snapshots/<skill-name>/<timestamp>/ and stores metadata
# (name, timestamp, file hashes). Skips when no changes since last snapshot.
# Caps at 10 snapshots per skill, auto-pruning the oldest.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
SQUAD_BASE=${SQUAD_BASE:-${SQUAD_HOME:-$SQUAD_ROOT}}
DATA=${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}
SNAPSHOTS=$DATA/skill-snapshots
MAX_SNAPSHOTS=10

usage() {
  printf 'Usage: %s <skill-name>\n' "$(basename "$0")" >&2
  printf 'Snapshot a skill directory before an update.\n' >&2
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

# Collect sorted file paths relative to the skill directory.
collect_files() {
  (cd "$SKILL_DIR" && find . -type f -not -name '.' | sort)
}

# Build a hash manifest: "<relative-path>\t<sha256>" for all files.
hash_manifest() {
  local root=$1 f sha
  while IFS= read -r f; do
    sha=$(sha256sum "$root/$f" | awk '{print $1}')
    printf '%s\t%s\n' "$f" "$sha"
  done < <(collect_files)
}

# Determine latest snapshot directory, if any.
latest_snapshot_dir() {
  local skill_snap=$SNAPSHOTS/$SKILL_NAME
  if [ -d "$skill_snap" ]; then
    local latest
    latest=$(find "$skill_snap" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -1)
    if [ -n "$latest" ]; then
      printf '%s' "$latest"
      return 0
    fi
  fi
  return 1
}

# Skip when hash manifest matches the latest snapshot.
if prev=$(latest_snapshot_dir); then
  prev_manifest=$prev/manifest.tsv
  if [ -f "$prev_manifest" ]; then
    current_manifest=$(mktemp)
    trap 'rm -f "$current_manifest"' EXIT
    hash_manifest "$SKILL_DIR" > "$current_manifest"
    if cmp -s "$current_manifest" "$prev_manifest"; then
      printf 'no changes since last snapshot\n'
      exit 0
    fi
  fi
fi

# Create timestamped snapshot directory.
TS=$(date '+%Y%m%dT%H%M%S')
SNAP_DIR=$SNAPSHOTS/$SKILL_NAME/$TS
mkdir -p "$SNAP_DIR"

# Copy all skill files into the snapshot.
(cd "$SKILL_DIR" && find . -type f -not -name '.' -exec cp --parents {} "$SNAP_DIR" \;)

# Write manifest and metadata.
hash_manifest "$SKILL_DIR" > "$SNAP_DIR/manifest.tsv"
cat > "$SNAP_DIR/metadata.json" <<EOF
{"skill":"$SKILL_NAME","timestamp":"$TS","files":$(collect_files | wc -l | tr -d ' ')}
EOF

# Prune to MAX_SNAPSHOTS, removing the oldest first.
snap_root=$SNAPSHOTS/$SKILL_NAME
count=$(find "$snap_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -gt "$MAX_SNAPSHOTS" ]; then
  prune_count=$((count - MAX_SNAPSHOTS))
  find "$snap_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n "$prune_count" | while IFS= read -r old; do
    rm -rf "$old"
  done
fi

printf 'snapshot created: %s (%s files)\n' "$SNAP_DIR" "$(collect_files | wc -l | tr -d ' ')"
