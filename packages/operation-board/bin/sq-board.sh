#!/usr/bin/env bash
# sq-board.sh - mission-planning board combining backlog + live operational state.
#
# Reads Squad's durable state and renders a formatted board of missions/operations:
#   - data/backlog.md (task queue, parsed directly from markdown)
#   - state/<id>.meta (window, worktree, harness, model, effort, mode, kind, backend)
#   - state/window-states (per-window ground truth: label, state, detail)
#   - state/<id>.status (bounded tail for latest status event per task)
#
# Output modes:
#   (default)   formatted terminal table grouped by backlog section
#   --json      machine-readable JSON array
#   --compact   one line per mission (for piping / quick glance)
#
# Naming: "sq-board" (short, follows sq-* convention).
# Package name: "operation-board" (commander's choice).
set -euo pipefail

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SELF")"

# Resolve Squad base by walking up from this script
find_squad_root() {
  local dir="$SCRIPT_DIR"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/AGENTS.md" ] && [ -d "$dir/bin" ] && [ -d "$dir/state" ] 2>/dev/null; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-$(find_squad_root || echo "")}}"
if [ -z "$SQUAD_BASE" ]; then
  echo "sq-board: cannot locate Squad base (set SQUAD_BASE or run from inside a Squad repo)" >&2
  exit 1
fi

BACKLOG="${SQUAD_BACKLOG:-$SQUAD_BASE/data/backlog.md}"
STATE_DIR="$SQUAD_BASE/state"

# --- Colors (disabled when not a terminal) ---
if [ -t 1 ]; then
  RST='\033[0m' B='\033[1m' DIM='\033[2m'
  RED='\033[31m' GRN='\033[32m' YLW='\033[33m'
  BLU='\033[34m' MAG='\033[35m' CYN='\033[36m'
else
  RST='' B='' DIM='' RED='' GRN='' YLW='' BLU='' MAG='' CYN=''
fi

# --- Parse arguments ---
MODE="table"
FILTER_STATE=""
FILTER_KIND=""
SHOW_DONE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --json)       MODE="json"; shift ;;
    --compact)    MODE="compact"; shift ;;
    --state)      FILTER_STATE="$2"; shift 2
                  [ "$FILTER_STATE" = "done" ] && SHOW_DONE=true ;;
    --kind)       FILTER_KIND="$2"; shift 2 ;;
    --with-done)  SHOW_DONE=true; shift ;;
    --help|-h)
      cat >&2 <<'EOF'
usage: sq-board.sh [--json|--compact] [--state <s>] [--kind <k>] [--with-done]

Mission-planning board: combines backlog queue with live operational state.

Output modes:
  (default)    formatted terminal table grouped by section
  --json       machine-readable JSON array
  --compact    one line per mission

Filters:
  --state <s>       filter by state (in_flight, held, queued, done)
  --kind <k>        filter by kind (strike, recon, commander, ops, docs)
  --with-done       include done items (excluded by default)

Env: SQUAD_BASE, SQUAD_BACKLOG
EOF
      exit 0
      ;;
    *) echo "sq-board: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- Helpers ---

meta_field() {
  local f="$STATE_DIR/$1.meta"
  [ -f "$f" ] && grep "^${2}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- || true
}

last_status() {
  local f="$STATE_DIR/$1.status"
  [ -f "$f" ] && tail -1 "$f" 2>/dev/null || true
}

ws_for() {
  if [ -f "$STATE_DIR/window-states" ]; then
    awk -F'\t' -v id="$1" '$2==id{print $3"\t"$4"\t"$5; found=1; exit} END{if(!found)print "\t\t"}' "$STATE_DIR/window-states"
  else
    printf '\t\t'
  fi
}

busy_elapsed() {
  local f="$STATE_DIR/$1.busy-gen"
  if [ ! -f "$f" ]; then
    local mfile="$STATE_DIR/$1.meta"
    grep -q '^busy_gen=' "$mfile" 2>/dev/null || return 0
    f="$mfile"
  fi
  local mtime now diff
  mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "")
  [ -n "$mtime" ] || return 0
  now=$(date +%s)
  diff=$((now - mtime))
  if [ "$diff" -lt 60 ]; then echo "${diff}s"
  elif [ "$diff" -lt 3600 ]; then echo "$((diff / 60))m"
  else echo "$((diff / 3600))h$((diff % 3600 / 60))m"
  fi
}

icon_for() {
  case "$1" in
    working)           printf "${GRN}⠋${RST}" ;;
    awaiting-decision) printf "${YLW}◆${RST}" ;;
    blocked)           printf "${RED}✖${RST}" ;;
    done)              printf "${GRN}✓${RST}" ;;
    idle)              printf "${DIM}◌${RST}" ;;
    failed)            printf "${RED}✗${RST}" ;;
    *)                 printf "${DIM}·${RST}" ;;
  esac
}

