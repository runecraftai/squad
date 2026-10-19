#!/usr/bin/env bash
# Opt-in live guard for the TUIOS away-mode composer read and the Pi-native
# handoff readiness record.
#
# These are rendered-surface signals, so the portable regressions can only prove
# the classifier against captured frames; the live half has to watch a real Pi
# draw its own composer. This wrapper is env-gated and self-skipping, and it
# drives the guarded lab (bin/sq-afk-tuios-lab.sh), which builds a private
# disposable TUIOS session and names the installed Pi and TUIOS versions when
# the guard fails.
#
# Run: SQUAD_TUIOS_AFK_LIVE=1 bin/sq-test-run.sh --family live-harness-optin
set -u

if [ "${SQUAD_TUIOS_AFK_LIVE:-0}" != 1 ]; then
  echo "skip: set SQUAD_TUIOS_AFK_LIVE=1 to run the live TUIOS/Pi away-mode guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v pi >/dev/null 2>&1 \
  || { echo "skip: pi is not installed, so the live TUIOS Pi composer guard cannot run"; exit 0; }

exec "$ROOT/bin/sq-afk-tuios-lab.sh" lifecycle
