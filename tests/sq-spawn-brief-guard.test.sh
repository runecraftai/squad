#!/usr/bin/env bash
# Regression test for refusing an unedited operator brief before dispatch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/sq-spawn.sh"
TMP_ROOT=$(fm_test_tmproot sq-spawn-brief-guard)
CASE_DIR="$TMP_ROOT/case"
HOME_DIR="$CASE_DIR/home"
PROJ_DIR="$CASE_DIR/project"
WT_DIR="$CASE_DIR/worktree"
FAKEBIN=$(fm_fakebin "$CASE_DIR/fake")
ID=brief-guard-test

mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
fm_git_worktree "$PROJ_DIR" "$WT_DIR" "brief-guard-test"
printf '%s\n' '# Task' '{TASK}' "echo done >> $HOME_DIR/state/$ID.status" > "$HOME_DIR/data/$ID/brief.md"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${SQUAD_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'Squad\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" fob

run_spawn() {
  SQUAD_BASE="$HOME_DIR" SQUAD_STATE_OVERRIDE="$HOME_DIR/state" \
    SQUAD_DATA_OVERRIDE="$HOME_DIR/data" SQUAD_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    SQUAD_CONFIG_OVERRIDE="$HOME_DIR/config" SQUAD_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" SQUAD_FAKE_PANE_PATH="$WT_DIR" PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$ID" "$PROJ_DIR" --mode drill --yolo off 2>&1
}

out=$(run_spawn)
status=$?
[ "$status" -ne 0 ] || fail "spawn accepted a brief with the literal {TASK} line"
assert_contains "$out" "literal {TASK} placeholder" "refusal did not identify the unreplaced task placeholder"
[ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "refused placeholder brief left task metadata behind"

printf '%s\n' '# Task' 'Do the real work.' "echo done >> $HOME_DIR/state/$ID.status" > "$HOME_DIR/data/$ID/brief.md"
out=$(run_spawn)
status=$?
expect_code 0 "$status" "spawn should pass the brief placeholder check after substitution (got: $out)"
assert_contains "$out" "spawned $ID" "substituted brief did not reach a successful spawn"
pass "sq-spawn refuses the literal task scaffold and accepts a substituted brief"
