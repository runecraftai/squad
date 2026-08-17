#!/usr/bin/env bash
# sq-sidebar.sh - Squad Operations Board (workmux-parity tmux sidebar).
#
# Renders a per-operator card sidebar in tmux panes from Squad ground truth.
# The sidebar is a CONSUMER of the ground-truth contract; it never reads
# screens and never maps Squad verbs itself. bin/sq-window-state.sh owns the
# verb -> label translation and publishes state/window-states (its header owns
# the file contract); bin/sq-crew-state.sh owns current-state reconciliation;
# bin/sq-classify-lib.sh owns the status-event vocabulary. This script reads
# state/window-states plus state/<id>.meta, state/<id>.busy-gen, and
# state/<id>.status and renders the sidebar.
#
# GLOBAL SIDEBAR (workmux parity):
# When toggled on, a sidebar pane is created in EVERY tmux window of the
# CURRENT SESSION and a session-scoped hook auto-adds sidebar panes to newly
# created windows in that session. When toggled off, all sidebar panes in the
# session are killed and the hook is removed. The sidebar is session-scoped:
# toggling in one session never affects other concurrent sessions. Every sidebar
# pane renders the same ground-truth data; the pane placement is per-window,
# the data is not.
#
# LAYOUT MODES:
#   tiles (default) - two-line cards with status stripe
#   compact         - one-line per card
# Toggled live with the `v` key in a focused sidebar pane, or `sq-sidebar.sh
# layout` from the command line. Persisted in @sq-sidebar-layout global option.
#
# SIDEBAR-LOCAL NAVIGATION (when the sidebar pane is focused):
#   j/k     navigate down/up
#   Enter   jump to the selected agent's pane
#   g/G     jump to first/last agent
#   v       toggle layout mode (tiles/compact)
#   f       toggle session filter
#   q       close sidebar in current session (with quit confirmation)
#
# SESSION SCOPING:
# The sidebar is session-scoped by construction. All tmux hooks, options, and
# pane operations target the current session only. Global keybindings use
# session-scoped conditionals: sidebar-local keys (j/k/Enter/g/G/v/f/q) are
# intercepted only when the current session has an active sidebar pane. This
# prevents the sidebar from leaking into other concurrent tmux sessions.
#
# Visual model (top to bottom, all sections opt-out via env):
#   rollup   one line per tmux session: its worst (most-actionable) operator
#            state and the operator count
#   INBOX    one two-line card per operator needing attention
#            (awaiting-decision, blocked, failed), most actionable first
#   routine  one two-line card per remaining operator (working, idle, done,
#            unknown), sorted by window target
# In compact mode, each card is one line instead of two.
# A card is exactly two display lines (tiles) or one line (compact); `map` and
# `click` resolve a rendered pane line to its card's window through the same
# frame, so line count and order stay exact even with the section headers.
#
# Card tokens: each card line is a configurable template whose tokens are
# substituted per card (see SQ_SIDEBAR_LINE1 / SQ_SIDEBAR_LINE2 / SQ_SIDEBAR_COMPACT_LINE):
#   {glyph}   the state icon (spinner while working, static otherwise)
#   {id}      the task id, left-padded to 12 columns
#   {label}   the sidebar-facing state label (working, awaiting-decision, ...)
#   {state}   the canonical Squad verb behind the label
#   {detail}  the reconciled prose, or model·effort when there is no prose
#   {elapsed} wall-clock since the busy contract was armed, right-padded to 8
#   {model}   the recorded model tag from meta (raw)
#   {effort}  the recorded effort tag from meta (raw)
#   {unread}  the unread glyph on a done card not yet acknowledged, else empty
#   {window}  the recorded tmux target (session:window)
#   {session} the session part of the window target
# The actionability ordering (failed > blocked > awaiting-decision > unknown >
# working > idle > done) and the INBOX membership set (awaiting-decision,
# blocked, failed) are THIS script's own rendering policy; the ground truth
# only supplies labels.
#
# PANE LIFECYCLE CLEANUP:
# Cards disappear automatically when a mission is torn down: the ground-truth
# file (state/window-states) drops entries whose meta file is gone, so the
# next render no longer shows the card. The sidebar pane itself is killed when
# its host window is killed (standard tmux behavior). No explicit cleanup
# step is needed; the ground-truth contract handles card lifecycle.
#
# Subcommands:
#   cards [BASE]    print one raw TAB-separated record per operator card, in
#                   window order (window, id, label, state, detail, elapsed,
#                   model, effort) - the machine-side/powerkit contract
#   inbox [BASE]    the same records, restricted to attention operators and
#                   sorted most-actionable first
#   render [BASE]   print the display lines with ANSI styling (spinner when
#                   working); SQ_SIDEBAR_NO_COLOR=1 prints plain text
#   map [BASE]      print one window target per rendered line (empty for
#                   headers/separators) so a click resolves any line exactly
#   badge <window> [BASE]  print a colored state icon (+ unread glyph) with no
#                   trailing newline, for a window-status-format tab badge
#   ack [BASE]      mark every currently-done task as acknowledged; prints the
#                   count; the C-M-a keybinding
#   filter [BASE]   cycle the sidebar filter (all -> awaiting-decision ->
#                   blocked -> failed -> working -> idle -> done -> all) and
#                   print the new value; the C-M-f keybinding
#   next-inbox [BASE]  select-window to the next attention operator, cycling;
#                   the C-M-n keybinding
#   publish [BASE]  run bin/sq-window-state.sh publish for the base
#   run [BASE]      the sidebar pane loop: self-tag, publish on the refresh
#                   cadence, re-render every frame until the pane is killed
#   toggle [BASE]   GLOBAL toggle: open a sidebar pane in EVERY tmux window
#                   and hook new-window creation, or close all when active
#   add-pane [BASE]  create a sidebar pane in the current window (called by
#                   the after-new-window hook)
#   layout [BASE]   toggle tiles/compact layout mode; prints new value
#   navigate <direction> [BASE]  move sidebar selection up/down
#   select [BASE]   jump to the selected agent's window
#   first [BASE]    jump to the first agent
#   last [BASE]     jump to the last agent
#   last-done [BASE]  jump to most recently completed/attention operator;
#                   repeated invocations cycle reverse-chronologically
#   last-agent      toggle between current and last visited window (like
#                   vim's Ctrl-^ or tmux's last-window)
#   reap [BASE]     list stale operators (last status older than threshold);
#                   display-only, never wired to recovery actions
#
# SESSION SCOPING:
# All sidebar state is session-scoped: @sq-sidebar-active-<session>,
# @sq-sidebar-session (records which session owns the sidebar pane), hooks
# use -t <session>, and pane cleanup targets only the current session.
#   click <line> [BASE]  focus the operator window whose card occupies pane
#                   line <line> (1-based pane row; the tmux loader passes the
#                   mouse row and the base recorded by run in @sq-sidebar-base)
#   focus <window>  select-window to the given target (exposed for scripts)
#
# BASE resolution: argument > SQ_SIDEBAR_BASE > SQUAD_BASE > SQUAD_HOME >
# this repo root. The renderer, card reader, badge, and publish are tmux-free
# and fully testable against fake state dirs; only toggle/run/click/focus/
# filter/next-inbox/last-done/last-agent need tmux and fail closed with a
# stderr note when missing.
#
# Env: SQUAD_STATE_OVERRIDE selects the state dir (tests); SQUAD_CREW_STATE_BIN
# overrides the reconciler binary for publish (tests); SQ_SIDEBAR_WIDTH (default
# 25), SQ_SIDEBAR_SPINNER (space-separated frame glyphs), SQ_SIDEBAR_REFRESH_SECS
# (publish cadence in run, default 2), SQ_SIDEBAR_FRAME_SECS (render cadence,
# default 1), SQ_SIDEBAR_NOW (epoch; pins the spinner frame for tests),
# SQ_SIDEBAR_ELAPSED_NOW (epoch; pins the elapsed clock for tests),
# SQ_SIDEBAR_NO_COLOR=1 and SQ_SIDEBAR_NO_ELAPSED=1 disable their feature,
# SQ_SIDEBAR_LINE1 / SQ_SIDEBAR_LINE2 (card token templates, defaults below),
# SQ_SIDEBAR_COMPACT_LINE (compact mode token template, default below),
# SQ_SIDEBAR_FILTER (label to restrict cards to, empty or "all" for none),
# SQ_SIDEBAR_UNREAD (default ●), SQ_SIDEBAR_NO_ROLLUP=1, SQ_SIDEBAR_NO_INBOX=1,
# SQ_SIDEBAR_CURRENT (pins the current window for next-inbox tests),
# SQ_SIDEBAR_STALE_THRESHOLD (hours for reap, default 4).
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
UNREAD="${SQ_SIDEBAR_UNREAD:-●}"
# The token templates default through a variable rather than an inline `${:-...}`
# word, because literal braces in an inline default word confuse bash's
# parameter-expansion closing-brace scan.
DEFAULT_LINE1='{glyph} {id}{elapsed}{unread}'
DEFAULT_LINE2='{label} {detail}'
DEFAULT_COMPACT='{glyph} {id} {elapsed} {label} {detail}'
LINE1="${SQ_SIDEBAR_LINE1:-$DEFAULT_LINE1}"
LINE2="${SQ_SIDEBAR_LINE2:-$DEFAULT_LINE2}"
COMPACT_LINE="${SQ_SIDEBAR_COMPACT_LINE:-$DEFAULT_COMPACT}"
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

