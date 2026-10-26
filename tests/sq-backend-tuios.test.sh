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
emit_verb_catalogue() {
  cat <<'JSON'
{"version":1,"daemon_version":"0.8.0","success":true,"verbs":[
 {"verb":"capture-pane","params":[{"name":"session"},{"name":"window"},{"name":"scrollback"},{"name":"lines"}]},
 {"verb":"close-window","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"get-agent-state","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"get-window","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"list-agents","params":[{"name":"session"},{"name":"all"},{"name":"select"}]},
 {"verb":"list-queued","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"list-windows","params":[{"name":"session"}]},
 {"verb":"list-workspaces","params":[{"name":"session"}]},
 {"verb":"new-window","params":[{"name":"session"},{"name":"name"},{"name":"cwd"},{"name":"focus"},{"name":"workspace"}]},
 {"verb":"set-workspace-name","params":[{"name":"session"},{"name":"workspace"},{"name":"name"}]},
 {"verb":"peek-prompt","params":[{"name":"session"},{"name":"window"}]},
 {"verb":"queue-prompt","params":[{"name":"session"},{"name":"window"},{"name":"text"},{"name":"from"}]},
 {"verb":"resume-agent","params":[{"name":"session"},{"name":"window"},{"name":"dry_run"}]},
 {"verb":"send-keys","params":[{"name":"session"},{"name":"window"},{"name":"keys"}]},
 {"verb":"send-text","params":[{"name":"session"},{"name":"window"},{"name":"text"}]},
 {"verb":"subscribe","params":[{"name":"session"},{"name":"types"}],"returns":[{"name":"seq"},{"name":"boot_id"}]},
 {"verb":"respond","params":[{"name":"session"},{"name":"window"},{"name":"action"},{"name":"value"},{"name":"prompt_id"}],"returns":[{"name":"prompt_id"},{"name":"settled_by"}]}
]}
JSON
}
case "${1:-}" in
  --version) printf 'tuios version %s\n' "${SQUAD_TUIOS_FAKE_VERSION:-0.8.0}" ;;
  session-info)
    [ "${SQUAD_TUIOS_FAKE_SESSION_DEAD:-0}" = 1 ] && exit 1
    printf '{"name":"%s"}\n' "${SQUAD_TUIOS_FAKE_SESSION:-owned}"
    ;;
  list-verbs)
    if [ "${SQUAD_TUIOS_FAKE_VERBS_FAIL:-0}" = 1 ]; then exit 1; fi
    if [ -n "${SQUAD_TUIOS_FAKE_VERBS_MALFORMED:-}" ]; then printf '%s\n' "$SQUAD_TUIOS_FAKE_VERBS_MALFORMED"; exit 0; fi
    emit_verb_catalogue | jq -c --arg verb "${SQUAD_TUIOS_FAKE_VERBS_OMIT:-}" --arg pair "${SQUAD_TUIOS_FAKE_PARAM_OMIT:-}" --arg ret "${SQUAD_TUIOS_FAKE_RETURN_OMIT:-}" '
      if $verb != "" then .verbs |= map(select(.verb != $verb)) else . end
      | if $pair != "" then
          ($pair | split(":")) as $p
          | .verbs |= map(if .verb == $p[0] then .params |= map(select(.name != $p[1])) else . end)
        else . end
      | if $ret != "" then
          ($ret | split(":")) as $r
          | .verbs |= map(if .verb == $r[0] then .returns |= map(select(.name != $r[1])) else . end)
        else . end'
    ;;
  subscribe)
    printf '{"type":"subscribed","boot_id":"boot-a","seq":1}\n'
    [ -z "${SQUAD_TUIOS_FAKE_EVENT:-}" ] || printf '{"type":"agent-state","window":"%s","state":"needs_input","seq":2,"boot_id":"boot-a"}\n' "${SQUAD_TUIOS_FAKE_EVENT}"
    [ -z "${SQUAD_TUIOS_FAKE_SUBSCRIBE_PID_FILE:-}" ] || printf '%s\n' "$$" > "$SQUAD_TUIOS_FAKE_SUBSCRIBE_PID_FILE"
    exec sleep "${SQUAD_TUIOS_FAKE_SUBSCRIBE_SLEEP:-5}"
    ;;
  list-attention)
    printf '{"boot_id":"%s","success":true,"items":[]}\n' "${SQUAD_TUIOS_FAKE_BOOT_ID:-boot-a}"
    ;;
  list-workspaces)
    [ "${SQUAD_TUIOS_FAKE_WORKSPACES_FAIL:-0}" = 1 ] && exit 1
    if [ "${SQUAD_TUIOS_FAKE_WORKSPACES_FAIL_ONCE:-0}" = 1 ] \
       && [ -f "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME" ] \
       && [ ! -f "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME.workspaces-failed-once" ]; then
      : > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME.workspaces-failed-once"
      exit 1
    fi
    if [ "${SQUAD_TUIOS_FAKE_ALLOC_PAUSE:-0}" = 1 ] && [ ! -e "$SQUAD_TUIOS_FAKE_ALLOC_PAUSE_MARK" ]; then
      : > "$SQUAD_TUIOS_FAKE_ALLOC_PAUSE_MARK"
      for _ in $(seq 1 500); do
        [ ! -e "$SQUAD_TUIOS_FAKE_ALLOC_RELEASE" ] || break
        sleep 0.01
      done
      [ -e "$SQUAD_TUIOS_FAKE_ALLOC_RELEASE" ] || exit 80
    fi
    rows=()
    for workspace in $(seq 1 9); do
      name= count=0
      case "$workspace" in 1) name=personal; count=1 ;; 4) name=existing; count=1 ;; esac
      if [ -f "$SQUAD_TUIOS_CREATED_WORKSPACE" ] && [ "$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE")" = "$workspace" ]; then
        name=$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME" 2>/dev/null || printf '')
        [ ! -f "$SQUAD_TUIOS_CREATED_WINDOW" ] || count=1
      fi
      rows+=("$(jq -cn --argjson ws "$workspace" --arg name "$name" --argjson count "$count" '{workspace:$ws,name:$name,window_count:$count}')")
    done
    printf '{"success":true,"workspaces":[%s]}\n' "$(IFS=,; echo "${rows[*]}")"
    ;;
  set-workspace-name)
    shift
    [ "${1:-}" = --session ] && shift 2
    printf '%s\n' "${1:-}" > "$SQUAD_TUIOS_CREATED_WORKSPACE"
    printf '%s\n' "${2:-}" > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
    printf '{"success":true}\n'
    ;;
  list-windows)
    if [ "${SQUAD_TUIOS_FAKE_LIST_FAIL:-0}" = 1 ]; then
      exit 1
    elif [ "${SQUAD_TUIOS_FAKE_LIST_FAIL_AFTER_CREATE:-0}" = 1 ] && [ -f "$SQUAD_TUIOS_CREATED_WINDOW" ]; then
      exit 1
    elif [ "${SQUAD_TUIOS_FAKE_BAD_ELEMENT:-0}" = 1 ]; then
      printf '{"windows":["x"]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_WINDOW_ID_SHAPE:-0}" = 1 ]; then
      printf '{"windows":[{"window_id":"w-opaque_7","name":"sq-task-1","workspace":%s,"cwd":"/tmp/wt"}]}\n' "${SQUAD_TUIOS_FAKE_PLACEMENT:-4}"
    elif [ "${SQUAD_TUIOS_FAKE_NO_IDENTITY:-0}" = 1 ]; then
      printf '{"windows":[{"name":"sq-task-1","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_CONFLICTING_ID:-0}" = 1 ]; then
      printf '{"windows":[{"window":{"id":"w-opaque_7"},"id":"stale-id","name":"sq-task-1","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_NESTED_LABEL:-0}" = 1 ]; then
      printf '{"windows":[{"id":"w-opaque_7","window":{"id":"w-opaque_7","name":"sq-nested"},"cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_NESTED_WORKSPACE:-0}" = 1 ]; then
      printf '{"windows":[{"window":{"id":"w-opaque_7","workspace":%s}}]}\n' "${SQUAD_TUIOS_FAKE_PLACEMENT:-$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE" 2>/dev/null || printf '2')}"
    elif [ "${SQUAD_TUIOS_FAKE_NO_WORKSPACE:-0}" = 1 ]; then
      # Pre-creation empty so label conflict does not trip; post-creation a
      # record that omits every workspace field, i.e. missing placement.
      if [ ! -f "$SQUAD_TUIOS_CREATED_WINDOW" ]; then
        printf '{"windows":[]}\n'
      else
        printf '{"windows":[{"id":"w-opaque_7","name":"%s","cwd":"/tmp/wt"}]}\n' "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}"
      fi
    elif [ "${SQUAD_TUIOS_FAKE_DURABLE_LABEL:-0}" = 1 ]; then
      printf '{"windows":[{"id":"w-opaque_7","custom_name":"sq-durable","title":"pi - live","cwd":"/tmp/wt"}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_ERROR_INVENTORY:-0}" = 1 ]; then
      printf '{"error":{"code":"daemon_unreachable"}}\n'
    elif [ "${SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOWS:-0}" = 1 ]; then
      printf '{"error":{"code":"daemon_unreachable"},"windows":[]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_STRING_WINDOW:-0}" = 1 ]; then
      printf '{"windows":[{"window":"w-opaque_7","name":"sq-task-1","workspace":4}]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_MISSING:-0}" = 1 ] || { [ "${SQUAD_TUIOS_FAKE_EMPTY_WINDOWS:-0}" = 1 ] && [ ! -f "$SQUAD_TUIOS_CREATED_WINDOW" ]; }; then
      printf '{"windows":[]}\n'
    elif [ "${SQUAD_TUIOS_FAKE_RESTORED_WINDOW:-0}" = 1 ]; then
      printf '{"windows":[{"window_id":"w-opaque_7","custom_name":"sq-task-1","workspace":4,"cwd":"%s"}]}\n' "${SQUAD_TUIOS_FAKE_RESTORED_CWD:-/tmp/wt}"
    else
      name=${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task-1}
      [ ! -f "$SQUAD_TUIOS_CREATED_LABEL" ] || name=$(<"$SQUAD_TUIOS_CREATED_LABEL")
      placement=${SQUAD_TUIOS_FAKE_PLACEMENT:-$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE" 2>/dev/null || printf '5')}
      printf '{"windows":[{"id":"w-opaque_7","name":"%s","workspace":%s,"cwd":"/tmp/wt"}]}\n' "$name" "$placement"
    fi
    ;;
  get-window)
    if [ "${SQUAD_TUIOS_FAKE_GET_WINDOW_FAIL_ONCE:-0}" = 1 ]; then
      marker="$SQUAD_TUIOS_CREATED_WINDOW.get-window-failed"
      if [ ! -f "$marker" ]; then
        touch "$marker"
        exit 1
      fi
    fi
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
    if [ -n "${SQUAD_TUIOS_FAKE_AGENTS_SEQ:-}" ]; then
      seq_file=${SQUAD_TUIOS_FAKE_AGENTS_COUNT_FILE:?}
      n=$(cat "$seq_file" 2>/dev/null || echo 0)
      n=$((n + 1))
      printf '%s' "$n" > "$seq_file"
      state=$(printf '%s' "$SQUAD_TUIOS_FAKE_AGENTS_SEQ" | cut -d, -f"$n")
      [ -n "$state" ] || state=$(printf '%s' "$SQUAD_TUIOS_FAKE_AGENTS_SEQ" | awk -F, '{print $NF}')
      printf '{"agents":[{"id":"w-opaque_7","foreground":"","state":"%s","harness_id":"pi","confidence":"certain","blocked_by":"approval"}]}\n' "$state"
      exit 0
    fi
    if [ -n "${SQUAD_TUIOS_FAKE_AGENTS:-}" ]; then printf '%s\n' "$SQUAD_TUIOS_FAKE_AGENTS"; else
      printf '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done"}]}\n'
    fi
    ;;
  get-agent-state)
    printf '{"state":"%s","blocked_by":"%s","needs_you":%s,"ready":%s,"success":true}\n' \
      "${SQUAD_TUIOS_FAKE_AGENT_STATE:-working}" \
      "${SQUAD_TUIOS_FAKE_BLOCKED_BY:-}" \
      "${SQUAD_TUIOS_FAKE_NEEDS_YOU:-false}" \
      "${SQUAD_TUIOS_FAKE_READY:-false}"
    ;;
  respond)
    [ -z "${SQUAD_TUIOS_FAKE_RESPOND_MARK:-}" ] || : > "$SQUAD_TUIOS_FAKE_RESPOND_MARK"
    if [ -n "${SQUAD_TUIOS_FAKE_RESPOND_PROSE:-}" ]; then
      jq -cn --arg err "$SQUAD_TUIOS_FAKE_RESPOND_PROSE" '{error: $err, success: false}'
      exit 1
    fi
    if [ "${SQUAD_TUIOS_FAKE_RESPOND_FAIL:-0}" = 1 ]; then
      printf '{"error":{"code":"%s","message":"simulated response refusal"}}\n' "${SQUAD_TUIOS_FAKE_RESPOND_ERROR:-timeout}" >&2
      exit 1
    fi
    [ -z "${SQUAD_TUIOS_FAKE_RESPOND_STDERR:-}" ] || printf '%s\n' "$SQUAD_TUIOS_FAKE_RESPOND_STDERR" >&2
    respond_prompt_id=
    respond_prev=
    for respond_arg in "$@"; do
      if [ "$respond_prev" = --prompt-id ]; then respond_prompt_id=$respond_arg; break; fi
      respond_prev=$respond_arg
    done
    [ -n "$respond_prompt_id" ] || respond_prompt_id=${SQUAD_TUIOS_FAKE_PROMPT_ID:-p1}
    printf '{"success":true,"prompt_id":"%s","settled_by":"%s","state":"%s"}\n' \
      "${SQUAD_TUIOS_FAKE_RESPOND_ID:-$respond_prompt_id}" "${SQUAD_TUIOS_FAKE_SETTLED:-state}" "${SQUAD_TUIOS_FAKE_STATE:-working}"
    ;;
  peek-prompt)
    if [ -n "${SQUAD_TUIOS_FAKE_RESPOND_MARK:-}" ] && [ -e "$SQUAD_TUIOS_FAKE_RESPOND_MARK" ] \
       && [ "${SQUAD_TUIOS_FAKE_PROMPT_STATE_AFTER_RESPOND:-}" = fail ]; then
      exit 1
    elif [ "${SQUAD_TUIOS_FAKE_PROMPT_STATE:-blocked}" = unblocked ] \
       || { [ -n "${SQUAD_TUIOS_FAKE_RESPOND_MARK:-}" ] && [ -e "$SQUAD_TUIOS_FAKE_RESPOND_MARK" ] \
            && [ "${SQUAD_TUIOS_FAKE_PROMPT_STATE_AFTER_RESPOND:-}" = unblocked ]; }; then
      printf '{"blocked":false,"found":false,"reason":"the pane is not on needs_input","success":true}\n'
    else
      prompt_actions='"actions":["approve","deny","choose","text"],'
      [ -z "${SQUAD_TUIOS_FAKE_PROMPT_ACTIONS:-}" ] || prompt_actions=$(printf '"actions":%s,' "$SQUAD_TUIOS_FAKE_PROMPT_ACTIONS")
      [ "${SQUAD_TUIOS_FAKE_PROMPT_NO_ACTIONS:-0}" = 1 ] && prompt_actions=
      printf '{"blocked":true,"found":%s,"kind":"%s","message":"%s","lines":["%s"],"options":%s,"prompt_id":"%s",%s"answerable":true,"reason":"%s","success":true}\n' \
        "${SQUAD_TUIOS_FAKE_PROMPT_FOUND:-true}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_KIND:-approval}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_MESSAGE:-approve Bash: make}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_MESSAGE:-approve Bash: make}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_OPTIONS:-[]}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_ID:-p1}" \
        "$prompt_actions" \
        "${SQUAD_TUIOS_FAKE_PROMPT_REASON:-}"
    fi
    ;;
  queue)
    if [ "${2:-}" = ls ]; then
      if [ -n "${SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ:-}" ]; then
        seq_file=${SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE:?}
        n=$(cat "$seq_file" 2>/dev/null || echo 0)
        n=$((n + 1))
        printf '%s' "$n" > "$seq_file"
        state=$(printf '%s' "$SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ" | cut -d, -f"$n")
        [ -n "$state" ] || state=$(printf '%s' "$SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ" | awk -F, '{print $NF}')
        printf '{"entries":[{"id":"%s","state":"%s"}]}\n' "${SQUAD_TUIOS_FAKE_QUEUE_ID:-q1}" "$state"
        exit 0
      fi
      if [ -n "${SQUAD_TUIOS_FAKE_QUEUE_LS:-}" ]; then
        printf '%s\n' "$SQUAD_TUIOS_FAKE_QUEUE_LS"
      else
        printf '{"entries":[]}\n'
      fi
      exit 0
    fi
    if [ "${SQUAD_TUIOS_FAKE_QUEUE_FAIL:-0}" = 1 ]; then
      if [ -n "${SQUAD_TUIOS_FAKE_QUEUE_ERROR_CODE:-}" ]; then
        jq -cn --arg code "$SQUAD_TUIOS_FAKE_QUEUE_ERROR_CODE" \
          --arg msg "${SQUAD_TUIOS_FAKE_QUEUE_ERROR:-queue-prompt failed}" \
          '{error: {code: $code, message: $msg}, success: false}'
      else
        printf '%s' "${SQUAD_TUIOS_FAKE_QUEUE_ERROR:-queue-prompt failed}" | jq -Rs '{error: ., success: false}'
      fi
      exit 1
    fi
    printf '{"delivering":%s,"id":"%s","position":1,"queued":1,"success":true}\n' \
      "${SQUAD_TUIOS_FAKE_QUEUE_DELIVERING:-false}" "${SQUAD_TUIOS_FAKE_QUEUE_ID:-q1}"
    ;;
  resume-agent)
    if [ "${SQUAD_TUIOS_FAKE_RESUME_OK:-0}" = 1 ]; then
      printf '{"agent_session_id":"sid","command":"claude --resume sid","success":true,"typed":true,"window_id":"w-opaque_7"}\n'
    else
      printf '{"error":"%s","success":false}\n' "${SQUAD_TUIOS_FAKE_RESUME_ERROR:-resume-agent failed}"
      exit 1
    fi
    ;;
  run-command)
    # `run-command CloseWindow <id> --json`: exits 0 even when the close failed,
    # so the envelope is the only success signal.
    if [ "${SQUAD_TUIOS_FAKE_CLOSE_ENVELOPE:-}" = fail ]; then
      printf '{"message":"%s","success":false}\n' "${SQUAD_TUIOS_FAKE_CLOSE_MESSAGE:-no window found matching w-opaque_7}"
    else
      [ "${4:-}" != CloseWindow ] || rm -f "$SQUAD_TUIOS_CREATED_WINDOW"
      printf '{"message":"command executed","success":true}\n'
    fi
    ;;
  capture-pane) printf '%s\n' "${SQUAD_TUIOS_FAKE_CAPTURE:-captured output}" ;;
  new-window)
    printf '%s\n' "${2:-sq-task-1}" > "$SQUAD_TUIOS_CREATED_LABEL"
    shift 2
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --workspace ]; then printf '%s\n' "$2" > "$SQUAD_TUIOS_CREATED_WORKSPACE"; shift 2; else shift; fi
    done
    touch "$SQUAD_TUIOS_CREATED_WINDOW"
    printf 'w-opaque_7\n'
    ;;
  *) : ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/tuios"
