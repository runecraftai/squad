#!/usr/bin/env bash
# Send one line of literal text to an operator endpoint, then Enter.
# Usage: sq-send.sh <target> [--resolve-key <key>]... <text...>
#   <target> may be an exact task id, a legacy sq-<id> task label resolved
#   through this base's state/<id>.meta, or an explicit well-formed backend
#   target. sq-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: sq-send.sh <target> --key Enter
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the target backend confirms a
# submit or reports an inconclusive send. If a swallowed Enter is positively
# confirmed, sq-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction.
# Submission dispatches through the target's recorded backend; the tmux adapter
# shares its composer/submit core with the away-mode daemon via bin/sq-tmux-lib.sh.
# Tune with SQUAD_SEND_RETRIES (default 3) / SQUAD_SEND_SLEEP (0.4).
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
#
# From-Squad marker: when the resolved target is a task selector whose meta
# records kind=xo, the text uses the live-charter-compatible
# from-squad carrier owned by bin/sq-operational-input.sh so the XO
# routes its reply via its status file or a status-pointed doc instead of
# stranding it in chat the main Squad never reads. An operator/recon target,
# an explicit backend-target escape-hatch target, and the --key path are never
# marked - their behavior is unchanged.
#
# Parent-owned pending-reply expectation: every newly marked XO request
# also receives a privacy-safe correlation id and a durable parent record under
# state/pending-replies/ before delivery (bin/sq-pending-reply-lib.sh). Delivery
# success and reply success are separate facts: a successful submit never
# resolves the expectation. Set SQUAD_PENDING_REPLY_EXISTING_CORR=<id> when
# re-sending a recovery request for an already-open expectation so a second
# record is not created. Direct unmarked commander input never creates one.
#
# Decision closure (answerer-closes): pass --resolve-key <key> (repeatable,
# before the message) when this send answers an open keyed needs-decision: or
# blocked: record in the target task's state/<id>.status. After the submit is
# confirmed, sq-send itself appends the closing
# "resolved [key=<key>]: answered: <capped excerpt>" line to that status file,
# so the commander-facing OPEN DECISIONS record closes at answer time and never
# depends on the busy worker writing a matching resolved line. The close is a
# LOCAL append for every target kind - operator, recon, local XO, and
# remote XO alike - because the open-decision ledger sq-stand-to-drain
# folds lives in this base's own state dir (a remote mate's escalations reach
# it through the parent-replies ingest); only the answer message crosses the
# backend or remote transport. Each named key must currently be open in that
# ledger per status_open_decisions (bin/sq-classify-lib.sh) or sq-send refuses
# before sending, so a mistyped key cannot deliver an answer while silently
# orphaning the decision. A failed or unconfirmed send never closes a key; a
# delivered answer whose closing append fails exits nonzero with the exact
# manual close command, leaving the decision open to re-surface (the safe
# direction). A send without the flag never closes anything: a routine steer,
# working:, or done: event still cannot clear a commander decision. The flag is
# refused with --key, with an explicit backend target (no task ledger in this
# base), and with an empty message.
#
# After a successful text submit sq-send pauses SQUAD_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: submit confirmation only proves the text was
# accepted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is sq-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
# Pi and pi-signed task extensions also expose a private delivery dropbox. When
# present, text uses Pi's sendUserMessage(..., { deliverAs: "followUp" }) so a
# parked composer cannot swallow the steer. A missing or unavailable extension
# falls back to the recorded backend's normal submit path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/sq-gate-refuse-lib.sh
. "$SCRIPT_DIR/sq-gate-refuse-lib.sh"
# Fail closed before any unit mutation: a drill gate agent must never steer
# an operator (see bin/sq-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-}}"
if [ -z "$SQUAD_BASE" ]; then
  echo "error: SQUAD_BASE is not set (legacy SQUAD_HOME is also accepted); sq-send refuses to resolve targets without an explicit Squad base" >&2
  exit 1
fi

STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
if [ ! -d "$SQUAD_BASE" ]; then
  echo "error: SQUAD_BASE '$SQUAD_BASE' is not a directory; sq-send cannot resolve this base's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; sq-send cannot resolve targets for SQUAD_BASE '$SQUAD_BASE'" >&2
  exit 1
fi

