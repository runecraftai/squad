#!/usr/bin/env bash
# Generate or query a skills registry JSON file for CDN-based distribution.
# Scans skills/ directories and produces a machine-readable catalog that can
# be served from a CDN (jsDelivr, unpkg, GitHub Pages, or any static host).
#
# --grimoire-output additionally emits a second, schema-compliant registry
# (docs/skill-distribution.md "Grimoire registry") that validates against
# @runecraft/skills' packages/core/src/index.ts `validateRegistry` - the
# schema the skills MCP server (`@runecraft/grimoire-mcp`) requires. It is a
# separate file: the legacy registry above keeps its own shape unchanged for
# existing consumers.
#
# Usage:
#   sq-skill-registry.sh                       # generate registry.json to stdout
#   sq-skill-registry.sh --output <f>          # write the legacy registry to file
#   sq-skill-registry.sh --query <name>        # look up a skill by name (legacy registry)
#   sq-skill-registry.sh --grimoire-output <f> # also write the schema-compliant registry
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"

OUTPUT=""
QUERY=""
GRIMOIRE_OUTPUT=""

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
    --grimoire-output)
      [ $# -ge 2 ] || { echo "error: --grimoire-output requires a path" >&2; exit 2; }
      GRIMOIRE_OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: sq-skill-registry.sh [--output <file>] [--query <name>] [--grimoire-output <file>]\n'
      printf 'Generate or query a skills registry for CDN distribution.\n'
      printf -- '--grimoire-output additionally writes the schema-compliant registry the skills MCP needs.\n'
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

  local matched
  matched=$(printf '%s\n' "$frontmatter" | grep -n -m1 "^${field}:") || true
  if [ -z "$matched" ]; then
    # Fall back to searching for a nested field (e.g. source: under metadata:).
    matched=$(printf '%s\n' "$frontmatter" | grep -n -m1 "${field}:") || true
    if [ -z "$matched" ]; then
      echo ""
      return
    fi
  fi

  local line_no line
  line_no="${matched%%:*}"
  line="${matched#*:}"

  local value
  value=$(printf '%s\n' "$line" | sed "s/^.*${field}:[[:space:]]*//" | tr -d '"')

  # Check for YAML block scalar indicators.
  if [ "$value" = ">-" ] || [ "$value" = ">" ] || [ "$value" = "|" ] || [ "$value" = "|-" ]; then
    # Collect indented lines after the field's own line, folding them to a
    # single space-joined string; a blank line within the block is skipped,
    # and the first non-indented, non-blank line ends the block.
    local block_content="" block_line trimmed
    while IFS= read -r block_line; do
      if printf '%s\n' "$block_line" | grep -q '^[[:space:]]*$'; then
        continue
      fi
      if printf '%s\n' "$block_line" | grep -q '^[[:space:]]'; then
        trimmed=$(printf '%s' "$block_line" | sed 's/^[[:space:]]*//')
        if [ -z "$block_content" ]; then
          block_content="$trimmed"
        else
          block_content="$block_content $trimmed"
        fi
      else
        break
      fi
    done < <(printf '%s\n' "$frontmatter" | tail -n "+$((line_no + 1))")

    if [ -n "$block_content" ]; then
      printf '%s\n' "$block_content" | tr -d '"'
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

# --- Grimoire (schema-compliant) registry -----------------------------------
#
# Emits a second registry matching the Registry/Skill types validated by
# @runecraft/skills' packages/core/src/index.ts (`validateRegistry`, lines
# 5-7 and 21-31 as read from the runecraftai/skills clone on 2026-10-06):
# exact key sets, schemaVersion=1, per-skill contentSha256 over the skill's
# own files, and non-empty attribution carrying an https: URL. That package
# is not a dependency of this repo and is not consumed directly here; this
# generator targets its documented schema instead.
#
# Only public and explicitly user-invocable skills are included - an
# internal-only skill (category=internal) is counted and reported on stderr
# but never written to this file, per docs/skill-distribution.md "Grimoire
# registry" distribution policy. A name present under both skills/ and
# .agents/skills/ (an internal counterpart of a public skill) is published
# once, from its public skills/ directory.

# Sanitize an arbitrary skill name into the lowercase hyphenated id the
# schema requires (^[a-z0-9]+(?:-[a-z0-9]+)*$).
grimoire_sanitize_id() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# JSON-escape a string for embedding in a double-quoted JSON value, covering
# every C0 control character (and DEL) so a skill's text can never emit JSON
# that a strict parser rejects.
grimoire_json_escape() {
  local s="$1" out="" ch i hex
  local len=${#s}
  for ((i = 0; i < len; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      '\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\b') out+='\b' ;;
      $'\t') out+='\t' ;;
      $'\n') out+='\n' ;;
      $'\f') out+='\f' ;;
      $'\r') out+='\r' ;;
      *)
        if [[ "$ch" == [[:cntrl:]] ]]; then
          printf -v hex '\\u%04x' "$(printf '%d' "'$ch")"
          out+="$hex"
        else
          out+="$ch"
        fi
        ;;
    esac
  done
  printf '%s' "$out"
}

# Hash a file, or stdin when given no argument, with whichever SHA-256 tool
# the platform provides (macOS ships shasum, not sha256sum). Prints the hex
# digest only.
grimoire_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" | awk '{print $1}'
  else
    echo "error: sha256sum or shasum is required" >&2
    return 1
  fi
}

