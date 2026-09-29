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
  session-info)
    [ "${SQUAD_TUIOS_FAKE_SESSION_DEAD:-0}" = 1 ] && exit 1
    printf '{"name":"%s"}\n' "${SQUAD_TUIOS_FAKE_SESSION:-owned}"
    ;;
  list-windows)
    if [ "${SQUAD_TUIOS_FAKE_LIST_FAIL:-0}" = 1 ]; then
      exit 1
    elif [ "${SQUAD_TUIOS_FAKE_BAD_ELEMENT:-0}" = 1 ]; then
      printf '{"windows":["x"]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE:-0}" = 1 ]; then
      printf '{"windows":[{"window_id":"w-opaque_7","name":"sq-task-1","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_NO_IDENTITY:-0}" = 1 ]; then
      printf '{"windows":[{"name":"sq-task-1","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_CONFLICTING_ID:-0}" = 1 ]; then
      printf '{"windows":[{"window":{"id":"w-opaque_7"},"id":"stale-id","name":"sq-task-1","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_NESTED_LABEL:-0}" = 1 ]; then
      printf '{"windows":[{"id":"w-opaque_7","window":{"id":"w-opaque_7","name":"sq-nested"},"cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_DURABLE_LABEL:-0}" = 1 ]; then
      printf '{"windows":[{"id":"w-opaque_7","custom_name":"sq-durable","title":"pi - live","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_ERROR_INVENTORY:-0}" = 1 ]; then
      printf '{"error":{"code":"daemon_unreachable"}}\n'
    elif [ "${SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS:-0}" = 1 ]; then
      printf '{"error":{"code":"daemon_unreachable"},"windows":[]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_STRING_WINDOW:-0}" = 1 ]; then
      printf '{"windows":[{"window":"w-opaque_7","name":"sq-task-1"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_MISSING:-0}" = 1 ] || [ "${SQUAD_TUIOS_FAKE_EMPTY_WINDOWS:-0}" = 1 ]; then
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
  get-window)
    # A session with an attached client omits the daemon cwd from this shape;
    # list-windows is the shape that always carries it.
    if [ "${SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW:-0}" = 1 ]; then
      printf '{"error":{"code":"window_gone"},"window":{"id":"w-opaque_7","name":"sq-task-1"}}\n'
    elif [ "${SQUAD_TUIOS_FAKE_ATTACHED_CLIENT:-0}" = 1 ]; then
      printf '{"window":{"id":"w-opaque_7","name":"%s","has_foreground_process":true}}\n' "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}"
    else
      printf '{"window":{"id":"w-opaque_7","name":"%s","cwd":"/tmp/wt","has_foreground_process":false}}\n' "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}"
    fi
    ;;
  list-agents)
    if [ -n "${SQUAD_TUIOS_FAKE_AGENTS:-}" ]; then printf '%s\n' "$SQUAD_TUIOS_FAKE_AGENTS"; else
      printf '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done"}]}\n'
    fi
    ;;
  get-agent-state) printf '{"state":"%s"}\n' "${SQUAD_TUIOS_FAKE_AGENT_STATE:-working}" ;;
  capture-pane) printf '%s\n' "${SQUAD_TUIOS_FAKE_CAPTURE:-captured output}" ;;
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

# The worktree-discovery probe must work on an attached session, where
# get-window omits the daemon cwd.
SQUAD_TUIOS_FAKE_ATTACHED_CLIENT=1
export SQUAD_TUIOS_FAKE_ATTACHED_CLIENT
[ "$(fm_backend_tuios_current_path owned:w-opaque_7)" = '/tmp/wt' ] || fail 'cwd must come from the daemon inventory while a client is attached'
unset SQUAD_TUIOS_FAKE_ATTACHED_CLIENT

# A flat window: string record without a top-level cwd must not raise a jq
# indexing error from the worktree-discovery probe; it reads as no path.
SQUAD_TUIOS_FAKE_STRING_WINDOW=1
export SQUAD_TUIOS_FAKE_STRING_WINDOW
current_path_out=$(fm_backend_tuios_current_path owned:w-opaque_7 2>"$TMP_ROOT/current-path-err") \
  || fail 'a string-shaped window record must not fail the discovery probe'
[ -z "$current_path_out" ] || fail 'a string-shaped window record carries no cwd, so the probe must be empty'
[ -s "$TMP_ROOT/current-path-err" ] && fail 'a silent read failure must not leak a jq indexing error'
unset SQUAD_TUIOS_FAKE_STRING_WINDOW
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'capture-pane --session owned --window w-opaque_7 --scrollback --lines 10' 'capture did not use supported bounded scrollback flags'