# shellcheck source=bin/sq-backend.sh
. "$SCRIPT_DIR/sq-backend.sh"
# shellcheck source=bin/sq-marker-lib.sh
. "$SCRIPT_DIR/sq-marker-lib.sh"
# shellcheck source=bin/sq-pending-reply-lib.sh
. "$SCRIPT_DIR/sq-pending-reply-lib.sh"
# shellcheck source=bin/sq-classify-lib.sh
. "$SCRIPT_DIR/sq-classify-lib.sh"
# shellcheck source=bin/sq-line-cap-lib.sh
. "$SCRIPT_DIR/sq-line-cap-lib.sh"

SQUAD_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/sq-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

# fm_send_pi_native: deliver through the task extension's private dropbox.
# Return 0 only after the extension reports sendUserMessage accepted the text
# and an agent_start busy edge proved Pi is processing it. Return 2 when the
# extension is unavailable so the caller can use the normal backend path.
fm_send_pi_native() {  # <state-dir> <task-id> <message>
  local state_dir=$1 task_id=$2 message=$3 dir ready request_id request tmp timeout
  local response deadline status ready_pid ready_start current_start
  dir="$state_dir/.pi-delivery/$task_id"
  ready="$dir/ready"
  [ -d "$dir" ] || return 2
  [ -f "$ready" ] || return 2
  ready_pid=$(sed -n '1p' "$ready" 2>/dev/null || true)
  ready_start=$(sed -n '2p' "$ready" 2>/dev/null || true)
  case "$ready_pid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  case "$ready_start" in
    ''|*[!0-9]*) return 2 ;;
  esac
  kill -0 "$ready_pid" 2>/dev/null || return 2
  current_start=$(awk '{print $22}' "/proc/$ready_pid/stat" 2>/dev/null || true)
  [ "$current_start" = "$ready_start" ] || return 2

  request_id="$task_id.$$.$RANDOM"
  request="$dir/$request_id.request"
  response="$dir/$request_id.response"
  tmp="$request.tmp"
  if ! printf '%s\n%s\n' "$request_id" "$message" > "$tmp" || ! mv "$tmp" "$request"; then
    rm -f "$tmp"
    return 1
  fi

  timeout=${SQUAD_PI_DELIVERY_TIMEOUT:-5}
  case "$timeout" in
    ''|*[!0-9]*) timeout=5 ;;
  esac
  deadline=$(( $(date +%s) + timeout ))
  while [ ! -f "$response" ] && [ "$(date +%s)" -le "$deadline" ]; do
    sleep 0.05
  done
  if [ ! -f "$response" ]; then
    # Do not fall back after a live extension accepted an unconfirmed request:
    # that could submit the same steer twice. The request remains for the
    # extension to reconcile, and the caller gets an explicit failure.
    return 1
  fi
  status=$(sed -n '1p' "$response")
  rm -f "$response"
  case "$status" in
    processing) return 0 ;;
    unavailable) return 2 ;;
    *) return 1 ;;
  esac
}

# fm_send_clear_after_interrupt: muse RESTORES the interrupted prompt back into
# the composer when Escape cancels a turn, as real bright text (verified: fg
# 38;2;204;211;219, luminance ~210, muse 0.1.0-R708.1), not de-emphasised ghost
# text. Classifying that as pending input is correct - the text really is
# unsubmitted - but leaving it there means the NEXT steer types onto the end of
# it and submits both as one garbled message. Ctrl-U clears the composer
# (verified), so the interrupt is not complete until it has been sent. A failed
# clear is loud rather than silent, because the alternative is a corrupted steer.
fm_send_clear_after_interrupt() {  # <key>
  local key=$1
  [ "$key" = Escape ] || return 0
  case "$TARGET_HARNESS" in muse*) : ;; *) return 0 ;; esac
  [ "$TARGET_BACKEND" != remote ] || return 0
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" C-u "$EXPECTED_LABEL"; then
    echo "error: Escape reached $T, but the muse composer could not be cleared; it still holds the restored prompt. Clear it before sending the next message." >&2
    return 1
  fi
}

