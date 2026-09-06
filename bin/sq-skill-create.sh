#!/usr/bin/env bash
# Generate a new skill package from a natural-language description.
# Produces a complete skill directory with SKILL.md (frontmatter,
# Triggers, Do NOT use for, example usage, validation checklist),
# optional tests/ stub, and format/trigger validation.
#
# Usage:
#   sq-skill-create.sh "<description>"
#     Interactive mode — prints generated content for review.
#   sq-skill-create.sh "<description>" --name <name> --dir <path>
#     Non-interactive mode — generates to <path>/<name>/.
#   sq-skill-create.sh "<description>" --name <name> --dir <path> --approve
#     Generates and installs to the target location.
#   sq-skill-create.sh "<description>" --name <name> --dir <path> --tests
#     Also creates a tests/ stub directory.
#
# Exit codes:
#   0  success
#   1  usage error or validation failure
#   2  bad arguments
set -euo pipefail

# ── usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
usage: sq-skill-create.sh "<description>" [--name <name>] [--dir <path>] [--approve] [--tests]

Generate a new skill package from a description.

Arguments:
  <description>   Natural-language description of what the skill does.
  --name <name>   Skill directory name (auto-derived from description when omitted).
  --dir <path>    Parent directory for the skill (default: current directory).
  --approve       Copy generated content to the target location.
  --tests         Create a tests/ stub inside the skill directory.

Without --approve the script prints the generated SKILL.md for review and exits.
EOF
}

# ── parse arguments ──────────────────────────────────────────────────────────

DESCRIPTION=""
SKILL_NAME=""
TARGET_DIR=""
APPROVE=0
CREATE_TESTS=0

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --name)
      [[ $# -ge 2 ]] || { echo "error: --name requires a value" >&2; exit 2; }
      SKILL_NAME="$2"; shift 2 ;;
    --dir)
      [[ $# -ge 2 ]] || { echo "error: --dir requires a value" >&2; exit 2; }
      TARGET_DIR="$2"; shift 2 ;;
    --approve) APPROVE=1; shift ;;
    --tests) CREATE_TESTS=1; shift ;;
    -*) echo "error: unknown flag '$1'" >&2; exit 2 ;;
    *)
      if [[ -z "$DESCRIPTION" ]]; then
        DESCRIPTION="$1"; shift
      else
        echo "error: unexpected argument '$1'" >&2; exit 2
      fi
      ;;
  esac
done

[[ -n "$DESCRIPTION" ]] || { echo "error: description is required" >&2; exit 2; }

# ── resolve paths ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_FORMAT="$SCRIPT_DIR/sq-check-skill-format.sh"
VALIDATE_TRIGGERS="$SCRIPT_DIR/sq-check-skill-triggers.sh"

# Auto-derive skill name from description if not provided.
if [[ -z "$SKILL_NAME" ]]; then
  SKILL_NAME=$(echo "$DESCRIPTION" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
    | cut -d'-' -f1-4)
  [[ -n "$SKILL_NAME" ]] || SKILL_NAME="new-skill"
fi

# Auto-derive target directory.
if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR="$(pwd)"
fi

SKILL_DIR="$TARGET_DIR/$SKILL_NAME"
TEMP_DIR=""
cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

# ── generate trigger phrases from description ────────────────────────────────

generate_triggers() {
  local desc="$1"
  local triggers=()

  # Build trigger phrases from common patterns
  triggers+=("Use when the user asks to ${desc%%.*}.")
  triggers+=("Activates for ${desc%%.*}.")

  # Extract key nouns/verbs from the description for trigger matching
  local keywords
  keywords=$(echo "$desc" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | \
    grep -vxE '(a|an|the|is|are|was|were|be|been|being|have|has|had|do|does|did|will|would|shall|should|may|might|can|could|must|need|to|of|in|for|on|with|at|by|from|as|into|through|during|before|after|above|below|between|out|off|over|under|again|further|then|once|that|this|these|those|and|but|or|nor|not|no|so|if|when|while|where|how|what|which|who|whom|whose|it|its|you|your|i|my|we|our|they|their|he|she|his|her|me|us|them|also|just|only|very|more|most|some|any|all|each|every|both|few|many|much|such)' | \
    sort -u | head -6)

  for kw in $keywords; do
    triggers+=("Trigger on \"$kw\".")
  done

  printf '%s\n' "${triggers[@]}"
}

# ── generate anti-triggers from description ──────────────────────────────────

generate_anti_triggers() {
  local desc="$1"
  local anti=()

  anti+=("Do NOT use for tasks outside the scope of ${desc%%.*}.")
  anti+=("Do NOT use for general-purpose operations unrelated to the core purpose.")
  anti+=("Do NOT use when a more specific skill already covers the request.")

  printf '%s\n' "${anti[@]}"
}

# ── generate SKILL.md content ────────────────────────────────────────────────

