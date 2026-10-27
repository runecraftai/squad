#!/usr/bin/env bash
# Shared drill axi run attribution and current-run lifecycle primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# drill run belongs to a given worktree, and for the current-run capture built
# on it (source, lifecycle, gate-parked detail, and the reported exec state
# projected from it). Used by sq-crew-state.sh (read-only current-state
# reporting), sq-exec-state.sh (dispatch claim, recovery, and that projection),
# and sq-teardown.sh (pre-teardown run abort, see its "Fix 1" header comment).
# Getting this wrong in either direction is unsafe: a false negative hides a
# genuinely parked run, and a false positive lets teardown act on a run it does
# not own.
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

# Newest same-branch listing row, bound to current code before trusting it.
fm_drill_runs_status_for_branch() {  # <worktree> <timeout> <limit> <branch>
  local wt=$1 timeout_secs=$2 limit=$3 branch=$4 out row st rest br sha
  out=$(fm_drill_run "$wt" "$timeout_secs" runs --limit "$limit")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(fm_drill_trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(fm_drill_trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(fm_drill_trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      # Only the newest same-branch run is eligible; an unbindable head makes
      # attribution unknown rather than exposing an older terminal execution.
      if [ -z "$sha" ] || ! fm_drill_head_matches_worktree "$wt" "$sha"; then
        printf 'unknown'
        return 0
      fi
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}


# Capture the current branch/code-bound run for reporting and execution recovery.
# Results: SQ_DRILL_RUN_OUT, SQ_DRILL_RUN_SOURCE (full/coarse/none/unverified),
# SQ_DRILL_COARSE_STATUS. A terminal snapshot must not hide a newer active run.
fm_drill_current_run() {  # <worktree> <timeout> <runs-limit>
  local wt=$1 timeout_secs=$2 limit=$3 branch run_branch status outcome head
  SQ_DRILL_RUN_OUT=
  SQ_DRILL_RUN_SOURCE=none
  SQ_DRILL_COARSE_STATUS=
  [ -d "$wt" ] || return 0
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 0
  [ -n "$branch" ] || return 0
  SQ_DRILL_RUN_OUT=$(fm_drill_run "$wt" "$timeout_secs" axi status)
  [ -n "$SQ_DRILL_RUN_OUT" ] || return 0
  run_branch=$(fm_drill_strip_quotes "$(fm_drill_field "$SQ_DRILL_RUN_OUT" branch)")
  head=$(fm_drill_strip_quotes "$(fm_drill_field "$SQ_DRILL_RUN_OUT" head)")
  if [ "$run_branch" = "$branch" ] && fm_drill_head_matches_worktree "$wt" "$head"; then
    SQ_DRILL_RUN_SOURCE=full
    status=$(fm_drill_strip_quotes "$(fm_drill_field "$SQ_DRILL_RUN_OUT" status)")
    outcome=$(fm_drill_strip_quotes "$(fm_drill_field "$SQ_DRILL_RUN_OUT" outcome)")
    case "$status:$outcome" in
      failed:*|cancelled:*|completed:*|*:failed|*:passed|*:checks-passed|*:cancelled)
        SQ_DRILL_COARSE_STATUS=$(fm_drill_runs_status_for_branch "$wt" "$timeout_secs" "$limit" "$branch")
        case "$SQ_DRILL_COARSE_STATUS" in
          unknown|'') SQ_DRILL_RUN_SOURCE=unverified ;;
          running) SQ_DRILL_RUN_SOURCE=coarse ;;
        esac
        ;;
    esac
  else
    SQ_DRILL_COARSE_STATUS=$(fm_drill_runs_status_for_branch "$wt" "$timeout_secs" "$limit" "$branch")
    case "$SQ_DRILL_COARSE_STATUS" in
      unknown|'') : ;;
      *) SQ_DRILL_RUN_SOURCE=coarse ;;
    esac
  fi
}

