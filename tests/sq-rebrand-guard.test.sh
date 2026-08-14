#!/usr/bin/env bash
# tests/sq-rebrand-guard.test.sh - repo-wide rebrand guards (design.md §8).
#
# Executed as the final gate of M1 (T-M1-12) and enforced in CI afterwards.
# Scans git-tracked content EXCLUDING .specs/ (the planning corpus is the only
# place allowed to name the fork origin and the legal caveat, RISK-01) and
# EXCLUDING this file itself (it legitimately contains the forbidden patterns).
#
# Guards (design.md §8.1-8.7):
#   1. no "firstmate"/"first mate"/"Firstmate" tokens (case-insensitive)
#   2. no upstream author identities: kunchenguid / Kun Chen / @kunchenguid
#   3. no \bfm- or \bfmx- prefixes (fmx- escapes \bfm- and is grepped explicitly)
#   4. no \bFM_ env prefix
#   5. no mapped-sense vocabulary: captain, crewmate, fleet, secondmate,
#      treehouse (case-insensitive and _-adjacency-aware, with the two
#      documented legacy-alias env names allowlisted), ahoy, bearings, stow,
#      wake-queue, "ship task", "scout task", "scout worktree", "the watch",
#      watch.sh, watcher-continuity
#      (natural-English watch/ship/scout outside these patterns is ALLOWED -
#      the allowlist is this exact pattern list, never bare-word greps)
#   6. keep-list asserts: AGENTS.md exists, CLAUDE.md is a symlink to it,
#      .tasks.toml and .drill.yaml exist, .claude/skills symlink intact
#   7. .specs/ is the only location allowed to mention the fork origin/legal
#      caveat (enforced by construction: every guard excludes .specs/)
#   8. packages/*/vendor.json provenance records name the upstream source
#      repository and are exempt the same way .specs/ is: provenance metadata
#      (M3/M5/M6 vendoring pattern), not authorship credit in Squad content.
#   9. every packages/*/package.json npm identity is @runecraft/<dirname>
#      (commander decision 2026-08-14: publish all npm packages under the
#      @runecraft scope because bare names like drill/fob are squatted on
#      npm; bin names and CLI commands are untouched by the rename)
#
# Nivel-2 closure (slice 6, decisions 2026-08-11):
# - `fm_`/`fmx_` function prefixes are native Squad vocabulary (decision 1), so
#   no guard pattern bans them; guard 3 still bans the dash forms.
# - firstmate was already case-insensitive (guard 1); treehouse is now
#   case-insensitive and _-adjacency-aware (guard 5), so TREEHOUSE_* and
#   SQUAD_TREEHOUSE_* identifiers can no longer hide behind case or
#   word-boundary gaps. Only the two documented legacy-alias env names
#   (docs/configuration.md env table, slice-3 contract) stay allowlisted.
#
# Status: drafted at T-M1-01; RED until the M1 sweep completes; runs green at
# T-M1-12 (full-suite gate); treehouse case/adjacency closure landed in the
# Nivel-2 slice-6 finalization. All guards run in one pass and report the FULL
# remaining hit list together.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Files to scan: tracked content, excluding .specs/, this guard file,
# vendored-package provenance records, and binary assets.
tracked_files() {
  git -C "$ROOT" ls-files -z | tr '\0' '\n' \
    | grep -v '^\.specs/' \
    | grep -v '^tests/sq-rebrand-guard.test.sh$' \
    | grep -v '^packages/[^/]*/vendor\.json$' \
    | grep -v '\.png$' \
    | grep -v '\.gif$'
}

# Violations accumulate across all guards so the sweep gate reports the FULL
# remaining hit list in one run instead of stopping at the first guard.
GUARD_FAILURES=""

record_failure() {  # <label> <detail>
  printf -v GUARD_FAILURES '%s-- %s --\n%s\n' "$GUARD_FAILURES" "$1" "$2"
}

