#!/usr/bin/env bash
# Containment-backed bounded execution: bin/sq-op-contain.sh,
# packages/sq-supervisor, and the fm_run_contained/fm_run_timed seam.
#
# The contract under test:
#   - The legacy path stays the default, so no host changes behaviour on upgrade.
#   - Strict Linux mode (SQUAD_OP_CONTAINMENT=systemd) never silently degrades:
#     a missing binary or manager is a refusal, not a weaker guarantee.
#   - A descendant that starts its own session and process group, ignores TERM,
#     and holds the operation open is gone after the bound. Proven by process
#     inspection, never by exit code.
#   - Killing the runner itself does not defeat containment: the manager owns the
#     unit and its deadline still acts.
#   - A successful operation still reports the command's own exit status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-op-contain) || fail "cannot create the test root"
BIN_DIR="$TMP_ROOT/bin"
RUNNER="$ROOT/bin/sq-op-contain.sh"
mkdir -p "$BIN_DIR"

cleanup_extra() {
  local pid
  for pid in ${SPAWNED_PIDS:-}; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  systemctl --user list-units 'sq-op-*' --all --no-legend 2>/dev/null \
    | awk '{print $1}' | xargs -r systemctl --user reset-failed 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_extra EXIT
trap 'cleanup_extra; exit 130' INT
trap 'cleanup_extra; exit 143' TERM

SPAWNED_PIDS=""

pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

pid_session() {
  awk '{print $6}' "/proc/$1/stat" 2>/dev/null
}

# --- pure contract, no manager required -------------------------------------

# libprobe <mode> <body>: run <body> in a fresh shell that has sourced the
# timeout library, with the containment mode it should see. The body expands
# here, the library path arrives as the child's $1.
libprobe() {  # <containment-mode> <body>
  local mode=$1 body=$2
  SQUAD_OP_CONTAINMENT=$mode bash -c ". \"\$1\"; $body" _ "$ROOT/bin/sq-timeout-lib.sh"
}

mode=$(libprobe '' 'fm_containment_mode')
[ "$mode" = legacy ] || fail "the default containment mode must stay legacy, got '$mode'"
pass "legacy group-kill stays the default mode"

mode=$(libprobe systemd 'fm_containment_mode')
[ "$mode" = systemd ] || fail "SQUAD_OP_CONTAINMENT=systemd must select the contained path, got '$mode'"
pass "strict mode is selected only by explicit opt-in"

out=$(SQUAD_SUPERVISOR_BIN="$TMP_ROOT/absent" libprobe systemd 'fm_run_timed 5 /bin/true' 2>&1)
rc=$?
[ "$rc" -eq 78 ] || fail "strict mode without the binary must refuse with 78, got $rc"
printf '%s' "$out" | grep -Fq 'sq-install-supervisor.sh' \
  || fail "the refusal must name how to install the binary, got: $out"
pass "strict mode refuses instead of silently degrading when the binary is absent"

# Outcome-state mapping: the shim owns the caller-facing status contract while
# the binary owns the outcome states.
make_stub() {  # <path> <exit-status> <json>
  cat > "$1" <<SH
#!/usr/bin/env bash
printf '%s\n' '$3'
exit $2
SH
  chmod +x "$1"
}

make_stub "$TMP_ROOT/stub-ok" 0 '{"state":"completed","exit_code":42}'
SQUAD_SUPERVISOR_BIN="$TMP_ROOT/stub-ok" "$RUNNER" 5 /bin/true >/dev/null 2>&1
rc=$?
[ "$rc" -eq 42 ] || fail "a completed outcome must report the command's own status, got $rc"
pass "a completed operation reports the command's own exit status"

make_stub "$TMP_ROOT/stub-timeout" 3 '{"state":"timeout","detail":"deadline reached"}'
err=$(SQUAD_SUPERVISOR_BIN="$TMP_ROOT/stub-timeout" "$RUNNER" 5 /bin/true 2>&1 >/dev/null)
rc=$?

[ "$rc" -eq 124 ] || fail "a timeout outcome must map to 124, got $rc"
printf '%s' "$err" | grep -Fq 'operation timeout' || fail "a timeout must be named, got: $err"
pass "a timeout maps to 124 and names itself"

make_stub "$TMP_ROOT/stub-unknown" 4 '{"state":"unknown-result","detail":"result unreadable"}'
err=$(SQUAD_SUPERVISOR_BIN="$TMP_ROOT/stub-unknown" "$RUNNER" 5 /bin/true 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 125 ] || fail "an unknown outcome must be 125, never success, got $rc"
printf '%s' "$err" | grep -Fq 'unknown-result' || fail "an unknown outcome must be named, got: $err"
pass "an unknown outcome is reported as failed, never as success"

make_stub "$TMP_ROOT/stub-pending" 5 '{"state":"cleanup-pending","detail":"2 processes remained"}'
SQUAD_SUPERVISOR_BIN="$TMP_ROOT/stub-pending" "$RUNNER" 5 /bin/true >/dev/null 2>&1
rc=$?
[ "$rc" -eq 125 ] || fail "a still-populated group must be 125, got $rc"
pass "a group that stayed populated is reported as failure"

# The legacy mechanism keeps its own contract when strict mode is not selected.
libprobe '' 'fm_run_timed 1 /bin/sleep 30'
rc=$?
[ "$rc" -eq 124 ] || fail "the legacy bound must still report 124, got $rc"
pass "the legacy bound contract is unchanged"

# --- real containment -------------------------------------------------------

if ! command -v go >/dev/null 2>&1; then
  printf 'skip: go toolchain unavailable for the containment proof\n'
  exit 0
fi
if ! "$ROOT/bin/sq-install-supervisor.sh" "$BIN_DIR" >/dev/null 2>&1; then
  fail "building the vendored sq-supervisor failed"
fi
SUPERVISOR="$BIN_DIR/sq-supervisor"
if ! "$SUPERVISOR" capabilities >/dev/null 2>&1; then
  printf 'skip: systemd user manager unavailable for the containment proof\n'
  exit 0
fi
pass "the vendored sq-supervisor builds and reports a working user manager"

# Delegation must be transparent: existing callers capture stdout with $(...)
# and check 124. A contained run may not silently empty either one.
out=$(SQUAD_SUPERVISOR_BIN="$SUPERVISOR" libprobe systemd 'fm_run_timed 10 /bin/echo delegated-stdout')
rc=$?
[ "$rc" -eq 0 ] || fail "a delegated success must keep status 0, got $rc"
[ "$out" = delegated-stdout ] || fail "a delegated run must relay the command's stdout, got '$out'"
pass "strict mode relays stdout, so existing \$(...) callers keep working"

err=$(SQUAD_SUPERVISOR_BIN="$SUPERVISOR" libprobe systemd 'fm_run_timed 10 /bin/sh -c "echo to-stderr >&2; exit 9"' 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 9 ] || fail "a delegated failure must keep the command's status, got $rc"
printf '%s' "$err" | grep -Fq 'to-stderr' || fail "a delegated run must relay the command's stderr, got '$err'"
pass "strict mode relays stderr and the command's own failure status"

SQUAD_SUPERVISOR_BIN="$SUPERVISOR" libprobe systemd 'fm_run_timed 1 /bin/sleep 30' >/dev/null 2>&1
rc=$?
[ "$rc" -eq 124 ] || fail "a delegated bound must still report 124, got $rc"
pass "strict mode keeps fm_run_timed's 124 bound contract"

write_backend() {  # <path> <pid-file> <second mode>
  cat > "$1" <<SH
#!/usr/bin/env bash
case "$3" in
  session) setsid bash -c 'trap "" TERM; exec sleep 300' & ;;
  group) set -m; bash -c 'trap "" TERM; exec sleep 300' & set +m ;;