fm_send_normalize_key() {  # <key>
  case "$1" in
    Escape|escape|Esc|esc) printf '%s' Escape ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_send_record_interrupt() {  # <key>
  local key=$1 id gen
  [ "$key" = Escape ] || return 0
  case "$TARGET_HARNESS" in claude*) : ;; *) return 0 ;; esac
  [ -n "$TARGET_META" ] || return 0
  id=$(fm_send_id_from_meta "$TARGET_META")
  [ -f "$STATE/$id.busy-gen" ] || return 0
  gen=$(fm_meta_get "$TARGET_META" busy_gen)
  if [ -n "$gen" ]; then
    "$SQUAD_ROOT/bin/sq-busy-event.sh" apply "$STATE" "$id" idle \
      --gen "$gen" --source sq-interrupt --event interrupt
  else
    "$SQUAD_ROOT/bin/sq-busy-event.sh" apply "$STATE" "$id" idle \
      --current-gen --source sq-interrupt --event interrupt
  fi || {
    echo "error: key '$key' reached $T, but the Claude interrupt state could not be recorded for $id" >&2
    return 1
  }
}

fm_send_meta_for_key_value() {  # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() {  # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $(( ${#s} - ${#no_colons} ))
}

fm_send_resolve_target() {  # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  TARGET_REMOTE_ID=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      id=$(fm_send_id_from_meta "$meta")
      RESOLVED_TARGET="remote:$id"
      TARGET_BACKEND=remote
      TARGET_META=$meta
      TARGET_HARNESS=$(fm_meta_get "$meta" harness)
      EXPECTED_LABEL="sq-$id"
      TARGET_SELECTOR=1
      TARGET_REMOTE_ID=$id
      RESOLUTION_TRIED="meta=$meta; placement=remote"
      return 0
    fi
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
    sq-*:*)
      # A named Herdr session may itself begin with "sq-". Keep that explicit
      # session:pane target on the validated backend-target path below rather
      # than mistaking it for an unresolved task selector.
      ;;
    sq-*)
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#sq-}.meta; backend=none"
      echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this Squad home" >&2
      return 1
      ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'sq-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
    *:*)
      colons=$(fm_send_count_colons "$raw")
      if [ "$colons" -ge 2 ]; then
        assumed=herdr
      else
        assumed=tmux
      fi
      if ! fm_backend_target_exists "$assumed" "$raw"; then
        echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use sq-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
        return 1
      fi
      RESOLVED_TARGET=$raw
      TARGET_BACKEND=$assumed
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
      return 0
      ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use sq-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift

# Collect --resolve-key flags (answerer-closes; see the header contract). They
# must precede --key or the message text; everything after the last flag is the
# message exactly as before, so ordinary sends are byte-identical.
RESOLVE_KEYS=
fm_send_add_resolve_key() {  # <key>
  local k=$1
  case "$k" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: --resolve-key '$k' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)" >&2
      return 1
      ;;
  esac
  case " $RESOLVE_KEYS " in
    *" $k "*)
      echo "error: duplicate --resolve-key '$k'" >&2
      return 1
      ;;
  esac
  RESOLVE_KEYS="${RESOLVE_KEYS}${RESOLVE_KEYS:+ }$k"
}
while :; do
  case "${1:-}" in
    --resolve-key)
      [ $# -ge 2 ] || { echo "error: --resolve-key requires a key" >&2; exit 1; }
      fm_send_add_resolve_key "$2" || exit 1
      shift 2
      ;;
    --resolve-key=*)
      fm_send_add_resolve_key "${1#--resolve-key=}" || exit 1
      shift
      ;;
    *) break ;;
  esac
done

if [ "$TARGET_BACKEND" != remote ]; then
  fm_backend_validate "$TARGET_BACKEND" || exit 1
fi

# Classify a from-squad -> XO request. Only a task selector resolved
# through this base's meta whose authoritative kind is XO is marked: the
# XO then routes its reply via the status path (see sq-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this base)
# and any operator/recon target are left unmarked, and so is the --key path.
MARK_FROM_SQUAD=0
PENDING_REPLY_CORR=
PENDING_REPLY_CREATED=0
TARGET_TASK_ID=
if [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] && [ "$(fm_meta_get "$TARGET_META" kind)" = xo ]; then
  MARK_FROM_SQUAD=1
  TARGET_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
fi

