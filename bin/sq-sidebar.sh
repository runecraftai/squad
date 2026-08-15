#!/usr/bin/env bash
# sq-sidebar.sh - Squad ground-truth tmux sidebar (replaces tmux-agents-mon).
#
# Renders a per-operator card sidebar in a tmux pane from Squad ground truth.
# The sidebar is a CONSUMER of the ground-truth contract; it never reads
# screens and never maps Squad verbs itself. bin/sq-window-state.sh owns the
# verb -> label translation and publishes state/window-states (its header owns
# the file contract); bin/sq-crew-state.sh owns current-state reconciliation;
# bin/sq-classify-lib.sh owns the status-event vocabulary. This script reads
# state/window-states plus state/<id>.meta and state/<id>.busy-gen and renders
# the cards.
#
# Card model (two display lines per operator window, one raw record per card):
#   line 1: <glyph> <id> [<elapsed>]      state-colored mission row
#   line 2: <label> <detail-or-meta>      state-colored label + current prose
#   cards: <window>\t<id>\t<label>\t<state>\t<detail>\t<elapsed>\t<model>\t<effort>
# The two-lines-per-card layout is the ONE layout constant this script owns;
# `click` maps a rendered pane line to its card with ((line + 1) / 2), so
# `render` must keep emitting exactly two lines per card.
#
# Elapsed time is a simple honest approximation: wall-clock since the task's
# busy contract was armed (state/<id>.busy-gen mtime, written once at spawn),
# falling back to the meta file's mtime. It is not billing-grade and this
# script does NOT compute session cost - it only shows the recorded model and
# effort tags from meta as the cost context. See docs/sq-sidebar.md.
#
# Subcommands:
#   cards [BASE]    print one raw TAB-separated record per operator card
#   render [BASE]   print the display lines with ANSI styling (spinner when
#                   working); SQ_SIDEBAR_NO_COLOR=1 prints plain text
#   publish [BASE]  run bin/sq-window-state.sh publish for the base
#   run [BASE]      the sidebar pane loop: self-tag, publish on the refresh
#                   cadence, re-render every frame until the pane is killed
#   toggle [BASE]   open a 25-wide left sidebar pane in the current window, or
#                   close it when one is already open (C-M-s, workmux-style)
#   click <line> [BASE]  focus the operator window whose card occupies pane
#                   line <line> (1-based pane row; the tmux loader passes the
#                   mouse row and the base recorded by run in @sq-sidebar-base)
#   focus <window>  select-window to the given target (exposed for scripts)
#
# BASE resolution: argument > SQ_SIDEBAR_BASE > SQUAD_BASE > SQUAD_HOME >
# this repo root. The renderer, card reader, and publish are tmux-free and
# fully testable against fake state dirs; only toggle/run/click/focus need
# tmux and fail closed with a stderr note when it is missing.
#
# Env: SQUAD_STATE_OVERRIDE selects the state dir (tests); SQUAD_CREW_STATE_BIN
# overrides the reconciler binary for publish (tests); SQ_SIDEBAR_WIDTH (default
# 25), SQ_SIDEBAR_SPINNER (space-separated frame glyphs), SQ_SIDEBAR_REFRESH_SECS
# (publish cadence in run, default 2), SQ_SIDEBAR_FRAME_SECS (render cadence,
# default 1), SQ_SIDEBAR_NOW (epoch; pins the spinner frame for tests),
# SQ_SIDEBAR_ELAPSED_NOW (epoch; pins the elapsed clock for tests),
# SQ_SIDEBAR_NO_COLOR=1 and SQ_SIDEBAR_NO_ELAPSED=1 disable their feature.
set -euo pipefail

SELF="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WS_BIN="${SQUAD_WINDOW_STATE_BIN:-$SCRIPT_DIR/sq-window-state.sh}"
CREW_STATE_BIN="${SQUAD_CREW_STATE_BIN:-$SCRIPT_DIR/sq-crew-state.sh}"

WIDTH="${SQ_SIDEBAR_WIDTH:-25}"
REFRESH_SECS="${SQ_SIDEBAR_REFRESH_SECS:-2}"
FRAME_SECS="${SQ_SIDEBAR_FRAME_SECS:-1}"
SPINNER="${SQ_SIDEBAR_SPINNER:-⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏}"
LINES_PER_CARD=2
read -r -a SPINNER_FRAMES <<< "$SPINNER"

resolve_base() {  # [BASE] -> base path, per the sq-* scripts' chain
  local base="${1:-}"
  if [[ -z "$base" ]]; then base="${SQ_SIDEBAR_BASE:-}"; fi
  if [[ -z "$base" ]]; then base="${SQUAD_BASE:-}"; fi
  if [[ -z "$base" ]]; then base="${SQUAD_HOME:-}"; fi
  if [[ -z "$base" ]]; then base="$SQUAD_ROOT"; fi
  printf '%s' "$base"
}

