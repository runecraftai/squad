#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the unit-wide
# dead-shell-vs-agent-composer rule). Owned by bin/sq-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/sq-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../sq-composer-lib.sh"

# Shared normalized-transition shape and status->action policy table
# (bin/sq-transition-lib.sh). Orca's poll producer normalizes its own vocabulary
# into that shape, so the adapter loads the library itself instead of relying on
# whichever consumer happened to source it first.
# shellcheck source=bin/sq-transition-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../sq-transition-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(orca repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  out=$(orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

# Resolve the base workspace, not the caller's inherited mission workspace.
# Refuse before mission allocation when the commander's hosting workspace is absent.
fm_backend_orca_host_workspace() {  # <base-path>
  local out id
  fm_backend_orca_tool_check || return 1
  # A fresh install has no Orca repo entry for this base yet. repo_ensure shows
  # before it adds, so an already-registered base is a no-op, and the call is best
  # effort: when registration is unnecessary or cannot run, the worktree show below
  # stays the authority that refuses a truly missing hosting workspace.
  fm_backend_orca_repo_ensure "$1" >/dev/null 2>&1 || true
  out=$(orca worktree show --worktree "path:$1" --json) || {
    echo "error: Orca hosting workspace unavailable for Squad base $1; open that workspace before spawning" >&2
    return 1
  }
  id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: Orca hosting workspace has no identity for Squad base $1" >&2
    return 1
  }
  printf '%s' "$id"
}

fm_backend_orca_terminal_create() {  # <hosting-workspace-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  # terminal create may silently return a hidden background handle. Never launch
  # a mission there: the visible tab and its exact hosting workspace are required.
  # The observed live Orca 1.4.243 create response is recorded by
  # docs/verification/runtime-backends.md#orca, which owns the evidence of record.
  # This gate requires surface, tabId, and worktreeId exactly as that response
  # carries them.
  if ! printf '%s' "$out" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const t = (d.result || {}).terminal || {};
process.exit(t.surface === "visible" && t.tabId && t.worktreeId === process.argv[1] ? 0 : 1);
' "$worktree_id"; then
    fm_backend_orca_kill "$terminal" || true
    echo "error: Orca did not create a visible mission tab in hosting workspace $worktree_id; refusing hidden launch" >&2
    return 1
  fi
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_capture_rendered() {  # <terminal-id>
  echo 'error: orca complete rendered viewport is unverified; cannot evaluate busy expiry' >&2
  return 1
}

# Orca's terminal/worker observations can expose an exact agentWait record.
# An absent field is unsupported or unobservable, never evidence of no prompt.
# ONE read serves the poll: the wait verdict, the stable prompt identity used
# for dedupe, and the prompt text this line returns to its caller. The operator
# notification is NOT taken from that read: the shared consumer asks
# fm_backend_prompt_summary at wake time, which re-reads the terminal here (as
# TUIOS also does), so the notified text can be a later observation than the
# identity the poll deduped on and may have changed or cleared by then.
# The identity deliberately covers only the source kind and the message-ish text
# - never the raw record - because any volatile per-read field (timestamp, id,
# cursor, attempt counter) would turn one standing prompt into a fresh
# escalation on every poll.
fm_backend_orca_agent_read() {  # <terminal-id> -> <verdict>\t<identity>\t<text>
  local out
  fm_backend_orca_tool_check || { printf 'unknown'; return 0; }
  out=$(orca terminal show --terminal "$1" --json 2>/dev/null) || { printf 'unknown'; return 0; }
  printf '%s' "$out" | node -e '
const fs = require("fs");
const crypto = require("crypto");
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.stdout.write("unknown"); process.exit(0); }
if (data.ok === false) { process.stdout.write("unknown"); process.exit(0); }
const r = data.result || {};
const candidates = [r.observation?.agentWait, r.agentWait, r.terminal?.agentWait];
const wait = candidates.find(v => v !== undefined);
if (wait === undefined) { process.stdout.write("unknown"); process.exit(0); }
if (wait === null || wait === false) { process.stdout.write("clear"); process.exit(0); }
const text = v => (typeof v === "string" || typeof v === "number") ? String(v) : "";
const kind = text(wait.kind);
const prompt = text(wait.question) || text(wait.prompt) || text(wait.title) || text(wait.message);
const identity = crypto.createHash("md5").update(JSON.stringify([kind, prompt])).digest("hex");
process.stdout.write(["waiting", identity, prompt].join("\t"));
'
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

fm_backend_orca_json_field() {  # <field> <json>
  local field=$1
  printf '%s' "$2" | node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) process.exit(2);
const r = data.result || {};
const term = r.terminal || {};
function scalar(v) {
  return (typeof v === "string" || typeof v === "number" || typeof v === "boolean") ? String(v) : "";
}
let v = "";
if (field === "limited") v = scalar(r.limited ?? term.limited);
if (field === "oldestCursor") v = scalar(r.oldestCursor || term.oldestCursor);
if (field === "nextCursor") v = scalar(r.nextCursor || term.nextCursor);
if (field === "latestCursor") v = scalar(r.latestCursor || term.latestCursor);
if (!v) process.exit(1);
process.stdout.write(v);
' "$field"
}

