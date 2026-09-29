#!/usr/bin/env bash
# Fake-CLI regression coverage for the explicit TUIOS session-provider adapter.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot sq-backend-tuios-tests)
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/tuios" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$SQUAD_TUIOS_LOG"
case "${1:-}" in
  --version) printf 'tuios version %s\n' "${SQUAD_TUIOS_FAKE_VERSION:-0.8.0}" ;;
  session-info) printf '{"name":"%s"}\n' "${SQUAD_TUIOS_FAKE_SESSION:-owned}" ;;
  list-windows)
    if [ "${SQUAD_TUIOS_FAKE_MISSING:-0}" = 1 ] || [ "${SQUAD_TUIOS_FAKE_EMPTY_WINDOWS:-0}" = 1 ]; then
      printf '{"windows":[]}\n'
    else
      printf '{"windows":[{"id":"w-opaque_7","name":"sq-task-1","cwd":"/tmp/wt"}]}\n'
    fi
    ;;
  tmux)
    case "${2:-}" in
      list-panes) printf '%s\n' "${SQUAD_TUIOS_FAKE_PANES:-%7 w-opaque_7}" ;;
      kill-pane) printf 'killed %s\n' "${4:-}" ;;
    esac
    ;;
  get-window) printf '{"window":{"id":"w-opaque_7","name":"%s","cwd":"/tmp/wt","has_foreground_process":false}}\n' "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}" ;;
  list-agents)
    if [ -n "${SQUAD_TUIOS_FAKE_AGENTS:-}" ]; then printf '%s\n' "$SQUAD_TUIOS_FAKE_AGENTS"; else
      printf '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done"}]}\n'
    fi
    ;;
  get-agent-state) printf '{"state":"%s"}\n' "${SQUAD_TUIOS_FAKE_AGENT_STATE:-working}" ;;
  capture-pane) printf 'captured output\n' ;;
  new-window) printf 'w-opaque_7\n' ;;
  *) : ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/tuios"
export PATH="$TMP_ROOT/fakebin:$PATH" SQUAD_TUIOS_BIN=tuios SQUAD_TUIOS_LOG="$TMP_ROOT/log"

source "$ROOT/bin/sq-backend.sh"
fm_backend_validate_spawn tuios || fail 'TUIOS should be a supported spawn backend'
[ "$(fm_backend_required_tools tuios)" = 'tuios jq fob' ] || fail 'required tools mismatch'
fm_backend_source tuios || fail 'adapter did not source'
fm_backend_tuios_tool_check || fail 'minimum TUIOS version should pass'

[ "$(fm_backend_tuios_target_exists owned:w-opaque_7 sq-task-1 && echo yes)" = yes ] || fail 'exact opaque target should resolve'
[ "$(fm_backend_tuios_capture owned:w-opaque_7 10 sq-task-1)" = 'captured output' ] || fail 'capture failed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'capture-pane --window w-opaque_7 --scrollback --lines 10 --session owned' 'capture did not use supported bounded scrollback flags'
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'agent inventory should corroborate Pi despite foreground=false'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = unknown ] || fail 'a TUIOS-reported agent state must not become a native busy verdict'

SQUAD_TUIOS_FAKE_MISSING=1
export SQUAD_TUIOS_FAKE_MISSING
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = missing ] || fail 'successful inventory omission should report missing'
unset SQUAD_TUIOS_FAKE_MISSING

SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = ambiguous ] || fail 'unattributed agent must remain ambiguous'
unset SQUAD_TUIOS_FAKE_AGENTS

SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":null,"harness_id":"pi","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7 2>/dev/null)" = alive ] || fail 'harness identity fallback must corroborate an agent when foreground is absent'
unset SQUAD_TUIOS_FAKE_AGENTS

SQUAD_TUIOS_SESSION=owned
export SQUAD_TUIOS_SESSION
[ "$(fm_backend_tuios_container_ensure /tmp/project)" = owned ] || fail 'explicitly configured live session should be accepted'
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-spawn-test
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
[ "$(fm_backend_tuios_create_task owned sq-spawn-test /tmp/wt)" = w-opaque_7 ] || fail 'task window creation failed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-spawn-test --session owned --cwd /tmp/wt --no-focus --print-id' 'spawn did not create an unfocused window in the exact session'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if SQUAD_TUIOS_SESSION='' PATH="$PATH" bash -c 'source "$1/bin/sq-backend.sh"; fm_backend_source tuios; fm_backend_tuios_container_ensure /tmp/project' _ "$ROOT" >/dev/null 2>&1; then
  fail 'missing explicit session must refuse'
fi
if SQUAD_TUIOS_FAKE_VERSION=0.7.9 fm_backend_tuios_tool_check >/dev/null 2>&1; then fail 'old TUIOS must refuse'; fi

no_jq_bin="$TMP_ROOT/no-jq-bin"
mkdir -p "$no_jq_bin"
cp "$TMP_ROOT/fakebin/tuios" "$no_jq_bin/tuios"
# dirname is required while sourcing sq-backend.sh, so it must stay on this
# isolated PATH or the adapter never loads and the check is never reached.
for tool in bash sed head dirname; do
  ln -sf "$(command -v "$tool")" "$no_jq_bin/$tool"
done
if PATH="$no_jq_bin" bash -c 'source "$1/bin/sq-backend.sh"; fm_backend_source tuios; fm_backend_tuios_tool_check' _ "$ROOT" 2>"$TMP_ROOT/jq-err" >/dev/null; then
  fail 'missing jq must be refused by the TUIOS tool check'
fi
assert_contains "$(cat "$TMP_ROOT/jq-err")" 'jq' 'missing jq refusal must name the missing tool'

TARGET=owned:w-opaque_7
SQUAD_TUIOS_FAKE_PANES='%7 other-window'
export SQUAD_TUIOS_FAKE_PANES
if fm_backend_tuios_kill "$TARGET" '' sq-task-1; then fail 'foreign pane mapping must refuse cleanup'; fi
[ "$(grep -c 'tmux kill-pane' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'foreign mapping issued a destructive command'
unset SQUAD_TUIOS_FAKE_PANES
if fm_backend_tuios_kill "$TARGET" '' wrong-label; then fail 'mismatched expected label must refuse cleanup'; fi
[ "$(grep -c 'tmux kill-pane' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'mismatched label issued a destructive command'
fm_backend_tuios_kill "$TARGET" '' sq-task-1 || fail 'exact task window close failed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'tmux list-panes -F #{pane_id} #{tuios_window_id}' 'cleanup did not inventory exact TUIOS pane identity'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'tmux kill-pane -t %7' 'cleanup did not close only the mapped exact pane'

# The generic UI submit path never claims delivery, even after transport success.
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = uncertain-delivery ] || fail 'UI submit must remain uncertain'

# Cleanup authority binds task id, session, opaque window id, and exact target.
meta="$TMP_ROOT/task.meta"
cat > "$meta" <<'EOF'
backend=tuios
window=owned:w-opaque_7
endpoint_task_id=task-1
worktree=/tmp/wt
project=/tmp/project
kind=strike
tuios_session=owned
tuios_window_id=w-opaque_7
EOF
fm_backend_validate_task_endpoint "$meta" task-1 || fail 'valid bound endpoint metadata should pass'
if fm_backend_validate_task_endpoint "$meta" other-task >/dev/null 2>&1; then fail 'mismatched task binding must refuse'; fi

pass 'TUIOS backend: fake CLI covers explicit session, opaque endpoint, corroborated liveness, uncertainty, and exact cleanup'
