#!/usr/bin/env bash
# Generate or query a skills registry JSON file for CDN-based distribution.
# Scans skills/ directories and produces a machine-readable catalog that can
# be served from a CDN (jsDelivr, unpkg, GitHub Pages, or any static host).
#
# Usage:
#   sq-skill-registry.sh                # generate registry.json to stdout
#   sq-skill-registry.sh --output <f>   # write to file
#   sq-skill-registry.sh --query <name> # look up a skill by name
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"

OUTPUT=""
QUERY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      [ $# -ge 2 ] || { echo "error: --output requires a path" >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    --query)
      [ $# -ge 2 ] || { echo "error: --query requires a skill name" >&2; exit 2; }
      QUERY="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: sq-skill-registry.sh [--output <file>] [--query <name>]\n'
      printf 'Generate or query a skills registry for CDN distribution.\n'
      exit 0
      ;;
    *)
      echo "error: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

# Extract YAML frontmatter field value.
# Handles both single-line values and YAML block scalars (>- and |).
frontmatter_field() {
  local file="$1" field="$2"
  local frontmatter
  frontmatter=$(sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null)
  
  local line
  line=$(echo "$frontmatter" | grep -m1 "^${field}:")
  if [ -z "$line" ]; then
    # Fall back to searching for a nested field (e.g. source: under metadata:).
    line=$(echo "$frontmatter" | grep -m1 "${field}:")
    if [ -z "$line" ]; then
      echo ""
      return
    fi
  fi
  
  local value
  value=$(echo "$line" | sed "s/^.*${field}:[[:space:]]*//" | tr -d '"')
  
  # Check for YAML block scalar indicators.
  if [ "$value" = ">-" ] || [ "$value" = ">" ] || [ "$value" = "|" ] || [ "$value" = "|-" ]; then
    # Read subsequent indented lines to collect the block scalar content.
    local collecting=false
    local block_content=""
    while IFS= read -r block_line; do
      if [ "$collecting" = false ]; then
        # First indented line after block scalar marker.
        if echo "$block_line" | grep -q '^ '; then
          collecting=true
          block_content="${block_line##*[![:space:]]}"
        fi
      else
        # Continue collecting while line is indented or empty.
        if echo "$block_line" | grep -q '^ '; then
          if [ -n "$block_line" ]; then
            block_content="$block_content ${block_line##*[![:space:]]}"
          fi
        else
          # Non-indented line ends the block scalar.
          break
        fi
      fi
    done <<< "$frontmatter"
    
    if [ -n "$block_content" ]; then
      echo "$block_content" | tr -d '"'
    else
      echo ""
    fi
  else
    echo "$value"
  fi
}

# Discover all skills and extract metadata.
generate_registry() {
  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT

  printf '{\n  "version": 1,\n  "generated": "%s",\n  "skills": [\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp"

  local first=true

  # Scan both skill directories.
  for base in "$SQUAD_BASE/.agents/skills" "$SQUAD_BASE/skills"; do
    [ -d "$base" ] || continue
    for skill_dir in "$base"/*/; do
      [ -f "$skill_dir/SKILL.md" ] || continue

      local name description source license user_invocable
      name=$(frontmatter_field "$skill_dir/SKILL.md" "name")
      description=$(frontmatter_field "$skill_dir/SKILL.md" "description")
      source=$(frontmatter_field "$skill_dir/SKILL.md" "source")
      license=$(frontmatter_field "$skill_dir/SKILL.md" "license")
      user_invocable=$(frontmatter_field "$skill_dir/SKILL.md" "user-invocable")

      # Determine visibility category.
      local category="internal"
      if [ -d "$SQUAD_BASE/skills/$name" ]; then
        category="public"
      fi
      if [ "$user_invocable" = "true" ]; then
        category="user-invocable"
      fi

      if [ "$first" = true ]; then
        first=false
      else
        printf ',\n' >> "$tmp"
      fi

      # Escape description for JSON.
      local escaped_desc
      escaped_desc=$(printf '%s' "$description" | sed 's/"/\\"/g' | tr '\n' ' ')

      printf '    {"name":"%s","description":"%s","source":"%s","license":"%s","category":"%s","path":"%s"}' \
        "$name" "$escaped_desc" "$source" "$license" "$category" "$(realpath --relative-to="$SQUAD_BASE" "$skill_dir")" >> "$tmp"
    done
  done

  printf '\n  ]\n}\n' >> "$tmp"

  if [ -n "$OUTPUT" ]; then
    mv "$tmp" "$OUTPUT"
    trap - EXIT
    printf 'registry generated: %s\n' "$OUTPUT"
  else
    cat "$tmp"
    trap - EXIT
  fi
}

# Query the registry for a specific skill.
query_registry() {
  local registry="${OUTPUT:-$SQUAD_BASE/skills-registry.json}"
  if [ ! -f "$registry" ]; then
    echo "error: registry not found: $registry" >&2
    echo "run sq-skill-registry.sh --output $registry first" >&2
    exit 1
  fi
  grep -o "{\"name\":\"$QUERY\"[^}]*}" "$registry" || {
    echo "skill not found: $QUERY" >&2
    exit 1
  }
}

if [ -n "$QUERY" ]; then
  query_registry
else
  generate_registry
fi