# First quiet executing step as <step>:<quiet-duration>. Drill owns freshness:
# consume its active_steps last_activity `quiet <duration> ago` prefix, never
# infer it from total runtime, pane hashes, or a second timeout. The running CI
# monitor intentionally waits silently for merge/close; CI fixes still execute.
# Missing/older activity tables and unknown activity are not stall evidence.
fm_drill_current_run_quiet_step() {
  [ "$SQ_DRILL_RUN_SOURCE" = full ] || return 0
  [ "$(fm_drill_current_run_state)" = active ] || return 0
  fm_drill_current_run_parked && return 0
  printf '%s\n' "$SQ_DRILL_RUN_OUT" | awk -F, '
    /^[[:space:]]*active_steps\[[0-9]+\]\{step,status,active_for,last_activity,agent_pid,round\}:/ { active=1; next }
    active && /^[[:space:]]*[^[:space:]]/ {
      step=$1; status=$2; activity=$4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", step)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      sub(/^[[:space:]]*"?/, "", activity)
      if (step !~ /^[a-z][a-z0-9_-]*$/ || status !~ /^(running|fixing)$/) { active=0; next }
      if (step == "ci" && status == "running") next
      if (activity ~ /^quiet [0-9]+([dhms][0-9]+)*[dhms] ago/) {
        sub(/^quiet /, "", activity); sub(/ ago.*/, "", activity)
        print step ":" activity
        exit
      }
    }
  '
}

# Lifecycle of the captured run, not the dispatch record or CI-ready task view.
# Non-terminal runs are `active`; fm_drill_current_run_parked refines that into
# parked-at-a-gate when the captured evidence shows one.
fm_drill_current_run_state() {
  local status outcome
  case "$SQ_DRILL_RUN_SOURCE" in
    coarse)
      case "$SQ_DRILL_COARSE_STATUS" in
        running) printf 'active' ;;
        completed|failed|cancelled) printf 'terminal' ;;
        *) printf 'unknown' ;;
      esac ;;
    full)
      status=$(fm_drill_strip_quotes "$(fm_drill_field "$SQ_DRILL_RUN_OUT" status)")
      outcome=$(fm_drill_strip_quotes "$(fm_drill_field "$SQ_DRILL_RUN_OUT" outcome)")
      case "$status:$outcome" in
        *:passed|*:checks-passed|*:failed|*:cancelled|completed:|failed:|cancelled:) printf 'terminal' ;;
        *:) printf 'active' ;;
        *) printf 'unknown' ;;
      esac ;;
    *) printf 'unknown' ;;
  esac
}

# 0 if the captured run is parked at a gate instead of executing. Only a full
# `axi status` capture can show a gate, so coarse runs-list evidence never
# reports a parked run and callers keep their fail-closed default. The rule
# mirrors bin/sq-crew-state.sh's run-step precedence: an empty outcome plus an
# approval/fix status, an awaiting_agent field, or a gate block is parked.
fm_drill_current_run_parked() {
  local status
  [ "$SQ_DRILL_RUN_SOURCE" = full ] || return 1
  [ -z "$(fm_drill_strip_quotes "$(fm_drill_field "$SQ_DRILL_RUN_OUT" outcome)")" ] || return 1
  status=$(fm_drill_strip_quotes "$(fm_drill_field "$SQ_DRILL_RUN_OUT" status)")
  case "$status" in awaiting_approval|fix_review) return 0 ;; esac
  printf '%s\n' "$SQ_DRILL_RUN_OUT" | grep -Eq '^[[:space:]]*(awaiting_agent|gate):[[:space:]]*'
}

# Reported execution state for a captured run lifecycle: an active or
# gate-parked run means the attempt is still executing, a terminal run means it
# is over, and unattributed evidence leaves the recorded dispatch state
# unchanged.
fm_drill_reported_exec_state() {  # <run_state> [recorded-state]
  case "$1" in
    active|parked) printf 'running\n' ;;
    terminal) printf 'released\n' ;;
    *) [ -z "${2:-}" ] || printf '%s\n' "$2" ;;
  esac
}
