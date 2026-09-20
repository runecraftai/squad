#!/usr/bin/env bash
# Behavioral tests for WORKFLOW.md spawn integration.
# Invokes sq-spawn.sh with and without WORKFLOW.md and asserts that the
# workflow= and workflow_config= lines appear (or do not appear) in the
# resulting state/<id>.meta, without requiring a running backend.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Mock SQUAD_ROOT: a self-contained root with symlinks to real scripts and
# overridden stubs for gate-refuse, busy-event, guard, harness, project-mode,
# operational-input, and the tmux adapter.
# ---------------------------------------------------------------------------
MOCK_ROOT="$TMP/mock-squad-root"
rm -rf "$MOCK_ROOT"
mkdir -p "$MOCK_ROOT/bin/backends"

# Symlink all real shell scripts from bin/ (except the ones we override).
for f in "$ROOT"/bin/*.sh; do
  ln -s "$f" "$MOCK_ROOT/bin/" 2>/dev/null || true
done

# Symlink real backends except tmux (which we stub).
for f in "$ROOT"/bin/backends/*.sh; do
  bn=$(basename "$f")
  [ "$bn" = "tmux.sh" ] || ln -s "$f" "$MOCK_ROOT/bin/backends/" 2>/dev/null || true
done

# Override gate-refuse-lib: always allows spawning (no gate-agent check).
rm -f "$MOCK_ROOT/bin/sq-gate-refuse-lib.sh"
cat > "$MOCK_ROOT/bin/sq-gate-refuse-lib.sh" <<'MOCK'
fm_refuse_if_gate_agent() { :; }
MOCK

# Override busy-event: echoes a gen token for arm, no-ops for apply/retire.
rm -f "$MOCK_ROOT/bin/sq-busy-event.sh"
cat > "$MOCK_ROOT/bin/sq-busy-event.sh" <<'MOCK'
CMD=${1:-}; shift || true
case "$CMD" in arm) printf 'mock-gen-%s\n' "$$" ;; *) exit 0 ;; esac
MOCK
chmod +x "$MOCK_ROOT/bin/sq-busy-event.sh"

# Override operational-input: passthrough.
rm -f "$MOCK_ROOT/bin/sq-operational-input.sh"
cat > "$MOCK_ROOT/bin/sq-operational-input.sh" <<'MOCK'
cat
MOCK
chmod +x "$MOCK_ROOT/bin/sq-operational-input.sh"

# Override project-mode: always drill.
rm -f "$MOCK_ROOT/bin/sq-project-mode.sh"
cat > "$MOCK_ROOT/bin/sq-project-mode.sh" <<'MOCK'
echo "drill"
MOCK
chmod +x "$MOCK_ROOT/bin/sq-project-mode.sh"

# Override guard: always passes.
rm -f "$MOCK_ROOT/bin/sq-guard.sh"
cat > "$MOCK_ROOT/bin/sq-guard.sh" <<'MOCK'
exit 0
MOCK
chmod +x "$MOCK_ROOT/bin/sq-guard.sh"

# Stub tmux adapter: provides adapter functions without a live tmux.
cat > "$MOCK_ROOT/bin/backends/tmux.sh" <<'TMUXSTUB'
# Stub tmux adapter for behavioral tests.
fm_backend_tmux_container_ensure() { printf '%s\n' "Squad"; }
fm_backend_tmux_create_task() { printf '%s\n' "@0"; }
fm_backend_tmux_send_text_line() { :; }
fm_backend_tmux_send_literal() { :; }
fm_backend_tmux_current_path() {
  local count progress_file
  progress_file="${TMUX_PROGRESS_FILE:-/tmp/squad-test-progress}"
  count=$(cat "$progress_file" 2>/dev/null || echo 0)
  if [ "$count" -ge 1 ]; then
    printf '%s\n' "${MOCK_WORKTREE:-/tmp/mock-worktree}"
  else
    printf '%s\n' "/tmp/mock-project"
    echo $((count + 1)) > "$progress_file"
  fi
}
fm_backend_tmux_current_command() { printf 'bash\n'; }
fm_backend_tmux_send_key() { :; }
fm_backend_tmux_kill() { :; }
TMUXSTUB

# Create a minimal git repository to serve as the mock worktree.
# sq-spawn.sh validates that the worktree is a real git root.
MOCK_GIT="$TMP/mock-worktree"
rm -rf "$MOCK_GIT"
mkdir -p "$MOCK_GIT"
git -C "$MOCK_GIT" init -q
git -C "$MOCK_GIT" commit --allow-empty -q -m 'init'

# ---------------------------------------------------------------------------
# Helper: set up a complete fake Squad base for one spawn invocation.
# ---------------------------------------------------------------------------
setup_squad_base() {
  local id=$1 proj=$2
  local base="$TMP/squad-base-$id"
  rm -rf "$base"
  mkdir -p "$base/state" "$base/data/$id" "$base/config" \
           "$base/projects/$proj" "$base/config/workflow"
  cat > "$base/data/$id/brief.md" <<BRIEF
This is a test brief for task $id.
The operator must report status: echo '{state}: {note}' >> 'state/$id.status'
BRIEF
  printf '%s\n' "$base"
}

# ---------------------------------------------------------------------------
# Helper: run sq-spawn.sh via the mock root.
# ---------------------------------------------------------------------------
run_spawn() {
  local id=$1 proj=$2 base=$3
  SQUAD_ROOT_OVERRIDE="$MOCK_ROOT" \
  SQUAD_ROOT="$MOCK_ROOT" \
  SQUAD_BASE="$base" \
  SQUAD_STATE_OVERRIDE="$base/state" \
  SQUAD_DATA_OVERRIDE="$base/data" \
  SQUAD_CONFIG_OVERRIDE="$base/config" \
  SQUAD_PROJECTS_OVERRIDE="$base/projects" \
  TMUX="" \
  PATH="$MOCK_ROOT/bin:$PATH" \
  TMUX_PROGRESS_FILE="$TMP/tmux-progress" \
  MOCK_WORKTREE="$MOCK_GIT" \
    "$MOCK_ROOT/bin/sq-spawn.sh" "$id" "projects/$proj" --mode drill --yolo off
}

# ===========================================================================
# Test 1: spawn WITH WORKFLOW.md
# ===========================================================================
echo "---- test: spawn with WORKFLOW.md ----"
id_with="tw-ok-$$"
proj_with="test-project-with"
base_with=$(setup_squad_base "$id_with" "$proj_with")

cat > "$base_with/projects/$proj_with/WORKFLOW.md" <<'WEOF'
---
schema_version: "1.0.0"
tracker:
  kind: github
  provider:
    repo: acme/example
workspace:
  root: "$HOME/workspaces"
execution:
  max_retry_attempts: 3
---
WEOF

spawn_exit=0
run_spawn "$id_with" "$proj_with" "$base_with" || spawn_exit=$?

meta="$base_with/state/$id_with.meta"
[ "$spawn_exit" -eq 0 ] || { echo "FAIL: spawn exited with code $spawn_exit for WITH case"; exit 1; }
[ -f "$meta" ] || { echo "FAIL: meta file not created for WITH case"; exit 1; }

workflow_line=$(grep '^workflow=' "$meta" || true)
[ -n "$workflow_line" ] || { echo "FAIL: missing workflow= line in meta"; exit 1; }

expected_wf="$base_with/projects/$proj_with/WORKFLOW.md"
actual_wf=${workflow_line#workflow=}
[ "$actual_wf" = "$expected_wf" ] || { echo "FAIL: workflow= path mismatch: expected $expected_wf, got $actual_wf"; exit 1; }

wf_config_line=$(grep '^workflow_config=' "$meta" || true)
[ -n "$wf_config_line" ] || { echo "FAIL: missing workflow_config= line in meta"; exit 1; }

wf_config_b64=${wf_config_line#workflow_config=}
wf_json=$(printf '%s' "$wf_config_b64" | base64 -d 2>/dev/null || true)
[ -n "$wf_json" ] || { echo "FAIL: workflow_config= is empty after base64 decode"; exit 1; }

schema_ver=$(printf '%s' "$wf_json" | jq -r .schema_version 2>/dev/null || true)
[ "$schema_ver" = "1.0.0" ] || { echo "FAIL: decoded workflow_config schema_version mismatch: got '$schema_ver'"; exit 1; }

tracker_kind=$(printf '%s' "$wf_json" | jq -r .tracker.kind 2>/dev/null || true)
[ "$tracker_kind" = "github" ] || { echo "FAIL: decoded workflow_config tracker.kind mismatch: got '$tracker_kind'"; exit 1; }

echo "ok - spawn with WORKFLOW.md records workflow= and workflow_config= in meta"

# ===========================================================================
# Test 2: spawn WITHOUT WORKFLOW.md
# ===========================================================================
echo "---- test: spawn without WORKFLOW.md ----"
id_without="tw-no-$$"
proj_without="test-project-without"
base_without=$(setup_squad_base "$id_without" "$proj_without")

spawn_exit=0
run_spawn "$id_without" "$proj_without" "$base_without" || spawn_exit=$?

meta="$base_without/state/$id_without.meta"
[ "$spawn_exit" -eq 0 ] || { echo "FAIL: spawn exited with code $spawn_exit for WITHOUT case"; exit 1; }
[ -f "$meta" ] || { echo "FAIL: meta file not created for WITHOUT case"; exit 1; }

has_workflow=$(grep -c '^workflow=' "$meta" || true)
[ "$has_workflow" = "0" ] || { echo "FAIL: workflow= line present in meta when no WORKFLOW.md (count=$has_workflow)"; exit 1; }

has_config=$(grep -c '^workflow_config=' "$meta" || true)
[ "$has_config" = "0" ] || { echo "FAIL: workflow_config= line present in meta when no WORKFLOW.md (count=$has_config)"; exit 1; }

echo "ok - spawn without WORKFLOW.md omits workflow= and workflow_config= from meta"

# An explicit materialized playbook identity is preserved in execution metadata.
id_playbook="tw-playbook-$$"
proj_playbook="test-project-playbook"
base_playbook=$(setup_squad_base "$id_playbook" "$proj_playbook")
cat > "$base_playbook/data/$id_playbook/brief.md" <<'BRIEF'
Execution playbook: id=bug-fix version=1
# Execution playbook: `bug-fix@1`
The operator must report status: echo '{state}: {note}' >> 'state/task.status'
BRIEF
spawn_exit=0
run_spawn "$id_playbook" "$proj_playbook" "$base_playbook" || spawn_exit=$?
meta="$base_playbook/state/$id_playbook.meta"
[ "$spawn_exit" -eq 0 ] || { echo "FAIL: playbook spawn exited with code $spawn_exit"; exit 1; }
grep -qx 'playbook=bug-fix' "$meta" || { echo "FAIL: playbook identity missing from meta"; exit 1; }
grep -qx 'playbook_version=1' "$meta" || { echo "FAIL: playbook version missing from meta"; exit 1; }
echo "ok - spawn records optional playbook identity"

id_wave="tw-feature-playbook-$$"
proj_wave="test-project-feature-playbook"
base_wave=$(setup_squad_base "$id_wave" "$proj_wave")
cat > "$base_wave/data/$id_wave/brief.md" <<'BRIEF'
Execution playbook: id=feature version=1
# Execution playbook: `feature@1`
The operator must report status: echo '{state}: {note}' >> 'state/task.status'
BRIEF
spawn_exit=0
run_spawn "$id_wave" "$proj_wave" "$base_wave" || spawn_exit=$?
meta="$base_wave/state/$id_wave.meta"
[ "$spawn_exit" -eq 0 ] || { echo "FAIL: feature playbook spawn exited with code $spawn_exit"; exit 1; }
grep -qx 'playbook=feature' "$meta" || { echo "FAIL: feature playbook identity missing from meta"; exit 1; }
grep -qx 'playbook_version=1' "$meta" || { echo "FAIL: feature playbook version missing from meta"; exit 1; }
echo "ok - spawn records a second playbook identity without collision"

# ===========================================================================
# Test 3: spawn with WORKFLOW.md in config/workflow/ fallback
# ===========================================================================
echo "---- test: spawn with private WORKFLOW.md fallback ----"
id_fb="tw-fb-$$"
proj_fb="test-project-fallback"
base_fb=$(setup_squad_base "$id_fb" "$proj_fb")

cat > "$base_fb/config/workflow/$proj_fb.md" <<'WEOF'
---
schema_version: "1.0.0"
tracker:
  kind: gitlab
  provider:
    repo: private/example
---
WEOF

spawn_exit=0
run_spawn "$id_fb" "$proj_fb" "$base_fb" || spawn_exit=$?

meta="$base_fb/state/$id_fb.meta"
[ "$spawn_exit" -eq 0 ] || { echo "FAIL: spawn exited with code $spawn_exit for fallback case"; exit 1; }
[ -f "$meta" ] || { echo "FAIL: meta file not created for fallback case"; exit 1; }

workflow_line=$(grep '^workflow=' "$meta" || true)
[ -n "$workflow_line" ] || { echo "FAIL: missing workflow= line in meta for fallback case"; exit 1; }

expected_fb="$base_fb/config/workflow/$proj_fb.md"
actual_fb=${workflow_line#workflow=}
[ "$actual_fb" = "$expected_fb" ] || { echo "FAIL: workflow= fallback path mismatch: expected $expected_fb, got $actual_fb"; exit 1; }

wf_config_line=$(grep '^workflow_config=' "$meta" || true)
[ -n "$wf_config_line" ] || { echo "FAIL: missing workflow_config= line for fallback case"; exit 1; }

wf_config_b64=${wf_config_line#workflow_config=}
wf_json=$(printf '%s' "$wf_config_b64" | base64 -d 2>/dev/null || true)
tracker_kind=$(printf '%s' "$wf_json" | jq -r .tracker.kind 2>/dev/null || true)
[ "$tracker_kind" = "gitlab" ] || { echo "FAIL: decoded fallback workflow_config tracker.kind mismatch: got '$tracker_kind'"; exit 1; }

echo "ok - spawn with private WORKFLOW.md fallback records correct path and config"

printf 'ok - sq-spawn WORKFLOW.md behavioral tests\n'
