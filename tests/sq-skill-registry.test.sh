#!/usr/bin/env bash
# Behavioral regressions for sq-skill-registry.sh's frontmatter parsing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/sq-skill-registry.sh"
TMP_ROOT=$(fm_test_tmproot sq-skill-registry)

# write_skill <base> <name> <frontmatter-body>: creates
# <base>/.agents/skills/<name>/SKILL.md with a --- delimited frontmatter block
# holding the given body plus a name: field, and a one-line markdown body.
write_skill() {
  local base="$1" name="$2" body="$3" dir
  dir="$base/.agents/skills/$name"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf '%s\n' "$body"
    printf -- '---\n'
    printf 'Body text.\n'
  } > "$dir/SKILL.md"
}

test_folded_block_scalar_folds_multiline_to_single_line() {
  local base out
  base="$TMP_ROOT/folded"
  write_skill "$base" folded-desc "$(printf 'description: >-\n  This is line one of the description.\n  This is line two of the description.\nlicense: MIT')"
  out=$(SQUAD_BASE="$base" "$SCRIPT")
  assert_contains "$out" '"description":"This is line one of the description. This is line two of the description."' \
    "folded block scalar keeps both lines and folds them to one space-joined string"
  pass "folded (>-) block scalar with the marker on its own line keeps all content"
}

test_literal_block_scalar_captures_content() {
  local base out
  base="$TMP_ROOT/literal"
  write_skill "$base" literal-desc "$(printf 'description: |\n  Line one here.\n  Line two here.\nlicense: MIT')"
  out=$(SQUAD_BASE="$base" "$SCRIPT")
  assert_contains "$out" '"description":"Line one here. Line two here."' \
    "literal block scalar keeps all content"
  pass "literal (|) block scalar with the marker on its own line keeps all content"
}

test_quoted_single_line_value() {
  local base out
  base="$TMP_ROOT/quoted"
  write_skill "$base" quoted-desc 'description: "A quoted single-line value."'
  out=$(SQUAD_BASE="$base" "$SCRIPT")
  assert_contains "$out" '"description":"A quoted single-line value."' \
    "quoted single-line description keeps its text"
  pass "quoted single-line description value is captured"
}

test_missing_description_stays_empty() {
  local base out
  base="$TMP_ROOT/missing"
  write_skill "$base" no-desc 'license: MIT'
  out=$(SQUAD_BASE="$base" "$SCRIPT")
  assert_contains "$out" '"name":"no-desc","description":""' \
    "a skill declaring no description comes out empty, not invented"
  pass "a skill with no description field at all stays empty"
}

test_folded_block_scalar_folds_multiline_to_single_line
test_literal_block_scalar_captures_content
test_quoted_single_line_value
test_missing_description_stays_empty