fm_backend_orca_read_text_paged() {  # <terminal-id> <limit>
  local terminal=$1 limit=${2:-200} out limited oldest cursor_out text older_text
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$limit" --json) || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok || return 1
  text=$(fm_backend_orca_json_text "$out") || return 1
  limited=$(fm_backend_orca_json_field limited "$out" 2>/dev/null || true)
  oldest=$(fm_backend_orca_json_field oldestCursor "$out" 2>/dev/null || true)
  if [ "$limited" = true ] && [ -n "$oldest" ]; then
    cursor_out=$(orca terminal read --terminal "$terminal" --cursor "$oldest" --limit "$limit" --json) || return 1
    printf '%s' "$cursor_out" | fm_backend_orca_json_ok || return 1
    older_text=$(fm_backend_orca_json_text "$cursor_out") || return 1
    text="${older_text}"$'\n'"${text}"
  fi
  printf '%s' "$text"
}

SQUAD_BACKEND_ORCA_COMPOSER_LINES=${SQUAD_BACKEND_ORCA_COMPOSER_LINES:-200}
SQUAD_BACKEND_ORCA_IDLE_RE=${SQUAD_BACKEND_ORCA_IDLE_RE:-'^Type a message\.\.\.$'}

# fm_backend_orca_composer_state: classify the composer's own bordered row as
# empty|pending|unknown. Real text stays pending, including a slash-command
# popup that closed by filling an argument-hint placeholder into the composer;
# that first Enter selected the popup item, it did not submit the command.
fm_backend_orca_composer_state() {  # <terminal-id> -> empty|pending|unknown
  local terminal=$1 cap line trimmed stripped="" found=0
  cap=$(fm_backend_orca_read_text_paged "$terminal" "$SQUAD_BACKEND_ORCA_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|') : ;;
      *) continue ;;
    esac
    stripped=$trimmed
    found=1
  done < <(printf '%s\n' "$cap")
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A row was found only by the bordered shape above, so content came from a
  # genuine composer box - delegate to the shared owner with bordered=1. A bare
  # dead-shell prompt has no bordered row and already returned 'unknown' above.
  fm_composer_classify_content 1 "$stripped" "$SQUAD_BACKEND_ORCA_IDLE_RE"
}

# --- backend-neutral blocked-agent transition (level-reconcile poll) --------
SQUAD_BACKEND_ORCA_ESCALATED_PREFIX=".orca-escalated-"
SQUAD_BACKEND_ORCA_PROMPT_HASH_PREFIX=".orca-prompt-"

fm_backend_orca_transition_marker() {  # <state-dir> <prefix> <terminal>
  local key
  key=$(printf '%s' "$3" | tr ':/.' '___')
  printf '%s/%s%s' "$1" "$2" "$key"
}

# Translate Orca's own wait vocabulary into the shared transition vocabulary
# (bin/sq-transition-lib.sh) so the shared policy table owns which action every
# verdict triggers; this adapter never re-encodes that mapping.
fm_backend_orca_normalize_status() {  # <agent-wait-verdict>
  case "$1" in
    waiting) printf 'blocked' ;;
    clear) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# One bounded line: the wait record is another program's text and must not break
