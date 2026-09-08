#!/usr/bin/env bash
# Workspace hook lifecycle and safety tests.
set -eu
# shellcheck disable=SC2153
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(fm_test_tmproot sq-hooks)
workspace="$root/workspace"
mkdir -p "$workspace"
cat > "$root/WORKFLOW.md" <<'EOF'
---
schema_version: "1.0.0"
hooks:
  after_create:
    command: ["bash", "-c", "printf 'after_create:%s\\n' \"$TASK_ID\" >> hook.log"]
    timeout_ms: 2000
  before_run:
    command: ["bash", "-c", "printf 'before_run:%s\\n' \"$TASK_ID\" >> hook.log"]
    timeout_ms: 2000
  after_run:
    command: ["bash", "-c", "printf 'after_run:%s\\n' \"$TASK_ID\" >> hook.log"]
    timeout_ms: 2000
  before_remove:
    command: ["bash", "-c", "printf 'before_remove:%s\\n' \"$TASK_ID\" >> hook.log"]
    timeout_ms: 2000
---
EOF
run_hook() {
  WORKFLOW_PATH="$root/WORKFLOW.md" SQUAD_BASE="$root" \
    "$ROOT/bin/sq-hooks.sh" "$@"
}
run_hook after_create "$workspace" hook-test 1 claimed v1 demo >/dev/null
run_hook before_run "$workspace" hook-test 1 claimed v1 demo >/dev/null
run_hook after_run "$workspace" hook-test 1 running v1 demo >/dev/null
run_hook before_remove "$workspace" hook-test 1 released v1 demo >/dev/null
for phase in after_create before_run after_run before_remove; do
  grep -q "^$phase:hook-test$" "$workspace/hook.log" || fail "$phase fires"
done
printf 'uncommitted work\n' > "$workspace/uncommitted.txt"
[ -f "$workspace/uncommitted.txt" ] || fail 'hooks preserve uncommitted work'

cat > "$root/timeout-workflow.md" <<'EOF'
---
schema_version: "1.0.0"
hooks:
  before_run:
    command: ["bash", "-c", "sleep 3"]
    timeout_ms: 1000
---
EOF
if WORKFLOW_PATH="$root/timeout-workflow.md" SQUAD_BASE="$root" \
  "$ROOT/bin/sq-hooks.sh" before_run "$workspace" timeout-test 1 claimed v1 demo >/dev/null 2>&1; then
  fail 'timeout rejects a hung hook'
fi

cat > "$root/failure-workflow.md" <<'EOF'
---
schema_version: "1.0.0"
hooks:
  before_remove:
    command: ["bash", "-c", "exit 1"]
    timeout_ms: 2000
  after_run:
    command: ["bash", "-c", "exit 1"]
    timeout_ms: 2000
---
EOF
if WORKFLOW_PATH="$root/failure-workflow.md" SQUAD_BASE="$root" \
  "$ROOT/bin/sq-hooks.sh" before_remove "$workspace" failure-test 1 released v1 demo >/dev/null 2>&1; then
  fail 'before_remove failure stops cleanup'
fi
[ -d "$workspace" ] || fail 'before_remove preserves workspace'
if WORKFLOW_PATH="$root/failure-workflow.md" SQUAD_BASE="$root" \
  "$ROOT/bin/sq-hooks.sh" after_run "$workspace" failure-test 1 running v1 demo >/dev/null 2>&1; then
  fail 'after_run failure prevents success'
fi

pass 'workspace hooks'