# Validate the answerer-closes request before any durable mutation or send: the
# target must have a task ledger in THIS base, the send must carry an answer
# message, and every named key must be open right now in that ledger per the
# ONE authoritative fold (status_open_decisions). Refusing here, before the
# send, is what keeps a mistyped key loud instead of delivering an answer that
# silently leaves its decision open.
RESOLVE_STATUS_FILE=
if [ -n "$RESOLVE_KEYS" ]; then
  if [ -z "$TARGET_SELECTOR" ] || [ -z "$TARGET_META" ]; then
    echo "error: --resolve-key needs a task selector resolved through this home's metadata; an explicit backend target has no decision ledger here" >&2
    exit 1
  fi
  if [ "${1:-}" = "--key" ]; then
    echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
    exit 1
  fi
  if [ -z "$*" ]; then
    echo "error: --resolve-key requires a nonempty answer message" >&2
    exit 1
  fi
  RESOLVE_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
  RESOLVE_STATUS_FILE="$STATE/$RESOLVE_TASK_ID.status"
  resolve_open_set=$(status_open_decisions "$RESOLVE_STATUS_FILE")
  for k in $RESOLVE_KEYS; do
    case "$resolve_open_set" in
      "$k"$'\t'*|*$'\n'"$k"$'\t'*) ;;
      *)
        echo "error: --resolve-key '$k': no open decision or blocker with that key in $RESOLVE_STATUS_FILE (already closed, mistyped, or transferred). Re-check the OPEN DECISIONS listing, then resend without that key or with the right one; nothing was sent." >&2
        exit 1
        ;;
    esac
  done
fi

# Close each answered decision in this base's ledger, only after delivery is
# fully confirmed. An append failure exits nonzero with the manual close
# command; the decision then stays open and re-surfaces, never silently lost.
fm_send_close_resolved_keys() {  # <answer-text>
  local note=$1 k line
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_KEYS; do
    line="resolved [key=$k]: answered: $note"
    fm_cap_line_var "$line"
    if ! printf '%s\n' "$SQUAD_LINE_CAP_LINE" >> "$RESOLVE_STATUS_FILE"; then
      echo "error: the answer was delivered to $T, but decision key '$k' could not be closed in $RESOLVE_STATUS_FILE. Close it manually with: echo 'resolved [key=$k]: <how it was answered>' >> $RESOLVE_STATUS_FILE - do not resend the answer." >&2
      return 1
    fi
  done
}

# Resolve the target's harness from its meta (recorded by sq-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A task selector carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive liveness preflight here. Active send paths own
# backend readiness: herdr, for example, must route through its session-aware
# target_ready path before sending, while zellij verifies pane labels in its
# send implementation. A failed backend send is still surfaced below as a hard
# error with the attempted resolution attached.

if [ "${1:-}" = "--key" ]; then
  case "$*" in
    *--resolve-key*)
      echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
      exit 1
      ;;
  esac
  key=$2
  semantic_key=$(fm_send_normalize_key "$key")
  if [ "$TARGET_BACKEND" = remote ]; then
    if ! "$SCRIPT_DIR/sq-on.sh" "$TARGET_REMOTE_ID" sq-remote-xo-control.sh key "$TARGET_REMOTE_ID" "$key" < /dev/null; then
      echo "error: key '$key' not sent to remote XO $TARGET_REMOTE_ID; completion may be unknown" >&2
      exit 1
    fi
  elif ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$key" "$EXPECTED_LABEL"; then
    echo "error: key '$key' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  fm_send_clear_after_interrupt "$semantic_key" || exit 1
  fm_send_record_interrupt "$semantic_key" || exit 1