# Operator-controlled payload text must never be parsed as TUIOS options: a
# leading-dash message is a literal payload after `--`, and the exact session
# binding must still precede it.
fm_backend_tuios_send_literal owned:w-opaque_7 '--session evil --window evil' >/dev/null 2>&1 \
  || fail 'leading-dash literal send should reach the CLI'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'send-text --session owned --window w-opaque_7 -- --session evil --window evil' \
  'leading-dash payload must stay literal after -- and keep the explicit session binding'
fm_backend_tuios_send_literal owned:w-opaque_7 '--' >/dev/null 2>&1 \
  || fail 'bare -- literal send should reach the CLI'
[ "$(tail -n1 "$SQUAD_TUIOS_LOG")" = 'send-text --session owned --window w-opaque_7 -- --' ] \
  || fail 'a bare -- payload must not consume the appended session flag'
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'agent inventory should corroborate Pi despite foreground=false'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = unknown ] || fail 'a TUIOS-reported agent state must not become a native busy verdict'

SQUAD_TUIOS_FAKE_MISSING=1
export SQUAD_TUIOS_FAKE_MISSING
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = missing ] || fail 'successful inventory omission should report missing'
unset SQUAD_TUIOS_FAKE_MISSING

SQUAD_TUIOS_FAKE_ERROR_INVENTORY=1
export SQUAD_TUIOS_FAKE_ERROR_INVENTORY
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'a windows-less JSON object must stay unreadable, never missing'
if fm_backend_tuios_create_task owned sq-dupe /tmp/wt >/dev/null 2>&1; then
  fail 'an unreadable window inventory must refuse duplicate-name creation'
fi
unset SQUAD_TUIOS_FAKE_ERROR_INVENTORY

# An error envelope that still carries a syntactically valid array must never
# read as an authoritative empty inventory, or recovery would relaunch a task.
SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS=1
export SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'an error envelope with an empty windows array must stay unreadable, never missing'
if fm_backend_tuios_create_task owned sq-errwin /tmp/wt >/dev/null 2>&1; then
  fail 'an error-envelope inventory must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-errwin' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'error-envelope inventory must not authorize window creation'
unset SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS

# The single-window read has the same envelope gap: an error that happens to
# carry a matching window object must stay unreadable, never a ready target.
SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW=1
export SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW
if fm_backend_tuios_target_exists owned:w-opaque_7 sq-task-1; then
  fail 'an error envelope that carries a window object must not read as a ready target'
fi
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'an error envelope on get-window must keep agent state unreadable'
unset SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW

if fm_backend_tuios_create_task owned sq-task-1 /tmp/wt >/dev/null 2>&1; then
  fail 'an existing TUIOS task label must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-task-1' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'duplicate-label refusal must not create a new window'

# A non-object window element must not read as an empty/duplicate-free inventory:
# jq indexing errors would otherwise fall through and create a second window.
SQUAD_TUIOS_FAKE_BAD_ELEMENT=1
export SQUAD_TUIOS_FAKE_BAD_ELEMENT
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'a non-object window element must stay unreadable'
if fm_backend_tuios_create_task owned sq-element /tmp/wt >/dev/null 2>&1; then
  fail 'a non-object window element must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-element' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'malformed inventory must not authorize window creation'
unset SQUAD_TUIOS_FAKE_BAD_ELEMENT

# A window identified as window_id must corroborate presence, never read as
# missing, or the recovery path would authorize a duplicate relaunch.
SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE=1
export SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'window_id-identified inventory must corroborate presence, never report missing'
unset SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE

# Disagreeing identity fields inside one record are a contradiction: reporting
# a lookup-order winner could turn a live window into authoritative absence and
# authorize a duplicate relaunch.
SQUAD_TUIOS_FAKE_CONFLICTING_ID=1
export SQUAD_TUIOS_FAKE_CONFLICTING_ID
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'a record whose own identity fields disagree must stay unreadable, never missing'
if fm_backend_tuios_create_task owned sq-stale /tmp/wt >/dev/null 2>&1; then
  fail 'a contradictory identity record must refuse window creation'
fi
unset SQUAD_TUIOS_FAKE_CONFLICTING_ID