# truncate <string> <max-chars>: the first <max> UTF-8 characters of <string>,
# never splitting a multibyte glyph mid-sequence. Locale-independent: bytes are
# decoded under a forced C locale, so a C/POSIX locale (GitHub runners default
# to LC_ALL=C) cannot turn cut's -c into byte counting and slice the trailing
# multibyte unread glyph or spinner off a card line.
truncate() {  # <string> <max-chars>
  local out
  [ -n "$1" ] || return 0
  [ "${2:-0}" -gt 0 ] || return 0
  out=$(
    LC_ALL=C
    s=$1
    max=$2
    n=0
    outseg=''
    while [ -n "$s" ] && [ "$n" -lt "$max" ]; do
      printf -v byte '%d' "'${s:0:1}"
      if [ "$byte" -lt 128 ]; then
        extra=0
      elif [ "$byte" -lt 224 ]; then
        extra=1
      elif [ "$byte" -lt 240 ]; then
        extra=2
      else
        extra=3
      fi
      outseg=${outseg}${s:0:$((extra + 1))}
      s=${s:$((extra + 1))}
      n=$((n + 1))
    done
    printf '%s' "$outseg"
  )
  printf '%s' "$out"
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

# state_rank <label>: the sidebar's own actionability ordering, most actionable
# first. This is a rendering policy, not ground truth.
state_rank() {  # <label>
  case "$1" in
    failed) printf '0' ;;
    blocked) printf '1' ;;
    awaiting-decision) printf '2' ;;
    unknown) printf '3' ;;
    working) printf '4' ;;
    idle) printf '5' ;;
    done) printf '6' ;;
    *) printf '7' ;;
  esac
}

# is_inbox_label <label>: 0 when the label is one that needs commander
# attention (the INBOX set), non-zero otherwise.
is_inbox_label() {  # <label>
  case "$1" in
    awaiting-decision | blocked | failed) return 0 ;;
    *) return 1 ;;
  esac
}

session_of() {  # <window> -> the session part before the first ':'
  printf '%s' "${1%%:*}"
}

# unread_for <state-dir> <id> <label>: 1 when a done task is unacknowledged.
unread_for() {  # <state-dir> <id> <label>
  local dir=$1 id=$2 label=$3 ack_mtime status_mtime
  [ "$label" = "done" ] || { printf '0'; return 0; }
  ack_mtime=$(file_mtime "$dir/$id.sidebar-ack")
  status_mtime=$(file_mtime "$dir/$id.status")
  if [ -z "$ack_mtime" ]; then printf '1'; return 0; fi
  if [ -n "$status_mtime" ] && [ "$status_mtime" -gt "$ack_mtime" ]; then
    printf '1'; return 0
  fi
  printf '0'
}

# static_glyph <label>: the always-static state icon (no spinner), used by the
# rollup header and the window-tab badge.
static_glyph() {  # <label>
  case "$1" in
    working) printf '▶' ;;
    awaiting-decision) printf '?' ;;
    blocked) printf '!' ;;
    done) printf '✓' ;;
    idle) printf '-' ;;
    failed) printf '✗' ;;
    *) printf '.' ;;
  esac
}

# glyph_for <label> <now>: spinner frames while working, static glyphs else.
glyph_for() {  # <label> <now>
  case "$1" in
    working) spinner_frame "$2" ;;
    *) static_glyph "$1" ;;
  esac
}

