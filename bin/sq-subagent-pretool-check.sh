#!/usr/bin/env bash
# PreToolUse guard against primary-session delegation outside the unit.
#
# A Squad primary that delegates through a harness's own delegation,
# scheduling, or background-work tool creates work with no `state/<id>.meta` and
# no `data/<id>/brief.md`. Only `bin/sq-spawn.sh` writes that metadata, and
# untracked project work contributes nothing to the in-flight branch of
# bin/sq-supervision-lib.sh or bin/sq-turnend-guard.sh. So such work is not
# merely unsupervised: absent an independent X-mode need, it makes the whole
# guard stack structurally inert, and it dies with the primary session instead
# of living in its own backend session.
#
# This scoped PreToolUse guard is the shipped mechanism.
# Claude primaries should also use an untracked per-base local
# `permissions.deny` list as hardening for known Claude delegation tools,
# because it removes them from the model's schema entirely.
# That deny list must not be tracked: it is Claude-only rather than
# harness-agnostic, and tracked project settings propagate into linked
# worktrees where they disarm legitimate operators.
# The tracked Claude matcher is deliberately `.*`: a stem-enumerating matcher
# would reintroduce the fail-open-by-enumeration problem this guard exists to
# solve, because any future tool name outside the matcher would never reach this
# script.
# This script is therefore the single owner of classification.
# It matches a delegation-SHAPED tool name rather than a fixed list, so a future
# tool that ships before anyone updates a local deny list is still refused.
#
# The guard is narrow by design. It classifies ONE thing: the shape of the tool
# name. It makes no judgment about whether the work should be delegated at all,
# which is a reasoning boundary no tool-shape hook can enforce.
# See docs/subagent-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/sq-subagent-pretool-check.sh
#   bin/sq-subagent-pretool-check.sh --tool '<tool-name>'
#
# Stdin mode extracts .tool_name for Claude and Codex, or .toolName for Grok.
# CLI mode is for adapters that already hold the tool name (OpenCode, Pi).
#
# Exit/output contract (identical shape to bin/sq-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine primary base (an operator/recon task worktree or a
#           non-Squad repo): exit 0 with no output, exactly like ALLOW.
#   ESCAPE - SQUAD_ALLOW_SUBAGENT=1 in the environment allows deliberately.
#   FAIL OPEN - malformed or empty stdin, or missing jq for stdin transport.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

# Lowercase substrings that mark a tool name as delegation-shaped: it creates
# work, an agent, a schedule, or an isolated workspace that Squad would not
# know about. This list is the single owner of the shipped classification.
DELEGATION_STEMS='agent subagent task workflow cron schedul worktree delegate spawn dispatch handoff remote sendmessage monitor'

# Exact lowercase tool names that match a stem above but only OBSERVE or STOP
# work that already exists. Reading or ending unaccounted work is not creating
# it, and denying these would strand already-running work with no way to inspect
# or end it. A local Claude deny list may still remove these from the
# schema; this shipped guard deliberately stays narrower so it can never be the
# reason a runaway task cannot be stopped.
OBSERVE_ONLY_TOOLS='taskoutput taskstop taskget tasklist cronlist bashoutput killshell'

# Exact lowercase tool names that match a stem above but create no RUNNABLE
# work. These write only the harness's session-local todo list, which has no
# executor: it spawns no agent, allocates no worktree, registers no schedule,
# and starts nothing that could outlive the session or escape a Squad
# guard. Denying them stops the primary tracking its own plan while granting no
# delegation power, and the deny text would tell it to run bin/sq-brief.sh for a
# todo entry, so the stem match here is a false positive rather than a policy.
# This is a separate list from OBSERVE_ONLY_TOOLS on purpose: these tools WRITE,
# so folding them into a list documented as observe-or-stop would make that
# contract untrue. Both lists are exact-name, never substring, so neither can
# widen by accident.
PLAN_ONLY_TOOLS='taskcreate taskupdate'

