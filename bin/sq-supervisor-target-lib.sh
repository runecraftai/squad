#!/usr/bin/env bash
# sq-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/sq-supervise-daemon.sh) must know which pane runs
# Squad itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/sq-afk-launch.sh) must resolve the SAME commander pane BEFORE it creates a
# separate launcher-owned terminal for the daemon, so it can pass that pane in as
# SQUAD_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the commander's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/sq-supervise-daemon.sh, so its unit tests (tests/sq-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.
#
# A detected marker is a PREFERENCE, never a verdict: an environment can carry
# markers for more than one backend (a herdr-derived pane id surviving inside a
# TUIOS session, a stale inherited TMUX_PANE), and committing to a marker whose
# target is gone used to block away mode outright. discover_supervisor_pane
# therefore validates each detected candidate in this same preference order and
# settles on the first one whose target actually resolves.

# Default supervisor pane target/backend when nothing is configured or detected.
# "Squad:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside tmux, herdr, and TUIOS.
SQUAD_SUPERVISOR_TARGET_DEFAULT="Squad:0"
SQUAD_SUPERVISOR_BACKEND_DEFAULT="tmux"

# _supervisor_pane_candidates: emit every detected supervisor pane candidate in
# preference order, one "<backend>\t<target>\t<source>" line each, where
# <source> names the exact env markers that produced it:
#   1. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from Squad's own pane. First so a tmux pane nested inside
#      herdr still resolves to tmux, matching fm_backend_detect's innermost-first
#      rule.
#   2. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID.
#   3. TUIOS_ENV=1 + TUIOS_SESSION + TUIOS_PANE_ID - TUIOS supplies these markers
#      inside its managed pane; require all three and compose the exact target.
# An incomplete marker set is not a candidate at all, so it can never mask a
# complete one behind it.
_supervisor_pane_candidates() {
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux\t%s\t%s\n' "$TMUX_PANE" 'TMUX_PANE'
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr\t%s:%s\t%s\n' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID" 'HERDR_ENV(HERDR_PANE_ID)'
  fi
  if [ "${TUIOS_ENV:-}" = "1" ] && [ -n "${TUIOS_SESSION:-}" ] && [ -n "${TUIOS_PANE_ID:-}" ]; then
    printf 'tuios\t%s:%s\t%s\n' "$TUIOS_SESSION" "$TUIOS_PANE_ID" 'TUIOS_ENV(TUIOS_SESSION+TUIOS_PANE_ID)'
  fi
}

# _supervisor_target_valid: cheap read-only check that BACKEND's TARGET endpoint
# exists right now. Delegates to bin/sq-backend.sh's fm_backend_target_exists,
# which both callers already source. A caller that sources this file without the
# backend library keeps the older behavior of trusting a bare marker rather than
# failing every resolution.
_supervisor_target_valid() {  # <backend> <target>
  if declare -F fm_backend_target_exists >/dev/null 2>&1; then
    fm_backend_target_exists "$1" "$2"
    return
  fi
  return 0
}