# Documented legacy-alias env names that stay legitimate: the two
# SQUAD_TREEHOUSE_RETURN_LOCK_* names are the permanent read-aliases for
# SQUAD_FOB_RETURN_LOCK_* (slice-3 contract, docs/configuration.md env table),
# so guard 5 must not flag them. Every other treehouse token in any case or
# identifier position is a violation.
TREEHOUSE_LEGACY_ALIAS_SED='s/\(^\|[^[:alnum:]_]\)SQUAD_TREEHOUSE_RETURN_LOCK_RETRIES\([^[:alnum:]_]\|$\)/\1\2/g; s/\(^\|[^[:alnum:]_]\)SQUAD_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS\([^[:alnum:]_]\|$\)/\1\2/g'

# guard_no_match <label> <pattern>...
# Records a violation if ANY tracked file matches ANY pattern (fixed -E -I -H -n).
# A pattern may be written case-insensitive with a leading ci: marker, which is
# stripped and applied as a real grep -i flag (grep -E has no inline (?i); the
# marker must stay paren-free for stock macOS Bash 3.2 parsing).
# Each hit is rechecked after stripping the documented legacy-alias tokens, so
# a line that only carried an allowlisted alias is not reported.
guard_no_match() {
  local label=$1; shift
  local pattern file ci hits matches="" keep="" stripped="" hit
  # bash 3.2 (stock macOS) cannot parse `case` inside a $(...) substitution,
  # so the case lives in the function body and only the grep runs in $().
  while IFS= read -r file; do
    for pattern in "$@"; do
      ci=0
      case "$pattern" in
        ci:*) ci=1; pattern=${pattern#ci:} ;;
      esac
      if [ "$ci" -eq 1 ]; then
        hits=$(grep -I -i -H -n -E -e "$pattern" -- "$ROOT/$file" 2>/dev/null | sed "s|^$ROOT/||")
      else
        hits=$(grep -I -H -n -E -e "$pattern" -- "$ROOT/$file" 2>/dev/null | sed "s|^$ROOT/||")
      fi
      if [ -n "$hits" ]; then
        keep=""
        while IFS= read -r hit; do
          stripped=$(printf '%s\n' "$hit" | sed "$TREEHOUSE_LEGACY_ALIAS_SED")
          if [ "$ci" -eq 1 ]; then
            printf '%s\n' "$stripped" | grep -qi -E -e "$pattern" \
              && keep="${keep}${keep:+$'\n'}${hit}"
          else
            printf '%s\n' "$stripped" | grep -q -E -e "$pattern" \
              && keep="${keep}${keep:+$'\n'}${hit}"
          fi
        done <<< "$hits"
        [ -n "$keep" ] && matches="${matches}${matches:+$'\n'}${keep}"
      fi
    done
  done < <(tracked_files)
  if [ -n "$matches" ]; then
    record_failure "$label" "$matches"
  else
    pass "$label"
  fi
}

test_guard_npm_scope() {
  local dir name expected failures=""
  for dir in "$ROOT"/packages/*/; do
    [ -f "$dir/package.json" ] || continue
    name=$(sed -n 's/^[[:space:]]*"name": "\([^"]*\)".*/\1/p' "$dir/package.json" | head -1)
    expected="@runecraft/$(basename "$dir")"
    if [ -z "$name" ] || [ "$name" != "$expected" ]; then
      failures="${failures}${failures:+$'\n'}packages/$(basename "$dir")/package.json name is '${name:-<unparsed>}', expected '$expected'"
    fi
  done
  if [ -n "$failures" ]; then
    record_failure "rebrand guard 9: npm identity is @runecraft-scoped" "$failures"
  else
    pass "rebrand guard 9: every packages/*/package.json npm name is @runecraft/<dir>"
  fi
}

test_guard_no_firstmate_tokens() {
  guard_no_match "rebrand guard 1: no firstmate tokens (excluding .specs/)" \
    'ci:firstmate|first mate'
}

test_guard_no_upstream_authors() {
  guard_no_match "rebrand guard 2: no upstream author identities (excluding .specs/)" \
    'ci:kunchenguid|kun chen|@kunchenguid'
}

test_guard_no_fm_prefix() {
  guard_no_match "rebrand guard 3: no \bfm- or \bfmx- prefixes (excluding .specs/)" \
    '\bfm-|\bfmx-'
}

test_guard_no_fm_env_prefix() {
  guard_no_match "rebrand guard 4: no \bFM_ env prefix (excluding .specs/)" \
    '\bFM_'
}

