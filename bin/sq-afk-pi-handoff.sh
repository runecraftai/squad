#!/usr/bin/env bash
# Pi-native away-mode handoff. The Pi extension owns submission and consumption;
# this sender only publishes an idempotent durable request and observes its ack.

fm_afk_pi_handoff_dir() {  # <state>
  printf '%s/.pi-away-handoff' "${1%/}"
}

fm_afk_pi_handoff_ready() {  # <state> <target> -> validated ready JSON
  local state=$1 target=$2 dir ready pid identity expected heartbeat now age
  [ "${SQUAD_SUPERVISOR_BACKEND:-}" = tuios ] || return 1
  fm_backend_source tuios || return 1
  fm_backend_tuios_target_ready "$target" || return 1
  dir=$(fm_afk_pi_handoff_dir "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/ready.json" ] && [ ! -L "$dir/ready.json" ] || return 1
  # version 3 carries the positive-delivery state: the extension reports idle,
  # editor-draft, open-prompt, and in-flight-send flags. An older extension
  # cannot describe that state, so it is refused here and the caller falls back
  # to the fail-safe composer path instead of trusting an unproven handoff.
  ready=$(jq -ce --arg target_session "${target%%:*}" --arg target_window "${target#*:}" '
    select(type == "object" and .version == 3 and (.pid | type == "number" and floor == .)
      and (.identity | type == "string") and (.session == $target_session)
      and (.window == $target_window) and (.idle | type == "boolean")
      and (.draft | type == "boolean") and (.prompts | type == "number" and floor == .)
      and (.sending | type == "boolean")
      and (.heartbeat | type == "number" and floor == .))
  ' "$dir/ready.json" 2>/dev/null) || return 1
  pid=$(printf '%s' "$ready" | jq -r '.pid')
  identity=$(printf '%s' "$ready" | jq -r '.identity')
  heartbeat=$(printf '%s' "$ready" | jq -r '.heartbeat')
  case "$pid:$heartbeat" in *[!0-9:]*) return 1 ;; esac
  [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null || return 1
  if ! declare -F fm_pid_identity >/dev/null; then
    # shellcheck source=bin/sq-stand-to-lib.sh
    SQUAD_STATE_OVERRIDE="$state" . "$SQUAD_DAEMON_DIR/sq-stand-to-lib.sh" || return 1
  fi
  expected=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$identity" = "$expected" ] || return 1
  now=$(date '+%s%3N' 2>/dev/null)
  case "$now" in *[!0-9]*|'') now=$(($(date '+%s') * 1000)) ;; esac
  age=$((now - heartbeat))
  [ "$age" -ge 0 ] && [ "$age" -le 5000 ] || return 1
  printf '%s' "$ready"
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

fm_afk_pi_handoff_submit() {  # <state> <target> <encoded-message> [covered-lines]
  local state=$1 target=$2 message=$3 lines=${4:-} dir ready id request status tmp prior prior_status nonce same replaceable
  ready=$(fm_afk_pi_handoff_ready "$state" "$target") || return 2
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
