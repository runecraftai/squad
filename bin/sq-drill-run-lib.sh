#!/usr/bin/env bash
# Shared drill axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# drill run belongs to a given worktree, used by sq-crew-state.sh
# (read-only current-state reporting) and sq-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `drill "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_drill_run keeps the fail-open query contract for read-only callers.
#
# The CLI is resolved through fm_drill_bin with a legacy fallback to the
# pre-rename `no-mistakes` binary while the live install still runs it
# (documented transition keep, mirroring bin/sq-gate-refuse-lib.sh; remove
# the legacy arm in a follow-up once the environment rename lands).
fm_drill_bin() {
  if command -v drill >/dev/null 2>&1; then
    printf '%s\n' drill
    return 0
  fi
  if command -v no-mistakes >/dev/null 2>&1; then
    printf '%s\n' no-mistakes
    return 0
  fi
  return 1
}

fm_drill_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none drill_bin
  shift 2
  drill_bin=$(fm_drill_bin) || return 1
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" "$drill_bin" "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" "$drill_bin" "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" "$drill_bin" "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_drill_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_drill_run_bounded "$@" 2>/dev/null
}

fm_drill_run() {  # <dir> <timeout_secs> <args...>
  fm_drill_run_checked "$@" || true
}

fm_drill_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_drill_strip_quotes() {
  local s
  s=$(fm_drill_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_drill_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_drill_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_drill_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}