# the caller's one-line state contract, so control characters are scrubbed here
# rather than by a regex inside the parser.
fm_backend_orca_prompt_summary() {  # <terminal-id>
  local snapshot verdict line
  snapshot=$(fm_backend_orca_agent_read "$1")
  verdict=${snapshot%%$'\t'*}
  [ "$verdict" = waiting ] || return 0
  line=${snapshot#*$'\t'}
  line=${line#*$'\t'}
  line=$(printf '%s' "$line" | LC_ALL=C tr '\t\r\n' '   ')
  line=$(printf '%s' "$line" | sed -E 's/  +/ /g; s/^ +//; s/ +$//')
  line=$(printf '%s' "$line" | cut -c1-300)
  [ -n "$line" ] || line='agent is waiting for human input'
  printf '%s' "$line"
}

fm_backend_orca_poll_transition() {  # <state-dir> <session> <terminal>
  local state=$1 terminal=$3 snapshot status action hash_marker esc_marker stored wait_hash record
  [ -n "$terminal" ] || return 2
  snapshot=$(fm_backend_orca_agent_read "$terminal")
  status=$(fm_backend_orca_normalize_status "${snapshot%%$'\t'*}")
  action=$(fm_transition_policy "$status")
  esc_marker=$(fm_backend_orca_transition_marker "$state" "$SQUAD_BACKEND_ORCA_ESCALATED_PREFIX" "$terminal")
  hash_marker=$(fm_backend_orca_transition_marker "$state" "$SQUAD_BACKEND_ORCA_PROMPT_HASH_PREFIX" "$terminal")
  if [ "$action" = fallback ]; then
    [ -e "$esc_marker" ] && return 3
    return 2
  fi
  if [ "$action" != actionable ]; then
    rm -f "$esc_marker" "$hash_marker"
    return 2
  fi
  wait_hash=${snapshot#*$'\t'}
  wait_hash=${wait_hash%%$'\t'*}
  if [ -z "$wait_hash" ]; then
    [ -e "$esc_marker" ] && return 3
    return 2
  fi
  stored=$(cat "$hash_marker" 2>/dev/null || true)
  [ -z "$stored" ] || [ "$stored" = "$wait_hash" ] || rm -f "$esc_marker"
  printf '%s' "$wait_hash" > "$hash_marker"
  [ ! -e "$esc_marker" ] || return 1
  record=$(fm_transition_record "$terminal" "" "" blocked "")
  printf '%s' "$record"
  return 0
}

fm_backend_orca_commit_transition() {  # <state-dir> <session> <record>
  local terminal
  terminal=$(fm_transition_pane_id "$3")
  [ -n "$terminal" ] || return 1
  : > "$(fm_backend_orca_transition_marker "$1" "$SQUAD_BACKEND_ORCA_ESCALATED_PREFIX" "$terminal")"
}

fm_backend_orca_clear_transition() {  # <state-dir> <window>
  local terminal=$2
  [ -n "$terminal" ] || return 0
  rm -f "$(fm_backend_orca_transition_marker "$1" "$SQUAD_BACKEND_ORCA_ESCALATED_PREFIX" "$terminal")" \
    "$(fm_backend_orca_transition_marker "$1" "$SQUAD_BACKEND_ORCA_PROMPT_HASH_PREFIX" "$terminal")"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then retry Enter until
# the composer row reads empty. Retries send only Enter, so a slash-command
# popup placeholder fill gets the required second Enter without duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 state
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_orca_send_key "$terminal" Enter || true
    sleep "$sleep_s"
    state=$(fm_backend_orca_composer_state "$terminal")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 0
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}

# Print the exact presence of a recorded terminal in its hosting workspace:
# present, mismatch, absent, incomplete, or unknown. absent means a complete
# inventory proved the handle is not in that workspace; incomplete means the
# inventory answered but did not cover every terminal or host, so absence from
# it is not proof on its own. unknown means the inventory could not answer, so a
# caller must fall back to an exact live observation. Handles are runtime-scoped,
# so this is how a tab that is gone from its hosting workspace is found without
# requiring a live terminal show.
fm_backend_orca_terminal_presence() {  # <hosting-workspace-id> <terminal-id>
  local worktree_id=$1 terminal=$2 out
  fm_backend_orca_tool_check >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  out=$(orca terminal list --worktree "id:$worktree_id" --json 2>/dev/null) || { printf 'unknown'; return 0; }
  printf '%s' "$out" | node -e '
const fs = require("fs");
const [terminal, host] = process.argv.slice(1);
let d;
try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok === false) process.exit(1);
const r = d.result || {};
if (!Array.isArray(r.terminals)) process.exit(1);
const hits = r.terminals.filter((t) => t && String(t.handle) === terminal);
if (hits.length === 0) {
  const omitted = (r.hostScope || {}).omittedHostIds;
  const complete = r.truncated === false && !(Array.isArray(omitted) && omitted.length > 0);
  process.stdout.write(complete ? "absent" : "incomplete");
  process.exit(0);
}
process.stdout.write(hits.length === 1 && String(hits[0].worktreeId) === host ? "present" : "mismatch");
' "$terminal" "$worktree_id" || printf 'unknown'
}

# Print the hosting workspace id of a live terminal, or fail when that terminal
# cannot be observed. A failed read alone is never proof of absence, so callers
# pair it with a complete workspace inventory before concluding a tab is gone.
fm_backend_orca_terminal_observe() {  # <terminal-id>
  local terminal=$1 out
  fm_backend_orca_tool_check >/dev/null 2>&1 || return 1
  out=$(orca terminal show --terminal "$terminal" --json 2>/dev/null) || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
const terminal = process.argv[1];
let d;
try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok === false) process.exit(1);
const t = (d.result || {}).terminal || {};
if (String(t.handle) !== terminal || t.worktreeId == null) process.exit(1);
process.stdout.write(String(t.worktreeId));
' "$terminal"
}

# Strict close for lifecycle paths that must know whether the tab is really gone
# before recording it closed or removing the worktree behind it.
fm_backend_orca_close() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal close --terminal "$1" --json
}
