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
# are unreadable (other users) cannot be inspected and are ignored.
#
# Output: nothing when there is nothing to do; otherwise one summary line with
# the count and freed size. --dry-run additionally lists each directory it would
# remove and removes nothing.
#
# Every error prints a warning on stderr and the exit status stays 0, so a
# session start that calls this can never be failed by it.
#
# Environment:
#   SQUAD_DRILL_SANDBOX_GRACE_MINUTES  grace window in minutes (default 60);
#                                      --grace-minutes overrides it.
#   SQUAD_DRILL_SANDBOX_ROOT           directory scanned for sandboxes
#                                      (default /tmp); a test seam.
set -u

PREFIX=drill-execution-policy-
ROOT=${SQUAD_DRILL_SANDBOX_ROOT:-/tmp}
GRACE=${SQUAD_DRILL_SANDBOX_GRACE_MINUTES:-60}
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
  # One process per source rather than per pid or fd: a busy host holds
  # thousands of descriptors and a fork each would make the sweep crawl.
  {
    readlink /proc/[0-9]*/cwd /proc/[0-9]*/fd/*
    cat /proc/[0-9]*/mountinfo
    cat /proc/[0-9]*/environ | tr '\0' '\n'
  } 2>/dev/null | grep -aoE "${PREFIX}[A-Za-z0-9._-]+" | sort -u
}

human_size() {
  awk -v k="$1" 'BEGIN {
    if (k >= 1048576) printf "%.1f GiB", k / 1048576
    else if (k >= 1024) printf "%.1f MiB", k / 1024
    else printf "%d KiB", k
  }'
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
  refs=$(referenced_sandboxes) || refs=""

  local count=0 total_kb=0 kb
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

    kb=$(du -sk -- "$d" 2>/dev/null | awk '{print $1}')
    case "$kb" in '' | *[!0-9]*) kb=0 ;; esac

    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would remove %s (%s)\n' "$d" "$(human_size "$kb")"
    else
      # Cache trees can hold read-only directories, which block removal.
      chmod -R u+rwX -- "$d" 2>/dev/null || true
      if ! rm -rf --one-file-system -- "$d" 2>/dev/null || [ -e "$d" ]; then
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
