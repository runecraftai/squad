#!/usr/bin/env bash
# Conservative cleanup of stale drill step-agent sandboxes under /tmp.
#
# Usage:
#   sq-drill-sandbox-gc.sh [--dry-run] [--grace-minutes N]
#
# Each drill run leaves /tmp/drill-execution-policy-<id> behind, holding the
# step agent's cache and HOME, and nothing else removes it. Stale ones can fill
# the tmpfs and wedge every later step agent with ENOSPC, so this sweep removes
# them.
#
# Only direct children of the sandbox root whose name matches
# drill-execution-policy-[A-Za-z0-9._-]+ are ever considered, and only real
# directories owned by the caller (never a symlink). A candidate is removed only
# when both independent signals agree it is dead:
#   - age: neither the directory nor anything inside it (symlinks not followed)
#     changed within the grace window, so a busy agent writing deep in its cache
#     is not mistaken for idle by the top-level mtime alone.
#   - references: no live process points into it, by working directory, open
#     file descriptor, mount (/proc/<pid>/mountinfo, which covers sandbox bind
#     mounts), or environment (HOME and cache variables).
# A referenced directory is kept whatever its age. Processes whose /proc entries
# are unreadable (other users) cannot be inspected and are ignored, but if the
# reference snapshot cannot be taken at all, nothing is removed and a warning is
# printed rather than treating the sandbox as dead.
#
# The grace window defaults to six hours because an idle drill run leaves no
# reference between sandboxed commands: it parks at approval gates and polls CI
# for hours, and both signals then look dead. A longer window keeps such a live
# run from being swept out from under itself while still reclaiming abandoned
# sandboxes.
#
# Output: nothing when there is nothing to do; otherwise one summary line with
# the count and freed size. --dry-run additionally lists each directory it would
# remove and removes nothing.
#
# Every error prints a warning on stderr and the exit status stays 0, so a
# session start that calls this can never be failed by it.
#
# Environment:
#   SQUAD_DRILL_SANDBOX_GRACE_MINUTES  grace window in minutes (default 360);
#                                      --grace-minutes overrides it.
#   SQUAD_DRILL_SANDBOX_ROOT           directory scanned for sandboxes
#                                      (default /tmp); a test seam.
#   SQUAD_DRILL_SANDBOX_PROC           procfs mount scanned for live references
#                                      (default /proc); a test seam.
set -u

PREFIX=drill-execution-policy-
ROOT=${SQUAD_DRILL_SANDBOX_ROOT:-/tmp}
GRACE=${SQUAD_DRILL_SANDBOX_GRACE_MINUTES:-360}
PROC=${SQUAD_DRILL_SANDBOX_PROC:-/proc}
DRY_RUN=0

warn() {
  printf 'sq-drill-sandbox-gc: warning: %s\n' "$*" >&2
}

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Basenames of every sandbox a live process references, one per line.
# Path components are matched whole, so drill-execution-policy-1 never shields
# drill-execution-policy-10.
referenced_sandboxes() {
  local pid rc refs
  # If the snapshot cannot be taken, report failure so the caller keeps every
  # candidate instead of mistaking an empty result for "no references".
  command -v cat find grep readlink sort tr >/dev/null 2>&1 || return 1
  readlink "$PROC/self/cwd" >/dev/null 2>&1 || return 1
  [ -r "$PROC/self/mountinfo" ] && [ -r "$PROC/self/environ" ] || return 1
  # A local pipefail makes a stage that fails or is killed fail the snapshot, so
  # a truncated stream can never pass sort's success off as a complete list.
  refs=$(
    set -o pipefail
    {
      # One process at a time, batching descriptor reads: a busy host holds
      # thousands of descriptors, which neither forks per descriptor nor exceeds
      # the argument limit and silently drops references.
      for pid in "$PROC"/[0-9]*; do
        [ -d "$pid" ] || continue
        readlink "$pid/cwd" 2>/dev/null
        [ -d "$pid/fd" ] && find "$pid/fd" -mindepth 1 -maxdepth 1 -exec readlink {} + 2>/dev/null
        cat "$pid/mountinfo" 2>/dev/null
        # stderr goes to /dev/null before the input redirect: bash reports a
        # failed input redirect itself, in the order the redirects appear, and a
        # pid that exits mid-scan or hides its environ must stay silent.
        tr '\0' '\n' 2>/dev/null <"$pid/environ"
      done
      # A pid that exits mid-scan fails only its own reads, which is expected,
      # so the scan itself still succeeds; a killed or broken stage does not.
      :
    } | { grep -aoE "${PREFIX}[A-Za-z0-9._-]+" || { rc=$?; [ "$rc" -eq 1 ]; }; } | sort -u
  ) || return 1
  printf '%s\n' "$refs"
}