state_dir() {  # [BASE] -> base/state, or $SQUAD_STATE_OVERRIDE when set (tests)
  if [ -n "${SQUAD_STATE_OVERRIDE:-}" ]; then
    printf '%s' "$SQUAD_STATE_OVERRIDE"
    return 0
  fi
  printf '%s/state' "$(resolve_base "$1")"
}

# meta_get <meta-file> <key>: the LAST value of `key=`, or empty. Mirrors the
# documented inline snippet fm_meta_get in bin/sq-backend.sh wraps.
meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

file_mtime() {  # <file> -> epoch seconds, or empty
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

elapsed_for() {  # <state-dir> <id> -> HH:MM:SS wall-clock, or empty
  local dir=$1 id=$2 start now diff h m s
  start=$(file_mtime "$dir/$id.busy-gen")
  [[ -n "$start" ]] || start=$(file_mtime "$dir/$id.meta")
  case "$start" in
    '' | *[!0-9]*) return 0 ;;
  esac
  now=${SQ_SIDEBAR_ELAPSED_NOW:-$(date +%s)}
  diff=$((now - start))
  [ "$diff" -lt 0 ] && diff=0
  h=$((diff / 3600)); m=$(((diff % 3600) / 60)); s=$((diff % 60))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

# spinner_frame <now>: the frame index is a pure function of the clock so the
# pane loop and a test both pick the same frame without shared state.
spinner_frame() {  # <now>
  local now=$1 n idx
  n=${#SPINNER_FRAMES[@]}
  [ "$n" -ge 1 ] || return 0
  idx=$((now % n))
  printf '%s' "${SPINNER_FRAMES[$idx]}"
}

# truncate <string> <max-chars>: character-safe (not byte-safe) truncation.
truncate() {  # <string> <max-chars>
  local s=$1 max=$2
  printf '%s' "$s" | cut -c1-"$max"
}

label_color() {  # <label> -> ANSI SGR color for the card
  case "$1" in
    working) printf '38;5;76' ;;           # green
    awaiting-decision) printf '38;5;220' ;; # yellow
    blocked) printf '38;5;196' ;;          # red
    done) printf '38;5;45' ;;              # cyan
    idle) printf '38;5;244' ;;             # gray
    failed) printf '38;5;196' ;;           # red
    *) printf '38;5;244' ;;                # unknown: gray
  esac
}

# glyph_for <label> <now>: spinner frames while working, static glyphs else.
glyph_for() {  # <label> <now>
  case "$1" in
    working) spinner_frame "$2" ;;
    awaiting-decision) printf '?' ;;
    blocked) printf '!' ;;
    done) printf '✓' ;;
    idle) printf '-' ;;
    failed) printf '✗' ;;
    *) printf '.' ;;
  esac
}

# cards_lines [BASE]: one raw TAB-separated record per operator card, in the
# same sorted order as state/window-states (the file is sorted by window).
cards_lines() {  # [BASE]
  local base=$1 dir ws window id label state detail elapsed model effort
  dir=$(state_dir "$base")
  ws="$dir/window-states"
  [ -f "$ws" ] || return 0
  while IFS=$'\t' read -r window id label state detail; do
    [ -n "$window" ] || continue
    elapsed=$(elapsed_for "$dir" "$id")
    model=$(meta_get "$dir/$id.meta" model)
    effort=$(meta_get "$dir/$id.meta" effort)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$window" "$id" "$label" "$state" "$detail" "$elapsed" "$model" "$effort"
  done < "$ws"
}

