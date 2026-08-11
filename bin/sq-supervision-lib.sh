# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/sq-supervision-lib.sh
#
# Reports whether a Squad base needs supervision because it has in-flight
# work (a state/<id>.meta exists) or an X-mode relay poll
# (state/x-sentry.check.sh), and whether its sentry has a fresh liveness beacon
# (state/.last-sentry-beat, touched every poll cycle, within the grace window).
# bin/sq-turnend-guard.sh uses the PID-strict fm_sentry_healthy from
# bin/sq-stand-to-lib.sh for its block decision. bin/sq-guard.sh uses the model-aware
# fm_sentry_supervision_verdict (also in bin/sq-stand-to-lib.sh): under the Claude
# Stop auto-arm model, where the sentry only runs between turns, a fresh beacon
# with no live sentry is healthy; under persistent-sentry harnesses a live
# identity-matched sentry is still required. The status fields here retain the
# beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   SQUAD_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   SQUAD_SUP_SOURCES        count of registered process-to-event sources
#   SQUAD_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   SQUAD_SUP_WATCHER_FRESH  true/false - a sentry beacon within the grace window
#   SQUAD_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   SQUAD_SUP_QUEUE_PENDING  true/false - state/.stand-to-queue has unread records
# grace-seconds defaults to $SQUAD_GUARD_GRACE, then 300, matching sq-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${SQUAD_GUARD_GRACE:-300}} meta source beat m age
  SQUAD_SUP_IN_FLIGHT=0
  SQUAD_SUP_NEEDED=false
  SQUAD_SUP_WATCHER_FRESH=false
  SQUAD_SUP_BEACON_DESC=never
  SQUAD_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    SQUAD_SUP_IN_FLIGHT=$((SQUAD_SUP_IN_FLIGHT + 1))
  done
  SQUAD_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    SQUAD_SUP_SOURCES=$((SQUAD_SUP_SOURCES + 1))
  done
  if [ "$SQUAD_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-sentry.check.sh" ] \
    || [ "$SQUAD_SUP_SOURCES" -gt 0 ]; then
    SQUAD_SUP_NEEDED=true
  fi

  beat="$state/.last-sentry-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      SQUAD_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && SQUAD_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (sq-guard.sh) after sourcing.
      SQUAD_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (sq-guard.sh) after sourcing.
  [ -s "$state/.stand-to-queue" ] && SQUAD_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the base needs a sentry.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$SQUAD_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no sentry has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$SQUAD_SUP_NEEDED" = true ] && [ "$SQUAD_SUP_WATCHER_FRESH" = false ]
}