export PATH="$TMP_ROOT/fakebin:$PATH" SQUAD_TUIOS_BIN=tuios SQUAD_TUIOS_LOG="$TMP_ROOT/log" \
  SQUAD_TUIOS_CREATED_WINDOW="$TMP_ROOT/created-window" SQUAD_TUIOS_CREATED_LABEL="$TMP_ROOT/created-label" \
  SQUAD_TUIOS_CREATED_WORKSPACE="$TMP_ROOT/created-workspace" \
  SQUAD_TUIOS_CREATED_WORKSPACE_NAME="$TMP_ROOT/created-workspace-name" \
  SQUAD_BACKEND_CONFIG_DIR="$TMP_ROOT/config" SQUAD_BACKEND_STATE_DIR="$TMP_ROOT/state"
mkdir -p "$TMP_ROOT/config" "$TMP_ROOT/state" "$TMP_ROOT/runtime"
XDG_RUNTIME_DIR="$TMP_ROOT/runtime"
export XDG_RUNTIME_DIR

source "$ROOT/bin/sq-backend.sh"
SQUAD_BACKEND_CONFIG_DIR="$TMP_ROOT/config"
SQUAD_BACKEND_STATE_DIR="$TMP_ROOT/state"
export SQUAD_BACKEND_CONFIG_DIR SQUAD_BACKEND_STATE_DIR
fm_backend_validate_spawn tuios || fail 'TUIOS should be a supported spawn backend'
[ "$(fm_backend_required_tools tuios)" = 'tuios jq fob flock' ] || fail 'required tools mismatch'
fm_backend_source tuios || fail 'adapter did not source'
fm_backend_tuios_tool_check || fail 'minimum TUIOS version should pass'

[ "$(fm_backend_tuios_target_exists owned:w-opaque_7 sq-task-1 && echo yes)" = yes ] || fail 'exact opaque target should resolve'
[ "$(fm_backend_tuios_capture owned:w-opaque_7 10 sq-task-1)" = 'captured output' ] || fail 'capture failed'

# Protocol discovery: the daemon's own verb catalogue must carry every verb and
# parameter this adapter uses before any task is created.
fm_backend_tuios_protocol_check owned || fail 'a complete verb catalogue must pass protocol discovery'
SQUAD_TUIOS_FAKE_VERBS_OMIT=resume-agent
export SQUAD_TUIOS_FAKE_VERBS_OMIT
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-verb-err"; then fail 'a catalogue missing a required verb must refuse'; fi
assert_contains "$(cat "$TMP_ROOT/proto-verb-err")" 'missing verb resume-agent' 'a missing verb must be named'
unset SQUAD_TUIOS_FAKE_VERBS_OMIT
SQUAD_TUIOS_FAKE_PARAM_OMIT=close-window:window
export SQUAD_TUIOS_FAKE_PARAM_OMIT
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-param-err"; then fail 'a catalogue missing a required parameter must refuse'; fi
assert_contains "$(cat "$TMP_ROOT/proto-param-err")" 'close-window has no parameter window' 'a missing parameter must be named'
unset SQUAD_TUIOS_FAKE_PARAM_OMIT
SQUAD_TUIOS_FAKE_VERBS_FAIL=1
export SQUAD_TUIOS_FAKE_VERBS_FAIL
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-fail-err"; then fail 'an unreadable catalogue must refuse'; fi
assert_contains "$(cat "$TMP_ROOT/proto-fail-err")" 'catalogue is unreadable' 'an unreadable catalogue must say so'
unset SQUAD_TUIOS_FAKE_VERBS_FAIL
if SQUAD_TUIOS_FAKE_SESSION_DEAD=1 fm_backend_tuios_container_ensure /tmp/project >/dev/null 2>&1; then
  fail 'a dead session must never reach protocol discovery or be adopted'
fi

[ "$(fm_backend_tuios_boot_id owned)" = 'boot-a' ] || fail 'the daemon boot id must be readable for restart detection'
SQUAD_TUIOS_FAKE_BOOT_ID=boot-b
export SQUAD_TUIOS_FAKE_BOOT_ID
[ "$(fm_backend_tuios_boot_id owned)" = 'boot-b' ] || fail 'a changed daemon boot id must be observable'
unset SQUAD_TUIOS_FAKE_BOOT_ID

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
rendered_log_start=$(wc -l < "$SQUAD_TUIOS_LOG")
[ "$(fm_backend_tuios_capture_rendered owned:w-opaque_7 sq-task-1)" = 'captured output' ] || fail 'rendered capture failed'
rendered_log=$(tail -n +$((rendered_log_start + 1)) "$SQUAD_TUIOS_LOG")
assert_contains "$rendered_log" 'capture-pane --session owned --window w-opaque_7' 'rendered capture did not target the owned window'
assert_not_contains "$rendered_log" '--scrollback' 'rendered capture requested scrollback instead of the visible screen'

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

# --- state and provenance ----------------------------------------------
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'agent inventory should corroborate Pi despite foreground=false'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = idle ] || fail 'a TUIOS-reported rest state must map to idle, never to a hard-coded unknown'

SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"working","harness_id":"pi","source":"report","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = busy ] || fail 'a reported working turn must map to busy'
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'a reported working turn is a live agent'
unset SQUAD_TUIOS_FAKE_AGENTS

SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","source":"report","confidence":"certain","blocked_by":"approval","needs_you":true}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = blocked ] || fail 'needs_input must map to blocked, never to ordinary work'
unset SQUAD_TUIOS_FAKE_AGENTS

# A restored pane after a daemon restart: the window survives, the shell is new,
# and nothing is attributed to it. This is recovery-grade `dead`, not the silent
# `ambiguous` degradation that never licensed recovery.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","source":"","confidence":"none","needs_you":false}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = dead ] || fail 'a restored agentless pane must be dead, never ambiguous'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = unknown ] || fail 'an agentless pane has no busy verdict'
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7 2>/dev/null)" = dead ] || fail 'the recovery classifier must stay dead on a reread'
unset SQUAD_TUIOS_FAKE_AGENTS

# A state with no attribution at all is an incomplete report, not proof of
# absence: recovery must not be licensed from it.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = ambiguous ] || fail 'unattributed non-empty state must remain ambiguous'
unset SQUAD_TUIOS_FAKE_AGENTS

# A finished agent whose process has exited: the daemon still names the harness
# it recorded, but its foreground program is gone. This is recovery-grade
# `dead`, never `alive`, because nothing is running in the pane to duplicate.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done","harness_id":"pi","source":"report","confidence":"certain","agent_session_id":"01a108df-1fb7-753d-992f-5b9623d45780","finished_unread":false}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = dead ] || fail 'a finished agent with no foreground program must be recovery-grade dead'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = idle ] || fail 'a finished, foreground-less agent still reports the daemon rest state'
unset SQUAD_TUIOS_FAKE_AGENTS

# The same finished report attributed by harness alone is still agentless.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done","harness_id":"pi","confidence":"none"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = dead ] || fail 'a finished agentless pane attributed by harness alone must be dead'
unset SQUAD_TUIOS_FAKE_AGENTS

