#!/usr/bin/env bash
# Tests for bin/sq-update.sh: fast-forward-only self-update of a running
# Squad repo and every registered XO home.
#
# The guarantees under test mirror sq-unit-sync.sh and prime directive #3:
#   - The running Squad repo (on its default branch) fast-forwards from
#     origin; a leased XO home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-Squad flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-XOs lists exactly the live XOs that advanced.
#   - XO homes resolve from both state/<id>.meta and the
#     data/XOs.md registry, deduped, and the Squad repo is never
#     re-processed as one of its own XOs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/sq-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot sq-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a Squad repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh sentry beacon keeps sq-guard quiet.
  touch "$w/home/state/.last-sentry-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add an XO home as a DETACHED worktree of the Squad repo (matching
# how fob leases an XO home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:sq-%s\n' "$id"
    printf 'kind=xo\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.sq-xo-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  SQUAD_ROOT_OVERRIDE="$w/main" SQUAD_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + XO behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_XO() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "Squad: updated " "Squad fast-forwarded"
  assert_contains "$out" "XO sm1: updated " "XO fast-forwarded"
  assert_contains "$out" "reread-Squad: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-XOs: sq-sm1" "updated XO is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "Squad HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "XO HEAD not at origin/main"
  # Squad stays on its default branch; XO stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "Squad left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "XO worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "Squad tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "XO tip is not a single-parent fast-forward"
  pass "T1 main + XO fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "Squad: updated " "Squad still advanced"
  assert_contains "$out" "reread-Squad: no" "non-instruction change skips reread"
  # The XO still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-XOs: sq-sm1" "advanced XO still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty XO is skipped, its edit preserved -------------------
test_dirty_XO_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "XO sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "sq-sm1" "skipped XO is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty XO skipped, local edit preserved"
}

# --- T5: diverged XO is skipped, its commit preserved --------------
test_diverged_XO_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the XO's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "XO sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "sq-sm1" "diverged XO is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged XO HEAD moved (unlanded work at risk)"
  pass "T5 diverged XO skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "Squad: already current" "Squad already current"
  assert_contains "$out" "XO sm1: already current" "XO already current"
  assert_contains "$out" "reread-Squad: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-XOs: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every XO-resolution edge at once:
#   reg1 - registered in XOs.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the Squad repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the Squad repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.sq-xo-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/XOs.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "XO reg1: updated " "registry-only XO fast-forwarded"
  assert_contains "$out" "XO sm1: updated " "meta+registry XO fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^XO sm1:' || true)
  [ "$count" -eq 1 ] || fail "XO sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "XO selfish" "Squad repo re-processed as its own XO"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'XO reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-XOs:')
  assert_contains "$nudge_line" "sq-sm1" "live-meta XO is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only XO without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the Squad repo"
}

# --- T9: Squad repo on a feature branch is skipped ---------------------
test_Squad_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate Squad mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "Squad: skipped: on feature/wip, expected main" "off-default Squad skipped"
  assert_contains "$out" "reread-Squad: no" "no reread when Squad was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped Squad HEAD moved"
  pass "T9 Squad off its default branch is skipped, not forced"
}

test_Squad_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "Squad: skipped: detached HEAD, expected main" "detached Squad skipped"
  assert_contains "$out" "reread-Squad: no" "no reread when detached Squad was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached Squad HEAD moved"
  pass "T10 Squad detached HEAD is skipped"
}

test_unsafe_XO_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.sq-xo-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/XOs.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "XO bad: skipped: unsafe home: XO home cannot be inside the active Squad home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-XOs: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe XO home HEAD moved"
  pass "T11 unsafe XO home is not fast-forwarded"
}

test_updates_main_and_XO
test_reread_gate_is_instruction_only
test_dirty_XO_skipped
test_diverged_XO_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_Squad_wrong_branch_skipped
test_Squad_detached_head_skipped
test_unsafe_XO_home_skipped_before_git_update

echo "# all sq-update tests passed"