# expand_tokens <template> <window> <id> <label> <state> <detail> <elapsed>
#               <model> <effort> <unread> <glyph>
# Replaces the card tokens in <template> with the given card's values. {id} is
# left-padded to 12, {elapsed} right-padded to 8 when present, {unread} is the
# unread glyph (or empty), and {detail} is the detail prose or model·effort
# when there is none. Values are substituted literally (no shell eval);
# unknown tokens pass through unchanged.
expand_tokens() {  # <template> <window> <id> <label> <state> <detail> <elapsed> <model> <effort> <unread> <glyph>
  local t=$1 window=$2 id=$3 label=$4 state=$5 detail=$6 elapsed=$7 \
        model=$8 effort=$9 unread=${10} glyph=${11}
  local id_pad el_pad unread_str detail_str session glyph_pad
  id_pad=$(printf '%-12s' "$(truncate "$id" 12)")
  glyph_pad=$(printf '%-2s' "$glyph")
  if [ -n "$elapsed" ] && [ "${SQ_SIDEBAR_NO_ELAPSED:-}" != 1 ]; then
    el_pad=$(printf '%8s' "$elapsed")
  else
    el_pad=""
  fi
  if [ "$unread" = 1 ]; then unread_str="$UNREAD"; else unread_str=""; fi
  if [ -n "$detail" ]; then
    detail_str=$detail
  elif [ -n "$model" ] || [ -n "$effort" ]; then
    detail_str="$model${effort:+·$effort}"
  else
    detail_str=""
  fi
  session=$(session_of "$window")
  t=${t//\{glyph\}/$glyph_pad}
  t=${t//\{id\}/$id_pad}
  t=${t//\{label\}/$label}
  t=${t//\{state\}/$state}
  t=${t//\{detail\}/$detail_str}
  t=${t//\{elapsed\}/$el_pad}
  t=${t//\{model\}/$model}
  t=${t//\{effort\}/$effort}
  t=${t//\{unread\}/$unread_str}
  t=${t//\{window\}/$window}
  t=${t//\{session\}/$session}
  printf '%s' "$t"
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

# inbox_lines [BASE]: attention operators (awaiting-decision/blocked/failed),
# most actionable first, same raw record shape as cards_lines.
inbox_lines() {  # [BASE]
  local base=$1 dir ws window id label state detail elapsed model effort rank
  dir=$(state_dir "$base")
  ws="$dir/window-states"
  [ -f "$ws" ] || return 0
  while IFS=$'\t' read -r window id label state detail; do
    [ -n "$window" ] || continue
    is_inbox_label "$label" || continue
    elapsed=$(elapsed_for "$dir" "$id")
    model=$(meta_get "$dir/$id.meta" model)
    effort=$(meta_get "$dir/$id.meta" effort)
    rank=$(state_rank "$label")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rank" "$window" "$id" "$label" "$state" "$detail" "$elapsed" "$model" "$effort"
  done < "$ws" | LC_ALL=C sort -k1,1n -k2,2 | cut -f2-
}

# records [BASE]: every operator as a 10-column record with a leading sort
# key. Inbox records sort first by actionability, routine records after by
# window target, so one sorted pass yields the INBOX-then-routine layout.
# Fields are separated by the unit separator (\x1f), NOT tab: model/effort
# may be empty, and tab-as-IFS collapses empty middle fields on read-back.
records() {  # [BASE] -> sortkey window id label state detail elapsed model effort unread
  local base=$1 dir ws window id label state detail elapsed model effort unread sk
  dir=$(state_dir "$base")
  ws="$dir/window-states"
  [ -f "$ws" ] || return 0
  while IFS=$'\t' read -r window id label state detail; do
    [ -n "$window" ] || continue
    elapsed=$(elapsed_for "$dir" "$id")
    model=$(meta_get "$dir/$id.meta" model)
    effort=$(meta_get "$dir/$id.meta" effort)
    unread=$(unread_for "$dir" "$id" "$label")
    if [ "${SQ_SIDEBAR_NO_INBOX:-}" != 1 ] && is_inbox_label "$label"; then
      sk="0$(printf '%02d' "$(state_rank "$label")")"
    else
      sk="1$window"
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$sk" "$window" "$id" "$label" "$state" "$detail" "$elapsed" "$model" "$effort" "$unread"
  done < "$ws" | LC_ALL=C sort
}

# session_label_pairs [BASE]: session<TAB>label lines sorted by session, the
# input rollup_lines aggregates.
session_label_pairs() {  # [BASE]
  local base=$1 dir ws window id label state detail
  dir=$(state_dir "$base")
  ws="$dir/window-states"
  [ -f "$ws" ] || return 0
  while IFS=$'\t' read -r window id label state detail; do
    [ -n "$window" ] || continue
    printf '%s\t%s\n' "$(session_of "$window")" "$label"
  done < "$ws" | LC_ALL=C sort
}

# rollup_lines [BASE]: session<TAB>worst-label<TAB>count.
rollup_lines() {  # [BASE]
  local base=$1 session prev="" worst="" count=0 label
  while IFS=$'\t' read -r session label; do
    [ -n "$session" ] || continue
    if [ -n "$prev" ] && [ "$session" != "$prev" ]; then
      printf '%s\t%s\t%s\n' "$prev" "$worst" "$count"
      worst=""; count=0
    fi
    prev=$session
    count=$((count + 1))
    if [ -z "$worst" ] || [ "$(state_rank "$label")" -lt "$(state_rank "$worst")" ]; then
      worst=$label
    fi
  done < <(session_label_pairs "$base")
  if [ -n "$prev" ]; then
    printf '%s\t%s\t%s\n' "$prev" "$worst" "$count"
  fi
}

# filter_active <filter>: 0 when the filter restricts to one label.
filter_active() {  # <filter>
  case "${1:-}" in
    '' | all) return 1 ;;
    *) return 0 ;;
  esac
}

# frame_lines [BASE]: the exact physical lines the sidebar shows, one per row,
# as window<TAB>kind<TAB>text. window is the sentinel `-` for non-clickable
# rows; kind is card:<label>, rollup:<label>, header, or sep, so render can
# color each row. Supports both tiles (two-line cards) and compact (one-line
# cards) layouts, selected by SQ_SIDEBAR_LAYOUT or @sq-sidebar-layout.
frame_lines() {  # [BASE]
  local base=$1 now filter dir session wlabel count text glyph layout
  local sk window id label state detail elapsed model effort unread line1 line2
  local inbox_seen=0 routine_seen=0 card_idx=0
  now=${SQ_SIDEBAR_NOW:-$(date +%s)}
  filter=${SQ_SIDEBAR_FILTER:-}
  layout=${SQ_SIDEBAR_LAYOUT:-tiles}
  dir=$(state_dir "$base")
  [ -f "$dir/window-states" ] || return 0

  if [ "${SQ_SIDEBAR_NO_ROLLUP:-}" != 1 ]; then
    while IFS=$'\t' read -r session wlabel count; do
      [ -n "$session" ] || continue
      glyph=$(static_glyph "$wlabel")
      text=$(printf '%s %s %s ops' "$glyph" "$session" "$count")
      printf '%s\t%s\t%s\n' "-" "rollup:$wlabel" "$(truncate "$text" "$((WIDTH - 1))")"
    done < <(rollup_lines "$base")
  fi

  while IFS=$'\x1f' read -r sk window id label state detail elapsed model effort unread; do
    [ -n "$window" ] || continue
    if filter_active "$filter" && [ "$label" != "$filter" ]; then
      continue
    fi
    if is_inbox_label "$label"; then
      if [ "$inbox_seen" = 0 ] && [ "${SQ_SIDEBAR_NO_INBOX:-}" != 1 ]; then
        printf '%s\t%s\t%s\n' "-" "header" "$(truncate '▸ INBOX' "$((WIDTH - 1))")"
      fi
      inbox_seen=1
    else
      if [ "$routine_seen" = 0 ]; then
        if [ "$inbox_seen" = 1 ] && [ "${SQ_SIDEBAR_NO_INBOX:-}" != 1 ]; then
          printf '%s\t%s\t%s\n' "-" "sep" \
            "$(printf '%*s' "$((WIDTH - 1))" '' | tr ' ' '─')"
        fi
        routine_seen=1
      fi
    fi
    glyph=$(glyph_for "$label" "$now")
    if [ "$layout" = "compact" ]; then
      # Compact: one line per card
      line1=$(expand_tokens "$COMPACT_LINE" "$window" "$id" "$label" "$state" "$detail" "$elapsed" "$model" "$effort" "$unread" "$glyph")
      printf '%s\t%s\t%s\n' "$window" "card:$label" "$(truncate "$line1" "$((WIDTH - 1))")"
    else
      # Tiles: two lines per card (default)
      line1=$(expand_tokens "$LINE1" "$window" "$id" "$label" "$state" "$detail" "$elapsed" "$model" "$effort" "$unread" "$glyph")
      line2=$(expand_tokens "$LINE2" "$window" "$id" "$label" "$state" "$detail" "$elapsed" "$model" "$effort" "$unread" "$glyph")
      printf '%s\t%s\t%s\n' "$window" "card:$label" "$(truncate "$line1" "$((WIDTH - 1))")"
      printf '%s\t%s\t%s\n' "$window" "card:$label" "$(truncate "$line2" "$((WIDTH - 1))")"
    fi
  done < <(records "$base")
}

# map [BASE]: one window target per rendered line (a sentinel `-` becomes empty
# for non-card rows).
map() {  # [BASE]
  local base=$1 window kind text
  while IFS=$'\t' read -r window kind text; do
    if [ "$window" = "-" ]; then
      printf '\n'
    else
      printf '%s\n' "$window"
    fi
  done < <(frame_lines "$base")
}

# render [BASE]: ANSI display lines, or the placeholder when there are no rows.
# When SQ_SIDEBAR_SELECTED is set, that card index is highlighted with inverse
# video so the user can see which card navigation would jump to.
render() {  # [BASE]
  local base=$1 out="" window kind text color card_idx=0 selected
  selected=${SQ_SIDEBAR_SELECTED:--1}
  while IFS=$'\t' read -r window kind text; do
    if [ "${SQ_SIDEBAR_NO_COLOR:-}" = 1 ]; then
      if [[ "$kind" == card:* ]] && [ "$card_idx" = "$selected" ]; then
        out="${out}[${text}]"$'\n'
      else
        out="${out}${text}"$'\n'
      fi
    else
      case "$kind" in
        card:*) color=$(label_color "${kind#card:}") ;;
        rollup:*) color=$(label_color "${kind#rollup:}") ;;
        *) color='38;5;244' ;;
      esac
      if [[ "$kind" == card:* ]] && [ "$card_idx" = "$selected" ]; then
        # Inverse video for selected card
        out="${out}"$'\033[7;'"${color}m${text}"$'\033[0m'$'\n'
      else
        out="${out}"$'\033['"${color}m${text}"$'\033[0m'$'\n'
      fi
    fi
    [[ "$kind" == card:* ]] && card_idx=$((card_idx + 1))
  done < <(frame_lines "$base")
  if [ -z "$out" ]; then
    if [ "${SQ_SIDEBAR_NO_COLOR:-}" = 1 ]; then
      printf '%s\n' '-- no Squad operators --'
    else
      printf '\033[38;5;244m-- no Squad operators --\033[0m\n'
    fi
    return 0
  fi
  printf '%s' "$out"
}

# resolve_session: the current tmux session name, or empty when tmux is not
# available. Used by toggle and q handler to scope operations to the current
# session only.
resolve_session() {
  command -v tmux >/dev/null 2>&1 || return 0
  tmux display-message -p '#{session_name}' 2>/dev/null || true
}

# badge <window> [BASE]: a colored state icon for a window-status-format tab,
# with no trailing newline; done+unread prepends the unread glyph.
badge() {  # <window> [BASE]
  local window=${1:-} base=${2:-} dir ws id label state detail row glyph unread
  [ -n "$window" ] || return 0
  dir=$(state_dir "$base")
  ws="$dir/window-states"
  [ -f "$ws" ] || return 0
  row=$(awk -F'\t' -v w="$window" '$1 == w { print; exit }' "$ws")
  [ -n "$row" ] || return 0
  id=$(printf '%s' "$row" | cut -f2)
  label=$(printf '%s' "$row" | cut -f3)
  glyph=$(static_glyph "$label")
  unread=$(unread_for "$dir" "$id" "$label")
  if [ "$unread" = 1 ]; then
    printf '\033[%sm%s%s\033[0m' "$(label_color "$label")" "$UNREAD" "$glyph"
  else
    printf '\033[%sm%s\033[0m' "$(label_color "$label")" "$glyph"
  fi
}

# ack [BASE]: write state/<id>.sidebar-ack for every done task; print count.
ack() {  # [BASE]
  local base=$1 dir ws window id label state detail count=0
  dir=$(state_dir "$base")
  ws="$dir/window-states"
  [ -f "$ws" ] || { printf '0\n'; return 0; }
  while IFS=$'\t' read -r window id label state detail; do
    [ -n "$window" ] || continue
    [ "$label" = "done" ] || continue
    printf '%s\n' "$(date +%s)" > "$dir/$id.sidebar-ack"
    count=$((count + 1))
  done < "$ws"
  printf '%d\n' "$count"
}

# filter_next <current>: the next filter in the cycle.
filter_next() {  # <current>
  case "${1:-}" in
    '' | all) printf 'awaiting-decision' ;;
    awaiting-decision) printf 'blocked' ;;
    blocked) printf 'failed' ;;
    failed) printf 'working' ;;
    working) printf 'idle' ;;
    idle) printf 'done' ;;
    done) printf 'all' ;;
    *) printf 'all' ;;
  esac
}