# Every state that does not positively indicate a finished agent stays out of
# the recovery class, even with no foreground program.
for sig in working needs_input errored idle unknown; do
  SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' "{\"agents\":[{\"id\":\"w-opaque_7\",\"foreground\":\"\",\"state\":\"$sig\",\"harness_id\":\"pi\",\"confidence\":\"certain\"}]}")
  export SQUAD_TUIOS_FAKE_AGENTS
  [ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] \
    || fail "state '$sig' with no foreground must still classify alive, never recoverable"
  unset SQUAD_TUIOS_FAKE_AGENTS
done

# A detected foreground program keeps the report live whatever the state, so a
# running agent is never mistaken for a finished one.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done","harness_id":"pi","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = alive ] || fail 'a done agent that still has its foreground program must stay alive'
unset SQUAD_TUIOS_FAKE_AGENTS

# --- prompt content ----------------------------------------------------
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"approval"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
assert_contains "$(fm_backend_prompt_summary tuios owned:w-opaque_7)" 'approval: approve Bash: make' \
  'a classified blocking prompt must be readable through the prompt verb'
assert_contains "$(fm_backend_prompt_summary tuios owned:w-opaque_7)" 'prompt_id=p1' \
  'the summary must name the exact prompt id an answer has to carry'
unset SQUAD_TUIOS_FAKE_AGENTS
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'peek-prompt --session owned --window w-opaque_7 --json' \
  'prompt content must come from the prompt verb'
SQUAD_TUIOS_FAKE_PROMPT_STATE=unblocked
export SQUAD_TUIOS_FAKE_PROMPT_STATE
[ -z "$(fm_backend_prompt_summary tuios owned:w-opaque_7)" ] || fail 'a pane that is not blocked has no prompt summary'
unset SQUAD_TUIOS_FAKE_PROMPT_STATE
[ -z "$(fm_backend_prompt_summary tmux owned:w-opaque_7 2>/dev/null)" ] || fail 'backends without a prompt verb must report no prompt summary'

# Numbered options: the daemon's peek-prompt carries an options array (plain
# strings, or objects with a label/text/name) alongside the message, and the
# summary renders them as "1) ... 2) ..." so a wake naming this prompt also
# names what a person can answer with.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"approval"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_PROMPT_OPTIONS=$(printf '%s' '["Yes","No"]')
export SQUAD_TUIOS_FAKE_PROMPT_OPTIONS
summary=$(fm_backend_prompt_summary tuios owned:w-opaque_7)
assert_contains "$summary" 'approval: approve Bash: make' 'the message must still be readable with options present'
assert_contains "$summary" '1) Yes 2) No' 'plain-string options must render as numbered options'
unset SQUAD_TUIOS_FAKE_PROMPT_OPTIONS

SQUAD_TUIOS_FAKE_PROMPT_OPTIONS=$(printf '%s' '[{"label":"Allow once"},{"text":"Always allow"}]')
export SQUAD_TUIOS_FAKE_PROMPT_OPTIONS
assert_contains "$(fm_backend_prompt_summary tuios owned:w-opaque_7)" '1) Allow once 2) Always allow' \
  'object-shaped options must render their label/text as numbered options'
unset SQUAD_TUIOS_FAKE_PROMPT_OPTIONS

# The daemon numbers each option itself (`n`), so a prompt whose numbers are not
# 1..N must name the numbers a person actually sees.
SQUAD_TUIOS_FAKE_PROMPT_OPTIONS=$(printf '%s' '[{"n":2,"label":"Allow once"},{"n":5,"label":"Always allow"}]')
export SQUAD_TUIOS_FAKE_PROMPT_OPTIONS
assert_contains "$(fm_backend_prompt_summary tuios owned:w-opaque_7)" '2) Allow once 5) Always allow' \
  "the summary must render the prompt's own on-screen option numbers"
unset SQUAD_TUIOS_FAKE_PROMPT_OPTIONS

SQUAD_TUIOS_FAKE_PROMPT_OPTIONS='[]'
export SQUAD_TUIOS_FAKE_PROMPT_OPTIONS
summary=$(fm_backend_prompt_summary tuios owned:w-opaque_7)
[ "$summary" = 'approval: approve Bash: make prompt_id=p1' ] \
  || fail "an empty options array must change nothing but the prompt id: $summary"
unset SQUAD_TUIOS_FAKE_PROMPT_OPTIONS SQUAD_TUIOS_FAKE_AGENTS

# --- delivery: the queue path and its distinct verdicts ----------------
# Blocked: nothing is typed, and the distinct verdict names the block.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"question"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
: > "$SQUAD_TUIOS_LOG"
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'allow' 3 0 0 sq-task-1)" = agent_blocked ] \
  || fail 'a blocked pane must refuse with agent_blocked'
if grep -qE '^(queue|send-text|send-keys) ' "$SQUAD_TUIOS_LOG"; then
  fail 'a blocked pane must never receive typed text'
fi
unset SQUAD_TUIOS_FAKE_AGENTS

# The agent took the queued entry: an observed postcondition, so delivery is real.
: > "$SQUAD_TUIOS_LOG"
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = empty ] \
  || fail 'a queue entry the agent took must confirm delivery'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'queue --session owned --window w-opaque_7 --json -- do work' \
  'the queue path must be used for asynchronous steering, not raw text plus Enter'

# The entry was typed and not taken: a real verdict, and never a success.
SQUAD_TUIOS_FAKE_QUEUE_LS=$(printf '%s' '{"entries":[{"id":"q1","state":"stalled"}]}')
export SQUAD_TUIOS_FAKE_QUEUE_LS
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = stalled ] \
  || fail 'a stalled queue entry must be reported as stalled'
unset SQUAD_TUIOS_FAKE_QUEUE_LS

# Still waiting for the agent's next rest is not a stall: the daemon owns it.
SQUAD_TUIOS_FAKE_QUEUE_LS=$(printf '%s' '{"entries":[{"id":"q1","state":"waiting"}]}')
export SQUAD_TUIOS_FAKE_QUEUE_LS
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = empty ] \
  || fail 'a queue entry waiting for the next rest is a confirmed queueing'
unset SQUAD_TUIOS_FAKE_QUEUE_LS

# A being-typed entry that then stalls is observed across polls before any
# verdict: the first poll must see `delivering`, and only a later `stalled` poll
# may resolve it.
SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ='delivering,stalled'
SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE="$TMP_ROOT/queue-ls-count"
export SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE
printf '0' > "$SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE"
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = stalled ] \
  || fail 'a delivering entry that stalls must be reported as stalled'
[ "$(cat "$SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE")" -ge 2 ] \
  || fail 'the delivering->stalled transition must be observed across polls, not resolved on the first'
unset SQUAD_TUIOS_FAKE_QUEUE_LS_SEQ SQUAD_TUIOS_FAKE_QUEUE_LS_COUNT_FILE

# A full queue is a refusal that typed nothing, and says so distinctly. The
# second wording is the live TUIOS 0.8.0 message, which carries no code token.
SQUAD_TUIOS_FAKE_QUEUE_FAIL=1 SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: the pane already holds as many queued messages as allowed (queue_full)'
export SQUAD_TUIOS_FAKE_QUEUE_FAIL SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = queue_full ] \
  || fail 'a full queue must be reported as queue_full'
SQUAD_TUIOS_FAKE_QUEUE_ERROR=$(printf '%s' 'queue-prompt failed: the queue for window w-opaque_7 holds 8 messages, as many as [agents.queue] max allows.
Most likely cause: Nothing was queued.
Fix: run tuios queue ls.')
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = queue_full ] \
  || fail 'the live full-queue wording must map to queue_full'
SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: the target agent was mid-turn (not_ready)'
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = not_ready ] \
  || fail 'a not-ready refusal must be reported as not_ready'
SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: the prompt was typed and not taken (prompt_stalled)'
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = prompt_stalled ] \
  || fail 'a typed-but-untaken prompt must be reported as prompt_stalled'
# A pane without an attributable agent is refused; it never falls back to
# typing into the terminal.
SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: window w-opaque_7 runs no agent tuios knows of, so nothing would take a queued prompt.'
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
: > "$SQUAD_TUIOS_LOG"
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = no_agent ] \
  || fail 'a pane with no attributable agent must be refused without typing'
if grep -qE '^(send-text|send-keys) ' "$SQUAD_TUIOS_LOG"; then
  fail 'a pane without an attributable agent must not receive terminal input'
fi
# A daemon that reports the refusal as a structured code rather than prose must
# still reach the same verdict, so the code path is not a generic send failure.
for pair in queue_full:queue_full agent_blocked:agent_blocked not_ready:not_ready prompt_stalled:prompt_stalled no_agent:no_agent; do
  code=${pair%%:*} want=${pair#*:}
  SQUAD_TUIOS_FAKE_QUEUE_ERROR_CODE=$code SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt refused'
  export SQUAD_TUIOS_FAKE_QUEUE_ERROR_CODE SQUAD_TUIOS_FAKE_QUEUE_ERROR
  [ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = "$want" ] \
    || fail "the structured $code refusal must be reported as $want"
done
unset SQUAD_TUIOS_FAKE_QUEUE_ERROR_CODE SQUAD_TUIOS_FAKE_QUEUE_ERROR
SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: something undocumented'
export SQUAD_TUIOS_FAKE_QUEUE_ERROR
[ "$(fm_backend_tuios_send_text_submit owned:w-opaque_7 'do work' 3 0 0 sq-task-1)" = send-failed ] \
  || fail 'an unrecognized refusal must stay a plain send failure'
unset SQUAD_TUIOS_FAKE_QUEUE_FAIL SQUAD_TUIOS_FAKE_QUEUE_ERROR

# --- recovery ----------------------------------------------------------
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"working","harness_id":"pi","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = live ] || fail 'a live agent must never be resumed over'
unset SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"idle","harness_id":"pi","confidence":"certain","agent_session_id":"sid"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = live ] || fail 'an attributed agent between turns must never be resumed over'
unset SQUAD_TUIOS_FAKE_AGENTS
# A finished, foreground-less agent with a recorded conversation is recoverable
# through the product's own resume verb instead of being mistaken for live.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done","harness_id":"pi","confidence":"certain","agent_session_id":"sid"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_RESUME_OK=1
export SQUAD_TUIOS_FAKE_RESUME_OK
if [ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 claude)" != resumed ]; then
  fail 'a finished, foreground-less agent with a recorded conversation must be resumable'
fi
unset SQUAD_TUIOS_FAKE_RESUME_OK
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done","harness_id":"pi","confidence":"certain","agent_session_id":"sid"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 claude)" = live ] || fail 'a done agent that still holds a foreground program must never be resumed over'
unset SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","confidence":"none","agent_session_id":""}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = no_conversation ] || fail 'a pane with no recorded conversation cannot be resumed'
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","confidence":"none","agent_session_id":"sid"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_RESUME_OK=1
export SQUAD_TUIOS_FAKE_RESUME_OK
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 claude)" = resumed ] || fail 'a supported harness must resume the recorded conversation'
unset SQUAD_TUIOS_FAKE_RESUME_OK
SQUAD_TUIOS_FAKE_RESUME_ERROR='harness pi has no resume command (not_resumable)'
export SQUAD_TUIOS_FAKE_RESUME_ERROR
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = unsupported ] || fail 'a harness with no resume command must be reported unsupported'
SQUAD_TUIOS_FAKE_RESUME_ERROR='no conversation is recorded for this pane (not_resumable)'
export SQUAD_TUIOS_FAKE_RESUME_ERROR
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 pi)" = no_conversation ] || fail 'a missing recorded conversation must be reported'
SQUAD_TUIOS_FAKE_RESUME_ERROR='the pane shell is not at its prompt (not_ready)'
export SQUAD_TUIOS_FAKE_RESUME_ERROR
[ "$(fm_backend_tuios_resume_agent owned:w-opaque_7 claude)" = not_ready ] || fail 'a shell that is not at its prompt must be reported not_ready'
unset SQUAD_TUIOS_FAKE_RESUME_ERROR SQUAD_TUIOS_FAKE_AGENTS

# Reusing a restored window needs BOTH a changed daemon boot id and a confirmed
# agentless pane; neither alone is enough to authorize a relaunch. A finished
# agent whose foreground program is gone is the second agentless shape, checked
# separately below.
SQUAD_TUIOS_FAKE_RESTORED_WINDOW=1
export SQUAD_TUIOS_FAKE_RESTORED_WINDOW
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","confidence":"none"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-old)" = 'w-opaque_7' ] \
  || fail 'a restored agentless window after a boot change must be reusable'
if fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-a >/dev/null 2>&1; then
  fail 'an unchanged daemon boot id must never authorize reuse'
fi
if fm_backend_tuios_reuse_restored_task owned sq-task-1 '' >/dev/null 2>&1; then
  fail 'no recorded boot id must never authorize a post-restart reuse'
fi
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
if fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-old >/dev/null 2>&1; then
  fail 'a window a live agent owns must never be reused'
fi
if fm_backend_tuios_reuse_restored_task owned sq-other-1 boot-old >/dev/null 2>&1; then
  fail 'a window without the task label must never be reused'
fi
unset SQUAD_TUIOS_FAKE_RESTORED_WINDOW SQUAD_TUIOS_FAKE_AGENTS

# A finished agent whose foreground program is gone authorizes reuse of the
# recorded window even on the SAME daemon boot id: the daemon's own report is
# the evidence, and the window label still identifies the task.
SQUAD_TUIOS_FAKE_RESTORED_WINDOW=1
export SQUAD_TUIOS_FAKE_RESTORED_WINDOW
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done","harness_id":"pi","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-a)" = 'w-opaque_7' ] \
  || fail 'a finished, foreground-less agent must be reusable on the same daemon boot id'
