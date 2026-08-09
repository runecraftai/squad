#!/usr/bin/env bash
# Bootstrap detection, best-effort unit refresh/prune, and installs.
# Usage: sq-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "UNIT_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "TANGLE: <remediation>",
#                 "XO_SYNC: XO <id>: skipped: <reason>",
#                 "NUDGE_XOS: XO <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged sq-<id> with '<message>'",
#                 "XO_LIVENESS: XO <id>: skipped: <reason>|respawn failed after <cause>: <reason>",
#                 "XO_HANDOFF: XO <id>: pending delivery: <n> item(s)",
#                 "SQX: X mode on ..." or "SQX: X mode off ...".
#          When a RUNNING local XO worktree is fast-forwarded to
#          Squad's own current default-branch commit, that update is a
#          purely local fast-forward and never an origin fetch. Remote routes
#          instead converge the persistent home to their configured remote code
#          root. If either placement changes its loaded instruction surface
#          (AGENTS.md, bin/, or .agents/skills/), bootstrap immediately nudges it
#          via SQUAD_HOME=<active-home> bin/sq-send.sh sq-<id> so meta resolves the
#          current route and the standard from-squad marker is applied. A
#          successful send prints one BOOTSTRAP_INFO line with the exact target
#          and message sent; a failed send leaves an idempotent retry marker
#          under state/.XO-nudge-pending/ and prints an actionable
#          NUDGE_XOS line.
#          Already-current or no-instruction-change homes are silently left alone.
#          The XO sweep also propagates declared inherited local material
#          into each validated live XO home.
#          XO_SYNC lines report actionable skipped placement-specific
#          syncs or inheritance failures for live XO homes, plus
#          quarantine diagnostics for divergent shared commander-preference
#          copies; no-op/current and successful updates stay quiet.
#          XO_LIVENESS lines report only actionable failures from the
#          recovery-grade state owned by bin/sq-backend.sh's
#          fm_backend_agent_state: skipped distinguishes an existing ambiguous
#          process, an unreadable target, and an unverified backend; respawn
#          failed names whether the endpoint was missing or agent-less.
#          Already-live and successfully relaunched XOs are silent
#          unless SQUAD_BOOTSTRAP_VERBOSE_FACTS=1 requests BOOTSTRAP_INFO facts.
#          A TANGLE line means the Squad primary checkout (SQUAD_ROOT) is stranded
#          on a feature branch instead of its default branch - a operator's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          fob is also MISSING when its installed version lacks
#          "fob get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
#          The AXI-family floor policy is owned beside GH_AXI_MIN and
#          LAVISH_AXI_MIN below; the per-tool owners point there. An installed
#          build below its floor reports MISSING like no-mistakes, so the operator
#          is asked to upgrade rather than silently running an older tool.
#          tasks-axi feature probes remain a separate defense-in-depth check.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). A compatible tasks-axi default backend is silent.
#          quota-axi is required for the agent-owned dispatch-profile array
#          procedure in AGENTS.md section 4 and
#          .agents/skills/quota-array-dispatch/SKILL.md.
#          On a primary home, the locked mutable path materializes the visible
#          default config/startup-memory-budget=7500 when absent. It never
#          guesses at malformed or unsafe existing files, and XO homes
#          await the primary-authoritative inherited value instead of creating
#          their own.
#          X mode is OPTIONAL and inert unless SQUAD_HOME/.env has a non-empty
#          SQX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an SQX line.
#          Unit sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by SQUAD_UNIT_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed sq-unit-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set SQUAD_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          Set SQUAD_BOOTSTRAP_DETECT_ONLY=1 to skip the six MUTATING sweeps
#          (PR-check migration, XO_sync, XO_liveness_sweep,
#          XO_handoff_resume, x_mode_setup, fleet_sync) while still
#          printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          sq-session-start.sh's read-only path when another live session holds
#          the unit lock, so a second concurrent session never race-mutates
#          PR-check artifacts, XO homes, pending handoff outboxes,
#          X-mode artifacts, project clones, or repair instructions.
#          Unset/0 (the default) runs every sweep exactly as before - this flag
#          is purely additive.
#          Set SQUAD_BOOTSTRAP_NETWORK to split this run by whether a step talks to
#          the network, so a session start can print its digest from local reads
#          alone and run the network half concurrently:
#            all  (default, and any unrecognized value) - everything, exactly as
#                 before. Unrecognized values fall back here on purpose: a typo
#                 must never silently skip a safety sweep.
#            skip - every LOCAL step, and none of the network ones. Skips
#                 `gh auth status`, XO_liveness_sweep, XO_sync,
#                 XO_handoff_resume, and fleet_sync.
#            only - ONLY those network steps and nothing else. No tool detection,
#                 no version floors, no tangle check, no PR-check migration, no
#                 x_mode_setup: those already ran on the local pass.
#          SQUAD_BOOTSTRAP_DETECT_ONLY composes with it unchanged, so `only` plus
#          detect-only is the read-only `gh auth status` probe on its own.
#          bin/sq-startup-network.sh owns the deferral: it runs the `only` phase
#          in a detached bounded worker and publishes the result. This file stays
#          the single owner of every sweep, and the split changes only WHEN each
#          runs, never WHETHER.
#          A relaunch that the liveness sweep performs during an `only` run is
#          always reported, because a digest composed before that run already
#          printed the superseded endpoint record.
#          Set SQUAD_BOOTSTRAP_LOCKED=1 alongside it when the sweeps are skipped
#          because THIS session already ran them while holding the unit lock,
#          rather than because it has no lock at all. The two cases differ in
#          exactly one place: repair ownership. A locked session is told to
#          restore a tangled primary checkout itself, while an unlocked one is
#          told to leave that work to the lock holder. Unset/0 (the default)
#          keeps detect-only meaning unlocked, exactly as before.
#        sq-bootstrap.sh install <tool>...
#          Install the named tools (only ones the commander approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_HOME="${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}"
PROJECTS="${SQUAD_PROJECTS_OVERRIDE:-$SQUAD_HOME/projects}"
CONFIG="${SQUAD_CONFIG_OVERRIDE:-$SQUAD_HOME/config}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_HOME/state}"
DATA="${SQUAD_DATA_OVERRIDE:-$SQUAD_HOME/data}"
# shellcheck source=bin/sq-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-tasks-axi-lib.sh"
# shellcheck source=bin/sq-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-quota-axi-lib.sh"
# shellcheck source=bin/sq-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-tangle-lib.sh"
# shellcheck source=bin/sq-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-ff-lib.sh"
# shellcheck source=bin/sq-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-config-inherit-lib.sh"
# shellcheck source=bin/sq-xo-nudge-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-xo-nudge-lib.sh"
# shellcheck source=bin/sq-startup-memory-budget-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-startup-memory-budget-lib.sh"
# shellcheck source=bin/sq-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-x-lib.sh"
# shellcheck source=bin/sq-backend.sh disable=SC1091
. "$SCRIPT_DIR/sq-backend.sh"
# shellcheck source=bin/sq-remote-readiness-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-remote-readiness-lib.sh"
# sq-timing-lib.sh is inert unless SQUAD_TIMING_LOG names a file, which only the
# deferred network stage sets, so an ordinary bootstrap run records nothing.
# shellcheck source=bin/sq-timing-lib.sh disable=SC1091
. "$SCRIPT_DIR/sq-timing-lib.sh"

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep.
case "${SQUAD_BOOTSTRAP_NETWORK:-all}" in
  skip|only) SQUAD_BOOTSTRAP_NETWORK_PHASE=${SQUAD_BOOTSTRAP_NETWORK:-all} ;;
  *) SQUAD_BOOTSTRAP_NETWORK_PHASE=all ;;