human_size() {
  awk -v k="$1" 'BEGIN {
    if (k >= 1048576) printf "%.1f GiB", k / 1048576
    else if (k >= 1024) printf "%.1f MiB", k / 1024
    else printf "%d KiB", k
  }'
}

# Some rm implementations (BSD/macOS) reject --one-file-system. Probe once with
# a throwaway directory so an unsupported flag falls back to a plain rm -rf
# instead of failing every removal. If no probe directory can be created, the
# plain form is used rather than skipping the sweep.
rm_supports_one_file_system() {
  local probe
  probe=$(mktemp -d "${TMPDIR:-/tmp}/sq-drill-sandbox-gc-probe.XXXXXX" 2>/dev/null) || return 1
  if rm -rf --one-file-system -- "$probe" 2>/dev/null && [ ! -e "$probe" ]; then
    return 0
  fi
  rm -rf -- "$probe" 2>/dev/null || true
  return 1
}

main() {
  case "$GRACE" in
    '' | *[!0-9]*)
      warn "grace window must be a whole number of minutes, got '$GRACE'"
      return 0
      ;;
  esac
  [ -d "$ROOT" ] || return 0

  local -a candidates=()
  local d name
  for d in "$ROOT/$PREFIX"*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    name=${d##*/}
    case "$name" in
      "$PREFIX" | *[!A-Za-z0-9._-]*) continue ;;
    esac
    [ -L "$d" ] && continue
    [ -d "$d" ] && [ -O "$d" ] || continue
    candidates+=("$d")
  done
  [ "${#candidates[@]}" -gt 0 ] || return 0

  local refs recent
  if ! refs=$(referenced_sandboxes); then
    warn "could not scan $PROC for live sandbox references, keeping all candidates"
    return 0
  fi

  local count=0 total_kb=0 kb du_out
  local -a rm_one_fs=()
  if [ "$DRY_RUN" -eq 0 ] && rm_supports_one_file_system; then
    rm_one_fs=(--one-file-system)
  fi
  for d in "${candidates[@]}"; do
    name=${d##*/}
    if printf '%s\n' "$refs" | grep -qxF -- "$name"; then
      continue
    fi
    # find -quit stops at the first recent entry, so a busy sandbox is cheap.
    if ! recent=$(find "$d" -mmin "-$GRACE" -print -quit 2>/dev/null); then
      warn "could not scan $d, keeping it"
      continue
    fi
    [ -z "$recent" ] || continue

    # Take du's own status: an unreadable subtree must not look like a
    # successful zero-size measurement with no warning.
    if du_out=$(du -sk -- "$d" 2>/dev/null); then
      kb=${du_out%%[[:space:]]*}
      case "$kb" in '' | *[!0-9]*)
        warn "could not measure $d, counting it without a size"
        kb=0
        ;;
      esac
    else
      warn "could not measure $d, counting it without a size"
      kb=0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would remove %s (%s)\n' "$d" "$(human_size "$kb")"
    else
      # Cache trees can hold read-only directories, which block removal.
      find "$d" -xdev -type d -exec chmod u+rwx {} + 2>/dev/null || true
      if ! rm -rf "${rm_one_fs[@]+"${rm_one_fs[@]}"}" -- "$d" 2>/dev/null || [ -e "$d" ]; then
        warn "could not fully remove $d"
        continue
      fi
    fi
    count=$((count + 1))
    total_kb=$((total_kb + kb))
  done

  [ "$count" -gt 0 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'sq-drill-sandbox-gc: would remove %d stale drill sandbox(es) under %s, freeing %s\n' \
      "$count" "$ROOT" "$(human_size "$total_kb")"
  else
    printf 'sq-drill-sandbox-gc: removed %d stale drill sandbox(es) under %s, freed %s\n' \
      "$count" "$ROOT" "$(human_size "$total_kb")"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --grace-minutes)
      if [ "$#" -lt 2 ]; then
        warn "--grace-minutes requires a value"
        exit 0
      fi
      GRACE=$2
      shift 2
      ;;
    --grace-minutes=*)
      GRACE=${1#--grace-minutes=}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      warn "unknown argument '$1'"
      exit 0
      ;;
  esac
done

main || warn "sweep failed"
exit 0