# Compute the per-file records and the aggregate contentSha256 for one skill
# directory, matching @runecraft/skills' digestFiles exactly: sort files by
# raw byte path order, then hash path bytes + a single NUL byte + file bytes,
# for each file in that order (packages/core/src/index.ts:13-17). Prints
# "<contentSha256>\x1e<files-json-array>" to stdout.
grimoire_skill_files() {
  local skill_dir="$1" rel_list content_sha256
  rel_list=$(mktemp)
  (cd "$skill_dir" && find . -type f | sed 's|^\./||') | LC_ALL=C sort > "$rel_list"

  content_sha256=$(
    {
      while IFS= read -r rel; do
        printf '%s' "$rel"
        printf '\0'
        cat "$skill_dir/$rel"
      done < "$rel_list"
    } | grimoire_sha256
  )

  local files_json="" first=true rel size sha
  while IFS= read -r rel; do
    size=$(LC_ALL=C wc -c < "$skill_dir/$rel" | tr -d ' ')
    sha=$(grimoire_sha256 "$skill_dir/$rel")
    if [ "$first" = true ]; then first=false; else files_json="$files_json,"; fi
    files_json="$files_json{\"path\":\"$(grimoire_json_escape "$rel")\",\"sha256\":\"$sha\",\"size\":$size}"
  done < "$rel_list"

  rm -f "$rel_list"
  printf '%s\x1e[%s]' "$content_sha256" "$files_json"
}

generate_grimoire_registry() {
  local tmp seen
  tmp=$(mktemp)
  seen=$(mktemp)
  trap 'rm -f "$tmp" "$seen"' RETURN

  local catalog_version="squad-skills" revision generated_at
  revision=$(git -C "$SQUAD_BASE" rev-parse --short=12 HEAD 2>/dev/null) || revision="unversioned-$(date -u +%s)"
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  printf '{\n  "schemaVersion": 1,\n  "catalogVersion": "%s",\n  "revision": "%s",\n  "generatedAt": "%s",\n  "skills": [\n' \
    "$catalog_version" "$revision" "$generated_at" > "$tmp"

  local first=true published=0 excluded=0 base skill_dir name

  for base in "$SQUAD_BASE/skills" "$SQUAD_BASE/.agents/skills"; do
    [ -d "$base" ] || continue
    for skill_dir in "$base"/*/; do
      [ -f "$skill_dir/SKILL.md" ] || continue
      name=$(frontmatter_field "$skill_dir/SKILL.md" "name")
      [ -n "$name" ] || name=$(basename "$skill_dir")
      if grep -Fxq "$name" "$seen" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$name" >> "$seen"

      local user_invocable is_public category
      user_invocable=$(frontmatter_field "$skill_dir/SKILL.md" "user-invocable")
      if [ "$base" = "$SQUAD_BASE/skills" ]; then
        is_public=true
      else
        is_public=false
      fi
      if [ "$user_invocable" = "true" ]; then
        category="user-invocable"
      elif [ "$is_public" = true ]; then
        category="public"
      else
        category="internal"
      fi

      if [ "$category" = "internal" ]; then
        excluded=$((excluded + 1))
        continue
      fi

      local id version description license source attrib_text
      id=$(grimoire_sanitize_id "$name")
      version=$(frontmatter_field "$skill_dir/SKILL.md" "version")
      [ -n "$version" ] || version="1.0.0"
      description=$(frontmatter_field "$skill_dir/SKILL.md" "description")
      [ -n "$description" ] || description="$name"
      license=$(frontmatter_field "$skill_dir/SKILL.md" "license")
      [ -n "$license" ] || license="MIT"
      source=$(frontmatter_field "$skill_dir/SKILL.md" "source")
      attrib_text=$(frontmatter_field "$skill_dir/SKILL.md" "attribution")
      [ -n "$attrib_text" ] || attrib_text="Distributed via Runecraft Squad"

      local attrib_name attrib_url
      case "$source" in
        */*)
          attrib_name="$source"
          attrib_url="https://github.com/$source"
          ;;
        *)
          attrib_name="Runecraft Squad"
          attrib_url="https://github.com/runecraftai/squad"
          ;;
      esac

      local hashed content_sha256 files_json
      hashed=$(grimoire_skill_files "$skill_dir")
      content_sha256="${hashed%%$'\x1e'*}"
      files_json="${hashed#*$'\x1e'}"

      if [ "$first" = true ]; then first=false; else printf ',\n' >> "$tmp"; fi
      printf '    {"id":"%s","name":"%s","version":"%s","category":"%s","description":"%s","license":"%s","attribution":[{"name":"%s","url":"%s","text":"%s"}],"entrypoint":"SKILL.md","files":%s,"contentSha256":"%s"}' \
        "$id" "$(grimoire_json_escape "$name")" "$(grimoire_json_escape "$version")" "$category" \
        "$(grimoire_json_escape "$description")" "$(grimoire_json_escape "$license")" \
        "$(grimoire_json_escape "$attrib_name")" "$attrib_url" "$(grimoire_json_escape "$attrib_text")" \
        "$files_json" "$content_sha256" >> "$tmp"

      published=$((published + 1))
    done
  done

  printf '\n  ]\n}\n' >> "$tmp"
  mv "$tmp" "$GRIMOIRE_OUTPUT"
  printf 'grimoire registry generated: %s (%d published, %d excluded as internal)\n' \
    "$GRIMOIRE_OUTPUT" "$published" "$excluded" >&2
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

if [ -n "$GRIMOIRE_OUTPUT" ]; then
  generate_grimoire_registry
fi