esac
local_phase() { [ "$SQUAD_BOOTSTRAP_NETWORK_PHASE" != only ]; }
network_phase() { [ "$SQUAD_BOOTSTRAP_NETWORK_PHASE" != skip ]; }

network_mutation_authorized() {
  local expected=${SQUAD_BOOTSTRAP_NETWORK_LOCK_PID:-} current
  [ -n "$expected" ] || return 0
  case "$expected" in *[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

network_sweep_authorized() {
  local label=$1
  if network_mutation_authorized; then
    return 0
  fi
  echo "NETWORK_CHECKS: unit lock ownership changed before $label, so this stale worker skipped that sweep"
  return 1
}

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${SQUAD_UNIT_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$SQUAD_UNIT_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$SQUAD_UNIT_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "UNIT_SYNC: $line" ;;
      *': STUCK:'*) echo "UNIT_SYNC: $line" ;;
      *': recovered:'*) echo "UNIT_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "UNIT_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$SQUAD_ROOT/bin/sq-unit-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/sq-unit-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$SQUAD_ROOT/bin/sq-unit-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "UNIT_SYNC: unit: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

XO_sync() {
  # shellcheck source=bin/sq-stand-to-lib.sh disable=SC1091
  . "$SCRIPT_DIR/sq-stand-to-lib.sh"
  # Placement-specific XO sync: local homes fast-forward to the primary
  # checkout's current default-branch commit. That path is purely LOCAL - no
  # fetch, no origin dependency: a linked-worktree home already holds the primary's
  # commit (sq-ff-lib.sh), while a standalone clone without it is skipped until
  # /updatesquad refreshes it from origin. Startup sends reread nudges only
  # for RUNNING XOs whose instruction surface (AGENTS.md, bin/, or
  # .agents/skills/) actually changed, so a XO already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Unlike
  # /updatesquad, startup owns the live-convergence send itself because it is
  # a deterministic locked sweep and can report success as BOOTSTRAP_INFO while
  # preserving failed sends as NUDGE_XOS retry markers.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$SQUAD_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=xo' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "XO_SYNC: XO $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  SECOND_MATE_NUDGE_MESSAGE=$SQUAD_SECOND_MATE_NUDGE_MESSAGE
  REMOTE_SECOND_MATE_NUDGE_MESSAGE=$SQUAD_REMOTE_SECOND_MATE_NUDGE_MESSAGE
  SECOND_MATE_NUDGE_PENDING_DIR="$STATE/.XO-nudge-pending"

  XO_nudge_marker_path() {
    fm_XO_nudge_marker_path "$STATE" "$1"
  }

  XO_write_nudge_marker() {
    local id=$1 home=$2 commit=$3 instr=$4 message=${5:-$SECOND_MATE_NUDGE_MESSAGE} remote=${6:-0}
    fm_XO_nudge_write "$STATE" "$id" "$home" "$commit" "$instr" "$message" "$remote"
  }

  XO_send_nudge() {
    local id=$1 home=$2 commit=$3 instr=$4 selector marker out
    selector="sq-$id"
    marker=$(XO_nudge_marker_path "$id") || {
      echo "NUDGE_XOS: XO $id: send failed: unsafe id"
      return 0
    }
    if ! XO_write_nudge_marker "$id" "$home" "$commit" "$instr"; then
      echo "NUDGE_XOS: XO $id: send failed: cannot record retry marker"
      return 0
    fi
    if out=$(SQUAD_HOME="$SQUAD_HOME" SQUAD_ROOT_OVERRIDE="$SQUAD_ROOT" SQUAD_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/sq-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
      rm -f "$marker"
      echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
    else
      echo "NUDGE_XOS: XO $id: send failed: $(first_line "$out")"
    fi
  }

  fm_ff_after_instruction_update() {
    local id=$1 home=$2 _window=$3 instr=$4
    XO_send_nudge "$id" "$home" "$primary_head" "$instr"
  }

  XO_retry_pending_nudges() {
    local marker id selector home commit message remote expected_marker meta meta_home home_real head out
    [ -d "$SECOND_MATE_NUDGE_PENDING_DIR" ] || return 0
    for marker in "$SECOND_MATE_NUDGE_PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      id=$(fm_meta_get "$marker" id)
      if ! expected_marker=$(XO_nudge_marker_path "$id"); then
        echo "NUDGE_XOS: XO ${id:-unknown}: send failed: retry marker has unsafe id"
        continue
      fi
      [ "$expected_marker" = "$marker" ] || {
        echo "NUDGE_XOS: XO $id: send failed: retry marker filename mismatch"
        continue
      }
      selector=$(fm_meta_get "$marker" selector)
      home=$(fm_meta_get "$marker" home)
      commit=$(fm_meta_get "$marker" commit)
      message=$(fm_meta_get "$marker" message)
      remote=$(fm_meta_get "$marker" remote)
      [ -n "$remote" ] || remote=0
      [ "$selector" = "sq-$id" ] || {
        echo "NUDGE_XOS: XO ${id:-unknown}: send failed: retry marker selector mismatch"
        continue
      }
      case "$remote" in
        0) [ "$message" = "$SECOND_MATE_NUDGE_MESSAGE" ] || {
          echo "NUDGE_XOS: XO ${id:-unknown}: send failed: retry marker message mismatch"
          continue
        } ;;
        1) [ "$message" = "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" ] || {
          echo "NUDGE_XOS: XO ${id:-unknown}: send failed: remote retry marker message mismatch"
          continue
        } ;;
        *)
          echo "NUDGE_XOS: XO ${id:-unknown}: send failed: retry marker placement is invalid"
          continue
          ;;
      esac
      [ "$remote" -ne 1 ] || continue
      meta="$STATE/$id.meta"
      [ -f "$meta" ] && [ "$(fm_meta_get "$meta" kind)" = XO ] || {
        echo "NUDGE_XOS: XO ${id:-unknown}: send failed: retry target has no live XO metadata"
        continue
      }
      meta_home=$(fm_meta_get "$meta" home)
      [ -n "$meta_home" ] || meta_home=$(XO_registry_field "$DATA/XOs.md" "$id" home || true)
      if ! validate_XO_home "$id" "$meta_home"; then
        echo "NUDGE_XOS: XO $id: send failed: retry target home unsafe: $VALIDATION_ERROR"
        continue
      fi
      home_real="$VALIDATED_HOME"
      [ "$home_real" = "$home" ] || {
        echo "NUDGE_XOS: XO $id: send failed: retry target home changed"
        continue
      }
      head=$(git -C "$home_real" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || {
        echo "NUDGE_XOS: XO $id: send failed: retry target is not at recorded instruction commit"
        continue
      }
      if out=$(SQUAD_HOME="$SQUAD_HOME" SQUAD_ROOT_OVERRIDE="$SQUAD_ROOT" SQUAD_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/sq-send.sh" "$selector" "$SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$marker"
        echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
      else
        echo "NUDGE_XOS: XO $id: send failed: $(first_line "$out")"
      fi
    done
  }

  local tmp line
  XO_retry_pending_nudges
  tmp=$(mktemp "${TMPDIR:-/tmp}/sq-xo-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_XO_metas "$STATE" "$primary_head" yes "$DATA/XOs.md" >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      XO\ *': skipped:'*) echo "XO_SYNC: $line" ;;
      BOOTSTRAP_INFO:\ *) echo "$line" ;;
      NUDGE_XOS:\ *) echo "$line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  unset -f fm_ff_after_instruction_update
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into every VALIDATED live XO home swept above.
  # FF_SEEN_HOMES is exactly that set, and sq-config-inherit-lib.sh owns the
  # declared config items plus data/commander-shared.md.
  # After a successful push that changes allowlisted config/* for an already-
  # running home, send its literal-content reread instruction pointer so the
  # live agent does not keep applying stale defaults. Spawn/respawn already
  # re-reads at launch and needs no redundant nudge unless files changed after launch.
  local id home home_real home_lock propagated_homes report reread_out reread_skip_pending
  propagated_homes=""
  XO_RESPAWNED_IDS=${XO_RESPAWNED_IDS:-}
  while IFS='|' read -r id home _window _meta; do
    validate_XO_home "$id" "$home" || continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    mkdir -p "$home_real/state" || {
      echo "CONFIG_REREAD: XO $id: send failed: could not create state directory"
      continue
    }
    home_lock=$(fm_config_inherit_lock_path "$home_real") || {
      echo "CONFIG_REREAD: XO $id: send failed: could not resolve per-home lock"
      continue
    }
    fm_lock_acquire_wait "$home_lock" || {
      echo "CONFIG_REREAD: XO $id: send failed: could not acquire per-home lock"
      continue
    }
    reread_skip_pending=0
    case " $XO_RESPAWNED_IDS " in
      *" $id "*) reread_skip_pending=1 ;;
    esac
    if [ "$reread_skip_pending" -eq 0 ] \
      && fm_config_reread_retry_queue_is_full "$SQUAD_HOME" "$id"; then
      fm_config_reread_retry_pending "$id" "$home_real" || true
      if fm_config_reread_retry_queue_is_full "$SQUAD_HOME" "$id"; then
        echo "CONFIG_REREAD: XO $id: send failed: retry instruction queue is full"
        fm_lock_release "$home_lock" || true
        continue
      fi
    fi
    report=$(mktemp "${TMPDIR:-/tmp}/sq-bootstrap-inherit.XXXXXX" 2>/dev/null) || {
      echo "XO_SYNC: XO $id: skipped: inheritance failed"
      fm_lock_release "$home_lock" || true
      continue
    }
    if SQUAD_CONFIG_INHERIT_REPORT="$report" SQUAD_CONFIG_INHERIT_LIVE=1 \
      propagate_XO_inheritance "$SQUAD_HOME" "$home_real" "$CONFIG" "$DATA"; then
      :
    else
      echo "XO_SYNC: XO $id: skipped: inheritance failed"
    fi
    if ! reread_out=$(SQUAD_HOME="$SQUAD_HOME" SQUAD_ROOT_OVERRIDE="$SQUAD_ROOT" \
      SQUAD_STATE_OVERRIDE="$STATE" \
      SQUAD_CONFIG_REREAD_SKIP_PENDING="$reread_skip_pending" \
      fm_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
      if [ -n "$reread_out" ]; then
        printf '%s\n' "$reread_out"
      else
        echo "CONFIG_REREAD: XO $id: send failed: unknown error"
      fi
    elif [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    fi
    rm -f "$report"
    fm_lock_release "$home_lock" || true
  done < <(live_XO_meta_records "$STATE" "$DATA/XOs.md")

  # One remote XO's convergence, split out of the loop so each host is
  # individually timed; every `return` here was a `continue` and still means
  # "move on to the next XO".
  XO_sync_remote_one() {  # <id> <home> <remote-host>
    local id=$1 _home=$2 remote_host=$3
    local sync_out inherit_out nudge_needed remote_marker remote_pending converged out remote_lock remote_generation
    remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_lock" ] || ! fm_lock_acquire_wait "$remote_lock"; then
      echo "NUDGE_XOS: XO $id: send failed: cannot lock remote inheritance transaction"
      return 0
    fi
    if ! "$SCRIPT_DIR/sq-procevent-remote-reply.sh" arm "$id" >/dev/null 2>&1; then
      echo "XO_LIVENESS: XO $id: skipped: remote reply source could not be registered"
    fi
    remote_generation=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_generation" ]; then
      echo "XO_SYNC: XO $id: skipped: remote inheritance generation could not be published"
      fm_lock_release "$remote_lock" || true
      return 0
    fi
    remote_marker=$(XO_nudge_marker_path "$id" 2>/dev/null || true)
    remote_pending=0
    if [ -f "$remote_marker" ] && [ "$(fm_meta_get "$remote_marker" remote)" = 1 ]; then remote_pending=1; fi
    if ! XO_write_nudge_marker "$id" "$_home" "" remote \
      "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 1; then
      echo "NUDGE_XOS: XO $id: send failed: cannot record remote retry marker"
      fm_lock_release "$remote_lock" || true
      return 0
    fi
    nudge_needed=0
    converged=1
    if sync_out=$("$SCRIPT_DIR/sq-on.sh" "$id" sq-remote-XO-control.sh sync "$id" < /dev/null 2>&1); then
      case "$sync_out" in synced:*) nudge_needed=1 ;; esac
    else
      echo "XO_SYNC: XO $id: skipped: remote tracked-file sync failed on $remote_host: $(first_line "$sync_out")"
      converged=0
    fi
    if inherit_out=$(SQUAD_CONFIG_INHERIT_LIVE=1 \
      "$SCRIPT_DIR/sq-remote-inherit-push.sh" "$id" "$remote_generation" 2>&1); then
      if printf '%s\n' "$inherit_out" | grep -Eq '^(pushed|removed):'; then nudge_needed=1; fi
    else
      echo "XO_SYNC: XO $id: skipped: remote inheritance failed on $remote_host: $(first_line "$inherit_out")"
      converged=0
    fi
    [ "$remote_pending" -eq 0 ] || nudge_needed=1
    if [ "$converged" -eq 1 ] && [ "$nudge_needed" -eq 1 ]; then
      if out=$(SQUAD_HOME="$SQUAD_HOME" SQUAD_ROOT_OVERRIDE="$SQUAD_ROOT" SQUAD_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/sq-send.sh" "sq-$id" "$REMOTE_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
        rm -f "$remote_marker"
        [ "${SQUAD_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: nudged remote sq-$id after convergence"
      else
        echo "NUDGE_XOS: XO $id: send failed: $(first_line "$out")"
      fi
    elif [ "$converged" -eq 1 ]; then
      rm -f "$remote_marker"
    fi
    fm_lock_release "$remote_lock" || true
    return 0
  }

  # Remote routes converge through the generic transport. Their code root and
  # inherited files are authoritative on that host; no local path probe or
  # local fast-forward is attempted for them.
  local remote_host __fm_timing_stamp
  while IFS='|' read -r id _home _window meta; do
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ -n "$remote_host" ] || continue
    __fm_timing_stamp=$(fm_timing_now_ms)
    XO_sync_remote_one "$id" "$_home" "$remote_host"
    fm_timing_record XO convergence "$__fm_timing_stamp" "$id@$remote_host"
  done < <(live_XO_meta_records "$STATE" "$DATA/XOs.md")
  return 0
}

# A relaunch replaces the endpoint record a digest may already have printed. On
# the local pass that digest has not been composed yet, so the fact stays behind
# SQUAD_BOOTSTRAP_VERBOSE_FACTS as before; on the deferred network pass the digest
# is already out, so reporting it is what keeps the superseded record from being
# acted on.
report_relaunch() {  # <id> <cause> <where>
  [ "${SQUAD_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] || ! local_phase || return 0
  echo "BOOTSTRAP_INFO: XO $1 relaunched after $2 ($3)"
}

XO_liveness_sweep() {
  # Idempotent XO liveness guarantee - SESSION START ONLY. The detailed
  # state machine and its only recovery-authorizing states are owned by
  # fm_backend_agent_state. A missing tmux pane is not enough: tmux must prove
  # the window or session absent. This preserves duplicate prevention for
  # existing ambiguous processes and every transiently unreadable target while
  # adding the missing-session path the original bare-shell and Herdr-husk sweep
  # lacked.
  # A meta with no window remains owned by xo-provisioning recovery.
  # XO homes never contain kind=xo meta, so this is naturally a
  # primary-only no-op there. Mid-session liveness remains explicitly out of
  # scope and requires a separate periodic signal.
  [ -d "$STATE" ] || return 0
  local meta id remote_host label __fm_timing_stamp
  XO_RESPAWNED_IDS=""
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=xo$' "$meta" 2>/dev/null || continue
    # Identity for the timing record is read here, in the loop, so the per-meta
    # body below keeps its single-exit-per-outcome shape.
    id=$(basename "$meta" .meta)
    remote_host=$(fm_meta_get "$meta" remote_host)
    label=$id
    [ -z "$remote_host" ] || label="$id@$remote_host"
    __fm_timing_stamp=$(fm_timing_now_ms)
    XO_liveness_one "$meta" "$id"
    fm_timing_record XO liveness "$__fm_timing_stamp" "$label"
  done
  return 0
}

# One XO's liveness check. Split out of the sweep so each is individually
# timed; every `return` here was a `continue` in the loop and means exactly the
# same thing - move on to the next XO. XO_RESPAWNED_IDS stays a
# global that this appends to, so the sweep's hand-off to XO_sync is
# unchanged.
XO_liveness_one() {  # <meta> <id>
  local meta=$1 id=$2
  local window harness backend target agent_state out cause remote_host remote_rc readiness_reason route_out remote_backend
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 0
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    remote_rc=0
    fm_remote_readiness_ensure "$SCRIPT_DIR" "$id" || remote_rc=$?
    if [ "$remote_rc" -eq 255 ]; then
      echo "XO_LIVENESS: XO $id: skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      readiness_reason=$(printf '%s\n' "$SQUAD_REMOTE_READINESS_OUT" \
        | awk '/^check [^=]+=(fixable|human):|^action:|^error:/ { print; exit }')
      [ -n "$readiness_reason" ] || readiness_reason=$(first_line "$SQUAD_REMOTE_READINESS_OUT")
      [ -n "$readiness_reason" ] || readiness_reason="unknown readiness failure"
      echo "XO_LIVENESS: XO $id: skipped: remote readiness failed on $remote_host: $readiness_reason"
      return 0
    fi
    if out=$("$SCRIPT_DIR/sq-on.sh" "$id" sq-remote-XO-control.sh state "$id" < /dev/null 2>/dev/null); then
      remote_rc=0
    else
      remote_rc=$?
    fi
    if [ "$remote_rc" -eq 255 ]; then
      echo "XO_LIVENESS: XO $id: skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      echo "XO_LIVENESS: XO $id: skipped: remote endpoint probe unreadable on $remote_host"
      return 0
    fi
    agent_state=$(printf '%s\n' "$out" | tail -1)
    case "$agent_state" in
      alive)
        if route_out=$("$SCRIPT_DIR/sq-on.sh" "$id" sq-remote-XO-control.sh route "$id" < /dev/null 2>/dev/null); then
          remote_rc=0
        else
          remote_rc=$?
        fi
        if [ "$remote_rc" -eq 255 ]; then
          echo "XO_LIVENESS: XO $id: skipped: remote host unavailable or endpoint route unknown; route preserved on $remote_host"
          return 0
        fi
        if [ "$remote_rc" -ne 0 ]; then
          echo "XO_LIVENESS: XO $id: skipped: alive remote endpoint route is unreadable on $remote_host; inspect and migrate or retire it explicitly"
          return 0
        fi
        remote_backend=$(printf '%s\n' "$route_out" | sed -n 's/^backend=//p' | tail -1)
        if [ "$remote_backend" != herdr ]; then
          echo "XO_LIVENESS: XO $id: skipped: alive remote endpoint is recorded on backend '${remote_backend:-missing}'; migrate or retire it explicitly"
          return 0
        fi
        [ "${SQUAD_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] || echo "BOOTSTRAP_INFO: remote XO $id already live (host=$remote_host)"
        ;;
      dead|missing)
        cause="remote endpoint $agent_state on its configured host"
        if out=$(SQUAD_SPAWN_NO_GUARD=1 "$SQUAD_ROOT/bin/sq-spawn.sh" "$id" --XO 2>&1); then
          XO_RESPAWNED_IDS="$XO_RESPAWNED_IDS $id"
          report_relaunch "$id" "$cause" "host=$remote_host"
        else
          echo "XO_LIVENESS: XO $id: respawn failed after $cause: $(first_line "$out")"
        fi
        ;;
      ambiguous|unreadable|unverified)
        echo "XO_LIVENESS: XO $id: skipped: remote endpoint state is $agent_state on $remote_host"
        ;;
      *) echo "XO_LIVENESS: XO $id: skipped: remote endpoint returned an invalid state" ;;
    esac
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target="$window"
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi) ;;
    *)
      case "$agent_state" in dead|missing) agent_state=unverified-harness ;; esac
      ;;
  esac
  case "$agent_state" in
    alive)
      if [ "${SQUAD_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
        echo "BOOTSTRAP_INFO: XO $id already live (backend=$backend)"
      fi
      ;;
    dead|missing)
      if [ "$agent_state" = dead ]; then
        cause="confirmed agent absence on existing endpoint"
        fm_backend_kill "$backend" "$target" 2>/dev/null || true
      else
        cause="recorded endpoint confidently missing"
      fi
      if out=$(SQUAD_SPAWN_NO_GUARD=1 "$SQUAD_ROOT/bin/sq-spawn.sh" "$id" --XO 2>&1); then
        XO_RESPAWNED_IDS="$XO_RESPAWNED_IDS $id"
        report_relaunch "$id" "$cause" "backend=$backend"
      else
        echo "XO_LIVENESS: XO $id: respawn failed after $cause: $(first_line "$out")"
      fi
      ;;
    ambiguous)
      echo "XO_LIVENESS: XO $id: skipped: existing endpoint has ambiguous agent process (backend=$backend)"
      ;;
    unreadable)
      echo "XO_LIVENESS: XO $id: skipped: endpoint probe unreadable (backend=$backend)"
      ;;
    unverified-harness)
      echo "XO_LIVENESS: XO $id: skipped: recorded harness '$harness' is unverified for recovery (backend=$backend)"
      ;;
    *)
      echo "XO_LIVENESS: XO $id: skipped: agent recovery classifier unverified (backend=$backend)"
      ;;
  esac
  return 0
}