# The finished shape is boot-independent: an empty recorded boot id still reuses
# the recorded window, so metadata that predates the boot marker recovers too.
[ "$(fm_backend_tuios_reuse_restored_task owned sq-task-1 '')" = 'w-opaque_7' ] \
  || fail 'a finished, foreground-less agent must be reusable without recorded boot evidence'
# Every live or ambiguous shape still refuses, even after a boot change.
assert_not_reusable() {  # <agents-json> <message>
  SQUAD_TUIOS_FAKE_AGENTS=$1
  export SQUAD_TUIOS_FAKE_AGENTS
  if fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-old >/dev/null 2>&1; then
    fail "$2"
  fi
}
assert_not_reusable '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"done","harness_id":"pi","confidence":"certain"}]}' \
  'a done agent whose foreground program is present must never be reused'
assert_not_reusable '{"agents":[{"id":"w-opaque_7","foreground":"","state":"working","harness_id":"pi","confidence":"certain"}]}' \
  'a working agent must never be reused'
assert_not_reusable '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done"}]}' \
  'a done report with no attribution must never be reused'
unset SQUAD_TUIOS_FAKE_RESTORED_WINDOW SQUAD_TUIOS_FAKE_AGENTS

# The same-label lookup must read identity through the shared normalizer, so an
# inventory that reports the documented `id` key (the default TUIOS shape) is
# reusable after a restart exactly like a `window_id` one.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"none","harness_id":"","confidence":"none"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_reuse_restored_task owned sq-task-1 boot-old)" = 'w-opaque_7' ] \
  || fail 'a restored id-keyed window after a boot change must be reusable'
unset SQUAD_TUIOS_FAKE_AGENTS

# --- inventory safety (unchanged contract) ------------------------------
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
unset SQUAD_TUIOS_FAKE_ERROR_WITH_WINDOW

# The agent report reads the agent inventory, whose own error envelope must stay
# unreadable rather than turning into an authoritative agentless verdict.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"error":{"code":"daemon_unreachable"},"agents":[]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7)" = unreadable ] || fail 'an agent-inventory error envelope must keep agent state unreadable'
[ "$(fm_backend_tuios_busy_state owned:w-opaque_7)" = unknown ] || fail 'an agent-inventory error envelope must keep the busy verdict unknown'
unset SQUAD_TUIOS_FAKE_AGENTS

if fm_backend_tuios_create_task owned sq-task-1 /tmp/wt >/dev/null 2>&1; then
  fail 'an existing TUIOS task label must refuse duplicate-name creation'
