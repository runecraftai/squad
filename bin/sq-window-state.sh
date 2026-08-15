#!/usr/bin/env bash
# sq-window-state.sh - publish per-window ground truth for the tmux sidebar.
#
# The tmux sidebar (tmux-agents-mon) classifies operator panes by screen
# reading, which is a signal, not a guarantee. Squad owns the actual truth:
# state/<id>.status wake-event lines plus the harness busy state, reconciled
# into one authoritative current-state line by bin/sq-crew-state.sh. This
# script derives that truth per task window and publishes it in one parseable
# file the sidebar can consume.
#
# It does NOT watch state/*.status (bin/sq-status-notify.sh already owns that
# notification watcher) and does NOT re-derive status semantics
# (bin/sq-classify-lib.sh owns the status-event vocabulary, bin/sq-crew-state.sh
# owns current-state reconciliation). It is a pure one-shot derivation: run
# `publish` on the sidebar's refresh cadence (the sidebar itself re-scans every
# 2s), from a tmux status-interval hook, or from any periodic or event-driven
# driver a consumer already runs - no daemon is needed here.
#
# File contract (owned by this header; docs/configuration.md "Operational base
# layout and state" points here):
#   state/window-states - one line per tmux task window, TAB-separated:
#     <window>\t<id>\t<label>\t<state>\t<detail>
#   window  the recorded tmux target from state/<id>.meta (e.g. "Squad:sq-abc"),
#           the key the sidebar joins on against its live window list
#   id      the task id
#   label   the sidebar-facing state; exactly one of:
#             working           operator is actively working
#             awaiting-decision parked at a gate needing a decision/approval
#             blocked           stuck, needs help
#             done              finished
#             idle              declared external wait (paused)
#             failed            work failed
#             unknown           no current-state source available
#   state   the canonical Squad verb from sq-crew-state.sh
#           (working|parked|done|blocked|paused|failed|unknown)
#   detail  the crew-state detail prose, tabs/newlines collapsed to spaces
#   The file is replaced atomically on every publish, so a reader never sees a
#   partial write. Absent or empty means there are no tmux task windows to
#   show. Stale rows self-clean: a torn-down task drops out of the next
#   publish because its meta file is gone.
#   The verb -> label translation below is the ONE owner of that mapping; a
#   consumer renders labels (glyph/color) however it likes and never maps
#   Squad verbs itself.
#
# Only tasks whose effective backend is tmux (explicit backend=tmux or absent
# backend=, per bin/sq-backend.sh's fm_backend_of_meta) and that record a
# window= naming a real local tmux target are published; orca/herdr/zellij/
# cmux tasks have no tmux window the sidebar can show. XO tasks (kind=xo) are
# excluded entirely, and so is any window=remote:* target: sq-spawn.sh's
# remote-XO path records window=remote:<id> with no backend= line, which
# names no local tmux window the sidebar could join.
#
# Usage:
#   sq-window-state.sh publish  derive and atomically write state/window-states
#   sq-window-state.sh list     derive and print the lines to stdout
#
# Env: SQUAD_STATE_OVERRIDE selects the state dir (tests);
#      SQUAD_CREW_STATE_BIN overrides the reconciler binary (tests).
# Fail-closed: an unknown or missing subcommand prints usage to stderr and
# exits non-zero; a task whose reconciler call fails is published as unknown,
# never silently dropped.
set -euo pipefail

SELF="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
CREW_STATE_BIN="${SQUAD_CREW_STATE_BIN:-$SCRIPT_DIR/sq-crew-state.sh}"
OUT_FILE="$STATE/window-states"
SEP=' · '

# shellcheck source=bin/sq-backend.sh
. "$SCRIPT_DIR/sq-backend.sh"

usage() {
  printf 'usage: sq-window-state.sh publish|list\n' >&2
}

# Canonical crew-state verb from the reconciler's one line
# ("state: <verb> · source: <src> · <detail>"). Anything malformed or missing
# reports unknown so a row is never silently dropped.
crew_state_verb() {  # <crew-state-line>
  local line=$1
  case "$line" in
    state:*) line=${line#state: }; printf '%s' "${line%% *}" ;;
    *) printf 'unknown' ;;
  esac
}

# Detail prose after the "source: <src>" marker, tabs/newlines collapsed so
# one detail never spans a TSV field. A line without the trailing separator
# (no detail) yields an empty detail; a malformed line passes through as-is.
crew_state_detail() {  # <crew-state-line>
  local line=$1 rest detail
  case "$line" in
    state:*source:*)
      rest=${line#*source:}
      rest=${rest#"${rest%%[![:space:]]*}"}
      case "$rest" in
        *"$SEP"*)
          detail=${rest#*"$SEP"}
          detail=${detail#"${detail%%[![:space:]]*}"}
          printf '%s' "${detail//[$'\t'$'\n']/ }"
          ;;
      esac
      ;;
    *) printf '%s' "${line//[$'\t'$'\n']/ }" ;;
  esac
}

# The single owner of the crew-state verb -> sidebar label translation.
label_for_state() {  # <crew-state-verb>
  case "$1" in
    working) printf 'working' ;;
    parked) printf 'awaiting-decision' ;;
    blocked) printf 'blocked' ;;
    done) printf 'done' ;;
    paused) printf 'idle' ;;
    failed) printf 'failed' ;;
    *) printf 'unknown' ;;
  esac
}

# Derive one TSV row per tmux task window, sorted by window target for a
# deterministic file. Prints nothing when there are no tmux task windows.
derive() {
  local meta id backend window kind line state label detail
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ ! -L "$meta" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    [ "$backend" = tmux ] || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    case "$window" in remote:*) continue ;; esac
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = xo ] && continue
    id=$(basename "$meta"); id=${id%.meta}
    line=$("$CREW_STATE_BIN" "$id" 2>/dev/null) || true
    state=$(crew_state_verb "$line")
    label=$(label_for_state "$state")
    detail=$(crew_state_detail "$line")
    printf '%s\t%s\t%s\t%s\t%s\n' "$window" "$id" "$label" "$state" "$detail"
  done | LC_ALL=C sort
}

case "${1:-}" in
  list) derive ;;
  publish)
    if ! derive > "$OUT_FILE.tmp.$$"; then rm -f "$OUT_FILE.tmp.$$"; exit 1; fi
    mv -f "$OUT_FILE.tmp.$$" "$OUT_FILE"
    ;;
  *) usage; exit 1 ;;
esac
