#!/usr/bin/env bash
# Behavioral regressions for sq-skill-registry.sh's frontmatter parsing and
# for --grimoire-output's schema-compliant registry (docs/skill-distribution.md
# "Grimoire registry").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/sq-skill-registry.sh"
VALIDATOR="$ROOT/tests/fixtures/grimoire-registry-validate.mjs"
DIGEST="$ROOT/tests/fixtures/grimoire-digest-files.mjs"
TMP_ROOT=$(fm_test_tmproot sq-skill-registry)

NODE_BIN=$(command -v node || true)

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

# write_public_skill <base> <name> <extra-frontmatter>: creates
# <base>/skills/<name>/SKILL.md (the public, installer-facing location).
write_public_skill() {
  local base="$1" name="$2" body="${3:-}" dir
  dir="$base/skills/$name"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'description: a public skill named %s\n' "$name"
    [ -n "$body" ] && printf '%s\n' "$body"
    printf -- '---\n'
    printf 'Body text.\n'
  } > "$dir/SKILL.md"
}

# write_internal_skill <base> <name> <extra-frontmatter>: creates
# <base>/.agents/skills/<name>/SKILL.md. This location is internal-only: the
# grimoire registry never publishes it, even when the extra frontmatter sets
# user-invocable: true.
write_internal_skill() {
  local base="$1" name="$2" body="${3:-}" dir
  dir="$base/.agents/skills/$name"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'description: an internal skill named %s\n' "$name"
    [ -n "$body" ] && printf '%s\n' "$body"
    printf -- '---\n'
    printf 'Body text.\n'
  } > "$dir/SKILL.md"
}

test_grimoire_output_passes_real_schema_validation() {
  if [ -z "$NODE_BIN" ]; then
    pass "grimoire schema validation (skipped, no node on PATH)"
    return 0
  fi
  local base out rc
  base="$TMP_ROOT/grimoire-valid"
  write_public_skill "$base" sample-public
  write_internal_skill "$base" sample-ui 'user-invocable: true'
  out=$(SQUAD_BASE="$base" "$SCRIPT" --grimoire-output "$base/grimoire.json" --output "$base/legacy.json" 2>&1)
  assert_present "$base/grimoire.json" "grimoire-output writes the schema-compliant registry file"
  "$NODE_BIN" "$VALIDATOR" "$base/grimoire.json" > "$base/validate.out" 2>&1
  rc=$?
  expect_code 0 "$rc" "the generated grimoire registry passes the real validator's checks ($out; $(cat "$base/validate.out"))"
  pass "--grimoire-output produces a registry that validates against validateRegistry's exact checks"
}

test_legacy_output_still_fails_real_schema_validation() {
  if [ -z "$NODE_BIN" ]; then
    pass "legacy schema rejection (skipped, no node on PATH)"
    return 0
  fi
  local base rc
  base="$TMP_ROOT/legacy-invalid"
  write_public_skill "$base" sample-public
  SQUAD_BASE="$base" "$SCRIPT" --output "$base/legacy.json" >/dev/null
  "$NODE_BIN" "$VALIDATOR" "$base/legacy.json" > "$base/validate.out" 2>&1
  rc=$?
  expect_code 1 "$rc" "the legacy registry (no --grimoire-output) still fails validateRegistry, proving the schema gap the new flag closes"
  pass "the legacy registry shape stays unchanged and still fails the MCP server's schema"
}

test_grimoire_output_excludes_internal_only_skill() {
  if [ -z "$NODE_BIN" ]; then
    pass "grimoire internal-only exclusion (skipped, no node on PATH)"
    return 0
  fi
  local base out ids
  base="$TMP_ROOT/grimoire-excludes-internal"
  write_public_skill "$base" visible-public
  write_internal_skill "$base" hidden-internal
  out=$(SQUAD_BASE="$base" "$SCRIPT" --grimoire-output "$base/grimoire.json" 2>&1)
  assert_contains "$out" "1 published, 1 excluded as internal" \
    "generator reports the published/excluded split on stderr"
  ids=$("$NODE_BIN" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).skills.map(s=>s.id).join(","))' "$base/grimoire.json")
  [ "$ids" = "visible-public" ] || fail "expected only visible-public in the registry, got: $ids"
  pass "--grimoire-output excludes internal-only skills from the published catalog"
}

test_grimoire_output_dedupes_internal_counterpart_of_a_public_skill() {
  local base out ids
  base="$TMP_ROOT/grimoire-dedupe"
  write_public_skill "$base" shared-name
  write_internal_skill "$base" shared-name
  out=$(SQUAD_BASE="$base" "$SCRIPT" --grimoire-output "$base/grimoire.json" 2>&1)
  assert_contains "$out" "1 published, 0 excluded as internal" \
    "a name present under both skills/ and .agents/skills/ is published exactly once, from its public copy"
  if [ -n "$NODE_BIN" ]; then
    ids=$("$NODE_BIN" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).skills.map(s=>s.id).join(","))' "$base/grimoire.json")
    [ "$ids" = "shared-name" ] || fail "expected exactly one shared-name entry, got: $ids"
  fi
  pass "a name shared between a public and an internal skill directory is published once, with no duplicate id"
}