badge_for() {
  case "$1" in
    strike)     printf "${RED}◆${RST}" ;;
    recon)      printf "${BLU}◇${RST}" ;;
    commander)  printf "${YLW}★${RST}" ;;
    ops)        printf "${GRN}⚙${RST}" ;;
    docs)       printf "${CYN}✎${RST}" ;;
    *)          printf "${DIM}·${RST}" ;;
  esac
}

section_label() {
  case "$1" in
    in_flight)  printf "${GRN}▶ IN FLIGHT${RST}" ;;
    held)       printf "${YLW}◆ HELD${RST}" ;;
    queued)     printf "${CYN}■ QUEUED${RST}" ;;
    done)       printf "${DIM}✓ DONE${RST}" ;;
    *)          printf "$1" ;;
  esac
}

# --- Data collection: parse backlog.md directly ---
collect_board() {
  local sec="queued"
  local out
  out=$(mktemp)

  while IFS= read -r line; do
    # Detect section headers
    case "$line" in
      "## In flight"*) sec="in_flight"; continue ;;
      "## Queued"*)     sec="queued"; continue ;;
      "## Done"*)       sec="done"; continue ;;
    esac

    # Only process task lines: checkbox bullets (- [ ]/- [x]) or legacy
    # in-flight bullets (- **id** -)
    printf '%s' "$line" | grep -Eq '^- \[.\] |^- \*\*[A-Za-z0-9][A-Za-z0-9._-]*\*\* - ' || continue

    # Held is per-item derived state: any non-done item carrying a hold tag
    local st="$sec"
    if [ "$sec" != "done" ] && printf '%s' "$line" | grep -qE '\(hold(-kind|-until)?:'; then
      st="held"
    fi

    # Apply state filter
    [ -n "$FILTER_STATE" ] && [ "$st" != "$FILTER_STATE" ] && continue
    [ "$SHOW_DONE" = false ] && [ "$sec" = "done" ] && continue

    # Parse: - [ ] id - title (repo: X) (kind: Y) ... (or - **id** - ...)
    local id rest kind repo

    if printf '%s' "$line" | grep -q '^- \*\*'; then
      id=$(printf '%s' "$line" | sed -E 's/^- \*\*([A-Za-z0-9][A-Za-z0-9._-]*)\*\* -.*/\1/')
      rest=$(printf '%s' "$line" | sed -E 's/^- \*\*[^*]+\*\* - //')
    else
      id=$(printf '%s' "$line" | sed 's/^- \[.\] \([^ ]*\) -.*/\1/')
      rest=$(printf '%s' "$line" | sed 's/^- \[.\] [^ ]* - //')
    fi

    # Extract kind: (kind: X) tag, else legacy leading kind word, else meta kind=
    kind=$(printf '%s' "$rest" | grep -oP '\(kind: \K[^)]+' 2>/dev/null || echo "-")
    if [ "$kind" = "-" ]; then
      case "$rest" in
        SHIP*)      kind="strike" ;;
        SCOUT*)     kind="recon" ;;
        DOCS-ONLY*) kind="docs" ;;
      esac
    fi
    if [ "$kind" = "-" ]; then
      kind=$(meta_field "$id" "kind")
      [ -n "$kind" ] || kind="-"
    fi

    # Apply kind filter
    [ -n "$FILTER_KIND" ] && [ "$kind" != "$FILTER_KIND" ] && continue

    # Extract repo from (repo: X)
    repo=$(printf '%s' "$rest" | grep -oP '\(repo: \K[^)]+' 2>/dev/null || echo "-")

    # Extract title: between "id - " and metadata tags
    # Metadata tags: (repo: X), (kind: X), (since DATE), (priority: N), (hold: ...), etc.
    title=$(printf '%s' "$rest" | sed -E 's/ \(repo: [^)]*\)//; s/ \(kind: [^)]*\)//; s/ \(since [^)]*\)//; s/ \(priority: [^)]*\)//; s/ \(hold: [^)]*\)//; s/ \(hold-kind: [^)]*\)//; s/ \(hold-until: [^)]*\)//; s/ \(blocked-by: [^)]*\)//; s/ \(start: [^)]*\)//' | head -c 200)

    # Sanitize: collapse tabs/newlines in title to spaces, truncate by characters
    title=$(printf '%s' "$title" | tr '\t\n' '  ' | cut -c1-160)

    # Enrich with live state
    local model effort mode backend window
    model=$(meta_field "$id" "model")
    effort=$(meta_field "$id" "effort")
    mode=$(meta_field "$id" "mode")
    backend=$(meta_field "$id" "backend")
    window=$(meta_field "$id" "window")

    # Window-states
    local ws_data ws_label ws_state ws_detail
    ws_data=$(ws_for "$id")
    ws_label=$(printf '%s' "$ws_data" | cut -f1)
    ws_state=$(printf '%s' "$ws_data" | cut -f2)
    ws_detail=$(printf '%s' "$ws_data" | cut -f3)

    # Last status event + busy elapsed
    local status_event elapsed
    status_event=$(last_status "$id")
    elapsed=$(busy_elapsed "$id")

    # Sanitize detail and status for TSV safety (collapse tabs/newlines, truncate)
    ws_detail=$(printf '%s' "$ws_detail" | tr '\t\n' '  ' | cut -c1-200)
    status_event=$(printf '%s' "$status_event" | tr '\t\n' '  ' | cut -c1-200)

    # US: id state kind repo title model effort mode backend ws_label ws_state ws_detail status_event elapsed window
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$id" "$st" "$kind" "$repo" "$title" \
      "$model" "$effort" "$mode" "$backend" \
      "$ws_label" "$ws_state" "$ws_detail" \
      "$status_event" "$elapsed" "$window"
  done < "$BACKLOG" > "$out"

  cat "$out"
  rm -f "$out"
}