# inbox_next [BASE] <current>: the next attention window target after <current>
# (cycling), or the first when <current> is not in the set; empty when none.
inbox_next() {  # [BASE] <current>
  local base=$1 current=$2 i=0 found=-1 idx=0 w
  local -a windows=()
  while IFS=$'\t' read -r w _; do
    [ -n "$w" ] || continue
    windows+=("$w")
  done < <(inbox_lines "$base")
  if [ "${#windows[@]}" -eq 0 ]; then return 0; fi
  for w in "${windows[@]}"; do
    if [ "$w" = "$current" ]; then found=$i; break; fi
    i=$((i + 1))
  done
  if [ "$found" -ge 0 ]; then
    idx=$(( (found + 1) % ${#windows[@]} ))
  fi
  printf '%s' "${windows[$idx]}"
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

# card_count [BASE]: count the total number of cards in the frame (respecting
# filter). Used by navigate to clamp the selected index.
card_count() {  # [BASE]
  local base=$1 count=0 window kind text
  while IFS=$'\t' read -r window kind text; do
    [[ "$kind" == card:* ]] && count=$((count + 1))
  done < <(frame_lines "$base")
  printf '%d' "$count"
}

# card_window_at [BASE] <index>: the window target of the card at the given
# 0-based index in the frame. Empty if the index is out of range.
card_window_at() {  # [BASE] <index>
  local base=$1 target=$2 idx=0 window kind text
  while IFS=$'\t' read -r window kind text; do
    [[ "$kind" == card:* ]] || continue
    if [ "$idx" = "$target" ]; then
      printf '%s' "$window"
      return 0
    fi
    idx=$((idx + 1))
  done < <(frame_lines "$base")
}

# last_done_windows [BASE]: attention + recently-done windows, sorted by
# status-log mtime descending (most recent first). Used by last-done to
# cycle through operators needing attention.
last_done_windows() {  # [BASE]
  local base=$1 dir ws window id label state detail mtime
  dir=$(state_dir "$base")
  ws="$dir/window-states"
  [ -f "$ws" ] || return 0
  while IFS=$'\t' read -r window id label state detail; do
    [ -n "$window" ] || continue
    # Include attention operators and recently done ones
    if is_inbox_label "$label" || [ "$label" = "done" ]; then
      mtime=$(file_mtime "$dir/$id.status")
      [ -n "$mtime" ] || mtime=0
      printf '%s\t%s\t%s\n' "$mtime" "$window" "$label"
    fi
  done < "$ws" | LC_ALL=C sort -k1,1rn -k2,2 | cut -f2-
}

run() {  # [BASE]: the sidebar pane loop; killed with the pane
  local base=$1 every n=0 filter no_rollup no_inbox layout key selected count session
  base=$(resolve_base "$base")
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the sidebar pane requires tmux" >&2
    exit 1
  }
  session=$(resolve_session)
  tmux set-option -p @sq-sidebar 1 2>/dev/null || true
  tmux set-option -p @sq-sidebar-base "$base" 2>/dev/null || true
  if [ -n "${SQ_SIDEBAR_NO_ROLLUP:-}" ]; then
    tmux set-option -g @sq-sidebar-no-rollup "$SQ_SIDEBAR_NO_ROLLUP" 2>/dev/null || true
  fi
  if [ -n "${SQ_SIDEBAR_NO_INBOX:-}" ]; then
    tmux set-option -g @sq-sidebar-no-inbox "$SQ_SIDEBAR_NO_INBOX" 2>/dev/null || true
  fi
  every=$(( (REFRESH_SECS + FRAME_SECS - 1) / FRAME_SECS ))
  [ "$every" -lt 1 ] && every=1
  publish "$base" || true
  while :; do
    n=$((n + 1))
    if (( n % every == 0 )); then
      publish "$base" || true
    fi
    filter=$(tmux show-option -gv @sq-sidebar-filter 2>/dev/null || true)
    no_rollup=${SQ_SIDEBAR_NO_ROLLUP:-$(tmux show-option -gv @sq-sidebar-no-rollup 2>/dev/null || true)}
    no_inbox=${SQ_SIDEBAR_NO_INBOX:-$(tmux show-option -gv @sq-sidebar-no-inbox 2>/dev/null || true)}
    layout=$(tmux show-option -gv @sq-sidebar-layout 2>/dev/null || echo "tiles")
    selected=$(tmux show-option -gv -t "$session" @sq-sidebar-selected 2>/dev/null || echo "-1")
    SQ_SIDEBAR_FILTER="$filter" SQ_SIDEBAR_NO_ROLLUP="$no_rollup" \
      SQ_SIDEBAR_NO_INBOX="$no_inbox" SQ_SIDEBAR_LAYOUT="$layout" \
      SQ_SIDEBAR_SELECTED="$selected" render_pane "$base"
    # Read a keypress with timeout; sidebar-local navigation keys
    read -r -t "$FRAME_SECS" -n 1 key 2>/dev/null || true
    case "${key:-}" in
      j) # navigate down
        count=$(SQ_SIDEBAR_FILTER="$filter" SQ_SIDEBAR_NO_ROLLUP="$no_rollup" \
          SQ_SIDEBAR_NO_INBOX="$no_inbox" SQ_SIDEBAR_LAYOUT="$layout" \
          card_count "$base")
        if [ "$count" -gt 0 ]; then
          if [ "$selected" -lt 0 ] || [ "$selected" -ge $((count - 1)) ]; then
            selected=0
          else
            selected=$((selected + 1))
          fi
          tmux set-option -t "$session" @sq-sidebar-selected "$selected" 2>/dev/null || true
        fi
        ;;
      k) # navigate up
        count=$(SQ_SIDEBAR_FILTER="$filter" SQ_SIDEBAR_NO_ROLLUP="$no_rollup" \
          SQ_SIDEBAR_NO_INBOX="$no_inbox" SQ_SIDEBAR_LAYOUT="$layout" \
          card_count "$base")
        if [ "$count" -gt 0 ]; then
          if [ "$selected" -le 0 ]; then
            selected=$((count - 1))
          else
            selected=$((selected - 1))
          fi
          tmux set-option -t "$session" @sq-sidebar-selected "$selected" 2>/dev/null || true
        fi
        ;;
      g) # jump to first
        count=$(SQ_SIDEBAR_FILTER="$filter" SQ_SIDEBAR_NO_ROLLUP="$no_rollup" \
          SQ_SIDEBAR_NO_INBOX="$no_inbox" SQ_SIDEBAR_LAYOUT="$layout" \
          card_count "$base")
        if [ "$count" -gt 0 ]; then
          selected=0
          tmux set-option -t "$session" @sq-sidebar-selected "$selected" 2>/dev/null || true
        fi
        ;;
      G) # jump to last
        count=$(SQ_SIDEBAR_FILTER="$filter" SQ_SIDEBAR_NO_ROLLUP="$no_rollup" \
          SQ_SIDEBAR_NO_INBOX="$no_inbox" SQ_SIDEBAR_LAYOUT="$layout" \
          card_count "$base")
        if [ "$count" -gt 0 ]; then
          selected=$((count - 1))
          tmux set-option -t "$session" @sq-sidebar-selected "$selected" 2>/dev/null || true
        fi
        ;;
      '') # no keypress, just re-render ;;
        ;;
      v) # toggle layout
        if [ "$layout" = "tiles" ]; then
          tmux set-option -g @sq-sidebar-layout "compact" 2>/dev/null || true
        else
          tmux set-option -g @sq-sidebar-layout "tiles" 2>/dev/null || true
        fi
        ;;
      f) # toggle filter
        filter=$(SQ_SIDEBAR_BASE="$base" "$SELF" filter 2>/dev/null || true)
        ;;
      q) # quit sidebar (session-scoped)
        local q_session
        q_session=$(resolve_session)
        if [ -n "$q_session" ]; then
          # Kill sidebar panes in THIS session only
          tmux list-panes -t "$q_session" -F '#{pane_id} #{@sq-sidebar}' 2>/dev/null |
            awk '$2 == 1 {print $1}' | while read -r pane; do
              tmux kill-pane -t "$pane" 2>/dev/null || true
            done
          tmux set-hook -t "$q_session" -u after-new-window 2>/dev/null || true
          tmux set-option -t "$q_session" -u @sq-sidebar-active-"$q_session" 2>/dev/null || true
          tmux set-option -t "$q_session" -u @sq-sidebar-session 2>/dev/null || true
          tmux set-option -t "$q_session" -u @sq-sidebar-selected 2>/dev/null || true
        fi
        exit 0
        ;;
      $'\n'|$'\r') # Enter - jump to selected agent
        if [ "$selected" -ge 0 ]; then
          local target
          target=$(SQ_SIDEBAR_FILTER="$filter" SQ_SIDEBAR_NO_ROLLUP="$no_rollup" \
            SQ_SIDEBAR_NO_INBOX="$no_inbox" SQ_SIDEBAR_LAYOUT="$layout" \
            card_window_at "$base" "$selected")
          [ -n "$target" ] && tmux select-window -t "$target" 2>/dev/null || true
        fi
        ;;
    esac
    key=""
  done
}