fi
[ "$(grep -c 'new-window sq-task-1' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'duplicate-label refusal must not create a new window'

# A live agent on the same label must keep refusing: the reuse path is only for
# a restored, agentless window.
SQUAD_TUIOS_FAKE_RESTORED_WINDOW=1
export SQUAD_TUIOS_FAKE_RESTORED_WINDOW
if fm_backend_tuios_create_task owned sq-task-1 /tmp/wt >/dev/null 2>&1; then
  fail 'create_task must never adopt a same-label window on its own'
fi
unset SQUAD_TUIOS_FAKE_RESTORED_WINDOW

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

# A null foreground normalizes to empty, so this is the same finished,
# foreground-less shape: harness identity alone corroborates a finished, not a
# running, agent, and the pane is recovery-grade dead.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":null,"harness_id":"pi","state":"done"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(fm_backend_tuios_agent_state owned:w-opaque_7 2>/dev/null)" = dead ] || fail 'a null foreground on a finished agent must classify dead, never alive'
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
[ "$(fm_backend_tuios_create_task owned sq-spawn-test /tmp/wt | cut -f1)" = w-opaque_7 ] || fail 'task window creation failed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-spawn-test --session owned --cwd /tmp/wt --workspace 2 --no-focus --print-id' 'spawn did not create an unfocused task-specific workspace in the exact session'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
# Legacy pid-lock remnants are inert under the kernel lock and must never be
# reclaimed or unlinked by a later allocator.
legacy_lock="$XDG_RUNTIME_DIR/.squad-tuios-workspace-owned.lock"
rm -rf "$legacy_lock"
mkdir -p "$legacy_lock"
printf 'not-a-pid\n' > "$legacy_lock/pid"
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-stale-lock
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
created=$(fm_backend_tuios_create_task owned sq-stale-lock /tmp/wt) || fail 'a legacy corrupt lock must not block task allocation'
[ "${created%%$'\t'*}" = w-opaque_7 ] || fail 'ignoring a legacy lock must still create the task window'
[ -n "${created#*$'\t'}" ] || fail 'create_task must return the selected workspace id'
[ -d "$legacy_lock" ] || fail 'the allocator must not remove a legacy lock directory'
[ -f "$XDG_RUNTIME_DIR/.squad-tuios-workspace-owned.flock" ] || fail 'the stable kernel-lock file must remain after allocation'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME

# Two separate bases share the session lock: a waiter cannot enter TUIOS while
# the first allocator owns the kernel lock, and the later allocation gets a
# different workspace without relying on shared task metadata.
rm -f "$SQUAD_TUIOS_CREATED_WINDOW" "$SQUAD_TUIOS_CREATED_LABEL" \
  "$SQUAD_TUIOS_CREATED_WORKSPACE" "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
mkdir -p "$TMP_ROOT/base-a/state" "$TMP_ROOT/base-a/config" \
  "$TMP_ROOT/base-b/state" "$TMP_ROOT/base-b/config"
(
  SQUAD_BACKEND_STATE_DIR="$TMP_ROOT/base-a/state"
  SQUAD_BACKEND_CONFIG_DIR="$TMP_ROOT/base-a/config"
  SQUAD_TUIOS_FAKE_ALLOC_PAUSE=1
  SQUAD_TUIOS_FAKE_ALLOC_PAUSE_MARK="$TMP_ROOT/alloc-paused"
  SQUAD_TUIOS_FAKE_ALLOC_RELEASE="$TMP_ROOT/alloc-release"
  SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1
  SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-base-a
  export SQUAD_BACKEND_STATE_DIR SQUAD_BACKEND_CONFIG_DIR \
    SQUAD_TUIOS_FAKE_ALLOC_PAUSE SQUAD_TUIOS_FAKE_ALLOC_PAUSE_MARK \
    SQUAD_TUIOS_FAKE_ALLOC_RELEASE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
  fm_backend_tuios_create_task owned sq-base-a /tmp/base-a
) > "$TMP_ROOT/base-a.out" 2> "$TMP_ROOT/base-a.err" &
alloc_a_pid=$!
for _ in $(seq 1 500); do
  [ ! -e "$TMP_ROOT/alloc-paused" ] || break
  sleep 0.01
done
[ -e "$TMP_ROOT/alloc-paused" ] || fail 'first allocator did not enter the protected inventory read'
lockfile="$XDG_RUNTIME_DIR/.squad-tuios-workspace-owned.flock"
lock_inode_before=$(stat -c '%d:%i' "$lockfile" 2>/dev/null || stat -f '%d:%i' "$lockfile")
log_lines_before_waiter=$(wc -l < "$SQUAD_TUIOS_LOG")
(
  SQUAD_BACKEND_STATE_DIR="$TMP_ROOT/base-b/state"
  SQUAD_BACKEND_CONFIG_DIR="$TMP_ROOT/base-b/config"
  SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1
  SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-base-b
  export SQUAD_BACKEND_STATE_DIR SQUAD_BACKEND_CONFIG_DIR \
    SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
  fm_backend_tuios_create_task owned sq-base-b /tmp/base-b
) > "$TMP_ROOT/base-b.out" 2> "$TMP_ROOT/base-b.err" &
alloc_b_pid=$!
sleep 0.1
[ "$(wc -l < "$SQUAD_TUIOS_LOG")" -eq "$log_lines_before_waiter" ] || fail 'second base reached TUIOS before the first allocation released the session lock'
touch "$TMP_ROOT/alloc-release"
wait "$alloc_a_pid" || fail "first base allocation failed: $(cat "$TMP_ROOT/base-a.err")"
wait "$alloc_b_pid" || fail "second base allocation failed: $(cat "$TMP_ROOT/base-b.err")"
[ "$(cut -f2 "$TMP_ROOT/base-a.out")" = 2 ] || fail 'the first base did not claim the lowest eligible workspace'
[ "$(cut -f2 "$TMP_ROOT/base-b.out")" = 3 ] || fail 'the waiting base reused the first base workspace'
lock_inode_after=$(stat -c '%d:%i' "$lockfile" 2>/dev/null || stat -f '%d:%i' "$lockfile")
[ "$lock_inode_before" = "$lock_inode_after" ] || fail 'a waiter replaced or unlinked the active session lock inode'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-base-a --session owned --cwd /tmp/base-a --workspace 2 --no-focus --print-id' 'first task was not created without focusing its workspace'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-base-b --session owned --cwd /tmp/base-b --workspace 3 --no-focus --print-id' 'second base did not create an unfocused task in a distinct workspace'
rm -rf "$legacy_lock"
pass 'flock serializes concurrent allocations across bases and keeps the per-session lock inode stable'
printf '2\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE"
printf 'sq-spawn-test\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"

# Every task gets a new workspace after the existing range. The adapter
# requires both workspace discovery and explicit new-window placement support.
fm_backend_tuios_protocol_check owned || fail 'a complete workspace catalogue must pass protocol discovery'
SQUAD_TUIOS_FAKE_VERBS_OMIT='list-workspaces'
export SQUAD_TUIOS_FAKE_VERBS_OMIT
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-ws-verb-err"; then fail 'a daemon without list-workspaces must refuse per-task placement'; fi
assert_contains "$(cat "$TMP_ROOT/proto-ws-verb-err")" 'missing verb list-workspaces' 'workspace discovery must name its missing verb'
unset SQUAD_TUIOS_FAKE_VERBS_OMIT
SQUAD_TUIOS_FAKE_PARAM_OMIT=new-window:workspace
export SQUAD_TUIOS_FAKE_PARAM_OMIT
if fm_backend_tuios_protocol_check owned 2>"$TMP_ROOT/proto-ws-param-err"; then fail 'new-window without workspace support must refuse'; fi
assert_contains "$(cat "$TMP_ROOT/proto-ws-param-err")" 'new-window has no parameter workspace' 'placement discovery must name its missing parameter'
unset SQUAD_TUIOS_FAKE_PARAM_OMIT
[ "$(fm_backend_tuios_container_ensure /tmp/project)" = owned ] || fail 'container_ensure must accept a workspace-capable session'
# A configured workspace is only a preference: occupied and named workspaces
# are never selected, and durable task metadata leases an otherwise empty one.
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
printf '4\n' > "$TMP_ROOT/config/tuios-workspace"
[ "$(fm_backend_tuios_next_workspace owned)" = 3 ] || fail 'an occupied configured workspace must be skipped'
printf '2\n' > "$TMP_ROOT/config/tuios-workspace"
printf '2\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE"
printf 'commander-label\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
[ "$(fm_backend_tuios_next_workspace owned)" = 3 ] || fail 'a named empty workspace must be skipped'
rm -f "$SQUAD_TUIOS_CREATED_WORKSPACE" "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
cat > "$TMP_ROOT/state/leased.meta" <<'META'
backend=tuios
tuios_session=owned
tuios_workspace_id=2
META
lease_workspace=$(fm_backend_tuios_next_workspace owned)
[ "$lease_workspace" = 3 ] || fail "a workspace leased by another task must be skipped (selected '$lease_workspace')"
rm -f "$TMP_ROOT/state/leased.meta"
printf '6\n' > "$TMP_ROOT/config/tuios-workspace"
preferred_workspace=$(fm_backend_tuios_next_workspace owned)
[ "$preferred_workspace" = 6 ] || fail "an available configured workspace must be preferred (selected '$preferred_workspace')"
rm -f "$TMP_ROOT/config/tuios-workspace"
# Restore the fake window record for the earlier live task after the selection
# unit fixtures temporarily used the same inventory marker.
printf '2\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE"
printf 'sq-spawn-test\n' > "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME"
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-grouped
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
[ "$(fm_backend_tuios_create_task owned sq-grouped /tmp/wt | cut -f1)" = w-opaque_7 ] || fail 'per-task workspace creation must succeed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-grouped --session owned --cwd /tmp/wt --workspace 3 --no-focus --print-id' 'a live task window must cause the next task to use another workspace'
# A nested window record carrying workspace under `.window` must verify the
# same exact placement instead of reading as absent.
SQUAD_TUIOS_FAKE_NESTED_WORKSPACE=1 SQUAD_TUIOS_FAKE_PLACEMENT=3
export SQUAD_TUIOS_FAKE_NESTED_WORKSPACE SQUAD_TUIOS_FAKE_PLACEMENT
[ "$(fm_backend_tuios_workspace_for_window owned w-opaque_7)" = 3 ] || fail 'a nested workspace field must be read exactly'
unset SQUAD_TUIOS_FAKE_NESTED_WORKSPACE SQUAD_TUIOS_FAKE_PLACEMENT
# The configured workspace is a preference; a live task makes the next free
# workspace the correct allocation rather than sharing the same screen.
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-next-ws
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
[ "$(fm_backend_tuios_create_task owned sq-next-ws /tmp/wt | cut -f1)" = w-opaque_7 ] || fail 'second task workspace creation must succeed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-next-ws --session owned --cwd /tmp/wt --workspace 2 --no-focus --print-id' 'the next task must take another empty workspace, not the occupied one'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
cat > "$TMP_ROOT/state/next-ws.meta" <<'META'
window=owned:w-opaque_7
endpoint_task_id=next-ws
backend=tuios
tuios_session=owned
tuios_window_id=w-opaque_7
tuios_workspace_id=2
META
rm -f "$SQUAD_TUIOS_CREATED_WINDOW"
SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1
export SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
fm_backend_tuios_release_task_workspace next-ws "$TMP_ROOT/state/next-ws.meta" || fail 'normal teardown must release and unname its empty task workspace'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'set-workspace-name --session owned 2' 'task teardown must clear only its own workspace name'
unset SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
rm -f "$TMP_ROOT/state/next-ws.meta"
# A wrong workspace must refuse and close only the just-created window.
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_PLACEMENT=1 SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-wrong-place
export SQUAD_TUIOS_FAKE_PLACEMENT SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-wrong-place /tmp/wt >/dev/null 2>&1; then fail 'wrong-workspace creation must refuse'; fi
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'a wrong-workspace refusal must close the just-created task window'
unset SQUAD_TUIOS_FAKE_PLACEMENT SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
# A post-creation inventory that omits every workspace field is missing
# placement and must refuse and close only the just-created window.
rm -f "$SQUAD_TUIOS_CREATED_WINDOW" "$SQUAD_TUIOS_CREATED_LABEL"
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_NO_WORKSPACE=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-missing-place
export SQUAD_TUIOS_FAKE_NO_WORKSPACE SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-missing-place /tmp/wt >/dev/null 2>&1; then fail 'missing placement must refuse'; fi
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'new-window sq-missing-place --session owned --cwd /tmp/wt --workspace 2 --no-focus --print-id' 'missing-placement creation must still target the allocated workspace'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'missing placement must close the just-created task window'
unset SQUAD_TUIOS_FAKE_NO_WORKSPACE
# An unreadable post-creation inventory must also close the created window.
rm -f "$SQUAD_TUIOS_CREATED_WINDOW" "$SQUAD_TUIOS_CREATED_LABEL"
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_LIST_FAIL_AFTER_CREATE=1 SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-verify-fail
export SQUAD_TUIOS_FAKE_LIST_FAIL_AFTER_CREATE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-verify-fail /tmp/wt >/dev/null 2>&1; then fail 'an unreadable post-creation inventory must refuse'; fi
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'an unverifiable placement must close the just-created task window'
unset SQUAD_TUIOS_FAKE_LIST_FAIL_AFTER_CREATE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
# A failed post-creation label read must attempt to close the created window so
# the exact id does not leak and block a retry.
rm -f "$SQUAD_TUIOS_CREATED_WINDOW" "$SQUAD_TUIOS_CREATED_LABEL" "$SQUAD_TUIOS_CREATED_WINDOW.get-window-failed"
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_GET_WINDOW_FAIL_ONCE=1 SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-label-fail
export SQUAD_TUIOS_FAKE_GET_WINDOW_FAIL_ONCE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-label-fail /tmp/wt >/dev/null 2>&1; then fail 'a failed post-creation label read must refuse'; fi
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'a failed post-creation label read must close the just-created task window'
unset SQUAD_TUIOS_FAKE_GET_WINDOW_FAIL_ONCE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS
# A transient failure of the post-naming verification read must not leak the
# just-set workspace name: the still-empty workspace is un-named so the pool
# can reuse it instead of skipping it forever.
rm -f "$SQUAD_TUIOS_CREATED_WORKSPACE" "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME" \
  "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME.workspaces-failed-once"
: > "$SQUAD_TUIOS_LOG"
SQUAD_TUIOS_FAKE_WORKSPACES_FAIL_ONCE=1 SQUAD_TUIOS_FAKE_EMPTY_WINDOWS=1 SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-name-leak
export SQUAD_TUIOS_FAKE_WORKSPACES_FAIL_ONCE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
if fm_backend_tuios_create_task owned sq-name-leak /tmp/wt >/dev/null 2>&1; then fail 'a failed post-naming verification read must refuse'; fi
[ ! -s "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME" ] || [ "$(cat "$SQUAD_TUIOS_CREATED_WORKSPACE_NAME")" = "" ] || fail 'a failed post-naming verification read leaked the just-set workspace name'
grep -qx 'set-workspace-name --session owned 2' "$SQUAD_TUIOS_LOG" || fail 'a failed post-naming verification read must clear the just-set workspace name'
unset SQUAD_TUIOS_FAKE_WORKSPACES_FAIL_ONCE SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
SQUAD_TUIOS_FAKE_WORKSPACES_FAIL=1
export SQUAD_TUIOS_FAKE_WORKSPACES_FAIL
if fm_backend_tuios_create_task owned sq-unreadable-workspaces /tmp/wt >/dev/null 2>&1; then fail 'unreadable workspace inventory must refuse before creation'; fi
[ "$(grep -c 'new-window sq-unreadable-workspaces' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'unreadable workspace inventory must not create a window'
unset SQUAD_TUIOS_FAKE_WORKSPACES_FAIL SQUAD_TUIOS_FAKE_EMPTY_WINDOWS SQUAD_TUIOS_FAKE_WINDOW_NAME
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

# --- cleanup: the native close, scoped to the recorded task window -------
TARGET=owned:w-opaque_7
: > "$SQUAD_TUIOS_LOG"
if fm_backend_tuios_kill "$TARGET" '' wrong-label >/dev/null 2>&1; then fail 'mismatched expected label must refuse cleanup'; fi
[ "$(grep -c 'run-command' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'mismatched label issued a destructive command'
: > "$SQUAD_TUIOS_LOG"
fm_backend_tuios_kill "$TARGET" '' sq-task-1 || fail 'exact task window close failed'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'run-command --session owned CloseWindow w-opaque_7 --json' 'cleanup did not use the native close for the exact session and window id'
[ "$(grep -c 'tmux ' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'cleanup must never go through the tmux compatibility shim'
[ "$(grep -c 'kill-session\|kill-server' "$SQUAD_TUIOS_LOG" || true)" -eq 0 ] || fail 'cleanup must never delete a session or the daemon'

# A close the daemon refused must fail loudly with the daemon's own message.
SQUAD_TUIOS_FAKE_CLOSE_ENVELOPE=fail SQUAD_TUIOS_FAKE_CLOSE_MESSAGE='no window found matching w-opaque_7'
export SQUAD_TUIOS_FAKE_CLOSE_ENVELOPE SQUAD_TUIOS_FAKE_CLOSE_MESSAGE
if fm_backend_tuios_kill "$TARGET" '' sq-task-1 2>"$TMP_ROOT/close-err"; then
  fail 'a refused close envelope must not report success'
fi
assert_contains "$(cat "$TMP_ROOT/close-err")" 'no window found matching w-opaque_7' 'a refused close must surface the daemon message'
unset SQUAD_TUIOS_FAKE_CLOSE_ENVELOPE SQUAD_TUIOS_FAKE_CLOSE_MESSAGE

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
tuios_boot_id=boot-a
EOF
fm_backend_validate_task_endpoint "$meta" task-1 || fail 'valid bound endpoint metadata should pass'
if fm_backend_validate_task_endpoint "$meta" other-task >/dev/null 2>&1; then fail 'mismatched task binding must refuse'; fi

# --- backend-neutral transition producer: level-reconcile / poll path --------
# fm_backend_tuios_poll_transition is the level-reconcile counterpart to
# herdr's event-wait producer (bin/sq-transition-lib.sh, bin/backends/herdr.sh):
# TUIOS has no event stream (no subscribe/after_seq verb), so it produces the
# SAME normalized record on the sentry's ordinary poll instead. These
# assertions exercise it directly, through the same fake daemon used above.
TRANSITION_STATE="$TMP_ROOT/transition-state"
mkdir -p "$TRANSITION_STATE"
TWINDOW=owned:w-opaque_7
ESC_MARKER=$(fm_backend_tuios_escalation_marker "$TRANSITION_STATE" "$TWINDOW")
HASH_MARKER=$(fm_backend_tuios_prompt_hash_marker "$TRANSITION_STATE" "$TWINDOW")

# Not blocked (working): defers to the existing poll machinery (rc=2), prints
# no record, and clears any stale dedupe markers left behind.
: > "$ESC_MARKER"; : > "$HASH_MARKER"
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"working","harness_id":"pi","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
[ "$RC" -eq 2 ] || fail "a working pane must defer (rc=2), got rc=$RC out=$OUT"
[ -z "$OUT" ] || fail "a working pane must print no record: $OUT"
[ ! -e "$ESC_MARKER" ] || fail 'a working read must clear the escalation marker'
[ ! -e "$HASH_MARKER" ] || fail 'a working read must clear the prompt-hash marker'
unset SQUAD_TUIOS_FAKE_AGENTS

# An ambiguous native read with no prior escalation is not known blocked: it
# must fall back to the ordinary poll machinery (rc=2), never take the
# skip-stale shortcut.
SQUAD_TUIOS_FAKE_LIST_FAIL=1
SQUAD_TUIOS_FAKE_AGENTS=
export SQUAD_TUIOS_FAKE_LIST_FAIL SQUAD_TUIOS_FAKE_AGENTS
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
unset SQUAD_TUIOS_FAKE_LIST_FAIL SQUAD_TUIOS_FAKE_AGENTS
[ "$RC" -eq 2 ] || fail "an ambiguous read with no prior escalation must fall back (rc=2), got rc=$RC out=$OUT"
[ -z "$OUT" ] || fail "an ambiguous read with no prior escalation must print no record: $OUT"

# Blocked, first sighting: a fresh actionable record (rc=0). The dedupe marker
# is NOT set until the caller commits it, mirroring herdr's own contract
# (apply decides, the caller commits only after it has handled the wake).
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"approval"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='trust this directory?'
export SQUAD_TUIOS_FAKE_PROMPT_MESSAGE
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
[ "$RC" -eq 0 ] || fail "first sighting of a blocked prompt must be actionable (rc=0), got rc=$RC"
[ "$(fm_transition_pane_id "$OUT")" = w-opaque_7 ] || fail "the record must name the pane: $OUT"
[ "$(fm_transition_to_status "$OUT")" = blocked ] || fail "the record's to_status must be blocked: $OUT"
[ ! -e "$ESC_MARKER" ] || fail 'the escalation marker must not be set before the caller commits'
fm_backend_tuios_commit_transition "$TRANSITION_STATE" owned "$OUT"
[ -e "$ESC_MARKER" ] || fail 'commit_transition did not record the escalation marker'

# The same standing prompt: no fresh edge (rc=1), no record - exactly once per
# distinct pending prompt, no repetition while it stands.
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
[ "$RC" -eq 1 ] || fail "an unchanged standing prompt must not re-escalate (rc=1), got rc=$RC out=$OUT"
[ -z "$OUT" ] || fail "an unchanged standing prompt must print no record: $OUT"

# A transient unreadable native read (list-windows fails -> the adapter's
# ambiguous `unknown` verdict) must NOT clear the dedupe markers: the same
# prompt is still standing, so treating `unknown` as "no longer waiting" would
# re-wake on the identical prompt. The next readable poll still dedupes.
[ -e "$ESC_MARKER" ] || fail 'setup: escalation marker should exist before the ambiguous-read check'
[ -e "$HASH_MARKER" ] || fail 'setup: prompt-hash marker should exist before the ambiguous-read check'
SQUAD_TUIOS_FAKE_LIST_FAIL=1
export SQUAD_TUIOS_FAKE_LIST_FAIL
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
unset SQUAD_TUIOS_FAKE_LIST_FAIL
[ "$RC" -eq 3 ] || fail "an unreadable native read over a previously escalated pane must skip stale (rc=3), got rc=$RC out=$OUT"
[ -z "$OUT" ] || fail "an unreadable native read must print no record: $OUT"
[ -e "$ESC_MARKER" ] || fail 'an ambiguous read must not clear the escalation marker'
[ -e "$HASH_MARKER" ] || fail 'an ambiguous read must not clear the prompt-hash marker'
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
[ "$RC" -eq 1 ] || fail "the same prompt must still dedupe after an ambiguous read (rc=1), got rc=$RC out=$OUT"

# The prompt READ itself can also come back unreadable while the status is
# still positively blocked. That is an ambiguous read for the dedupe key too:
# the markers stand and the same standing prompt does not re-fire. First the
# prompt verb read fails outright, then the daemon answers as blocked but with
# `.found:false`.
SQUAD_TUIOS_FAKE_PROMPT_STATE=unblocked
export SQUAD_TUIOS_FAKE_PROMPT_STATE
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
unset SQUAD_TUIOS_FAKE_PROMPT_STATE
[ "$RC" -eq 1 ] || fail "a failed prompt read must dedupe (rc=1), got rc=$RC out=$OUT"
[ -z "$OUT" ] || fail "a failed prompt read must print no record: $OUT"
[ -e "$ESC_MARKER" ] || fail 'a failed prompt read must not clear the escalation marker'
[ -e "$HASH_MARKER" ] || fail 'a failed prompt read must not clear the prompt-hash marker'
SQUAD_TUIOS_FAKE_PROMPT_FOUND=0
export SQUAD_TUIOS_FAKE_PROMPT_FOUND
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
unset SQUAD_TUIOS_FAKE_PROMPT_FOUND
[ "$RC" -eq 1 ] || fail "an unreadable (found=false) prompt must dedupe (rc=1), got rc=$RC out=$OUT"
[ -e "$ESC_MARKER" ] || fail 'a found=false prompt read must not clear the escalation marker'
[ -e "$HASH_MARKER" ] || fail 'a found=false prompt read must not clear the prompt-hash marker'

# A later poll that merely surfaces the numbered options for the SAME prompt is
# not a changed prompt: the identity hash excludes the options rendering.
SQUAD_TUIOS_FAKE_PROMPT_OPTIONS=$(printf '%s' '["Allow once","Always allow"]')
export SQUAD_TUIOS_FAKE_PROMPT_OPTIONS
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
unset SQUAD_TUIOS_FAKE_PROMPT_OPTIONS
[ "$RC" -eq 1 ] || fail "the same prompt with newly-read options must not re-escalate (rc=1), got rc=$RC out=$OUT"
[ -z "$OUT" ] || fail "the same prompt with newly-read options must print no record: $OUT"

# A changed prompt while STILL blocked (no intervening non-blocked read): a
# fresh edge again (rc=0) - the prompt content, not just the status, drives
# the dedupe key.
SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='allow network access?'
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
[ "$RC" -eq 0 ] || fail "a changed prompt while still blocked must re-escalate (rc=0), got rc=$RC"
fm_backend_tuios_commit_transition "$TRANSITION_STATE" owned "$OUT"

# Unblocked, then re-blocked with the ORIGINAL (byte-identical) prompt text:
# unblocking must clear both markers, so the identical prompt re-escalates.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"working","harness_id":"pi","confidence":"certain"}]}')
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
[ "$RC" -eq 2 ] || fail "an unblocked pane must defer (rc=2), got rc=$RC"
[ ! -e "$ESC_MARKER" ] || fail 'unblocking did not clear the escalation marker'
[ ! -e "$HASH_MARKER" ] || fail 'unblocking did not clear the prompt-hash marker'
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"approval"}]}')
SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='trust this directory?'
OUT=$(fm_backend_tuios_poll_transition "$TRANSITION_STATE" owned "$TWINDOW"); RC=$?
[ "$RC" -eq 0 ] || fail "a byte-identical prompt must re-escalate after an intervening unblock (rc=0), got rc=$RC"
fm_backend_tuios_commit_transition "$TRANSITION_STATE" owned "$OUT"
unset SQUAD_TUIOS_FAKE_AGENTS SQUAD_TUIOS_FAKE_PROMPT_MESSAGE

# clear_transition (the teardown path) removes both markers unconditionally.
[ -e "$ESC_MARKER" ] || fail 'setup: escalation marker should exist before the teardown cleanup check'
fm_backend_tuios_clear_transition "$TRANSITION_STATE" "$TWINDOW"
if [ -e "$ESC_MARKER" ] || [ -e "$HASH_MARKER" ]; then
  fail 'fm_backend_tuios_clear_transition did not remove both dedupe markers'
fi

pass 'TUIOS backend: the level-reconcile transition producer detects a blocked prompt, dedupes per distinct prompt, rearms after unblocking, and clear_transition removes both markers'

# Native event discovery is optional and based on the daemon's verb catalogue.
fm_backend_source tuios
fm_backend_tuios_events_capable || fail 'the catalog-listed subscribe verb should enable native TUIOS events'
SQUAD_TUIOS_FAKE_VERBS_OMIT=subscribe
export SQUAD_TUIOS_FAKE_VERBS_OMIT
if fm_backend_tuios_events_capable; then fail 'a daemon without subscribe must retain the polling fallback'; fi
unset SQUAD_TUIOS_FAKE_VERBS_OMIT
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"approval"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_EVENT=w-opaque_7
export SQUAD_TUIOS_FAKE_EVENT
OUT=$(fm_backend_tuios_wait_transition owned 2 "$TRANSITION_STATE" "$TWINDOW"); RC=$?
unset SQUAD_TUIOS_FAKE_EVENT SQUAD_TUIOS_FAKE_AGENTS
[ "$RC" -eq 0 ] || fail "a native blocked event must trigger authoritative level reconciliation (rc=$RC, out=$OUT)"
[ "$(fm_transition_to_status "$OUT")" = blocked ] || fail 'native event reconciliation must return the normalized blocked record'
pass 'TUIOS backend: catalog-gated native event wake re-reads authoritative prompt state; unsupported daemons retain polling'

# The baseline reconcile after subscribing must not be what satisfies the wait:
# the pane is idle until the consumed event line re-reads it as blocked.
EVENT_AGENTS_COUNT="$TMP_ROOT/event-agents-count"
SQUAD_TUIOS_FAKE_AGENTS_SEQ='working,needs_input'
SQUAD_TUIOS_FAKE_AGENTS_COUNT_FILE="$EVENT_AGENTS_COUNT"
SQUAD_TUIOS_FAKE_EVENT=w-opaque_7
export SQUAD_TUIOS_FAKE_AGENTS_SEQ SQUAD_TUIOS_FAKE_AGENTS_COUNT_FILE SQUAD_TUIOS_FAKE_EVENT
printf '0' > "$EVENT_AGENTS_COUNT"
OUT=$(fm_backend_tuios_wait_transition owned 2 "$TRANSITION_STATE" "$TWINDOW"); RC=$?
unset SQUAD_TUIOS_FAKE_EVENT SQUAD_TUIOS_FAKE_AGENTS_SEQ SQUAD_TUIOS_FAKE_AGENTS_COUNT_FILE
[ "$RC" -eq 0 ] || fail "an event on an idle baseline must wake the wait (rc=$RC, out=$OUT)"
[ "$(fm_transition_to_status "$OUT")" = blocked ] || fail 'the event-triggered read must return the normalized blocked record'
[ "$(cat "$EVENT_AGENTS_COUNT")" -ge 2 ] \
  || fail 'the event line must trigger its own authoritative re-read, not rely on the baseline reconcile'

# The sentry memoizes capability and exports the hint around this exact call, so
# the adapter must not spend a second catalogue round-trip on the same schema.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"needs_input","harness_id":"pi","confidence":"certain","blocked_by":"approval"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
probe_before=$(grep -c '^list-verbs --json' "$SQUAD_TUIOS_LOG" || true)
OUT=$(SQUAD_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_tuios_wait_transition owned 2 "$TRANSITION_STATE" "$TWINDOW"); RC=$?
probe_after=$(grep -c '^list-verbs --json' "$SQUAD_TUIOS_LOG" || true)
unset SQUAD_TUIOS_FAKE_AGENTS
[ "$RC" -eq 0 ] || fail "a confirmed-capability wait must still reconcile the blocked pane (rc=$RC, out=$OUT)"
[ "$probe_after" -eq "$probe_before" ] \
  || fail 'a sentry-confirmed capability hint must skip the repeated catalogue read'
pass 'TUIOS backend: the sentry-confirmed capability hint skips the repeated catalogue read'

# The reader is a bounded wait, not a one-shot: it keeps the stream open for the
# whole budget so a non-actionable event cannot remove the poll-interval floor.
tuios_bin=$(command -v tuios)
SQUAD_TUIOS_FAKE_EVENT=w-opaque_7
export SQUAD_TUIOS_FAKE_EVENT
started_ms=$(python3 -c 'import time; print(int(time.monotonic() * 1000))')
reader_out=$(python3 "$ROOT/bin/backends/tuios-eventwait.py" "$tuios_bin" owned 1 w-opaque_7 2>/dev/null)
reader_rc=$?
elapsed_ms=$(( $(python3 -c 'import time; print(int(time.monotonic() * 1000))') - started_ms ))
unset SQUAD_TUIOS_FAKE_EVENT
[ "$reader_rc" -eq 0 ] || fail "a matching event must not end the reader's budget (rc=$reader_rc)"
assert_contains "$reader_out" "$(printf 'w-opaque_7\tevent')" 'the reader must project the matching event line'
[ "$elapsed_ms" -ge 900 ] || fail "the reader must consume its whole budget instead of returning on the first event (elapsed=${elapsed_ms}ms)"

# SIGTERM is how the caller stops a reader that found its edge, and it must take
# the subscription child with it: a leaked `tuios subscribe` holds a daemon
# connection until its next event.
SUB_PID_FILE="$TMP_ROOT/eventwait-subscribe.pid"
SQUAD_TUIOS_FAKE_SUBSCRIBE_PID_FILE="$SUB_PID_FILE"
SQUAD_TUIOS_FAKE_SUBSCRIBE_SLEEP=60
export SQUAD_TUIOS_FAKE_SUBSCRIBE_PID_FILE SQUAD_TUIOS_FAKE_SUBSCRIBE_SLEEP
rm -f "$SUB_PID_FILE"
python3 "$ROOT/bin/backends/tuios-eventwait.py" "$tuios_bin" owned 60 w-opaque_7 >/dev/null 2>&1 &
reader_pid=$!
expected_child=0
while [ "$expected_child" -lt 300 ] && [ ! -s "$SUB_PID_FILE" ]; do
  sleep 0.01
  expected_child=$((expected_child + 1))
done
child_pid=$(cat "$SUB_PID_FILE" 2>/dev/null || true)
[ -n "$child_pid" ] || { kill "$reader_pid" 2>/dev/null || true; fail 'the subscription child never started'; }
kill -TERM "$reader_pid" 2>/dev/null || true
wait "$reader_pid" 2>/dev/null || true
child_gone=0
checks=0
while [ "$checks" -lt 200 ]; do
  if ! kill -0 "$child_pid" 2>/dev/null; then child_gone=1; break; fi
  sleep 0.01
  checks=$((checks + 1))
done
if [ "$child_gone" != 1 ]; then
  kill -9 "$child_pid" 2>/dev/null || true
  unset SQUAD_TUIOS_FAKE_SUBSCRIBE_PID_FILE SQUAD_TUIOS_FAKE_SUBSCRIBE_SLEEP
  fail 'SIGTERM must terminate the subscription child instead of orphaning it'
fi
unset SQUAD_TUIOS_FAKE_SUBSCRIBE_PID_FILE SQUAD_TUIOS_FAKE_SUBSCRIBE_SLEEP
pass 'TUIOS backend: the native event reader keeps its full budget and terminates its subscription on SIGTERM'

# The answer path requires the exact current prompt id and action, then invokes
# TUIOS's one-shot respond verb; a changed prompt is refused before any write.
SQUAD_TUIOS_FAKE_PROMPT_ID=prompt-alpha
export SQUAD_TUIOS_FAKE_PROMPT_ID
OUT=$(fm_backend_tuios_respond owned:w-opaque_7 approve prompt-alpha); RC=$?
[ "$RC" -eq 0 ] || fail "a current supported prompt should answer through TUIOS respond (rc=$RC, out=$OUT)"
assert_contains "$OUT" '"prompt_id":"prompt-alpha"' 'the response confirmation must identify the prompt answered'
assert_contains "$(cat "$SQUAD_TUIOS_LOG")" 'respond --json --session owned --window w-opaque_7 --prompt-id prompt-alpha approve' \
  'the exact answer must use the native prompt-id-bound verb'
SQUAD_TUIOS_FAKE_RESPOND_ID=prompt-beta
export SQUAD_TUIOS_FAKE_RESPOND_ID
err="$TMP_ROOT/respond-unconfirmed.err"
if fm_backend_tuios_respond owned:w-opaque_7 approve prompt-alpha >"$TMP_ROOT/respond-mismatch.out" 2>"$err"; then
  fail 'a response that does not confirm the exact prompt id must not report success'
fi
assert_contains "$(cat "$err")" 'did not confirm the exact prompt response' \
  'a mismatched response prompt id must be an unresolved write, not a confirmed answer'
assert_contains "$(cat "$err")" 'write is unresolved' \
  'a mismatched response prompt id must remain unresolved'
assert_contains "$(cat "$err")" 'do not retry' \
  'an unconfirmed write must never authorize a retry'
assert_not_contains "$(cat "$err")" 'before any retry' \
  'an unconfirmed write must not suggest a retry after a reconciliation read'
printf '%s' "$(cat "$TMP_ROOT/respond-mismatch.out")" | jq -e '
  .type == "tuios_prompt_recovery"
  and .reason == "unconfirmed_write_reconciliation"
  and .target == "owned:w-opaque_7"
  and .write == "unresolved"
  and .attempted_prompt_id == "prompt-alpha"
  and .attempted_action == "approve"
  and .prompt_id == "prompt-alpha"
' >/dev/null 2>&1 || fail 'an unconfirmed write must preserve the attempted answer and attach the current prompt read-only'
unset SQUAD_TUIOS_FAKE_RESPOND_ID
unset SQUAD_TUIOS_FAKE_PROMPT_ID
# The answer sends syntax parameters and reads exact-prompt returns, so a catalog
# missing any of them must refuse before the privileged verb runs.
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG" || true)
err="$TMP_ROOT/respond-capability.err"
SQUAD_TUIOS_FAKE_PARAM_OMIT=respond:window
export SQUAD_TUIOS_FAKE_PARAM_OMIT
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >/dev/null 2>"$err"; then
  fail 'a daemon that does not advertise the respond window parameter must refuse'
fi
assert_contains "$(cat "$err")" 'nothing was answered' 'a missing respond capability must be stated as a known no-op'
unset SQUAD_TUIOS_FAKE_PARAM_OMIT
SQUAD_TUIOS_FAKE_RETURN_OMIT=respond:settled_by
export SQUAD_TUIOS_FAKE_RETURN_OMIT
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >/dev/null 2>"$err"; then
  fail 'a daemon that does not advertise the respond settled_by return must refuse'
fi
assert_contains "$(cat "$err")" 'nothing was answered' 'an unadvertised respond return must be stated as a known no-op'
unset SQUAD_TUIOS_FAKE_RETURN_OMIT
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$respond_count" ] \
  || fail 'an incomplete respond capability must not invoke TUIOS respond'
# A successful answer may still write a diagnostic out of band; the envelope on
# stdout is what decides whether the exact prompt was answered.
SQUAD_TUIOS_FAKE_RESPOND_STDERR='daemon note about this successful answer'
export SQUAD_TUIOS_FAKE_RESPOND_STDERR
OUT=$(fm_backend_tuios_respond owned:w-opaque_7 approve p1 2>"$err") \
  || fail 'a diagnostic on stderr must not turn a confirmed answer into an uncertain outcome'
assert_contains "$OUT" '"settled_by":"state"' 'a confirmed answer must stay confirmed with a stderr diagnostic'
assert_contains "$(cat "$err")" 'daemon note about this successful answer' 'the out-of-band diagnostic must still be surfaced'
unset SQUAD_TUIOS_FAKE_RESPOND_STDERR
SQUAD_TUIOS_FAKE_PROMPT_OPTIONS=$(printf '%s' '[{"n":2,"label":"first"},{"n":5,"label":"second"}]')
export SQUAD_TUIOS_FAKE_PROMPT_OPTIONS
for action in approve deny choose text; do
  case "$action" in choose) value=5 ;; text) value=answer ;; *) value= ;; esac
  snapshot=$(SQUAD_TUIOS_FAKE_PROMPT_ID=prompt-beta fm_backend_tuios_respond owned:w-opaque_7 "$action" wrong-id "$value" 2>/dev/null) &&
    fail "a stale $action decision must refuse"
  printf '%s' "$snapshot" | jq -e --arg action "$action" '
    .type == "tuios_prompt_recovery"
    and .reason == "stale_decision"
    and .target == "owned:w-opaque_7"
    and .prompt_id == "prompt-beta"
    and .attempted_prompt_id == "wrong-id"
    and .attempted_action == $action
    and (.actions | index($action) != null)
    and (.options | map(.n) == [2,5])
    and (.prompt.prompt_id == "prompt-beta")
  ' >/dev/null 2>&1 || fail "a stale $action decision must return the full current prompt context"
  if [ -n "$value" ]; then
    printf '%s' "$snapshot" | jq -e --arg value "$value" '.attempted_value == $value' >/dev/null 2>&1 \
      || fail "a stale $action decision must preserve the attempted value"
  else
    printf '%s' "$snapshot" | jq -e '.attempted_value == null' >/dev/null 2>&1 \
      || fail "a stale $action decision must not invent an attempted value"
  fi
