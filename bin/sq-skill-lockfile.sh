#!/usr/bin/env bash
# Generate or verify a skill lockfile tracking installed skills with integrity hashes.
# The lockfile is a JSON manifest of all skills in .agents/skills/ and skills/,
# with per-skill SHA-256 content hashes for tamper detection.
#
# Usage:
#   sq-skill-lockfile.sh                # generate lockfile at .skill-lock.json
#   sq-skill-lockfile.sh --verify       # verify installed skills against lockfile
#   sq-skill-lockfile.sh --path <dir>   # write lockfile to a custom path
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"

MODE="generate"
LOCKFILE_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verify)
      MODE="verify"
      shift
      ;;
    --path)
      [ $# -ge 2 ] || { echo "error: --path requires a path" >&2; exit 2; }
      LOCKFILE_PATH="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: sq-skill-lockfile.sh [--verify] [--path <dir>]\n'
      printf 'Generate or verify a skill lockfile with SHA-256 integrity hashes.\n'
      exit 0
      ;;
    *)
      echo "error: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

LOCKFILE="${LOCKFILE_PATH:-$SQUAD_BASE/.skill-lock.json}"

# Discover all skill directories.
discover_skills() {
  local dirs=()
  for base in "$SQUAD_BASE/.agents/skills" "$SQUAD_BASE/skills"; do
    if [ -d "$base" ]; then
      for d in "$base"/*/; do
        [ -f "$d/SKILL.md" ] && dirs+=("$d")
      done
    fi
  done
  printf '%s\n' "${dirs[@]}"
}

# Compute a combined SHA-256 hash for all files in a skill directory.
skill_hash() {
  local dir="$1"
  (cd "$dir" && find . -type f -not -name '.' | sort | xargs sha256sum | sha256sum | awk '{print $1}')
}

# Extract skill name from SKILL.md frontmatter.
skill_name() {
  local skill_md="$1/SKILL.md"
  if [ -f "$skill_md" ]; then
    sed -n '/^---$/,/^---$/p' "$skill_md" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//' | tr -d '"' || basename "$1"
  else
    basename "$1"
  fi
}

# Extract skill description from SKILL.md frontmatter.
skill_description() {
  local skill_md="$1/SKILL.md"
  if [ -f "$skill_md" ]; then
    sed -n '/^---$/,/^---$/p' "$skill_md" | grep -m1 '^description:' | sed 's/^description:[[:space:]]*//' | tr -d '"' | head -c 120 || echo ""
  else
    echo ""
  fi
}

# Extract source metadata if present.
skill_source() {
  local skill_md="$1/SKILL.md"
  if [ -f "$skill_md" ]; then
    sed -n '/^---$/,/^---$/p' "$skill_md" | grep -m1 'source:' | sed 's/^.*source:[[:space:]]*//' | tr -d '"' || echo ""
  else
    echo ""
  fi
}

generate_lockfile() {
  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT

  printf '{\n  "version": 1,\n  "generated": "%s",\n  "skills": [\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp"

  local first=true
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    local name hash description source
    name=$(skill_name "$dir")
    hash=$(skill_hash "$dir")
    description=$(skill_description "$dir")
    source=$(skill_source "$dir")

    if [ "$first" = true ]; then
      first=false
    else
      printf ',\n' >> "$tmp"
    fi

    printf '    {"name":"%s","hash":"%s","path":"%s","source":"%s","description":"%s"}' \
      "$name" "$hash" "$(realpath --relative-to="$SQUAD_BASE" "$dir")" "$source" "$description" >> "$tmp"
  done < <(discover_skills)

  printf '\n  ]\n}\n' >> "$tmp"
  mv "$tmp" "$LOCKFILE"
  trap - EXIT
  printf 'lockfile generated: %s\n' "$LOCKFILE"
}

verify_lockfile() {
  if [ ! -f "$LOCKFILE" ]; then
    echo "error: lockfile not found: $LOCKFILE" >&2
    exit 1
  fi

  local failures=0
  local total=0

  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    local name hash stored_hash
    name=$(skill_name "$dir")
    hash=$(skill_hash "$dir")
    total=$((total + 1))

    stored_hash=$(grep -o "\"name\":\"$name\"[^}]*\"hash\":\"[^\"]*\"" "$LOCKFILE" 2>/dev/null | grep -o '"hash":"[^"]*"' | sed 's/"hash":"//;s/"//' || echo "")

    if [ -z "$stored_hash" ]; then
      printf 'MISSING: %s (not in lockfile)\n' "$name"
      failures=$((failures + 1))
    elif [ "$hash" != "$stored_hash" ]; then
      printf 'MISMATCH: %s (installed hash differs from lockfile)\n' "$name"
      failures=$((failures + 1))
    else
      printf 'OK: %s\n' "$name"
    fi
  done < <(discover_skills)

  printf '\n%d/%d skills verified\n' "$((total - failures))" "$total"
  [ "$failures" -eq 0 ] || exit 1
}

case "$MODE" in
  generate) generate_lockfile ;;
  verify) verify_lockfile ;;
esac
