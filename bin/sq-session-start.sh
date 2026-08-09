#!/usr/bin/env bash
# sq-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# sq-bootstrap.sh, then separately read data/projects.md, data/XOs.md,
# data/commander.md, data/commander-shared.md, data/learnings.md, then run
# sq-lock.sh, sq-stand-to-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls sq-lock.sh, sq-bootstrap.sh,
# sq-stand-to-drain.sh, and sq-startup-network.sh as real subprocesses and prints
# their real output. It never re-implements their logic; all
# sequencing/formatting logic added here stays local to this file. Those four
# scripts remain fully working
# standalone with unchanged default behavior - other flows (sq-bootstrap.sh
# install <tools> after consent, /updatesquad, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in SQUAD_BOOTSTRAP_DETECT_ONLY=1 flag on sq-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's six MUTATING sweeps
#                       (legacy PR-check migration, XO convergence,
#                       XO liveness, pending remote handoff retry,
#                       X-mode artifact writes, unit sync) also run only when
#                       locked; the four network sweeps run in the deferred
#                       stage rather than this synchronous bootstrap section.
#   3. stand-to drain     - mutates the durable stand-to queue, so it also only runs
#                       when locked.
#   4. supervision-instructions - the one emitted operating block for the
#                       detected primary harness.
#   5. read-once contract - the do-not-re-read contract covering every source
#                       represented by the two digests below.
#   6. unit digest   - a compact data/backlog.md identity/metadata listing,
#                       every state/*.meta, a bounded state/*.status tail,
#                       state/.afk, and a cheap per-task endpoint-liveness read:
#                       read-only, always runs.
#   7. network checks - the result of the deferred network stage started back at
#                       step 1, harvested WITHOUT waiting for it.
#   8. context digest - data/projects.md, data/XOs.md, data/commander.md,
#                       data/commander-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   9. closing reminder - prints the context-specific sentry next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the sentry itself.
#
# Those nine names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization, so anything it waits for is time the commander
# waits before the first turn - and every external-network call it used to make
# was individually unbounded. One unreachable remote XO could burn the
# entire SQUAD_SESSION_START_TIMEOUT and truncate the digest, so a slow network
# could cost the work queue itself.
# So no step between here and the last line below makes an external-network
# call. The five that did - `gh auth status`, XO liveness, XO
# convergence, pending remote handoff delivery, and the unit-sync fetch - are
# started as one detached bounded worker right after the lock (step 1) and
# harvested at step 7 without ever blocking on it. bin/sq-startup-network.sh
# owns that stage and its safety argument; bin/sq-bootstrap.sh remains the owner
# of the sweeps themselves and still runs every one of them.
# The digest is therefore composed from local reads and local subprocesses only,
# and an unreachable host now delays a reported check rather than the startup.
# What this deliberately trades: on a slow network the digest prints "IN
# PROGRESS" and names exactly which checks are not yet confirmed, instead of
# waiting for them. It never reports an unconfirmed check as passed.
#
# ORDERING, and why UNIT STATE now runs before CONTEXT: this digest is
# delivered through a harness that truncates an oversized payload from the TAIL,
# and it has really been truncated in practice - a 70KB digest arrived as lines
# 1-435 of 578, cutting off eight lines before the live-task inventory. What a
# truncated tail drops must therefore be the CHEAPEST thing to lose. Curated
# memory is stable session to session, is already governed by a commander-set
# budget (config/startup-memory-budget), and is recoverable with one targeted
# read; live unit identity - which tasks exist, their windows, worktrees,
# backends, and endpoint liveness - changes every session and is exactly what
# recovery depends on. So unit state goes first and the memory files absorb the
# truncation. The read-once contract moves ahead of both for the same reason: a
# contract that only arrives after the payload it governs is the first thing a
# truncated digest loses, and it carries the truncation caveat that keeps it
# honest when a stage below it never ran.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# XO homes, retrying pending handoff outboxes, writing X-mode artifacts,
# and fetching or fast-forwarding every project clone - before ever discovering
# another session already holds the lock. Two sessions racing those sweeps is
# exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in SQUAD_BOOTSTRAP_DETECT_ONLY=1
# mode) for its local read-only detect lines - missing tools, the worktree-tangle
# check, the harness override, crew-dispatch validation, tasks-axi and quota-axi
# tool checks, and tasks-axi availability - none of which mutate shared state
# and all of which are safe to compute without verified lock ownership.
# It deliberately skips the network-only GitHub-auth probe because a read-only
# session has no dispatch, spawn, steer, or merge action for that verdict to gate.
# Only projection cleanup, the six bootstrap mutating sweeps, and the
# stand-to queue drain are skipped.
# The context and unit-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: the startup listing is a RECOVERY input, not a reporting
# surface, so it carries what this turn can act on and nothing else.
#   - `done` rows are never listed. Retained completion history belongs to the
#     reporting surfaces (bin/sq-sitrep-snapshot.sh, /reporting), and at startup it
#     is pure weight - 10 done rows cost 3.3KB in an observed main-home digest.
#   - Every in-flight, held, and blocked row is listed IN FULL, with its
#     hold_kind/hold_reason and blocked_by. Those are the rows AGENTS.md
#     sections 7 and 10 make actionable at startup, so they are never bounded
#     away.
#   - Only the plain queued (dispatchable-now) listing is bounded, by
#     SQUAD_SESSION_START_QUEUED_LIMIT, default 20. Anything it omits is disclosed
#     with an exact remainder count and the command that shows the rest, so a
#     deep queue costs a counter rather than kilobytes.
#     (This replaces SQUAD_SESSION_START_BACKLOG_LIMIT, which bounded the whole
#     listing indiscriminately and so could drop a held or blocked row.)
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body. The groups are the tool's own filters
# (`--state in_flight`, `--state held`, `--state queued --blocked`, and
# `tasks-axi ready`), so this script never reimplements task state; the groups
# can overlap, because an in-flight item that is also held appears under both.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest; the same never-bound-a-held-or-blocked-row
# rule applies, recognized there from the title line's own hold/blocked-by
# markers.
# Full bodies are targeted follow-up only: `tasks-axi show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# STATUS TAILS: SQUAD_SESSION_START_STATUS_TAIL bounds how many lines each task's
# tail prints, and bin/sq-line-cap-lib.sh bounds how long each of those lines
# may be. Both bounds are safe because the section prints every task's full
# status log path, and AGENTS.md section 8 treats a status line as a wake EVENT
# rather than current state - bin/sq-crew-state.sh owns current state.
#
# RUNTIME BOUND: the digest is now executed on a session-open hook (see
# bin/sq-sessionstart-run.sh), which blocks session initialization while it
# runs, so an unbounded digest is no longer merely slow - it can strand a whole
# session behind one hung subprocess. Every remaining step is local, but local is
# not the same as bounded: tool version probes, the backlog listing, and the
# per-task endpoint reads are all unbounded subprocesses. So the whole digest
# still runs as ONE bounded child of this script (SQUAD_SESSION_START_TIMEOUT,
# default 120s). The deferred network stage deliberately sits OUTSIDE that bound,
# in its own process group under its own aggregate deadline, so a truncated
# digest neither waits for it nor orphans it unbounded. The
# child writes the digest straight to this script's stdout, so everything it
# emitted before the bound was hit is already delivered; the parent then prints
# a loud STARTUP TRUNCATED banner naming the stage that did not finish and the
# sections that were therefore never emitted, and still exits 0. The child
# records its progress in SQUAD_SESSION_START_STAGE_FILE, which is also the flag
# that tells a child it is the child - the parent never recurses.
# Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog, so
# the digest never runs without the same hard bound and process-group cleanup.
#
# Usage: sq-session-start.sh [--reemit]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#
#   --reemit  This process ALREADY took the helm at its own startup and has
#             only lost its context (a /clear or a compaction). Skip the
#             mutating sweeps that startup already reconciled - the stale Herdr
#             projection cleanup and bootstrap's six mutating sweeps (unit
#             sync, XO convergence and liveness, PR-check migration,
#             pending remote handoff retry, X-mode artifact writes) - and
#             re-emit the rest. The stand-to queue drain is NOT skipped: queued
#             records are this turn's work queue, they arrived after startup,
#             and a session that owns the lock is exactly the session that must
#             take them. Lock acquisition still runs, because ownership must be
#             re-verified rather than assumed: sq-lock.sh already treats a lock
#             this session's own harness holds as its own, so the re-emit
#             proceeds, while a lock another live session took meanwhile still
#             produces the ordinary read-only path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_HOME="${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_HOME/state}"
DATA="${SQUAD_DATA_OVERRIDE:-$SQUAD_HOME/data}"
CONFIG="${SQUAD_CONFIG_OVERRIDE:-$SQUAD_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"