# discover_supervisor_target: resolve the pane running Squad. Priority:
#   1. SQUAD_SUPERVISOR_TARGET env (explicit override) - may be a tmux target, a
#      herdr "<session>:<pane-id>" target, a TUIOS "<session>:<window-id>" target,
#      or an exact Orca terminal handle for explicit native-only Orca (paired with
#      discover_supervisor_backend to know which).
#   2. The first detected candidate from _supervisor_pane_candidates.
#   3. SQUAD_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if
#      the session is named differently). Returns 1 so the caller can warn.
# This is the unvalidated preference view; discover_supervisor_pane is the one
# callers use when a gone target must fall through instead of failing.
discover_supervisor_target() {
  local backend target source
  if [ -n "${SQUAD_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$SQUAD_SUPERVISOR_TARGET"
    return 0
  fi
  while IFS=$'\t' read -r backend target source; do
    printf '%s' "$target"
    return 0
  done < <(_supervisor_pane_candidates)
  printf '%s' "$SQUAD_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit SQUAD_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/sq-backend.sh's fm_backend_detect:
#   1. SQUAD_SUPERVISOR_BACKEND env (explicit override).
#   2. The backend of the first detected candidate.
#   3. SQUAD_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  local backend target source
  if [ -n "${SQUAD_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$SQUAD_SUPERVISOR_BACKEND"
    return 0
  fi
  while IFS=$'\t' read -r backend target source; do
    printf '%s' "$backend"
    return 0
  done < <(_supervisor_pane_candidates)
  printf '%s' "$SQUAD_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}

# discover_supervisor_pane: resolve the supervisor pane for the daemon and the
# away launcher, settling on the first detected candidate whose target actually
# exists. Prints one tab-separated line:
#   <backend>  <target>  <backend-source>  <target-source>  <settled>  <skipped>
# <settled> is `validated` for a detected or default pair whose target was
# confirmed, `explicit` for an authoritative override that was NOT probed, and
# `-` when nothing resolved: an explicit SQUAD_SUPERVISOR_TARGET/
# SQUAD_SUPERVISOR_BACKEND is the caller's word, is never silently replaced by a
# detected marker, and stays the daemon's own startup check to refuse loudly. If
# only the backend is explicit, only that backend's candidates are considered.
# <skipped> is `-`, or names every preferred candidate that was skipped because
# its target did not resolve. Empty fields are always `-` because tab is IFS
# whitespace, so `read` would otherwise collapse the empty field away.
# Returns 0 when the printed pair is settled, 1 when no candidate and not even
# the default pair resolved (the caller must fail loudly, naming the pair).
discover_supervisor_pane() {
  local explicit_target=${SQUAD_SUPERVISOR_TARGET:-}
  local explicit_backend=${SQUAD_SUPERVISOR_BACKEND:-}
  local backend target source first_backend="" first_target="" first_source=""
  local skipped="" settled="validated" backend_source

  if [ -n "$explicit_target" ]; then
    if [ -n "$explicit_backend" ]; then
      backend=$explicit_backend
      backend_source="SQUAD_SUPERVISOR_BACKEND"
    else
      backend=$(discover_supervisor_backend) || true
      backend_source="DISCOVERED"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$backend" "$explicit_target" "$backend_source" "SQUAD_SUPERVISOR_TARGET" "explicit" -
    return 0
  fi

  while IFS=$'\t' read -r backend target source; do
    [ -n "$backend" ] || continue
    if [ -n "$explicit_backend" ] && [ "$backend" != "$explicit_backend" ]; then
      continue
    fi
    if [ -z "$first_backend" ]; then
      first_backend=$backend
      first_target=$target
      first_source=$source
    fi
    if _supervisor_target_valid "$backend" "$target"; then
      if [ -n "$explicit_backend" ]; then
        backend_source="SQUAD_SUPERVISOR_BACKEND"
      else
        backend_source=$source
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$backend" "$target" "$backend_source" "$source" "$settled" "${skipped:--}"
      return 0
    fi
    if [ -n "$skipped" ]; then
      skipped="$skipped; "
    fi
    skipped="${skipped}${source} target '$target' on backend '$backend' did not resolve"
  done < <(_supervisor_pane_candidates)

  # Nothing validated. Name the closest preference in the failure pair so a
  # caller's loud error points at the real stale marker, then fall back to the
  # bare default when no candidate existed at all - which is a guess, so it is
  # logged like any other fallback rather than passing silently.
  if [ -n "$first_backend" ]; then
    backend=$first_backend
    target=$first_target
    source=$first_source
  else
    backend=${explicit_backend:-$SQUAD_SUPERVISOR_BACKEND_DEFAULT}
    target=$SQUAD_SUPERVISOR_TARGET_DEFAULT
    source="FALLBACK($SQUAD_SUPERVISOR_BACKEND_DEFAULT)"
    skipped="no detected supervisor markers"
  fi
  if [ -n "$explicit_backend" ]; then
    backend_source="SQUAD_SUPERVISOR_BACKEND"
  else
    backend_source=$source
  fi
  if _supervisor_target_valid "$backend" "$target"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$backend" "$target" "$backend_source" "$source" "$settled" "${skipped:--}"
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$backend" "$target" "$backend_source" "$source" - "${skipped:--}"
  return 1
}
