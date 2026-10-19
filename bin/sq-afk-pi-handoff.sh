#!/usr/bin/env bash
# Pi-native away-mode handoff. The Pi extension owns submission and consumption;
# this sender only publishes an idempotent durable request and observes its ack.

fm_afk_pi_handoff_dir() {  # <state>
  printf '%s/.pi-away-handoff' "${1%/}"
}

# Readiness is published per target. Every Pi process that loads the project
# extension (a worker running in a Squad worktree inherits SQUAD_BASE and the
# TUIOS pane variables just like the primary does) publishes its own record, so a
# single shared ready.json let whichever process wrote last evict the primary
# and the daemon fell back to terminal typing. The file name carries the exact
# session and window, sanitized identically by the extension (byte for byte).
fm_afk_pi_handoff_key() {  # <value> -> filename-safe token
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_'
}

fm_afk_pi_handoff_ready_file() {  # <state> <target>
  printf '%s/ready.%s.%s.json' "$(fm_afk_pi_handoff_dir "$1")" \
    "$(fm_afk_pi_handoff_key "${2%%:*}")" "$(fm_afk_pi_handoff_key "${2#*:}")"
}

# One record, one verdict: prints the validated record (rc 0) or a single
# refusal-reason token (rc 1) so a fallback can always say why it was taken.
fm_afk_pi_handoff_check_record() {  # <state> <target> <file>
  local state=$1 target=$2 file=$3 rec ready pid identity expected heartbeat now age
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'no-record'; return 1; }
  rec=$(jq -ce 'select(type == "object")' "$file" 2>/dev/null) && [ -n "$rec" ] \
    || { printf 'unreadable-record'; return 1; }
  rec=$(printf '%s' "$rec" | jq -ce --arg target_session "${target%%:*}" --arg target_window "${target#*:}" '
    select(.session == $target_session and .window == $target_window)') \
    || { printf 'other-target'; return 1; }
  # version 3 carries the positive-delivery state: the extension reports idle,
  # editor-draft, open-prompt, and in-flight-send flags. An older extension
  # cannot describe that state, so it is refused here and the caller falls back
  # to the fail-safe composer path instead of trusting an unproven handoff.
  ready=$(printf '%s' "$rec" | jq -ce '
    select(.version == 3 and (.pid | type == "number" and floor == .)
      and (.identity | type == "string") and (.idle | type == "boolean")
      and (.draft | type == "boolean") and (.prompts | type == "number" and floor == .)
      and (.sending | type == "boolean")
      and (.heartbeat | type == "number" and floor == .))') \
    || { printf 'schema'; return 1; }
  pid=$(printf '%s' "$ready" | jq -r '.pid')
  identity=$(printf '%s' "$ready" | jq -r '.identity')
  heartbeat=$(printf '%s' "$ready" | jq -r '.heartbeat')
  case "$pid:$heartbeat" in *[!0-9:]*) printf 'schema'; return 1 ;; esac
  if [ "$pid" -le 0 ] || ! kill -0 "$pid" 2>/dev/null; then printf 'dead-process'; return 1; fi
  if ! declare -F fm_pid_identity >/dev/null; then
    # shellcheck source=bin/sq-stand-to-lib.sh
    SQUAD_STATE_OVERRIDE="$state" . "$SQUAD_DAEMON_DIR/sq-stand-to-lib.sh" || { printf 'identity-unavailable'; return 1; }
  fi
  expected=$(fm_pid_identity "$pid" 2>/dev/null) || { printf 'identity-unavailable'; return 1; }
  [ "$identity" = "$expected" ] || { printf 'identity-mismatch'; return 1; }
  now=$(date '+%s%3N' 2>/dev/null)
  case "$now" in *[!0-9]*|'') now=$(($(date '+%s') * 1000)) ;; esac
  age=$((now - heartbeat))
  [ "$age" -ge 0 ] && [ "$age" -le 5000 ] || { printf 'stale-heartbeat'; return 1; }
  printf '%s' "$ready"
}

# Verdict for <target>: "ready <json>" (rc 0) or "refused <reason>" (rc 1). The
# per-target record is authoritative; the legacy shared ready.json is still
# honoured when it names this exact target, so a primary that started before the
# per-target layout keeps working until it restarts.
fm_afk_pi_handoff_evaluate() {  # <state> <target>
  local state=$1 target=$2 dir out why
  [ "${SQUAD_SUPERVISOR_BACKEND:-}" = tuios ] || { printf 'refused not-tuios'; return 1; }
  fm_backend_source tuios || { printf 'refused backend-unavailable'; return 1; }
  fm_backend_tuios_target_ready "$target" || { printf 'refused target-gone'; return 1; }
  dir=$(fm_afk_pi_handoff_dir "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] || { printf 'refused no-handoff-dir'; return 1; }
  if out=$(fm_afk_pi_handoff_check_record "$state" "$target" "$(fm_afk_pi_handoff_ready_file "$state" "$target")"); then
    printf 'ready %s' "$out"; return 0
  fi
  why=$out
  if out=$(fm_afk_pi_handoff_check_record "$state" "$target" "$dir/ready.json"); then
    printf 'ready %s' "$out"; return 0
  fi
  # A legacy record that is missing or names another window carries no news
  # about this target, so only a record that does name it can explain the refusal.
  if [ "$why" = no-record ]; then
    case "$out" in other-target) ;; *) why=$out ;; esac
  fi
  printf 'refused %s' "$why"
  return 1
}

