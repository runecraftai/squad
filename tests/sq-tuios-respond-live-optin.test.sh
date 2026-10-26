#!/usr/bin/env bash
# Opt-in live guard for the TUIOS blocked-operator answer path.
#
# The portable TUIOS suites prove call shape against a fake CLI; they cannot
# prove that a live daemon publishes a blocked agent-state event, that the
# production wake carries the operator's question and numbered options, that an
# unauthorized pane cannot answer, or that the exact prompt id is answered and
# the operator resumes. This wrapper drives the guarded lab's `respond` mode,
# which builds a private disposable daemon and session and never addresses the
# shared TUIOS daemon or any watched session.
#
# Run: SQUAD_TUIOS_AFK_LIVE=1 bin/sq-test-run.sh --family live-harness-optin
set -u

if [ "${SQUAD_TUIOS_AFK_LIVE:-0}" != 1 ]; then
  echo "skip: set SQUAD_TUIOS_AFK_LIVE=1 to run the live TUIOS blocked-operator answer guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v tuios >/dev/null 2>&1 \
  || { echo "skip: tuios is not installed, so the live TUIOS blocked-operator answer guard cannot run"; exit 0; }
command -v jq >/dev/null 2>&1 \
  || { echo "skip: jq is not installed, so the live TUIOS blocked-operator answer guard cannot run"; exit 0; }

exec "$ROOT/bin/sq-afk-tuios-lab.sh" respond