# The duplicate-label guard must read the same nested-first label shape the
# endpoint check reads, or a nested label bypasses duplicate-name refusal.
SQUAD_TUIOS_FAKE_NESTED_LABEL=1
export SQUAD_TUIOS_FAKE_NESTED_LABEL
if fm_backend_tuios_create_task owned sq-nested /tmp/wt >/dev/null 2>&1; then
  fail 'a nested window label must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-nested' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'nested-label refusal must not create a new window'
unset SQUAD_TUIOS_FAKE_NESTED_LABEL

# A live retitle must not hide the durable label that identifies the task.
SQUAD_TUIOS_FAKE_DURABLE_LABEL=1
export SQUAD_TUIOS_FAKE_DURABLE_LABEL
if fm_backend_tuios_create_task owned sq-durable /tmp/wt >/dev/null 2>&1; then
  fail 'a durable custom_name label must refuse duplicate-name creation after a live retitle'
fi
[ "$(grep -c 'new-window sq-durable' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'durable-label refusal must not create a new window'
unset SQUAD_TUIOS_FAKE_DURABLE_LABEL

# An element without a recognizable identity must invalidate the whole
# inventory as unreadable instead of reading as a reliable omission.
SQUAD_TUIOS_FAKE_NO_IDENTITY=1
export SQUAD_TUIOS_FAKE_NO_IDENTITY
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'an identity-less window element must stay unreadable, never missing'
if fm_backend_tuios_create_task owned sq-noid /tmp/wt >/dev/null 2>&1; then
  fail 'an identity-less inventory must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-noid' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'identity-less inventory must not authorize window creation'
unset SQUAD_TUIOS_FAKE_NO_IDENTITY

SQUAD_TUIOS_FAKE_LIST_FAIL=1
export SQUAD_TUIOS_FAKE_LIST_FAIL
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'a failed inventory read after a restart must stay unreadable'
unset SQUAD_TUIOS_FAKE_LIST_FAIL

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
SQUAD_TUIOS_FAKE_SESSION_DEAD=1
export SQUAD_TUIOS_FAKE_SESSION_DEAD
if fm_backend_tuios_container_ensure /tmp/project >/dev/null 2>&1; then
  fail 'a lost or restarted TUIOS session must refuse adoption'
fi
unset SQUAD_TUIOS_FAKE_SESSION_DEAD
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
if ! PATH="$no_jq_bin" bash -c 'source "$1/bin/sq-backend.sh"; fm_backend_required_tool_available tuios tuios' _ "$ROOT" >/dev/null 2>&1; then
  fail 'an installed TUIOS CLI must remain available when jq is absent'
fi
if PATH="$no_jq_bin" bash -c 'source "$1/bin/sq-backend.sh"; fm_backend_required_tool_available tuios jq' _ "$ROOT" >/dev/null 2>&1; then
  fail 'the jq dependency must still be reported unavailable when jq is absent'
fi

TARGET=owned:w-opaque_7
SQUAD_TUIOS_FAKE_PANES='%7 other-window'
export SQUAD_TUIOS_FAKE_PANES
if fm_backend_tuios_kill "$TARGET" '' sq-task-1; then fail 'foreign pane mapping must refuse cleanup'; fi
[ "$(grep -c 'tmux kill-pane' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'foreign mapping issued a destructive command'
unset SQUAD_TUIOS_FAKE_PANES
if fm_backend_tuios_kill "$TARGET" '' wrong-label; then fail 'mismatched expected label must refuse cleanup'; fi
[ "$(grep -c 'tmux kill-pane' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'mismatched label issued a destructive command'
fm_backend_tuios_kill "$TARGET" '' sq-task-1 || fail 'exact task window close failed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'tmux list-panes -a -F #{pane_id} #{tuios_window_id}' 'cleanup did not inventory session-wide exact TUIOS pane identity'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'tmux kill-pane -t %7' 'cleanup did not close only the mapped exact pane'

SQUAD_TUIOS_FAKE_CAPTURE='Permission required: allow tool? [y/N]'
export SQUAD_TUIOS_FAKE_CAPTURE
assert_contains "$(fm_backend_tuios_capture owned:w-opaque_7 10 sq-task-1)" 'Permission required' 'permission-prompt fixture must be readable'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = unknown ] || fail 'a permission prompt must not produce a busy or idle verdict'
[ "$(fm_backend_composer_state tuios owned:w-opaque_7)" = unknown ] || fail 'a permission prompt must not be classified as an empty composer'
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'allow' 3 0 0 sq-task-1)" = uncertain-delivery ] || fail 'a permission prompt must never be treated as accepted delivery'
unset SQUAD_TUIOS_FAKE_CAPTURE

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