esac
printf '%s\n' "\$!" > "$2"
trap '' TERM
sleep 300
SH
  chmod +x "$1"
}

wait_for_file() {  # <path> <ticks>
  local _
  for _ in $(seq 1 "$2"); do
    [ -s "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

for variant in session group; do
  descendant_file="$TMP_ROOT/$variant.pid"
  write_backend "$TMP_ROOT/backend-$variant.sh" "$descendant_file" "$variant"
  start=$(date +%s)
  SQUAD_SUPERVISOR_BIN="$SUPERVISOR" "$RUNNER" --stop-grace 1 2 "$TMP_ROOT/backend-$variant.sh" \
    >"$TMP_ROOT/$variant.out" 2>"$TMP_ROOT/$variant.err"
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  wait_for_file "$descendant_file" 5 || fail "$variant: the backend never recorded its descendant"
  descendant=$(cat "$descendant_file")
  SPAWNED_PIDS="$SPAWNED_PIDS $descendant"
  [ "$rc" -eq 124 ] || fail "$variant: a bounded operation must report 124, got $rc ($(cat "$TMP_ROOT/$variant.err"))"
  if [ "$variant" = session ]; then
    [ "$(pid_session "$descendant")" != "$(pid_session $$)" ] \
      || fail "session: the descendant must be in its own session for this proof to mean anything"
  fi
  pid_alive "$descendant" && fail "$variant: the TERM-resistant descendant (pid $descendant) outlived the operation"
  [ "$elapsed" -le 15 ] || fail "$variant: the operation took ${elapsed}s, want it bounded near deadline+grace"
  pass "$variant: a TERM-resistant descendant in its own $variant is gone after the bound (${elapsed}s)"
done

printf '%s' "$(cat "$TMP_ROOT/session.err")" | grep -Fq 'timeout' \
  || fail "the timeout must be named on stderr, got: $(cat "$TMP_ROOT/session.err")"
pass "the timeout reason is reported, not implied"

wait_for_child() {  # <parent-pid> <name>
  local child _
  for _ in $(seq 1 100); do
    child=$(pgrep -P "$1" -x "$2" 2>/dev/null | head -1)
    if [ -n "$child" ]; then
      printf '%s\n' "$child"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# The runner is not the owner: killing it must not release the operation.
kill_runner_file="$TMP_ROOT/killed.pid"
write_backend "$TMP_ROOT/backend-killed.sh" "$kill_runner_file" session
SQUAD_SUPERVISOR_BIN="$SUPERVISOR" "$RUNNER" --stop-grace 1 3 "$TMP_ROOT/backend-killed.sh" \
  >"$TMP_ROOT/killed.out" 2>"$TMP_ROOT/killed.err" &
shim_pid=$!
SPAWNED_PIDS="$SPAWNED_PIDS $shim_pid"
wait_for_file "$kill_runner_file" 50 || fail "killed: the backend never recorded its descendant"
survivor=$(cat "$kill_runner_file")
SPAWNED_PIDS="$SPAWNED_PIDS $survivor"
# The exact child this shim started, never an arbitrary process with the same
# name: another supervisor on the host may be running a real operation.
runner_pid=$(wait_for_child "$shim_pid" sq-supervisor) \
  || fail "killed: the sq-supervisor child of this runner was not visible to inspection"
pid_session "$runner_pid" >/dev/null 2>&1 || fail "killed: cannot inspect the runner's session"
kill -KILL "$runner_pid" 2>/dev/null || true
kill -KILL "$shim_pid" 2>/dev/null || true
wait "$shim_pid" 2>/dev/null || true
sleep 8
pid_alive "$survivor" && fail "killed: the descendant (pid $survivor) survived the runner being killed"
pass "killing the runner mid-operation does not defeat the manager's deadline or containment"

printf 'ok - %s\n' "containment contract holds on the real surface"