# --- Output: JSON ---
json_esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g'
}

render_json() {
  local board_data
  board_data=$(mktemp)
  collect_board > "$board_data"

  printf '[\n'
  local first=true
  while IFS=$'\x1f' read -r id state kind repo title model effort mode backend ws_label ws_state ws_detail status_event elapsed window; do
    $first || printf ',\n'
    first=false
    id=$(json_esc "$id")
    state=$(json_esc "$state")
    kind=$(json_esc "$kind")
    repo=$(json_esc "$repo")
    title=$(json_esc "$title")
    model=$(json_esc "$model")
    effort=$(json_esc "$effort")
    mode=$(json_esc "$mode")
    backend=$(json_esc "$backend")
    ws_label=$(json_esc "$ws_label")
    ws_state=$(json_esc "$ws_state")
    ws_detail=$(json_esc "$ws_detail")
    status_event=$(json_esc "$status_event")
    elapsed=$(json_esc "$elapsed")
    window=$(json_esc "$window")
    printf '  {"id":"%s","state":"%s","kind":"%s","repo":"%s","title":"%s","model":"%s","effort":"%s","mode":"%s","backend":"%s","endpoint_label":"%s","endpoint_state":"%s","endpoint_detail":"%s","last_event":"%s","busy_elapsed":"%s","window":"%s"}\n' \
      "$id" "$state" "$kind" "$repo" "$title" \
      "$model" "$effort" "$mode" "$backend" \
      "$ws_label" "$ws_state" "$ws_detail" \
      "$status_event" "$elapsed" "$window"
  done < "$board_data"
  printf '\n]\n'
  rm -f "$board_data"
}

# --- Output: compact ---
render_compact() {
  local board_data
  board_data=$(mktemp)
  collect_board > "$board_data"

  while IFS=$'\x1f' read -r id state kind repo title model effort mode backend ws_label ws_state ws_detail status_event elapsed window; do
    local icon
    icon=$(icon_for "$ws_label")
    local ep=""
    [ -n "$elapsed" ] && ep=" ${DIM}${elapsed}${RST}"
    local mp=""
    [ -n "$model" ] && mp=" ${DIM}${model}${RST}"
    printf '%b %-28s %s%s%s\n' "$icon" "${B}${id}${RST}" "$kind" "$mp" "$ep"
  done < "$board_data"
  rm -f "$board_data"
}

# --- Output: table ---
render_table() {
  local prev_sec=""
  local board_data
  board_data=$(mktemp)
  collect_board > "$board_data"

  if [ ! -s "$board_data" ]; then
    printf '\n  %s\n\n' "${DIM}No missions match the current filters.${RST}"
    rm -f "$board_data"
    return
  fi

  while IFS=$'\x1f' read -r id state kind repo title model effort mode backend ws_label ws_state ws_detail status_event elapsed window; do
    if [ "$state" != "$prev_sec" ]; then
      prev_sec="$state"
      printf '\n  %b\n' "$(section_label "$state")"
      printf '  %s\n' "────────────────────────────────────────────────────────────"
    fi

    local icon badge
    icon=$(icon_for "$ws_label")
    badge=$(badge_for "$kind")

    printf '  %b %b %-26s' "$icon" "$badge" "${B}${id}${RST}"
    [ -n "$model" ] && printf '  %s' "${DIM}${model}${RST}"
    [ -n "$effort" ] && printf '/%s' "${DIM}${effort}${RST}"
    [ -n "$elapsed" ] && printf '  %s' "${CYN}${elapsed}${RST}"
    [ -n "$mode" ] && printf '  %s' "${DIM}[${mode}]${RST}"
    printf '\n'

    local st
    st=$(printf '%.70s' "$title")
    printf '       %s%s%s\n' "${DIM}" "$st" "${RST}"

    if [ -n "$ws_detail" ] && [ "$ws_detail" != " " ]; then
      local sd
      sd=$(printf '%.60s' "$ws_detail")
      printf '       %s→ %s%s\n' "${DIM}" "$sd" "${RST}"
    fi
  done < "$board_data"

  rm -f "$board_data"
}

# --- Entry point ---
case "$MODE" in
  json)    render_json ;;
  compact) render_compact ;;
  *)       render_table ;;
esac