# toggle [BASE]: SESSION-SCOPED sidebar toggle. When active in the current
# session, kills all sidebar panes in that session and removes the session
# hook. When inactive, creates sidebar panes in ALL windows of the current
# session and installs a session-scoped hook for new windows.
toggle() {  # [BASE]
  local base=$1
  base=$(resolve_base "$base")
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the sidebar requires tmux" >&2
    exit 1
  }

  local session
  session=$(resolve_session)
  [ -n "$session" ] || {
    echo "sq-sidebar: cannot resolve current session" >&2
    exit 1
  }

  # Check if sidebar is active in THIS session (not globally)
  local session_active
  session_active=$(tmux show-option -gv @sq-sidebar-active-"$session" 2>/dev/null || true)

  if [ "$session_active" = "1" ]; then
    # Toggle OFF: kill sidebar panes in THIS session only, remove session hook
    tmux list-panes -t "$session" -F '#{pane_id} #{@sq-sidebar}' 2>/dev/null |
      awk '$2 == 1 {print $1}' | while read -r pane; do
        tmux kill-pane -t "$pane" 2>/dev/null || true
      done
    tmux set-hook -t "$session" -u after-new-window 2>/dev/null || true
    tmux set-option -t "$session" -u @sq-sidebar-active-"$session" 2>/dev/null || true
    tmux set-option -t "$session" -u @sq-sidebar-session 2>/dev/null || true
    tmux set-option -t "$session" -u @sq-sidebar-selected 2>/dev/null || true
    return 0
  fi

  # Toggle ON: set session option and install session-scoped hook
  tmux set-option -t "$session" @sq-sidebar-active-"$session" 1
  tmux set-option -t "$session" @sq-sidebar-session "$session"
  tmux set-option -t "$session" @sq-sidebar-base "$base"
  tmux set-option -t "$session" @sq-sidebar-selected -1
  # Session-scoped hook: only fires for windows created in THIS session
  tmux set-hook -t "$session" after-new-window "run-shell '#{q:@sq-sidebar-path} add-pane #{q:@sq-sidebar-base}'"

  # Create sidebar panes in all existing windows of THIS session
  tmux list-windows -t "$session" -F '#{session_name}:#{window_index}' 2>/dev/null | while read -r win; do
    # Skip if this window already has a sidebar pane
    local existing
    existing=$(tmux list-panes -t "$win" -F '#{@sq-sidebar}' 2>/dev/null | grep -c '^1$' || true)
    if [ "$existing" -gt 0 ]; then
      continue
    fi
    # Create sidebar pane in this window
    tmux split-window -t "$win" -h -p 17 -e "SQ_SIDEBAR_BASE=$base" "$SELF run" 2>/dev/null || true
  done
}