test_guard_no_mapped_vocabulary() {
  guard_no_match \
    "rebrand guard 5: no mapped-sense vocabulary (excluding .specs/)" \
    '\bcaptain\b' \
    '\bcrewmate\b' \
    '\bfleet\b' \
    '\bsecondmate\b' \
    'ci:(^|[^[:alpha:]])treehouse([^[:alpha:]]|$)' \
    '\bahoy\b' \
    '\bbearings\b' \
    '\bstow\b' \
    '\bwake-queue\b' \
    '\bship task\b' \
    '\bscout task\b' \
    '\bscout worktree\b' \
    '\bthe watch\b' \
    'watch\.sh' \
    'watcher-continuity'
}

test_guard_alias_allowlist_is_exact() {
  local pattern='(^|[^[:alpha:]])treehouse([^[:alpha:]]|$)'
  local line stripped
  for line in \
    'export SQUAD_TREEHOUSE_RETURN_LOCK_RETRIES=3' \
    "FOB_RETURN_LOCK_RETRIES=\${SQUAD_FOB_RETURN_LOCK_RETRIES:-\${SQUAD_TREEHOUSE_RETURN_LOCK_RETRIES:-3}}" \
    'SQUAD_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0.1' \
    "\`SQUAD_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS\` remains a compatible fallback"; do
    stripped=$(printf '%s\n' "$line" | sed "$TREEHOUSE_LEGACY_ALIAS_SED")
    if printf '%s\n' "$stripped" | grep -qi -E -e "$pattern"; then
      fail "guard 5 allowlist: exact documented alias still flagged: $line"
    fi
  done
  for line in \
    'SQUAD_TREEHOUSE_RETURN_LOCK_RETRIES_EXTRA=1' \
    'XSQUAD_TREEHOUSE_RETURN_LOCK_RETRIES=1' \
    'SQUAD_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS_MAX=1'; do
    stripped=$(printf '%s\n' "$line" | sed "$TREEHOUSE_LEGACY_ALIAS_SED")
    if ! printf '%s\n' "$stripped" | grep -qi -E -e "$pattern"; then
      fail "guard 5 allowlist: extended alias escaped the strip: $line"
    fi
  done
  pass "rebrand guard 5: allowlist strips only exact legacy-alias names"
}

test_guard_keep_list() {
  [ -f "$ROOT/AGENTS.md" ] || record_failure "rebrand guard 6: keep-list" "AGENTS.md missing"
  [ -L "$ROOT/CLAUDE.md" ] || record_failure "rebrand guard 6: keep-list" "CLAUDE.md is not a symlink"
  { [ -L "$ROOT/CLAUDE.md" ] && [ "$(readlink "$ROOT/CLAUDE.md")" = AGENTS.md ]; } \
    || record_failure "rebrand guard 6: keep-list" "CLAUDE.md does not point at AGENTS.md"
  [ -f "$ROOT/.tasks.toml" ] || record_failure "rebrand guard 6: keep-list" ".tasks.toml missing"
  [ -f "$ROOT/.drill.yaml" ] || record_failure "rebrand guard 6: keep-list" ".drill.yaml missing"
  [ -L "$ROOT/.claude/skills" ] || record_failure "rebrand guard 6: keep-list" ".claude/skills is not a symlink"
  if [ -z "$GUARD_FAILURES" ]; then
    pass "rebrand guard 6: keep-list asserts (AGENTS.md, CLAUDE.md symlink, .tasks.toml, .drill.yaml, .claude/skills symlink)"
  fi
}

test_guard_no_firstmate_tokens
test_guard_no_upstream_authors
test_guard_no_fm_prefix
test_guard_no_fm_env_prefix
test_guard_no_mapped_vocabulary
test_guard_alias_allowlist_is_exact
test_guard_keep_list
test_guard_npm_scope

if [ -n "$GUARD_FAILURES" ]; then
  printf 'not ok - rebrand guards: %s violation(s) remain (excluding .specs/)\n' \
    "$(printf '%s' "$GUARD_FAILURES" | grep -c '^-- ')" >&2
  printf '%s' "$GUARD_FAILURES" >&2
  exit 1
fi
exit 0