test_grimoire_content_sha256_matches_the_real_digestFiles_algorithm() {
  if [ -z "$NODE_BIN" ]; then
    pass "digestFiles fidelity (skipped, no node on PATH)"
    return 0
  fi
  local base expected actual
  base="$TMP_ROOT/grimoire-digest"
  write_public_skill "$base" digest-check
  mkdir -p "$base/skills/digest-check/scripts"
  printf '#!/bin/sh\necho hi\n' > "$base/skills/digest-check/scripts/run.sh"
  SQUAD_BASE="$base" "$SCRIPT" --grimoire-output "$base/grimoire.json" >/dev/null
  expected=$("$NODE_BIN" "$DIGEST" "$base/skills/digest-check" SKILL.md scripts/run.sh)
  actual=$("$NODE_BIN" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).skills.find(s=>s.id==="digest-check").contentSha256)' "$base/grimoire.json")
  [ "$actual" = "$expected" ] || fail "contentSha256 mismatch: generator=$actual real-algorithm=$expected"
  pass "contentSha256 matches an independent reimplementation of digestFiles, not just itself"
}

test_grimoire_excludes_user_invocable_skill_outside_public_dir() {
  if [ -z "$NODE_BIN" ]; then
    pass "user-invocable .agents-only exclusion (skipped, no node on PATH)"
    return 0
  fi
  local base out ids
  base="$TMP_ROOT/grimoire-ui-only"
  write_public_skill "$base" real-public
  write_internal_skill "$base" ui-only 'user-invocable: true'
  out=$(SQUAD_BASE="$base" "$SCRIPT" --grimoire-output "$base/grimoire.json" 2>&1)
  assert_contains "$out" "1 published, 1 excluded as internal" \
    "a .agents/skills/-only skill marked user-invocable: true is still excluded as internal"
  ids=$("$NODE_BIN" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).skills.map(s=>s.id).join(","))' "$base/grimoire.json")
  [ "$ids" = "real-public" ] || fail "expected only real-public in the registry, got: $ids"
  pass "public skills/ location is required even for user-invocable skills"
}

test_grimoire_payload_dir_mirrors_published_skills_only() {
  if [ -z "$NODE_BIN" ]; then
    pass "grimoire payload dir (skipped, no node on PATH)"
    return 0
  fi
  local base payload registry expected actual
  base="$TMP_ROOT/grimoire-payload"
  payload="$base/payload"
  registry="$base/grimoire.json"
  write_public_skill "$base" payload-skill
  mkdir -p "$base/skills/payload-skill/scripts"
  printf '#!/bin/sh\necho hi\n' > "$base/skills/payload-skill/scripts/run.sh"
  write_internal_skill "$base" hidden-internal
  write_internal_skill "$base" ui-only 'user-invocable: true'

  SQUAD_BASE="$base" "$SCRIPT" --grimoire-output "$registry" --grimoire-payload-dir "$payload" >/dev/null 2>&1

  assert_present "$payload/skills/payload-skill/SKILL.md" "payload dir carries the published skill's SKILL.md"
  assert_present "$payload/skills/payload-skill/scripts/run.sh" "payload dir carries the published skill's nested files"
  assert_absent "$payload/skills/hidden-internal" "an internal-only skill must not get a payload directory"
  assert_absent "$payload/skills/ui-only" "a user-invocable .agents-only skill must not get a payload directory"

  expected=$("$NODE_BIN" "$DIGEST" "$payload/skills/payload-skill" SKILL.md scripts/run.sh)
  actual=$("$NODE_BIN" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).skills.find(s=>s.id==="payload-skill").contentSha256)' "$registry")
  [ "$actual" = "$expected" ] || fail "payload files do not match the registry contentSha256: registry=$actual payload=$expected"
  pass "--grimoire-payload-dir mirrors exactly the published skills' hashed files"
}

test_grimoire_payload_dir_requires_grimoire_output() {
  local base rc
  base="$TMP_ROOT/grimoire-payload-requires"
  mkdir -p "$base"
  SQUAD_BASE="$base" "$SCRIPT" --grimoire-payload-dir "$base/payload" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "--grimoire-payload-dir without --grimoire-output is a usage error"
  pass "--grimoire-payload-dir requires --grimoire-output"
}

test_folded_block_scalar_folds_multiline_to_single_line
test_literal_block_scalar_captures_content
test_quoted_single_line_value
test_missing_description_stays_empty
test_grimoire_output_passes_real_schema_validation
test_legacy_output_still_fails_real_schema_validation
test_grimoire_output_excludes_internal_only_skill
test_grimoire_output_dedupes_internal_counterpart_of_a_public_skill
test_grimoire_content_sha256_matches_the_real_digestFiles_algorithm
test_grimoire_excludes_user_invocable_skill_outside_public_dir
test_grimoire_payload_dir_mirrors_published_skills_only
test_grimoire_payload_dir_requires_grimoire_output