# add-pane [BASE]: create a sidebar pane in the current window. Called by the
# after-new-window hook so new windows automatically get a sidebar pane.
add_pane() {  # [BASE]
  local base=$1
  base=$(resolve_base "$base")
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; add-pane requires tmux" >&2
    exit 1
  }
  # Check if this window already has a sidebar pane
  local existing
  existing=$(tmux list-panes -F '#{@sq-sidebar}' 2>/dev/null | grep -c '^1$' || true)
  if [ "$existing" -gt 0 ]; then
    return 0
  fi
  tmux split-window -h -p 17 -e "SQ_SIDEBAR_BASE=$base" "$SELF run" 2>/dev/null || true
}

# layout [BASE]: toggle tiles/compact layout mode; prints the new value.
layout_toggle() {  # [BASE]
  local cur next
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the layout key requires tmux" >&2
    exit 1
  }
  cur=$(tmux show-option -gv @sq-sidebar-layout 2>/dev/null || echo "tiles")
  if [ "$cur" = "tiles" ]; then
    next="compact"
  else
    next="tiles"
  fi
  tmux set-option -g @sq-sidebar-layout "$next" 2>/dev/null || true
  printf '%s\n' "$next"
}

# navigate <direction> [BASE]: move sidebar selection up/down.
navigate() {  # <direction> [BASE]
  local direction=${1:-} base=${2:-}
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; navigate requires tmux" >&2
    exit 1
  }
  base=$(resolve_base "$base")
  local session selected count filter no_rollup no_inbox layout
  session=$(resolve_session)
  selected=$(tmux show-option -gv -t "$session" @sq-sidebar-selected 2>/dev/null || echo "-1")
  filter=$(tmux show-option -gv @sq-sidebar-filter 2>/dev/null || true)
  no_rollup=$(tmux show-option -gv @sq-sidebar-no-rollup 2>/dev/null || true)
  no_inbox=$(tmux show-option -gv @sq-sidebar-no-inbox 2>/dev/null || true)
  layout=$(tmux show-option -gv @sq-sidebar-layout 2>/dev/null || echo "tiles")
  count=$(SQ_SIDEBAR_FILTER="$filter" SQ_SIDEBAR_NO_ROLLUP="$no_rollup" \
    SQ_SIDEBAR_NO_INBOX="$no_inbox" SQ_SIDEBAR_LAYOUT="$layout" \
    card_count "$base")
  if [ "$count" -eq 0 ]; then return 0; fi
  case "$direction" in
    down)
      if [ "$selected" -lt 0 ] || [ "$selected" -ge $((count - 1)) ]; then
        selected=0
      else
        selected=$((selected + 1))
      fi
      ;;
    up)
      if [ "$selected" -le 0 ]; then
        selected=$((count - 1))
      else
        selected=$((selected - 1))
      fi
      ;;
    *)
      echo "usage: sq-sidebar.sh navigate <up|down> [BASE]" >&2
      exit 1
      ;;
  esac
  tmux set-option -t "$session" @sq-sidebar-selected "$selected" 2>/dev/null || true
}