TOOL=""
TOOL_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: sq-subagent-pretool-check.sh [--tool <tool-name>] [--claude]

With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_name, or Grok toolName).
Denies a delegation-SHAPED tool name in a genuine primary home.
Claude primaries may also add an untracked per-home permissions.deny list that
removes known delegation tools from the model schema before this hook is needed.
Do not ship that Claude-only list in tracked project settings, because linked
worktrees inherit it and legitimate operators would lose their delegation tools.
This hook remains as the shipped guard for future delegation-shaped names
outside any local fixed list.
Fires only in a genuine Squad primary home; it is a silent no-op in a
operator/recon task worktree or any non-Squad repo, where a worker using
delegation tools is legitimate.
Exits 0 to allow and 2 to deny, naming the real operator dispatch path instead.
Set SQUAD_ALLOW_SUBAGENT=1 in the session environment to allow deliberately.
Malformed transport fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      TOOL_SET=1
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
      TOOL_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
fi

[ -n "$TOOL" ] || exit 0

LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

# An MCP tool belongs to an external integration, not to the harness's own
# delegation surface, and its name is chosen by that server. Never classify one
# here: an MCP server with a task or agent noun in a tool name is common and
# blocking it would be a false positive with no bearing on unit dispatch.
case "$TOOL" in
  mcp__*) exit 0 ;;
esac

for allowed in $OBSERVE_ONLY_TOOLS $PLAN_ONLY_TOOLS; do
  [ "$NORMALIZED" != "$allowed" ] || exit 0
done

MATCHED=""
for stem in $DELEGATION_STEMS; do
  case "$NORMALIZED" in
    *"$stem"*) MATCHED=$stem; break ;;
  esac
done
[ -n "$MATCHED" ] || exit 0

# The single deliberate escape hatch. It is an environment variable rather than
# a flag or a state file so it must be set when the session is launched, which
# makes a genuinely intended use possible and an accidental one impossible: no
# in-session tool call can set it for the call that follows.
[ "${SQUAD_ALLOW_SUBAGENT:-}" != "1" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
SQUAD_HOME=${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}
STATE=${SQUAD_STATE_OVERRIDE:-$SQUAD_HOME/state}

# Scope to a genuine primary base, exactly as the session-start nudge and the
# turn-end guard do. fm_primary_scope_matches accepts a plain checkout or a
# marked XO base - both operate a unit and must dispatch through it -
# and rejects a linked task worktree, which is the shape bin/sq-spawn.sh always
# hands an operator. An operator using delegation tools inside its own task
# worktree is legitimate and stays allowed. Any failure to confirm the base is
# inert (exit 0), never a block, so a broken environment never denies a call.
# shellcheck source=bin/sq-primary-scope-lib.sh
. "$SCRIPT_DIR/sq-primary-scope-lib.sh"
fm_primary_scope_matches "$SQUAD_ROOT" "$STATE" || exit 0

# Name the dedicated recon entry point only when this base carries it; degrade
# to the two-step brief-then-spawn path when it does not, rather than naming a
# script that is not there.
if [ -f "$SQUAD_ROOT/bin/sq-recon.sh" ]; then
  ROUTE='first classify the work under the AGENTS.md intake contract: work already classified as a recon goes to bin/sq-recon.sh "<question>" [project], while authorized ship work and its bounded research go to bin/sq-brief.sh then bin/sq-spawn.sh'
else
  ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/sq-brief.sh followed by bin/sq-spawn.sh for dispatched work'
fi

REASON="[subagent-dispatch] the Squad primary dispatches through the unit, not the harness's own delegation tools: work started that way has no durable unit record, leaves every Squad guard inert, and dies with this session. Instead, $ROUTE (blocked tool: $TOOL, delegation-shaped on \"$MATCHED\"). Launch the session with SQUAD_ALLOW_SUBAGENT=1 for a deliberate exception."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