done
assert_not_contains "$(tail -n 1 "$SQUAD_TUIOS_LOG")" 'respond ' 'a changed prompt must not invoke TUIOS respond'
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG" || true)
if fm_backend_tuios_respond owned:w-opaque_7 choose p1 1 >/dev/null 2>&1; then
  fail 'a number the prompt does not display must refuse even when it is within the option count'
fi
if fm_backend_tuios_respond owned:w-opaque_7 choose p1 3 >/dev/null 2>&1; then
  fail 'a choice outside the currently displayed option numbers must refuse'
fi
if fm_backend_tuios_respond owned:w-opaque_7 approve_always p1 >/dev/null 2>&1; then
  fail 'persistent approval must not be automated'
fi
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 1 >/dev/null 2>"$err"; then
  fail 'an action that takes no value must refuse a forwarded value'
fi
assert_contains "$(cat "$err")" 'takes no value' 'a value on a valueless action must be a known no-op'
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$respond_count" ] \
  || fail 'an invalid option or persistent approval must not invoke TUIOS respond'
# A prompt read that carries no actions array, or lacks the requested action, is
# refused before the privileged verb rather than guessed at.
SQUAD_TUIOS_FAKE_PROMPT_NO_ACTIONS=1
export SQUAD_TUIOS_FAKE_PROMPT_NO_ACTIONS
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >/dev/null 2>"$err"; then
  fail 'a prompt read with no actions array must refuse instead of guessing'