# select [BASE]: jump to the selected agent's window.
select_agent() {  # [BASE]
  local base=$1
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; select requires tmux" >&2
    exit 1
  }
  base=$(resolve_base "$base")
  local session selected filter no_rollup no_inbox layout target
  session=$(resolve_session)
  selected=$(tmux show-option -gv -t "$session" @sq-sidebar-selected 2>/dev/null || echo "-1")
  if [ "$selected" -lt 0 ]; then return 0; fi
  filter=$(tmux show-option -gv @sq-sidebar-filter 2>/dev/null || true)
  no_rollup=$(tmux show-option -gv @sq-sidebar-no-rollup 2>/dev/null || true)
  no_inbox=$(tmux show-option -gv @sq-sidebar-no-inbox 2>/dev/null || true)
  layout=$(tmux show-option -gv @sq-sidebar-layout 2>/dev/null || echo "tiles")
  target=$(SQ_SIDEBAR_FILTER="$filter" SQ_SIDEBAR_NO_ROLLUP="$no_rollup" \
    SQ_SIDEBAR_NO_INBOX="$no_inbox" SQ_SIDEBAR_LAYOUT="$layout" \
    card_window_at "$base" "$selected")
  [ -n "$target" ] && tmux select-window -t "$target" 2>/dev/null || true
}

# first [BASE]: jump to the first agent.
jump_first() {  # [BASE]
  local base=$1
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; first requires tmux" >&2
    exit 1
  }
  base=$(resolve_base "$base")
  local target
  target=$(SQ_SIDEBAR_NO_ROLLUP=1 SQ_SIDEBAR_NO_INBOX=1 card_window_at "$base" 0)
  [ -n "$target" ] && tmux select-window -t "$target" 2>/dev/null || true
}

# last [BASE]: jump to the last agent.
jump_last() {  # [BASE]
  local base=$1
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; last requires tmux" >&2
    exit 1
  }
  base=$(resolve_base "$base")
  local count target
  count=$(SQ_SIDEBAR_NO_ROLLUP=1 SQ_SIDEBAR_NO_INBOX=1 card_count "$base")
  if [ "$count" -gt 0 ]; then
    target=$(SQ_SIDEBAR_NO_ROLLUP=1 SQ_SIDEBAR_NO_INBOX=1 card_window_at "$base" $((count - 1)))
    [ -n "$target" ] && tmux select-window -t "$target" 2>/dev/null || true
  fi
}