REEMIT=0
for arg in "$@"; do
  case "$arg" in
    --reemit) REEMIT=1 ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/sq-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'sq-session-start: unknown argument: %s\n' "$arg" >&2
      printf 'usage: sq-session-start.sh [--reemit]\n' >&2
      exit 2
      ;;
  esac
done

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
SESSION_START_STAGES='lock bootstrap stand-to queue supervision-instructions read-once unit-state network-checks context next-step'

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${SQUAD_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$SQUAD_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/sq-timeout-lib.sh
. "$SCRIPT_DIR/sq-timeout-lib.sh"

if [ -z "${SQUAD_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${SQUAD_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*|0) SESSION_START_BUDGET=120 ;; esac
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/sq-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  fm_run_timed "$SESSION_START_BUDGET" \
    env SQUAD_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
    "$SCRIPT_DIR/sq-session-start.sh" "$@"
  SESSION_START_RC=$?
  if [ "$SESSION_START_RC" -eq 124 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/sq-session-start.sh now to finish taking the helm. If it truncates\n'
    printf '●  again, raise SQUAD_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
    printf '●  cannot finish inside the bound is a unit problem, not a reporting detail.\n'
    printf '%s\n' "$BAR"
  fi
  rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  exit 0
fi

PRIMARY_HARNESS=$("$SCRIPT_DIR/sq-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/sq-backend.sh
. "$SCRIPT_DIR/sq-backend.sh"
# shellcheck source=bin/sq-tasks-axi-lib.sh
. "$SCRIPT_DIR/sq-tasks-axi-lib.sh"
# shellcheck source=bin/sq-public-followup-lib.sh
. "$SCRIPT_DIR/sq-public-followup-lib.sh"
# shellcheck source=bin/sq-trace-context-lib.sh
. "$SCRIPT_DIR/sq-trace-context-lib.sh"
# shellcheck source=bin/sq-line-cap-lib.sh
. "$SCRIPT_DIR/sq-line-cap-lib.sh"

# One tasks-axi compatibility verdict per session start. The probe costs three
# tasks-axi subprocesses and this digest needs the same answer twice - here for
# the backlog listing and again inside the sq-bootstrap.sh child, which reports
# an incompatible build as MISSING. Computing it once and handing it to that
# child collapses six subprocesses to three. sq-tasks-axi-lib.sh owns both reuse
# layers and the one-hop consumption rule that keeps the verdict out of any
# agent's environment.
if fm_tasks_axi_compatible; then TASKS_AXI_COMPATIBLE=1; else TASKS_AXI_COMPATIBLE=0; fi

STATUS_TAIL=${SQUAD_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
QUEUED_LIMIT=${SQUAD_SESSION_START_QUEUED_LIMIT:-20}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=20 ;; esac
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (commander.md absent = Squad
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

# A queued title line whose own text already marks it held or blocked. The
# manual renderer has no task model, so this is the only signal it gets, and it
# is the one tasks-axi's markdown backend writes: "(hold: ...)", "(hold-kind:
# ...)", and "blocked-by: ...". Bracket expressions rather than backslashes,
# because awk's -v applies escape processing before the regex is ever compiled.
MANUAL_KEEP_RE='[(]hold|blocked-by:'

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to %s; indented task bodies omitted)\n' \
    "$reason" "$QUEUED_LIMIT"
  awk -v max="$QUEUED_LIMIT" -v keep_re="$MANUAL_KEEP_RE" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      # The Done heading is recognized so its items are skipped, never printed.
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ { in_flight++; print $0; next }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      if ($0 ~ keep_re) { gated++; print $0; next }
      if (plain_shown < max) { plain_shown++; print $0 }
      next
    }
    END {
      plain_total = queued_total - gated
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d in-flight, %d held or blocked queued, %d of %d other queued title line(s); %d done row(s) omitted)\n", \
          in_flight, gated, plain_shown, plain_total, done_total
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise SQUAD_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)\n", plain_total - plain_shown
        }
      }
    }
  ' "$path"
}