fi
assert_contains "$(cat "$err")" "does not accept action 'approve'" 'a prompt with no actions array must be a known no-op'
unset SQUAD_TUIOS_FAKE_PROMPT_NO_ACTIONS
SQUAD_TUIOS_FAKE_PROMPT_ACTIONS=$(printf '%s' '["approve"]')
export SQUAD_TUIOS_FAKE_PROMPT_ACTIONS
if fm_backend_tuios_respond owned:w-opaque_7 deny p1 >/dev/null 2>"$err"; then
  fail 'an action absent from a present actions list must refuse'
fi
assert_contains "$(cat "$err")" "does not accept action 'deny'" 'an action absent from the actions list must be a known no-op'
unset SQUAD_TUIOS_FAKE_PROMPT_ACTIONS
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$respond_count" ] \
  || fail 'an unaccepted action must not invoke TUIOS respond'
OUT=$(fm_backend_tuios_respond owned:w-opaque_7 choose p1 5) || fail 'a displayed option number should be accepted'
assert_contains "$(tail -n 1 "$SQUAD_TUIOS_LOG")" 'respond --json --session owned --window w-opaque_7 --prompt-id p1 choose -- 5' \
  'a choice must preserve the exact displayed option number and prompt id'
OUT=$(fm_backend_tuios_respond owned:w-opaque_7 text p1 '-not-a-flag') \
  || fail 'a free-text answer that begins with a dash must still be answerable'
assert_contains "$(tail -n 1 "$SQUAD_TUIOS_LOG")" 'respond --json --session owned --window w-opaque_7 --prompt-id p1 text -- -not-a-flag' \
  'a caller-supplied answer must be passed after -- so it is never parsed as a flag'
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
SQUAD_TUIOS_FAKE_RESPOND_FAIL=1
export SQUAD_TUIOS_FAKE_RESPOND_FAIL
err="$TMP_ROOT/respond-uncertain.err"
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >"$TMP_ROOT/respond-uncertain.out" 2>"$err"; then
  fail 'an uncertain native response must not report success'
fi
assert_contains "$(cat "$err")" 'outcome is unresolved' \
  'an unrecognized refusal must stay unresolved, never a known no-op'
assert_contains "$(cat "$err")" 'do not retry' \
  'a read-only reconciliation must not authorize resending'
printf '%s' "$(cat "$TMP_ROOT/respond-uncertain.out")" | jq -e '
  .type == "tuios_prompt_recovery"
  and .reason == "unconfirmed_write_reconciliation"
  and .target == "owned:w-opaque_7"
  and .write == "unresolved"
  and .attempted_prompt_id == "p1"
  and .attempted_action == "approve"
  and .prompt_id == "p1"
  and (.diagnostic | contains("simulated response refusal"))
' >/dev/null 2>&1 || fail 'an unconfirmed write must return its read-only reconciliation separately from the send result'
unset SQUAD_TUIOS_FAKE_RESPOND_FAIL
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'an uncertain native response must invoke respond exactly once'
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
SQUAD_TUIOS_FAKE_RESPOND_FAIL=1 SQUAD_TUIOS_FAKE_RESPOND_ERROR=risk_unacknowledged
export SQUAD_TUIOS_FAKE_RESPOND_FAIL SQUAD_TUIOS_FAKE_RESPOND_ERROR
err="$TMP_ROOT/respond-risk.err"
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >/dev/null 2>"$err"; then fail 'risk-matched approval without explicit acknowledgement must refuse'; fi
assert_contains "$(cat "$err")" 'nothing was answered' 'a risk refusal must be stated as a known no-op'
assert_not_contains "$(cat "$err")" 'outcome may be uncertain' 'risk refusal must not be misreported as uncertain'
unset SQUAD_TUIOS_FAKE_RESPOND_FAIL SQUAD_TUIOS_FAKE_RESPOND_ERROR
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a risk refusal must invoke the provider exactly once and must not be retried'

# The installed CLI renders these refusals as prose in `.error` and never prints
# the machine code token, so the live sentences below are the only signal.
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
err="$TMP_ROOT/respond-prose.err"
SQUAD_TUIOS_FAKE_RESPOND_PROSE='respond failed: respond pressed nothing: the pane is not on needs_input, no rule reads its prompt now, the prompt is not the one prompt_id names, or another client already answered it. Read it again with peek-prompt.'
export SQUAD_TUIOS_FAKE_RESPOND_PROSE
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >"$TMP_ROOT/respond-prose.out" 2>"$err"; then
  fail 'a prose prompt-changed refusal must not report success'
fi
assert_contains "$(cat "$err")" 'nothing was answered' 'a prose prompt-changed refusal must be stated as a known no-op'
assert_not_contains "$(cat "$err")" 'outcome may be uncertain' 'a prose prompt-changed refusal must not be misreported as uncertain'
printf '%s' "$(cat "$TMP_ROOT/respond-prose.out")" | jq -e '
  .type == "tuios_prompt_recovery"
  and .reason == "changed_prompt_refusal"
  and .target == "owned:w-opaque_7"
  and .prompt_id == "p1"
  and .attempted_prompt_id == "p1"
  and .attempted_action == "approve"
  and .attempted_value == null
  and (.actions | index("approve") != null)
  and (.options | map(.n) == [2,5])
  and (.prompt.prompt_id == "p1")
' >/dev/null 2>&1 || fail 'a changed-prompt refusal must return the current prompt and the attempted answer'
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a prose prompt-changed refusal must invoke the provider exactly once'
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
SQUAD_TUIOS_FAKE_RESPOND_MARK="$TMP_ROOT/respond-mark"
SQUAD_TUIOS_FAKE_PROMPT_STATE_AFTER_RESPOND=unblocked
export SQUAD_TUIOS_FAKE_RESPOND_MARK SQUAD_TUIOS_FAKE_PROMPT_STATE_AFTER_RESPOND
rm -f "$SQUAD_TUIOS_FAKE_RESPOND_MARK"
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >"$TMP_ROOT/respond-prose-unblocked.out" 2>"$err"; then
  fail 'a changed prompt that cleared must still be reported as a known no-op'
fi
printf '%s' "$(cat "$TMP_ROOT/respond-prose-unblocked.out")" | jq -e '
  .type == "tuios_prompt_recovery"
  and .reason == "changed_prompt_refusal"
  and .target == "owned:w-opaque_7"
  and .read == "not_blocked"
  and .blocked == false
  and .attempted_prompt_id == "p1"
  and .attempted_action == "approve"
' >/dev/null 2>&1 || fail 'a changed-prompt recovery read that finds no blocked prompt must say so explicitly'
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a cleared changed prompt must invoke the provider exactly once'
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
SQUAD_TUIOS_FAKE_PROMPT_STATE_AFTER_RESPOND=fail
export SQUAD_TUIOS_FAKE_PROMPT_STATE_AFTER_RESPOND
rm -f "$SQUAD_TUIOS_FAKE_RESPOND_MARK"
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >"$TMP_ROOT/respond-prose-readfail.out" 2>"$err"; then
  fail 'a changed prompt whose recovery read fails must still be a known no-op'
fi
printf '%s' "$(cat "$TMP_ROOT/respond-prose-readfail.out")" | jq -e '
  .type == "tuios_prompt_recovery"
  and .reason == "changed_prompt_refusal"
  and .target == "owned:w-opaque_7"
  and .read == "failed"
  and .blocked == null
  and .attempted_prompt_id == "p1"
  and .attempted_action == "approve"
' >/dev/null 2>&1 || fail 'a failed changed-prompt recovery read must be reported explicitly'
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a failed changed-prompt recovery read must invoke the provider exactly once'
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
weird_target='owned:w"q\b'
rm -f "$SQUAD_TUIOS_FAKE_RESPOND_MARK"
if fm_backend_tuios_respond "$weird_target" approve p1 >"$TMP_ROOT/respond-prose-quoted.out" 2>"$err"; then
  fail 'a quoted target must still be a known no-op after a changed-prompt refusal'
fi
printf '%s' "$(cat "$TMP_ROOT/respond-prose-quoted.out")" | jq -e --arg target "$weird_target" '
  .type == "tuios_prompt_recovery"
  and .target == $target
  and .read == "failed"
' >/dev/null 2>&1 || fail 'a recovery payload must escape a target that contains JSON metacharacters'
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a quoted target must invoke the provider exactly once'
unset SQUAD_TUIOS_FAKE_RESPOND_MARK SQUAD_TUIOS_FAKE_PROMPT_STATE_AFTER_RESPOND
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
unset SQUAD_TUIOS_FAKE_PROMPT_ID
SQUAD_TUIOS_FAKE_RESPOND_PROSE='An allow for an approval that matches a risk rule was refused because risk_ack did not name exactly the rules it matched. Nothing was answered. Read the rules with get-approval, or answer in the pane.'
export SQUAD_TUIOS_FAKE_RESPOND_PROSE
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >/dev/null 2>"$err"; then
  fail 'a prose risk refusal must not report success'