XO_handoff_resume() {
  [ -d "$DATA/handoff" ] || return 0
  "$SCRIPT_DIR/sq-backlog-handoff.sh" --resume-pending >/dev/null 2>&1 || true
}

XO_handoff_detect() {
  local outbox id count
  [ -d "$DATA/handoff" ] || return 0
  for outbox in "$DATA/handoff"/*.outbox.md; do
    [ -e "$outbox" ] || continue
    id=$(basename "$outbox" .outbox.md)
    case "$id" in ''|*[!A-Za-z0-9._-]*) id=unknown ;; esac
    if [ ! -f "$outbox" ] || [ -L "$outbox" ]; then
      echo "XO_HANDOFF: XO $id: pending delivery: unsafe outbox"
      continue
    fi
    count=$(awk '/^- \[[ x]\] / { count++ } END { print count + 0 }' "$outbox" 2>/dev/null || printf unknown)
    echo "XO_HANDOFF: XO $id: pending delivery: $count item(s)"
  done
}

install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    fob) echo "curl -fsSL https://github.com/squad-org/squad/releases/latest/download/fob-install.sh | sh  # OQ-03 placeholder" ;;
    no-mistakes) echo "curl -fsSL https://github.com/squad-org/squad/releases/latest/download/no-mistakes-install.sh | sh  # OQ-03 placeholder" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/sq-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops fob. A backend value with
# no verified dependency set is reported before the universal checks continue.
COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN=1.31.2
# AXI-FAMILY FLOOR POLICY. Every axi-family floor is the CURRENT LATEST published
# version of that tool, commander-bumped periodically to keep the whole unit on the
# newest axi tools. It is NOT the minimum feature-introduced version. These floors
# are expected to drift upward as new versions ship. Never lower a floor to the
# earliest release that happens to satisfy some depended-on behavior. The
# tasks-axi feature probes are an independent defense-in-depth concern, not part
# of its floor.
GH_AXI_MIN=0.1.29
LAVISH_AXI_MIN=0.1.46

fob_supports_lease() {
  fob get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# Shared semantic-version floor for the tool gates below. A version string that
# cannot be parsed into exactly one major.minor.patch triple is incompatible,
# never assumed current, so a development or vendored build cannot pass a floor
# it was never checked against.
tool_version_at_least() {  # <tool> <min-version>
  local tool=$1 min=$2 output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.sq-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty SQX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated sentry dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-sentry.check.sh - byte-static identity shim; the sentry validates
#                            its bytes and invokes bin/sq-x-poll.sh directly
#   config/x-mode.env      - exports SQUAD_CHECK_INTERVAL=30, sourced by the sentry
#                            arm so only an X instance polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts. It never touches the sentry itself;
# applying a cadence transition to a running sentry is the caller's job via
# the emitted harness-aware supervision repair instruction.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing shim_home
  env_file="$SQUAD_HOME/.env"
  shim="$STATE/x-sentry.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get SQX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/sq-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='repair missing sentry supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "SQX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; $(x_mode_supervision_repair)"
      else
        echo "SQX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "SQX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "SQX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "SQX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "SQX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  case "$SQUAD_HOME" in
    /*) shim_home=$SQUAD_HOME ;;
    *)
      shim_home=$(CDPATH='' cd -- "$SQUAD_HOME" 2>/dev/null && pwd -P) \
        || { fmx_arm_failed; return 0; }
      ;;
  esac
  shim_body=$(fmx_poll_shim_content "$shim_home" "$SQUAD_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$shim_home" "$SQUAD_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by sq-bootstrap.sh - X mode sentry cadence.
# Source this before the active harness protocol starts a sentry process so
# sq-sentry.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export SQUAD_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "SQX: X mode on - relay poll armed via state/x-sentry.check.sh; 30s sentry cadence in config/x-mode.env"
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","pi-signed","grok","kimi","muse"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${SQUAD_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

startup_memory_budget_setup() {
  # Primary bootstrap owns default publication. A XO is deliberately
  # passive here because its setting must converge from the primary through the
  # inherited-local-material contract rather than becoming a local authority.
  if [ -e "$SQUAD_HOME/.sq-xo-home" ] || [ -L "$SQUAD_HOME/.sq-xo-home" ]; then
    return 0
  fi
  if ! fm_startup_memory_budget_materialize "$CONFIG"; then
    echo "STARTUP_MEMORY_BUDGET: invalid config/$SQUAD_STARTUP_MEMORY_BUDGET_FILE - $SQUAD_STARTUP_MEMORY_BUDGET_ERROR"
  fi
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: sq-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. It pauses an
# identity-matched sentry, holds its lock, and neutralizes legacy PR checks
# before any tool detection or later bootstrap mutation can leave old artifacts
# runnable. Detect-only sessions never touch state, and the deferred network pass
# never repeats it: the local pass that ran first already closed that window.
if [ "${SQUAD_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ] && local_phase; then
  "$SCRIPT_DIR/sq-pr-check-migrate.sh" || true
  startup_memory_budget_setup
fi

# Local detection: presence, version floors, and configuration. Nothing here
# leaves this machine, so it stays on the session-start critical path.
detect_local_tools() {
  if [ "$BACKEND_VALID" -eq 0 ]; then
    echo "BACKEND_INVALID: $BACKEND (known: $SQUAD_BACKEND_KNOWN)"
  fi
  for t in $BACKEND_TOOLS; do
    fm_backend_required_tool_available "$BACKEND" "$t" \
      || missing_tool_diagnostic "$t"
  done
  for t in $COMMON_TOOLS; do
    command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
  done
  # The fob lease-support upgrade check is only relevant when the resolved
  # backend actually requires fob (every backend except orca, which owns its
  # own worktrees); an orca home must not be told to upgrade a provider it never uses.
  if fm_backend_list_contains "$TOOLS" fob \
    && command -v fob >/dev/null 2>&1 && ! fob_supports_lease; then
    echo "MISSING: fob (install: $(install_cmd fob))"
  fi
  if command -v no-mistakes >/dev/null 2>&1 && ! tool_version_at_least no-mistakes "$NO_MISTAKES_MIN"; then
    echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
  fi
  if command -v gh-axi >/dev/null 2>&1 && ! tool_version_at_least gh-axi "$GH_AXI_MIN"; then
    echo "MISSING: gh-axi (install: $(install_cmd gh-axi))"
  fi
  if command -v lavish-axi >/dev/null 2>&1 && ! tool_version_at_least lavish-axi "$LAVISH_AXI_MIN"; then
    echo "MISSING: lavish-axi (install: $(install_cmd lavish-axi))"
  fi
  if command -v quota-axi >/dev/null 2>&1 && ! fm_quota_axi_compatible; then
    echo "MISSING: quota-axi (install: $(install_cmd quota-axi))"
  fi
  if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
    echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
  fi
}

detect_local_config() {
  # Worktree-tangle check: the Squad primary checkout (SQUAD_ROOT) must sit on its
  # default branch, not a feature branch (see sq-tangle-lib.sh). Scoped to the
  # primary only; detached-HEAD worktrees and XO homes never trip it.
  tangle_branch=$(fm_primary_tangle_branch "$SQUAD_ROOT" 2>/dev/null || true)
  if [ -n "$tangle_branch" ]; then
    tangle_default=$(fm_default_branch "$SQUAD_ROOT" 2>/dev/null || echo main)
    if [ "${SQUAD_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && [ "${SQUAD_BOOTSTRAP_LOCKED:-0}" != 1 ]; then
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the unit lock"
    else
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $SQUAD_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
    fi
  fi
  crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ "${SQUAD_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
    echo "BOOTSTRAP_INFO: crew harness override active: $crew"
  fi
  crew_dispatch_validate
  if [ "${SQUAD_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
    && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
    echo "BOOTSTRAP_INFO: tasks-axi available"
  fi
}

# The order below is the order the diagnostics have always printed in, so a
# `skip` run is the same output with the network lines removed rather than a
# reshuffle. `gh auth status` sits between the two local blocks because that is
# where it has always been.
# Each network owner below is bracketed by an elapsed-time record, so a deferred
# stage that ran long can be attributed to the phase that spent the time.
# sq-timing-lib.sh discards the record unless the caller asked for timings, and
# every sweep is still called directly and in the same order, so nothing about
# what runs, in what sequence, or what it returns changes.
# The stamp variable is named for the library rather than `start` on purpose:
# fleet_sync and others assign plain names like `start` without `local`, and
# bash's dynamic scoping would let them overwrite a stamp held by a caller.
local_phase && detect_local_tools
if network_phase; then
  __fm_timing_stamp=$(fm_timing_now_ms)
  gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
  fm_timing_record phase gh-auth "$__fm_timing_stamp"
fi
local_phase && detect_local_config

if [ "${SQUAD_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  # XO_sync consumes XO_RESPAWNED_IDS from the liveness sweep, so
  # those two always run together in the same phase.
  if network_phase; then
    if network_sweep_authorized 'dead-XO relaunch'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      XO_liveness_sweep
      fm_timing_record phase XO-liveness "$__fm_timing_stamp"
    fi
    if network_sweep_authorized 'XO convergence'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      XO_sync
      fm_timing_record phase XO-sync "$__fm_timing_stamp"
    fi
    if network_sweep_authorized 'pending handoff delivery'; then
      __fm_timing_stamp=$(fm_timing_now_ms)
      XO_handoff_resume
      fm_timing_record phase handoff-delivery "$__fm_timing_stamp"
    fi
  fi
  # x_mode_setup writes local Relay artifacts only and never leaves the machine.
  local_phase && x_mode_setup
  if network_phase && network_sweep_authorized 'project clone refresh'; then
    __fm_timing_stamp=$(fm_timing_now_ms)
    fleet_sync
    fm_timing_record phase unit-sync "$__fm_timing_stamp"
  fi
fi
local_phase && XO_handoff_detect
exit 0