# last-done [BASE]: jump to the most recently completed or attention-needing
# operator. Repeated invocations cycle through all such operators in reverse
# chronological order (most recent status-log mtime first).
last_done() {  # [BASE]
  local base=$1 current next
  base=$(resolve_base "$base")
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; last-done requires tmux" >&2
    exit 1
  }
  current=${SQ_SIDEBAR_CURRENT:-$(tmux display-message -p '#{session_name}:#{window_name}' 2>/dev/null || true)}
  # Get the list of attention/done windows sorted by recency
  local -a windows=()
  while IFS=$'\t' read -r w _; do
    [ -n "$w" ] || continue
    windows+=("$w")
  done < <(last_done_windows "$base")
  if [ "${#windows[@]}" -eq 0 ]; then return 0; fi
  local i=0 found=-1 idx=0
  for w in "${windows[@]}"; do
    if [ "$w" = "$current" ]; then found=$i; break; fi
    i=$((i + 1))
  done
  if [ "$found" -ge 0 ]; then
    idx=$(( (found + 1) % ${#windows[@]} ))
  fi
  tmux select-window -t "${windows[$idx]}" 2>/dev/null || true
}

# last-agent: toggle between the current window and the last one visited.
# Like vim's Ctrl-^ or tmux's last-window, but remembers across session
# switches. Uses @sq-sidebar-last-window to track the previous window.
last_agent() {
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; last-agent requires tmux" >&2
    exit 1
  }
  local current last_window
  current=$(tmux display-message -p '#{session_name}:#{window_name}' 2>/dev/null || true)
  last_window=$(tmux show-option -gv @sq-sidebar-last-window 2>/dev/null || true)
  if [ -n "$last_window" ] && [ "$last_window" != "$current" ]; then
    tmux set-option -g @sq-sidebar-last-window "$current" 2>/dev/null || true
    tmux select-window -t "$last_window" 2>/dev/null || true
  fi
}

# reap [BASE]: list operators whose last status update is older than
# SQ_SIDEBAR_STALE_THRESHOLD hours. Display-only; never wired to recovery
# actions. The sentry's own stale-detection is separate and owns real recovery.
reap() {  # [BASE]
  local base=$1 dir ws now threshold_secs
  dir=$(state_dir "$base")
  ws="$dir/window-states"
  [ -f "$ws" ] || return 0
  now=${SQ_SIDEBAR_ELAPSED_NOW:-$(date +%s)}
  threshold_secs=$(( ${SQ_SIDEBAR_STALE_THRESHOLD:-4} * 3600 ))
  printf '%-12s %-20s %-12s %s\n' "ID" "WINDOW" "LABEL" "STALE_FOR"
  printf '%-12s %-20s %-12s %s\n' "----" "------" "-----" "---------"
  local found=0
  while IFS=$'\t' read -r window id label state detail; do
    [ -n "$window" ] || continue
    local mtime diff h m s stale_str
    mtime=$(file_mtime "$dir/$id.status")
    [ -n "$mtime" ] || mtime=$(file_mtime "$dir/$id.meta")
    [ -n "$mtime" ] || continue
    diff=$((now - mtime))
    if [ "$diff" -ge "$threshold_secs" ]; then
      h=$((diff / 3600)); m=$(((diff % 3600) / 60)); s=$((diff % 60))
      stale_str=$(printf '%02d:%02d:%02d' "$h" "$m" "$s")
      printf '%-12s %-20s %-12s %s\n' "$(truncate "$id" 12)" "$(truncate "$window" 20)" "$label" "$stale_str"
      found=1
    fi
  done < "$ws"
  if [ "$found" = "0" ]; then
    printf '(no stale operators)\n'
  fi
}

click() {  # <line> [BASE]
  local line=${1:-} base=${2:-} window
  case "$line" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ "$line" -ge 1 ] || return 0
  if command -v tmux >/dev/null 2>&1; then
    SQ_SIDEBAR_FILTER=$(tmux show-option -gv @sq-sidebar-filter 2>/dev/null || true)
    SQ_SIDEBAR_NO_ROLLUP=$(tmux show-option -gv @sq-sidebar-no-rollup 2>/dev/null || true)
    SQ_SIDEBAR_NO_INBOX=$(tmux show-option -gv @sq-sidebar-no-inbox 2>/dev/null || true)
    SQ_SIDEBAR_LAYOUT=$(tmux show-option -gv @sq-sidebar-layout 2>/dev/null || echo "tiles")
    export SQ_SIDEBAR_FILTER SQ_SIDEBAR_NO_ROLLUP SQ_SIDEBAR_NO_INBOX SQ_SIDEBAR_LAYOUT
  fi
  window=$(map "$base" | sed -n "${line}p")
  [ -n "$window" ] || return 0
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the click action requires tmux" >&2
    exit 1
  }
  # Track last window for last-agent
  local current
  current=$(tmux display-message -p '#{session_name}:#{window_name}' 2>/dev/null || true)
  tmux set-option -g @sq-sidebar-last-window "$current" 2>/dev/null || true
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

filter() {  # cycle the global filter, print the new value (no base needed)
  local cur next
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the filter key requires tmux" >&2
    exit 1
  }
  cur=$(tmux show-option -gv @sq-sidebar-filter 2>/dev/null || true)
  next=$(filter_next "$cur")
  tmux set-option -g @sq-sidebar-filter "$next" 2>/dev/null || true
  printf '%s\n' "$next"
}

next_inbox() {  # [BASE]: focus the next attention operator window
  local base=$1 current next
  base=$(resolve_base "$base")
  command -v tmux >/dev/null 2>&1 || {
    echo "sq-sidebar: tmux not found; the next-inbox key requires tmux" >&2
    exit 1
  }
  current=${SQ_SIDEBAR_CURRENT:-$(tmux display-message -p '#{session_name}:#{window_name}' 2>/dev/null || true)}
  next=$(inbox_next "$base" "$current")
  [ -n "$next" ] || return 0
  tmux select-window -t "$next" 2>/dev/null || true
}

case "${1:-}" in
  cards) cards_lines "${2:-}" ;;
  inbox) inbox_lines "${2:-}" ;;
  render) render "${2:-}" ;;
  map) map "${2:-}" ;;
  badge) shift; badge "${1:-}" "${2:-}" ;;
  ack) ack "${2:-}" ;;
  filter) filter ;;
  next-inbox) next_inbox "${2:-}" ;;
  publish) publish "${2:-}" ;;
  run) run "${2:-}" ;;
  toggle) toggle "${2:-}" ;;
  add-pane) add_pane "${2:-}" ;;
  layout) layout_toggle ;;
  navigate) shift; navigate "${1:-}" "${2:-}" ;;
  select) select_agent "${2:-}" ;;
  first) jump_first "${2:-}" ;;
  last) jump_last "${2:-}" ;;
  last-done) last_done "${2:-}" ;;
  last-agent) last_agent ;;
  reap) reap "${2:-}" ;;
  click) shift; click "${1:-}" "${2:-}" ;;
  focus) shift; focus "${1:-}" ;;
  *)
    echo "usage: sq-sidebar.sh cards|inbox|render|map|badge|ack|filter|next-inbox|publish|run|toggle|add-pane|layout|navigate|select|first|last|last-done|last-agent|reap|click|focus [BASE]" >&2
echo "  Squad Operations Board - tmux sidebar for operator monitoring" >&2
    exit 1
    ;;
esac