# tasks-axi closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times, once
# per group, each carrying this home's full backlog path. The section prints one
# equivalent pointer of its own (print_backlog_pointer), so the per-group help
# blocks stop at their `help[` header instead.
strip_axi_help() {
  awk '/^help\[/ { exit } { print }'
}

# Bound the dispatchable-now listing without rewriting the tool's own rendering:
# `tasks-axi ready` rows are the indented lines under its ready[N]{...} header,
# and every other line it prints (its count, its public-followup line) passes
# through untouched. Whatever is cut is disclosed exactly.
print_ready_queued_bounded() {
  local ready=$1 path=$2
  printf '%s\n' "$ready" | awk -v max="$QUEUED_LIMIT" -v path="$path" '
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) { print; shown++ }
      next
    }
    { rows = 0; print }
    END {
      if (total > 0) {
        printf "(shown %d of %d ready queued item(s))\n", shown, total
        if (total > shown) {
          printf "(%d more queued - tasks-axi ready --file %s)\n", total - shown, path
        }
      }
    }
  '
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight held blocked ready err
  if ! in_flight=$(tasks-axi list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$(tasks-axi list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(tasks-axi list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$(tasks-axi ready --file "$path" 2>&1); then
    err=$ready
  else
    printf 'compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and blocked row shown in full; ready queued bounded to %s; task bodies omitted)\n' \
      "$QUEUED_LIMIT"
    printf '\nin flight:\n'
    printf '%s\n' "$in_flight" | strip_axi_help
    printf '\nheld (commander- or time-gated; an in-flight item that is also held appears in both groups):\n'
    printf '%s\n' "$held" | strip_axi_help
    printf '\nblocked queued:\n'
    printf '%s\n' "$blocked" | strip_axi_help
    printf '\nready queued (dispatchable now):\n'
    print_ready_queued_bounded "$ready" "$path"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1 line
  printf 'status tail (last %s line(s), each capped at %s characters, wake-EVENT history, not current state; full log: %s):\n' \
    "$STATUS_TAIL" "$SQUAD_LINE_CAP_DEFAULT" "$status"
  # A operator writes its own status lines, so their length is unbounded: one
  # observed line ran 865 characters. Cap each one the way the wake digest's
  # OPEN DECISIONS section does; the lede carries the state word and the key,
  # and the full log path above reaches the rest.
  while IFS= read -r line || [ -n "$line" ]; do
    fm_cap_line "$line"
  done < <(tail -n "$STATUS_TAIL" "$status")
}

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

if [ "$REEMIT" -eq 1 ]; then
  section "SESSION START (CONTEXT RE-EMIT) - $SQUAD_HOME"
  printf 'This session already took the helm at its own startup and has only lost its\n'
  printf 'context. Lock ownership is re-verified and the durable records below are\n'
  printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
  printf 'XO convergence and liveness, PR-check migration, pending remote handoff\n'
  printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
else
  section "SESSION START - $SQUAD_HOME"
fi
# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/sq-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - UNIT LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: PR-check migration, stale Herdr child cleanup,\n'
    printf '●  XO convergence, XO liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, unit sync, and stand-to queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate unit state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  # Every network call this session start owes is launched HERE, detached and
  # bounded, so it runs concurrently with the whole digest below instead of in
  # front of it. Step 7 harvests whatever it has finished, without ever waiting.
  # --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
  # this process already ran the mutating sweeps at its own startup, so only the
  # read-only GitHub-auth probe is owed. A read-only session starts nothing at
  # all: it holds no mutation authority for the sweeps, and it must not spawn,
  # steer, or merge anyway, so it has no action left for an auth verdict to gate.
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/sq-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
fi

# --- 2. bootstrap --------------------------------------------------------
# SQUAD_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it twice would both
# re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(SQUAD_BOOTSTRAP_DETECT_ONLY=1 SQUAD_BOOTSTRAP_NETWORK=skip \
    SQUAD_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" "$SCRIPT_DIR/sq-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(SQUAD_BOOTSTRAP_DETECT_ONLY=1 SQUAD_BOOTSTRAP_LOCKED=1 SQUAD_BOOTSTRAP_NETWORK=skip \
    SQUAD_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" "$SCRIPT_DIR/sq-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/sq-herdr-session-cleanup.sh" 2>&1 || true
    SQUAD_BOOTSTRAP_NETWORK=skip SQUAD_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
      "$SCRIPT_DIR/sq-bootstrap.sh" 2>&1
  )
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. stand-to drain -------------------------------------------------------
# Drained records are this turn's first work queue, and the drain's separate
# OPEN DECISIONS section remains actionable even when that queue is empty
# (AGENTS.md sections 3 and 8).
# The drain also runs sq-guard.sh internally on the locked path, so the
# tangle/sentry-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively draining it. It still runs
# sq-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage stand-to queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.stand-to-queue" ] && QLEN=$(grep -c . "$STATE/.stand-to-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified unit-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(SQUAD_GUARD_READ_ONLY=1 "$SCRIPT_DIR/sq-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  DRAIN_OUT=$("$SCRIPT_DIR/sq-stand-to-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$SQUAD_ROOT/.pi/extensions/sq-primary-pi-watch.ts"
  PI_TURNEND_EXT="$SQUAD_ROOT/.pi/extensions/sq-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
"$SCRIPT_DIR/sq-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --x-mode "$X_MODE_PRESENT"

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it now
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage that never ran, which the truncation banner names by stage.
stage read-once
section "READ-ONCE CONTRACT"
cat <<'EOF'
Everything below is printed in full for this session start: every state/*.meta,
a compact data/backlog.md listing, a bounded tail of every state/*.status,
data/projects.md, data/XOs.md, data/commander.md, data/commander-shared.md,
and data/learnings.md.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status: re-reading everything defeats the entire
point of this command.

Go to a source directly only when:
  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),
  - its contents looked unparseable or corrupt,
  - an individual full status log is needed for older wake-event history, or a
    status line was capped and its tail matters (each task's full log path is
    printed with its tail),
  - a full task body is needed (tasks-axi show <id> --full, or data/backlog.md),
  - the backlog listing disclosed omitted queued items and this turn needs them,
  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this
    turn needs their verdict (bin/sq-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in
    which case that stage's sources were never emitted and must be reconciled.
EOF

# --- 6. unit-state digest ---------------------------------------------
# Before CONTEXT: see this file's ORDERING note. Live unit identity is what a
# truncated tail must never take.
stage unit-state
section "UNIT STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

subsection "Work under way (state/*.meta)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "sq-$id"; then
      printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window"
    else
      printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window"
    fi
  else
    printf 'endpoint: unknown (no window recorded)\n'
  fi

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns the sentry.\n'
else
  printf 'absent\n'
fi

# Public commitments made through the mySquad relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. sq-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches sq-public-followup.sh.
if fm_pf_relay_active "$SQUAD_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/sq-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments awaiting delivery"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public reply this home still owes. Reconcile terminal results with\n'
    printf '%s/bin/sq-public-followup.sh consume, then deliver a ready one with\n' "$SQUAD_ROOT"
    printf '%s/bin/sq-public-followup.sh deliver <id>. Load relay-respond for the procedure.\n' "$SQUAD_ROOT"
  fi
fi

# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (a stuck clone, a
# XO that could not be relaunched, broken GitHub auth), and the section
# after this one is the curated memory a truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so the
# worker started at step 1 has had the whole composition above to finish in. It
# is a NON-BLOCKING read either way - whatever the worker has published by now is
# printed, and whatever it has not is named as not yet confirmed.
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
  printf 'XO liveness and convergence, and pending handoff delivery were not run.\n'
  printf 'They need the unit lock, and this session must not spawn, steer, or merge, so it\n'
  printf 'has no action they would gate. The session holding the lock runs them.\n'
else
  "$SCRIPT_DIR/sq-startup-network.sh" harvest --pid $$ 2>&1 || true
fi

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections deliberately: curated memory is stable session to
# session, already governed by config/startup-memory-budget, and recoverable
# with one targeted read, so it is the cheapest thing for a truncated tail to
# take (see this file's ORDERING note).
stage context
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/XOs.md" "data/XOs.md"
print_file_or_absent "$DATA/commander.md" "data/commander.md"
print_file_or_absent "$DATA/commander-shared.md" "data/commander-shared.md (shared, main-authoritative, read-only in XO homes)"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the unit lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair unit state from here. Only a session
with verified unit-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns sentry
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$COMPLETION_PID" in
    ''|*[!0-9]*) COMPLETION_PID= ;;
  esac
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    :
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
fi

exit 0
