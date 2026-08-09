#!/usr/bin/env bash
# Self-update a running Squad and its XOs to the latest origin.
#
# Mechanical half of the /updatesquad skill. Fast-forwards the running
# Squad repo's default branch from origin, then fast-forwards every
# registered XO home. Local homes are fob worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root. FAST-FORWARD ONLY, exactly like
# sq-unit-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so an XO's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. XO homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/sq-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD XO sync used by sq-spawn.sh and
# sq-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge XOs itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-Squad: yes|no    (did the running Squad's instructions change)
#   - nudge-XOs: sq-<id>...|none   (updated live XOs to nudge)
#
# Usage: sq-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_HOME="${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_HOME/state}"
XOS_MD="$SQUAD_HOME/data/XOs.md"
# shellcheck source=bin/sq-ff-lib.sh
. "$SCRIPT_DIR/sq-ff-lib.sh"

"$SCRIPT_DIR/sq-guard.sh" || true

usage() { echo "usage: sq-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main Squad repo ---------------------------------------------------

reread_Squad="no"
ff_target "$SQUAD_ROOT" "Squad" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_Squad="yes"
fi

# --- XOs -----------------------------------------------------------
# An updated live XO is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatesquad's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=xo carries the
# authoritative home= path.
sweep_live_XO_metas "$STATE" origin no

# Registry backstop: an XO registered in data/XOs.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$XOS_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! XO_registry_parse_line "$line"; then
      echo "XO registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$XO_REGISTRY_ID
    home=$XO_REGISTRY_HOME
    if [ "$XO_REGISTRY_REMOTE" -eq 1 ]; then
      if remote_out=$("$SCRIPT_DIR/sq-on.sh" "$id" sq-remote-XO-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            echo "remote XO $id: updated on $XO_REGISTRY_HOST (${remote_result#synced: })"
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=xo' "$STATE/$id.meta"; then
              FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS sq-$id"
            fi
            ;;
          current:*) echo "remote XO $id: already current on $XO_REGISTRY_HOST (${remote_result#current: })" ;;
          *) echo "remote XO $id: skipped on $XO_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote XO $id: skipped on $XO_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      process_XO "$id" "$home" "" origin no
    fi
  done < "$XOS_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-Squad: $reread_Squad"
echo "nudge-XOs:${FF_NUDGE_WINDOWS:- none}"