fi
assert_contains "$(cat "$err")" 'no risk acknowledgement was inferred' 'a prose risk refusal must be stated as a known no-op'
assert_not_contains "$(cat "$err")" 'outcome may be uncertain' 'a prose risk refusal must not be misreported as uncertain'
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a prose risk refusal must invoke the provider exactly once'
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
SQUAD_TUIOS_FAKE_RESPOND_PROSE='respond failed: respond is for the person at an attached client. Only the person may call it: a client attached right now passing its attach nonce, or a pane the person gave the respond grant may also call it.
Most likely cause: this pane holds admin. The person can give this pane more with tuios set-pane-grants -w w-supervisor --grants respond.'
export SQUAD_TUIOS_FAKE_RESPOND_PROSE
TUIOS_SESSION=owned TUIOS_PANE_ID=w-supervisor \
  fm_backend_tuios_respond owned:w-opaque_7 approve p1 >/dev/null 2>"$err" \
  && fail 'a prose caller refusal must not report success'
assert_contains "$(cat "$err")" 'respond grant' 'a prose caller refusal must name the sanctioned grant remedy'
assert_not_contains "$(cat "$err")" 'set-pane-grants' \
  'a caller refusal must not forward the provider advice naming the raw grant verb'
assert_not_contains "$(cat "$err")" 'outcome may be uncertain' 'a caller refusal must not be misreported as uncertain'
[ "${SQUAD_BACKEND_PANE_GRANT_TARGET:-}" = 'owned:w-supervisor' ] \
  || fail 'a caller refusal must name the pane that needs the respond grant'
unset SQUAD_TUIOS_FAKE_RESPOND_PROSE SQUAD_BACKEND_PANE_GRANT_TARGET
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a prose caller refusal must invoke the provider exactly once'
unset SQUAD_TUIOS_FAKE_PROMPT_OPTIONS
pass 'TUIOS backend: prompt id, displayed option numbers, safety refusals, and uncertain outcomes are explicit'

# The answer's own settled outcome is not always the pane leaving the prompt: a
# closed window is a confident end state, and only a timeout stays uncertain.
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
err="$TMP_ROOT/respond-gone.err"
SQUAD_TUIOS_FAKE_SETTLED=gone
export SQUAD_TUIOS_FAKE_SETTLED
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >"$TMP_ROOT/respond-gone.out" 2>"$err"; then
  fail 'a closed window after the answer must not be reported as a settled prompt'
fi
assert_contains "$(cat "$err")" 'window closed' 'a closed operator window must be named as its own settled outcome'
assert_not_contains "$(cat "$err")" 'outcome may be uncertain' 'a closed window must not be misreported as uncertain'
assert_contains "$(cat "$TMP_ROOT/respond-gone.out")" '"settled_by":"gone"' 'the confirmed answer must still be reported'
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a closed window must invoke respond exactly once and must not be retried'
respond_count=$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")
SQUAD_TUIOS_FAKE_SETTLED=timeout
export SQUAD_TUIOS_FAKE_SETTLED
if fm_backend_tuios_respond owned:w-opaque_7 approve p1 >"$TMP_ROOT/respond-timeout.out" 2>"$err"; then
  fail 'a timed-out wait must not be reported as a settled prompt'
fi
assert_contains "$(cat "$err")" 'exact answer was confirmed' 'a timed-out wait must keep the confirmed answer'
assert_contains "$(cat "$err")" 'settlement outcome may be uncertain' 'a timed-out wait must keep the uncertain settlement wording'
printf '%s' "$(cat "$TMP_ROOT/respond-timeout.out")" | jq -e '
  .success == true and .prompt_id == "p1" and .settled_by == "timeout"
' >/dev/null 2>&1 || fail 'an uncertain settlement must still report the confirmed exact-id answer'
unset SQUAD_TUIOS_FAKE_SETTLED
[ "$(grep -c '^respond ' "$SQUAD_TUIOS_LOG")" -eq "$((respond_count + 1))" ] \
  || fail 'a timed-out wait must invoke respond exactly once and must not be retried'
pass 'TUIOS backend: a settled answer distinguishes the cleared prompt, a new prompt, a closed window, and a timeout'

# Exercise the public send command from task metadata, not just the sourced
# adapter: selectors must be tied to the recorded TUIOS session and window.
SEND_HOME="$TMP_ROOT/respond-home"
mkdir -p "$SEND_HOME/state"
fm_write_meta "$SEND_HOME/state/respond-task.meta" \
  'backend=tuios' 'kind=strike' 'window=owned:w-opaque_7' \
  'tuios_session=owned' 'tuios_window_id=w-opaque_7'
SQUAD_TUIOS_LOG="$TMP_ROOT/sq-send-respond.log"
export SQUAD_TUIOS_LOG
: > "$SQUAD_TUIOS_LOG"
SQUAD_BASE="$SEND_HOME" SQUAD_BACKEND=tuios SQUAD_TUIOS_SESSION=owned \
  SQUAD_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/sq-send.sh" respond-task --respond approve p1 >/dev/null \
  || fail 'sq-send should resolve task metadata and answer the exact TUIOS prompt'
[ "$(grep -c '^respond --json ' "$SQUAD_TUIOS_LOG")" -eq 1 ] \
  || fail 'sq-send must invoke native respond exactly once'
pass 'sq-send: recorded task id routes a prompt-bound response to its TUIOS window'

# The no-attributed-agent refusal is a no-op, not an ambiguous send: sq-send
# must say nothing was typed so no caller re-sends into that terminal.
: > "$SQUAD_TUIOS_LOG"
err="$TMP_ROOT/sq-send-no-agent.err"
if SQUAD_BASE="$SEND_HOME" SQUAD_BACKEND=tuios SQUAD_TUIOS_SESSION=owned \
  SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-respond-task \
  SQUAD_TUIOS_FAKE_QUEUE_FAIL=1 \
  SQUAD_TUIOS_FAKE_QUEUE_ERROR='queue-prompt failed: window w-opaque_7 runs no agent tuios knows of, so nothing would take a queued prompt.' \
  "$ROOT/bin/sq-send.sh" respond-task 'pick up the next unit' >/dev/null 2>"$err"; then
  fail 'a no-attributed-agent refusal must not report a delivered steer'
fi
assert_contains "$(cat "$err")" 'nothing was typed' 'a no-attributed-agent refusal must be reported as nothing typed'
assert_not_contains "$(cat "$err")" 'delivery unconfirmed' 'a no-attributed-agent refusal must not be reported as an unconfirmed send'
if grep -qE '^(send-text|send-keys) ' "$SQUAD_TUIOS_LOG"; then
  fail 'a no-attributed-agent refusal must not type into the pane'
fi
pass 'sq-send: a no-attributed-agent refusal reports nothing typed and types nothing'

# --- composer state ---------------------------------------------------------
# The composer is read from the pane: a bordered box whose rows are all blank is
# empty, any content is pending, and anything not provably a composer box at the
# bottom of the pane is unknown. The real Pi frame (rounded box, no prompt glyph,
# a two-row footer) is the shape that previously read `unknown` and wedged
# away-mode delivery for hours.
composer_of() {  # <capture-text> -> verdict
  SQUAD_TUIOS_FAKE_CAPTURE=$1 fm_backend_tuios_composer_state owned:w-opaque_7
}
PI_RULE='────────────────────────────────────────────────'
PI_BLANK='                                                '
pi_frame() {  # <row>... -> a Pi frame around the given composer rows, plus footer
  local row
  printf '%s\n' ' ⠏ Working' '' "╭${PI_RULE}╮"
  for row in "$@"; do printf '│ %-46s │\n' "$row"; done
  printf '%s\n' "╰${PI_RULE}╯" ' /home/user · main · 67% left' ' model · thinking: high'
}
[ "$(composer_of "$(pi_frame '')")" = empty ] || fail 'an empty Pi composer box must read empty'
# An empty frame alone is not proof the pane is writable: the daemon must also
# attribute a live agent to it. A crashed Pi can leave its last composer frame
# on screen with a shell prompt underneath, and that pane must never authorize
# the raw typing fallback.
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"","state":"done","harness_id":"pi","source":"report","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(composer_of "$(pi_frame '')")" = unknown ] || fail 'an empty frame on a dead agent must read unknown, never empty'
unset SQUAD_TUIOS_FAKE_AGENTS
SQUAD_TUIOS_FAKE_MISSING=1
export SQUAD_TUIOS_FAKE_MISSING
[ "$(composer_of "$(pi_frame '')")" = unknown ] || fail 'an empty frame with no attributed agent must read unknown, never empty'
unset SQUAD_TUIOS_FAKE_MISSING
SQUAD_TUIOS_FAKE_AGENTS=$(printf '%s' '{"agents":[{"id":"w-opaque_7","foreground":"pi","state":"working","harness_id":"pi","source":"report","confidence":"certain"}]}')
export SQUAD_TUIOS_FAKE_AGENTS
[ "$(composer_of "$(pi_frame '')")" = empty ] || fail 'an empty frame with a live attributed agent must read empty'
unset SQUAD_TUIOS_FAKE_AGENTS
[ "$(composer_of "$(pi_frame 'half typed')")" = pending ] || fail 'a typed draft must read pending'
[ "$(composer_of "$(pi_frame '' 'second line only' '')")" = pending ] \
  || fail 'a multi-line draft whose last line is blank must still read pending'
[ "$(composer_of "$(pi_frame 'first line only' '')")" = pending ] \
  || fail 'a draft above a blank last row must read pending, not empty'
[ "$(composer_of "$(pi_frame '' '')")" = empty ] || fail 'a box of only blank rows must read empty'
[ "$(composer_of "$(pi_frame '>')")" = empty ] || fail 'the bordered prompt glyph alone is an empty composer'
[ "$(composer_of "$(pi_frame '> typed')")" = pending ] || fail 'text after a bordered prompt glyph must read pending'
# Stock Pi 1.1.0 frame (captured live in the lab): a full-width rule above and
# below the editor, no side borders, blank editor row when empty.
pi_ruled() {  # <row>... -> stock Pi frame around the given editor rows, plus footer
  local row rule
  rule=$(printf '─%.0s' $(seq 1 78))
  printf '%s\n' ' ACK' '' "$rule"
  for row in "$@"; do printf '%s\n' "$row"; done
  printf '%s\n' "$rule" '/home/user/project (main)' '6.3%/8.2k (auto)                       model'
}
[ "$(composer_of "$(pi_ruled '')")" = empty ] || fail 'an empty stock Pi composer (rules only) must read empty'
[ "$(composer_of "$(pi_ruled '❯')")" = empty ] || fail 'a lone agent glyph in the stock Pi editor row is an empty composer'
[ "$(composer_of "$(pi_ruled '>')")" = unknown ] \
  || fail 'a lone shell glyph typed into the stock Pi editor row is a draft, not an empty composer'
[ "$(composer_of "$(pi_ruled '> unsent draft')")" = pending ] \
  || fail 'text after a shell glyph in the stock Pi editor row must read pending'
[ "$(composer_of "$(pi_ruled 'unsent live draft')")" = pending ] || fail 'a draft in the stock Pi composer must read pending'
[ "$(composer_of "$(pi_ruled '' 'second line')")" = pending ] || fail 'a multi-line stock Pi draft must read pending'
[ "$(composer_of "$(pi_ruled 'draft' '')")" = pending ] || fail 'a stock Pi draft above a blank row must read pending'
[ "$(composer_of "$(printf '%s\n' '────────────────' '────────────────')")" = unknown ] \
  || fail 'two adjacent rules with no editor row must read unknown'
[ "$(composer_of "$(printf '%s\n' 'a markdown rule follows' '────────────────' 'and text' 'after' 'it' 'all' 'the' 'way' 'down')")" = unknown ] \
  || fail 'a lone rule far above the bottom must read unknown'
# Claude-style square frame with the same contract.
[ "$(composer_of "$(printf '%s\n' '┌──────┐' '│ >    │' '└──────┘' '  ? for shortcuts')")" = empty ] \
  || fail 'a square-framed empty composer must read empty'

# Anything that is not provably the composer is unknown, never empty.
[ "$(composer_of 'captured output')" = unknown ] || fail 'a pane with no box must read unknown'
[ "$(composer_of "$(printf '%s\n' 'user@host ~ $ ')")" = unknown ] || fail 'a bare shell prompt must read unknown'
[ "$(composer_of "$(printf '%s\n' "╰${PI_RULE}╯" '│ x │')")" = unknown ] || fail 'rows without a top border must read unknown'
[ "$(composer_of "$(printf '%s\n' "╭${PI_RULE}╮" "╰${PI_RULE}╯")")" = unknown ] || fail 'a box with no content rows must read unknown'
# An earlier empty box in the scrollback (for example tool output) must not be
# taken for the composer once other output follows it.
[ "$(composer_of "$(printf '%s\n' "╭${PI_RULE}╮" "│ ${PI_BLANK:2}│" "╰${PI_RULE}╯" 'a' 'b' 'c' 'd' 'e' 'f')")" = unknown ] \
  || fail 'an old box far above the bottom of the pane must read unknown'
if [ "$(SQUAD_TUIOS_FAKE_SESSION_DEAD=1 fm_backend_tuios_composer_state owned:gone)" != unknown ]; then
  fail 'an unreadable capture must read unknown'
fi
unset SQUAD_TUIOS_FAKE_CAPTURE

pass 'TUIOS backend: the composer is read from its frame (boxed or ruled) - empty only when every row is blank, pending on any draft, unknown when no composer frame is proven'

pass 'TUIOS backend: fake CLI covers protocol discovery, real state/prompt mapping, the agent-aware queue verdicts, restart and finished-agent recovery, and the native close'