generate_skill_md() {
  local name="$1"
  local desc="$2"
  local tmpfile="$3"

  # Derive a human-readable title from the skill name.
  local title
  title=$(echo "$name" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')

  # Derive a short one-line summary for the description field.
  local short_desc
  short_desc=$(echo "$desc" | head -c 200)

  # Collect triggers
  local trigger_lines
  trigger_lines=$(generate_triggers "$desc")

  # Collect anti-triggers
  local anti_lines
  anti_lines=$(generate_anti_triggers "$desc")

  cat > "$tmpfile" <<SKILLEOF
---
name: ${name}
description: >-
  ${short_desc}.
user-invocable: true
metadata:
  generated: true
---

# ${title}

${desc}

## Triggers

${trigger_lines}

## Do NOT use for

${anti_lines}

## Example usage

\`\`\`
User: ${desc%%.*}
Skill: Loads and applies the relevant procedure.
\`\`\`

## Validation checklist

- [ ] SKILL.md has valid frontmatter (name, description)
- [ ] Triggers section is present and non-empty
- [ ] Do NOT use for section is present
- [ ] Description accurately reflects the skill purpose
- [ ] No overlap with existing skills
SKILLEOF
}

# ── main logic ───────────────────────────────────────────────────────────────

# Create a temp directory for generation and validation.
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sq-skill-create.XXXXXX") || {
  echo "error: failed to create temp directory" >&2
  exit 1
}

TEMP_SKILL_DIR="$TEMP_DIR/$SKILL_NAME"
mkdir -p "$TEMP_SKILL_DIR"

# Generate the SKILL.md
SKILL_MD="$TEMP_SKILL_DIR/SKILL.md"
generate_skill_md "$SKILL_NAME" "$DESCRIPTION" "$SKILL_MD"

echo "=== Generated SKILL.md ==="
cat "$SKILL_MD"
echo ""
echo "=========================="

# Validate format
echo ""
echo "Validating format..."
if ! bash "$VALIDATE_FORMAT" "$TEMP_SKILL_DIR"; then
  echo "error: generated SKILL.md failed format validation" >&2
  exit 1
fi
echo "Format validation: PASSED"

# Validate triggers
echo ""
echo "Validating triggers..."
if ! bash "$VALIDATE_TRIGGERS" "$TEMP_SKILL_DIR"; then
  echo "error: generated SKILL.md failed trigger validation" >&2
  exit 1
fi
echo "Trigger validation: PASSED"

# Create tests/ stub if requested
if [[ "$CREATE_TESTS" -eq 1 ]]; then
  mkdir -p "$TEMP_SKILL_DIR/tests"
  cat > "$TEMP_SKILL_DIR/tests/test-${SKILL_NAME}.sh" <<TESTEOF
#!/usr/bin/env bash
# Behavioral regressions for ${SKILL_NAME} skill.
set -u

# shellcheck source=tests/lib.sh
. "\$(dirname "\${BASH_SOURCE[0]}")/lib.sh"

SKILL_DIR="\$ROOT/.agents/skills/${SKILL_NAME}"

test_skill_exists() {
  assert_present "\$SKILL_DIR/SKILL.md" "skill SKILL.md should exist"
  pass "skill directory has SKILL.md"
}

test_skill_has_triggers() {
  local triggers
  triggers=\$(sed -n '/^## Triggers/,/^## /p' "\$SKILL_DIR/SKILL.md" | head -n -1)
  [ -n "\$triggers" ] || fail "Triggers section should not be empty"
  pass "skill has non-empty Triggers section"
}

test_skill_has_anti_triggers() {
  local anti
  anti=\$(sed -n '/^## Do NOT use for/,/^## /p' "\$SKILL_DIR/SKILL.md" | head -n -1)
  [ -n "\$anti" ] || fail "Do NOT use for section should not be empty"
  pass "skill has non-empty Do NOT use for section"
}

test_skill_exists
test_skill_has_triggers
test_skill_has_anti_triggers
TESTEOF
  chmod +x "$TEMP_SKILL_DIR/tests/test-${SKILL_NAME}.sh"
  echo ""
  echo "Created tests/test-${SKILL_NAME}.sh"
fi

# Approve: copy to target
if [[ "$APPROVE" -eq 1 ]]; then
  if [[ -d "$SKILL_DIR" ]]; then
    echo "error: target directory already exists: $SKILL_DIR" >&2
    echo "Remove it first or choose a different name." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$SKILL_DIR")"
  cp -r "$TEMP_SKILL_DIR" "$SKILL_DIR"
  echo ""
  echo "Installed skill to: $SKILL_DIR"
else
  echo ""
  echo "Generated skill in temp directory: $TEMP_SKILL_DIR"
  echo "Run with --approve to install to: $SKILL_DIR"
fi

echo ""
echo "Skill creation complete."