else
  MESSAGE=$*
  # The pre-marker answer text, kept for the closing resolved note so the
  # durable ledger records the plain answer without marker or corr bytes.
  RESOLVE_ANSWER_TEXT=$MESSAGE
  if [ "$MARK_FROM_SQUAD" = 1 ]; then
    # Reuse an existing correlation id for recovery resends; otherwise create a
    # durable parent expectation before delivery. Transport success never
    # resolves that expectation (see sq-pending-reply-lib.sh).
    existing_corr=${SQUAD_PENDING_REPLY_EXISTING_CORR:-$(fm_pending_reply_extract_corr "$MESSAGE")}
    if [ -n "$existing_corr" ] \
      && fm_pending_reply_corr_reusable "$STATE" "$existing_corr" "$TARGET_TASK_ID"; then
      PENDING_REPLY_CORR=$existing_corr
    else
      if [ -z "$TARGET_TASK_ID" ]; then
        echo "error: cannot create pending-reply expectation without a resolvable XO task id" >&2
        exit 1
      fi
      PENDING_REPLY_CORR=$(fm_pending_reply_create "$SQUAD_BASE" "$STATE" "$TARGET_TASK_ID" "$MESSAGE") \
        || { echo "error: failed to create parent pending-reply expectation for $TARGET_TASK_ID" >&2; exit 1; }
      PENDING_REPLY_CREATED=1
    fi
    fm_pending_reply_embed_corr "$MESSAGE" "$PENDING_REPLY_CORR" MESSAGE
    if [ "$PENDING_REPLY_CREATED" = 1 ] \
      && ! fm_pending_reply_prepare_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      echo "error: failed to durably prepare pending-reply delivery for $TARGET_TASK_ID" >&2
      exit 1
    fi
  fi
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The target backend's
  # verified submit retry still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${SQUAD_SEND_RETRIES:-3}
  sleep_s=${SQUAD_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Only exact empty confirms delivery; every other
  # verdict preserves the loud refusal boundary. Pi's task extension is the
  # preferred delivery path because it bypasses the parked composer entirely.
  send_rc=0
  native_rc=2
  if [ "$TARGET_BACKEND" != remote ] \
    && [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] \
    && [ "$(fm_meta_get "$TARGET_META" kind)" != xo ]; then
    case "$TARGET_HARNESS" in
      pi|pi-signed)
        if fm_send_pi_native "$STATE" "$(fm_send_id_from_meta "$TARGET_META")" "$MESSAGE"; then
          native_rc=0
        else
          native_rc=$?
        fi
        if [ "$native_rc" -eq 0 ]; then
          verdict=empty
        elif [ "$native_rc" -ne 2 ]; then
          send_rc=$native_rc
        fi
        ;;
    esac
  fi
  if [ "$send_rc" -eq 0 ] && [ "$native_rc" -eq 2 ]; then
    if [ "$TARGET_BACKEND" = remote ]; then
      if "$SCRIPT_DIR/sq-on.sh" "$TARGET_REMOTE_ID" sq-remote-xo-control.sh send "$TARGET_REMOTE_ID" "$MESSAGE" < /dev/null >/dev/null; then
        verdict=empty
      else
        send_rc=$?
        verdict=send-failed
      fi
    elif verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL"); then
      :
    else
      send_rc=$?
    fi
  fi
  if [ "$send_rc" -ne 0 ]; then
    if [ "$TARGET_BACKEND" = remote ] && [ "$send_rc" -eq 255 ] && [ -n "$PENDING_REPLY_CORR" ]; then
      fm_pending_reply_mark_delivery_unknown "$STATE" "$PENDING_REPLY_CORR" || true
      echo "error: text delivery to remote XO $TARGET_REMOTE_ID is unknown; do not resend - same-host reconciliation is required" >&2
      exit 1
    fi
    if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
    fi
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  case "$verdict" in
    empty)
      ;;
    send-failed)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    *)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not submitted to $T (delivery unconfirmed; verdict=${verdict:-unknown}; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
  esac
  # Delivery confirmed. Mark the pending expectation delivered without resolving
  # it: only a correlated parent report acknowledges the request.
  if [ -n "$PENDING_REPLY_CORR" ]; then
    if fm_pending_reply_confirm_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      :
    else
      delivery_commit_status=$?
      if [ "$delivery_commit_status" = 2 ]; then
        echo "error: text was delivered to $T, but its pending-reply delivery commit failed; a durable recovery marker was stored and the sentry will reconcile it. Do not resend." >&2
      else
        echo "error: text was delivered to $T, but its pending-reply delivery commit and recovery marker both failed. Do not resend; inspect $STATE manually." >&2
      fi
      exit 1
    fi
  fi
  # Delivery is fully confirmed: close each answered decision in this base's
  # ledger (answerer-closes; see the header contract).
  if [ -n "$RESOLVE_KEYS" ]; then
    fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
  fi
  # Submit landed with exact empty. Confirmation only proves the text was
  # accepted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # operator actually working instead of the stale idle pane. SQUAD_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${SQUAD_SEND_SETTLE:-1}" = 0 ] || sleep "${SQUAD_SEND_SETTLE:-1}"
fi
