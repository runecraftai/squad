# shellcheck shell=bash
# Shared sq-tasks backend selection and compatibility probe for bootstrap,
# teardown, and XO backlog handoff.
# Usage: . bin/sq-tasks-lib.sh
#
# Compatible means the resolved backend command reports SQUAD_TASKS_AXI_MIN or
# newer, `update --help` exposes --archive-body for recoverable note rewrites,
# and `mv --help` exposes [<id>...] for atomic multi-ID moves required by XO
# handoffs.
# SQUAD_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/sq-bootstrap.sh. The constant name is a durable version
# contract used by bootstrap probes; it is NOT a user-facing tool name (the
# purge decision 2026-08-14 keeps it only as the probe contract identifier).
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of the sq-tasks backend for routine
# Squad backlog mutations, but validated XO handoffs always invoke the legacy
# protocol alias (see the resolver note below).
# Absent or any other value keeps the default sq-tasks backend path, falling
# back to manual mutation when the tool is not compatible.
#
# This file is the single owner of SQUAD_TASKS_AXI_MIN. bin/sq-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three backend
# subprocesses, and one session start needs the same verdict twice: once in
# bin/sq-session-start.sh's backlog listing and once in the bin/sq-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in SQUAD_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive an
#     sq-tasks upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so an sq-tasks install or upgrade
# is picked up by the next process rather than being cached to disk.

SQUAD_TASKS_AXI_MIN=0.1.0

# Resolve the sq-tasks backend command: the forked sq-tasks (M2,
# T-M2-04) wins when installed; otherwise the legacy tasks-axi protocol-alias
# name is used so a pre-M2 environment keeps working. The fork keeps the same
# CLI protocol.
# Note: runtime call sites keep invoking the bare `tasks-axi` name so PATH
# shadowing (test fakebin stubs, the CI tasks-axi alias) keeps working; this
# resolver drives the compatibility probes below.
fm_tasks_axi_cmd() {
  if type -P sq-tasks >/dev/null 2>&1; then
    printf '%s\n' sq-tasks
  elif type -P tasks-axi >/dev/null 2>&1; then
    printf '%s\n' tasks-axi
  fi
}

SQUAD_TASKS_AXI_COMPATIBLE_MEMO=${SQUAD_TASKS_AXI_COMPATIBLE:-}
unset SQUAD_TASKS_AXI_COMPATIBLE
case "$SQUAD_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) SQUAD_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

fm_tasks_axi_version_parts() {
  local output cmd
  cmd=$(fm_tasks_axi_cmd) || return 1
  output=$("$cmd" --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  case "$SQUAD_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    SQUAD_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  SQUAD_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$SQUAD_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output cmd
  cmd=$(fm_tasks_axi_cmd) || return 1
  output=$("$cmd" update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output cmd
  cmd=$(fm_tasks_axi_cmd) || return 1
  output=$("$cmd" mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