# display_lines [BASE]: the exact lines the sidebar pane shows, one physical
# line per pane row. With SQ_SIDEBAR_NO_COLOR=1 the output is plain text that
# still equals the rendered line-for-line output. Empty when there are no
# operator cards; the pane shows a placeholder instead.
display_lines() {  # [BASE]
  local base=$1 now color glyph line1 line2 glyph_id
  now=${SQ_SIDEBAR_NOW:-$(date +%s)}
  color=1
  if [ "${SQ_SIDEBAR_NO_COLOR:-}" = 1 ]; then color=0; fi
  while IFS=$'\t' read -r window id label state detail elapsed model effort; do
    [ -n "$window" ] || continue
    glyph=$(glyph_for "$label" "$now")
    # Line 1: <glyph> <id> [<elapsed>]; line 2: <label> <detail-or-meta>.
    # Both truncated to the pane width minus one so a card never wraps and
    # the click line mapping stays exact.
    glyph_id=$(printf '%-2s %-12s' "$glyph" "$(truncate "$id" 12)")
    if [ -n "$elapsed" ] && [ "${SQ_SIDEBAR_NO_ELAPSED:-}" != 1 ]; then
      line1=$(printf '%-14s%8s' "$glyph_id" "$elapsed")
    else
      line1=$glyph_id
    fi
    if [ -n "$detail" ]; then
      line2=$(printf '%s %s' "$label" "$detail")
    elif [ -n "$model" ] || [ -n "$effort" ]; then
      line2=$(printf '%s %s' "$label" "$model${effort:+·$effort}")
    else
      line2=$label
    fi
    line1=$(truncate "$line1" "$((WIDTH - 1))")
    line2=$(truncate "$line2" "$((WIDTH - 1))")
    if [ "$color" -eq 1 ]; then
      printf '\033[%sm%s\033[0m\n' "$(label_color "$label")" "$line1"
      printf '\033[%sm%s\033[0m\n' "$(label_color "$label")" "$line2"
    else
      printf '%s\n' "$line1"
      printf '%s\n' "$line2"
    fi
  done < <(cards_lines "$base")
}

render() {  # [BASE]: ANSI display lines, or the placeholder when no cards
  local base=$1 out
  out=$(display_lines "$base")
  if [ -z "$out" ]; then
    if [ "${SQ_SIDEBAR_NO_COLOR:-}" = 1 ]; then
      printf '%s\n' '-- no Squad operators --'
    else
      printf '\033[38;5;244m-- no Squad operators --\033[0m\n'
    fi
    return 0
  fi
  printf '%s\n' "$out"
}

publish() {  # [BASE]
  local base=$1
  SQUAD_STATE_OVERRIDE="$(state_dir "$base")" SQUAD_CREW_STATE_BIN="$CREW_STATE_BIN" \
    "$WS_BIN" publish
}

# render_pane [BASE]: repaint the sidebar pane content in place.
render_pane() {  # [BASE]
  local base=$1
  printf '\033[2J\033[H'
  render "$base"
}

run() {  # [BASE]: the sidebar pane loop; killed with the pane
  local base=$1 every n=0
  base=$(resolve_base "$base")
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the sidebar pane requires tmux" >&2
    exit 1
  }
  tmux set-option -p @sq-sidebar 1 2>/dev/null || true
  tmux set-option -p @sq-sidebar-base "$base" 2>/dev/null || true
  every=$(( (REFRESH_SECS + FRAME_SECS - 1) / FRAME_SECS ))
  [ "$every" -lt 1 ] && every=1
  publish "$base" || true
  while :; do
    n=$((n + 1))
    if (( n % every == 0 )); then
      publish "$base" || true
    fi
    render_pane "$base"
    sleep "$FRAME_SECS"
  done
}

toggle() {  # [BASE]
  local base=$1 existing cmd benv
  base=$(resolve_base "$base")
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the sidebar requires tmux" >&2
    exit 1
  }
  existing=$(tmux list-panes -F '#{pane_id} #{@sq-sidebar}' 2>/dev/null |
    awk '$2 == 1 {print $1; exit}' || true)
  if [ -n "$existing" ]; then
    tmux kill-pane -t "$existing" 2>/dev/null || true
    return 0
  fi
  printf -v cmd '%q' "$SELF"
  tmux split-window -bh -l "$WIDTH" -e "SQ_SIDEBAR_BASE=$base" "$cmd run"
}

click() {  # <line> [BASE]
  local line=${1:-} base=${2:-} n row window
  case "$line" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ "$line" -ge 1 ] || return 0
  n=$(( (line + 1) / LINES_PER_CARD ))
  row=$(cards_lines "$base" | sed -n "${n}p")
  [ -n "$row" ] || return 0
  window=$(printf '%s' "$row" | cut -f1)
  [ -n "$window" ] || return 0
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the click action requires tmux" >&2
    exit 1
  }
  tmux select-window -t "$window" 2>/dev/null || true
}

focus() {  # <window>
  local window=${1:-}
  [ -n "$window" ] || {
    echo "usage: sq-sidebar.sh focus <window>" >&2
    exit 1
  }
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; focus requires tmux" >&2
    exit 1
  }
  tmux select-window -t "$window" 2>/dev/null || true
}

case "${1:-}" in
  cards) cards_lines "${2:-}" ;;
  render) render "${2:-}" ;;
  publish) publish "${2:-}" ;;
  run) run "${2:-}" ;;
  toggle) toggle "${2:-}" ;;
  click) shift; click "${1:-}" "${2:-}" ;;
  focus) shift; focus "${1:-}" ;;
  *)
    echo "usage: sq-sidebar.sh cards|render|publish|run|toggle|click|focus [BASE]" >&2
    exit 1
    ;;
esac