fm_afk_pi_handoff_ready() {  # <state> <target> -> validated ready JSON
  local verdict
  verdict=$(fm_afk_pi_handoff_evaluate "$1" "$2") || return 1
  printf '%s' "${verdict#ready }"
}

# Seconds since a file was last modified, or 0 when that cannot be established
# (0 always means "not stale", so a doubt preserves the existing request).
fm_afk_pi_handoff_age() {  # <path> -> seconds
  local m now
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=
  case "$m" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  now=$(date '+%s' 2>/dev/null)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  if [ "$now" -ge "$m" ]; then printf '%s' "$((now - m))"; else printf '0'; fi
}

fm_afk_pi_handoff_submit() {  # <state> <target> <encoded-message> [covered-lines] [ready-json]
  local state=$1 target=$2 message=$3 lines=${4:-} ready=${5:-} dir id request status tmp prior prior_status nonce same replaceable
  [ -n "$ready" ] || ready=$(fm_afk_pi_handoff_ready "$state" "$target") || return 2
  dir=$(fm_afk_pi_handoff_dir "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 2
  case "$lines" in ''|*[!0-9]*) lines= ;; *) [ "$lines" -gt 0 ] || lines= ;; esac
  request="$dir/request.json"
  if [ -e "$request" ]; then
    [ ! -L "$request" ] || return 2
    prior=$(jq -er '.id' "$request" 2>/dev/null) || return 2
    prior_status=$(jq -er --arg id "$prior" 'select(.id == $id) | .status' "$dir/result.json" 2>/dev/null) || prior_status=new
    same=0
    if jq -e --arg session "${target%%:*}" --arg window "${target#*:}" --arg message "$message" \
      'select(.session == $session and .window == $window and .message == $message)' "$request" >/dev/null 2>&1; then
      same=1
    fi
    # `handled` means Pi consumed the request, so an identical message is already
    # delivered while a different one may replace it. `uncertain` means the
    # extension's send never reached Pi, so republishing cannot duplicate it.
    # A `submitting` record is abandoned only when the live, identity-verified
    # extension reports no in-flight send AND the record has aged past the bound:
    # a send that had been in flight that long would have stopped refreshing the
    # ready heartbeat, so this is never a blind resend.
    replaceable=0
    case "$prior_status" in
      handled) replaceable=1 ;;
      uncertain) replaceable=1 ;;
      submitting)
        if printf '%s' "$ready" | jq -e '.sending == false' >/dev/null 2>&1 \
          && [ "$(fm_afk_pi_handoff_age "$dir/result.json")" -ge "${SQUAD_PI_HANDOFF_STALE_SECS:-30}" ]; then
          replaceable=1
        fi
        ;;
    esac
    if [ "$same" -eq 1 ]; then
      if [ "$replaceable" -ne 1 ]; then return 1; fi
      rm -f "$request" || return 1
      [ "$prior_status" != handled ] || return 0
    else
      if [ "$replaceable" -ne 1 ]; then
        log "Pi handoff has a different unresolved request; preserving the escalation buffer"
        return 1
      fi
      rm -f "$request" || return 1
    fi
  fi
  nonce="$(date '+%s')-$$-${RANDOM:-0}-${RANDOM:-0}"
  if command -v sha256sum >/dev/null 2>&1; then
    id=$(printf '%s\0%s' "$nonce" "$message" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    id=$(printf '%s\0%s' "$nonce" "$message" | shasum -a 256 | awk '{print $1}')
  else
    return 2
  fi
  [[ "$id" =~ ^[a-f0-9]{64}$ ]] || return 2
  tmp="$request.pending.$$"
  jq -n --arg id "$id" --arg session "${target%%:*}" --arg window "${target#*:}" --arg message "$message" \
    --arg lines "$lines" \
    '{id:$id,session:$session,window:$window,message:$message} + (if $lines == "" then {} else {lines:($lines|tonumber)} end)' > "$tmp" || { rm -f "$tmp"; return 2; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 2; }
  mv "$tmp" "$request" || { rm -f "$tmp"; return 2; }
  status=$(jq -er --arg id "$id" 'select(.id == $id) | .status' "$dir/result.json" 2>/dev/null) || status=new
  case "$status" in
    handled) rm -f "$request" || return 1; return 0 ;;
    new|submitting|queued|uncertain) return 1 ;;
    *) log "unrecognized Pi handoff result '$status'; preserving the escalation buffer"; return 2 ;;
  esac
}
