#!/usr/bin/env bash
# sq-status-notify.sh - desktop notifications (notify-send/mako) when Squad
# operators post a done, needs-decision, blocked, or failed wake event in
# state/<id>.status. Mirrors the herdr "blocked/done" notification behavior
# for operators running in tmux panes.
#
# Notified verbs (default): done needs-decision blocked failed
#   done           -> "Operator finished: <id>"
#   needs-decision -> "Operator needs your decision: <id>"
#   blocked        -> "Operator blocked: <id>"
#   failed         -> "Work failed: <id>"
# Any other <verb>: line is ignored. Override the set with SQ_NOTIFY_VERBS
# (a space-separated list).
#
# Behavior:
#   - Baseline: a status file first seen, or pre-existing history, never
#     notifies; only new appended lines after the baseline fire.
#   - Truncated or rotated status files reset the offset without re-notifying
#     history.
#   - When the operator's tmux window is already the focused window, the
#     notification is suppressed (herdr-like active-tab suppression).
#   - Clicking the notification body focuses the operator's tmux window.
#     The click handler forks per notification so the watcher never blocks on
#     an unacknowledged popup (notify-send -A implies --wait).
#   - Per-base notification offsets live under
#     $XDG_STATE_HOME/sq-status-notify/ (default ~/.local/state/sq-status-notify/),
#     one subdirectory per base.
#
# Usage:
#   sq-status-notify.sh watch [BASE]   polling daemon (default poll 5s)
#   sq-status-notify.sh scan  [BASE]   single pass (tests, internal use)
#   sq-status-notify.sh focus TARGET   focus the tmux window (click action)
#
# BASE resolution: argument > SQUAD_BASE > SQUAD_HOME > this repo root.
# Env: SQ_NOTIFY_POLL (seconds, default 5), SQ_NOTIFY_VERBS (space-separated
# verb list, default "done needs-decision blocked failed").
#
# Fail-closed: an unknown subcommand, or `focus` without TARGET, prints the
# reason to stderr and exits non-zero. notify-send is best-effort: when it is
# missing, the watcher prints one warning to stderr and keeps polling instead
# of dying (the same channel policy as config/wedge-alarm).
set -euo pipefail

SELF="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
POLL_SECONDS="${SQ_NOTIFY_POLL:-5}"
NOTIFY_VERBS="${SQ_NOTIFY_VERBS:-done needs-decision blocked failed}"
CACHE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sq-status-notify"

resolve_base() {  # [BASE] -> base path, per the sq-* scripts' chain
  local base="${1:-}"
  if [[ -z "$base" ]]; then base="${SQUAD_BASE:-}"; fi
  if [[ -z "$base" ]]; then base="${SQUAD_HOME:-}"; fi
  if [[ -z "$base" ]]; then base="$(cd "$SCRIPT_DIR/.." && pwd)"; fi
  printf '%s' "$base"
}

notify_one() {  # <id> <verb> <text> <target>
  local id=$1 verb=$2 text=$3 target=$4
  local title body current chosen
  case "$verb" in
    done) title="Operator finished: $id" ;;
    needs-decision) title="Operator needs your decision: $id" ;;
    blocked) title="Operator blocked: $id" ;;
    failed) title="Work failed: $id" ;;
    *) title="Squad: $id" ;;
  esac
  body="${text:0:280}"

  if [[ -n "$target" ]]; then
    # Suppression herdr-like: the operator's window is already focused, so the
    # notification would be noise.
    current="$(tmux display -p -F '#{session_name}:#{window_name}' 2>/dev/null || true)"
    if [[ -n "$current" && "$current" == "$target" ]]; then
      return 0
    fi
    # Fork: notify-send -A implies --wait; the action (click on the body)
    # focuses the operator's tmux window.
    (
      chosen="$(notify-send -a Squad -u normal -A "default=Focus window" "$title" "$body" 2>/dev/null || true)"
      case "$chosen" in
        default) exec "$SELF" focus "$target" ;;
      esac
    ) &
    return 0
  fi

  notify-send -a Squad -u normal "$title" "$body" 2>/dev/null || true
}

scan_once() {  # <base>: one pass over the base's state dir
  local base=$1 state_dir cache_sub dir id f size off target line verb text
  state_dir="$base/state"
  [[ -d "$state_dir" ]] || return 0
  cache_sub="$(printf '%s' "$base" | tr '/' '_')"
  dir="$CACHE_DIR/$cache_sub"
  mkdir -p "$dir"

  for f in "$state_dir"/*.status; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f" .status)"
    size="$(wc -c < "$f")"
    if [[ -f "$dir/$id.offset" ]]; then
      off="$(cat "$dir/$id.offset")"
    else
      off="$size" # baseline: never notify pre-existing history
    fi
    case "$off" in
      '' | *[!0-9]*) off="$size" ;; # corrupt offset: re-baseline, never spam
    esac
    if (( size < off )); then
      off="$size" # truncated/rotated file: reset without notifying history
    fi
    if (( off < size )); then
      target="$(awk -F= '$1=="window"{print $2}' "$state_dir/$id.meta" 2>/dev/null || true)"
      while IFS= read -r line; do
        [[ "$line" =~ ^([a-z-]+):[[:space:]]*(.*)$ ]] || continue
        verb="${BASH_REMATCH[1]}"
        text="${BASH_REMATCH[2]}"
        case " $NOTIFY_VERBS " in
          *" $verb "*) notify_one "$id" "$verb" "$text" "$target" ;;
        esac
      done < <(tail -c +"$((off + 1))" "$f")
    fi
    printf '%s' "$size" > "$dir/$id.offset"
  done
}

watch() {  # [BASE]: poll forever
  local base
  base="$(resolve_base "${1:-}")"
  command -v notify-send >/dev/null 2>&1 || {
    echo "sq-status-notify: notify-send not found; desktop notifications disabled" >&2
  }
  while true; do
    scan_once "$base"
    sleep "$POLL_SECONDS"
  done
}

focus() {  # TARGET: select the operator's tmux window (click action)
  local target=${1:?usage: sq-status-notify.sh focus TARGET}
  tmux select-window -t "$target" 2>/dev/null || true
}

case "${1:-}" in
  watch)
    shift
    watch "$@"
    ;;
  scan)
    shift
    scan_once "$(resolve_base "${1:-}")"
    ;;
  focus)
    shift
    focus "$@"
    ;;
  *)
    echo "usage: sq-status-notify.sh watch|scan [BASE] | focus TARGET" >&2
    exit 1
    ;;
esac
