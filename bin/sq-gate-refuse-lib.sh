#!/usr/bin/env bash
# sq-gate-refuse-lib.sh - fail-closed refusal that keeps a drill GATE agent
# out of Squad's unit lifecycle.
#
# The hazard (data/drill-gate-ambient-authority-containment-c3/report.md): a
# drill gate agent runs inside a Squad checkout with a free shell, so
# it auto-loads Squad's AGENTS.md, adopts the commander identity, and - seeing
# crew "in flight" - reaches for sq-spawn.sh/sq-send.sh/sq-teardown.sh to
# "delegate" and "reconcile" the shared worktree. It has real capability because
# those entrypoints self-locate their base and never knew a gate context existed.
#
# drill owns the authority-removal half (it neutralizes the project
# instructions and stamps DRILL_GATE into the gate agent's environment).
# THIS is the Squad capability-removal half: an enforceable script refusal,
# not a prose rule the neutralized agent would never read. It is sourced at the
# top of the three unit-lifecycle entrypoints and called before any unit
# mutation, so a gate agent that still reaches for the unit is stopped cold.
#
# Two independent signals, either of which refuses (fail closed):
#
#   1. A gate env marker set - the durable env marker drill stamps into every
#      gate agent: DRILL_GATE (current binary), and legacy NO_MISTAKES_GATE
#      (pre-rename binary, retained while the live install still runs it).
#      This is the primary signal and covers a relocated DRILL_HOME.
#   2. The current worktree's git-common-dir resolves under a drill gate
#      repo (.../.drill/repos/*.git, legacy .../.no-mistakes/repos/*.git) - the
#      UNSPOOFABLE backstop. It derives from the checkout's real filesystem
#      location, which the agent cannot relocate without breaking the gate's
#      own git operations, so it still refuses even if the agent tampered the
#      env marker away. Its limit: the literal-path match only fires for the
#      default base root (~/.drill, legacy ~/.no-mistakes); a relocated base
#      root is covered by signal 1.
#
# The legacy markers are a documented transition keep: the live binary rename
# is a post-merge environment step, so until it lands the pre-rename binary
# still stamps NO_MISTAKES_GATE and clones gate repos under .no-mistakes/.
# Remove the legacy arms in a follow-up once no install writes them.
#
# A NORMAL Squad session - a real primary checkout, a real fob/Orca
# crew worktree - has NEITHER signal and is COMPLETELY unaffected: the function
# returns 0 and the lifecycle proceeds exactly as before.
#
# This mirrors the unspoofable-marker precedent in bin/sq-marker-lib.sh: a signal
# the agent cannot forge, keyed on at a chokepoint, keeping the pattern familiar
# to Squad maintainers. It layers ABOVE drill's separately-shipping
# HEAD-continuity guard, which remains the adversarial/residual backstop.
#
# TEST-HARNESS ESCAPE HATCH (SQUAD_GATE_REFUSE_BYPASS=1): Squad's own test suite
# must exercise the REAL sq-spawn/sq-send/sq-teardown, but the drill gate
# runs that suite FROM a gate worktree (cwd git-common-dir under
# .drill/repos/*.git, and possibly DRILL_GATE set) - the exact
# environment this guard refuses. So both signals would fire during Squad's
# own validation and break unrelated tests. SQUAD_GATE_REFUSE_BYPASS=1 makes the
# guard a no-op; Squad's shared test helpers (tests/lib.sh and the backend
# safety helpers) export it, so every test that drives these scripts against its
# temp-sandbox unit is exempt. This does NOT weaken the boundary against the
# real hazard: the threat is a CONFUSED-not-adversarial gate agent that runs
# bin/sq-spawn.sh directly after adopting Squad's identity - it never sources
# Squad's test helpers, so it never carries the bypass; and the adversarial
# case (an agent that would deliberately set it) is covered by drill's
# neutral-execution-context and the HEAD-continuity guard. The dedicated
# tests/sq-gate-refuse.test.sh strips the bypass so it still verifies real refusal.
#
# Sourced by bin/sq-spawn.sh, bin/sq-send.sh, bin/sq-teardown.sh,
# bin/sq-sessionstart-nudge.sh, and the tests.
# No side effects on source. set -u / set -e safe. The refusal is a hard exit,
# not a return, because there is no safe way to continue a unit mutation from a
# gate context.

# The exit code every refusal uses, distinct enough to recognize in a caller or
# test as "the gate refusal fired" rather than an ordinary usage error.
SQUAD_GATE_REFUSE_EXIT=3

# fm_is_gate_agent: return 0 without output when this process looks like a
# drill gate agent. An optional root anchors the git-common-dir check;
# callers that omit it retain the historical current-worktree behavior.
fm_is_gate_agent() {
  local anchor=${1:-.} common
  if [ "${SQUAD_GATE_REFUSE_BYPASS:-}" = 1 ]; then
    return 1
  fi
  if [ "${DRILL_GATE+x}" = x ] || [ "${NO_MISTAKES_GATE+x}" = x ]; then
    SQUAD_GATE_REFUSE_REASON='env'
    return 0
  fi
  common=$(cd "$anchor" 2>/dev/null \
    && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo /nonexistent)" 2>/dev/null \
    && pwd -P || true)
  case "$common" in
    */.drill/repos/*.git|*/.no-mistakes/repos/*.git)
      SQUAD_GATE_REFUSE_REASON='path'
      SQUAD_GATE_REFUSE_COMMON=$common
      return 0 ;;
  esac
  return 1
}

# fm_refuse_if_gate_agent: exit SQUAD_GATE_REFUSE_EXIT with a clear stderr message if
# this process looks like a drill gate agent. Call before any unit
# mutation. No-ops (returns 0) for a normal Squad session, or when Squad's
# own test harness sets SQUAD_GATE_REFUSE_BYPASS=1 (see the header).
fm_refuse_if_gate_agent() {
  fm_is_gate_agent "${1:-.}" || return 0
  if [ "$SQUAD_GATE_REFUSE_REASON" = env ]; then
    echo "error: drill gate agent must not drive the unit (DRILL_GATE/NO_MISTAKES_GATE set)" >&2
  else
    echo "error: refusing unit lifecycle from inside a drill gate worktree ($SQUAD_GATE_REFUSE_COMMON)" >&2
  fi
  exit "$SQUAD_GATE_REFUSE_EXIT"
}
