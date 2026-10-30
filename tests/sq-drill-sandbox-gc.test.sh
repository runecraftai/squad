#!/usr/bin/env bash
# Tests the conservative drill sandbox cleanup in bin/sq-drill-sandbox-gc.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GC="$ROOT/bin/sq-drill-sandbox-gc.sh"
TMP_ROOT=$(fm_test_tmproot sq-drill-sandbox-gc)
SANDBOX_ROOT="$TMP_ROOT/tmp"
export SQUAD_DRILL_SANDBOX_ROOT="$SANDBOX_ROOT"
unset SQUAD_DRILL_SANDBOX_GRACE_MINUTES

HOLDERS=()
cleanup_holders() {
  local pid
  for pid in "${HOLDERS[@]+"${HOLDERS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_holders; fm_test_cleanup' EXIT

# make_sandbox <name> <age-in-hours> - a sandbox with nested content, aged as a whole.
make_sandbox() {
  local d="$SANDBOX_ROOT/$1"
  mkdir -p "$d/cache/deep" "$d/home"
  head -c 20000 /dev/zero >"$d/cache/deep/blob"
  printf 'x\n' >"$d/home/.profile"
  find "$d" -depth -exec touch -d "$2 hours ago" {} +
}

reset() {
  rm -rf "$SANDBOX_ROOT"
  mkdir -p "$SANDBOX_ROOT"
  # Keep the holders of an earlier case from pinning this case's namespace.
  cleanup_holders
  HOLDERS=()
}

run_gc() {
  OUT=$("$GC" "$@" 2>"$TMP_ROOT/err")
  RC=$?
  ERR=$(cat "$TMP_ROOT/err")
}

# --- stale unused directory is removed --------------------------------------
reset
make_sandbox drill-execution-policy-stale 7
run_gc
[ "$RC" -eq 0 ] || fail "real run exits 0 (got $RC)"
[ ! -e "$SANDBOX_ROOT/drill-execution-policy-stale" ] || fail "stale unused sandbox is removed"
case "$OUT" in
  *"removed 1 stale drill sandbox"*"freed "*) ;;
  *) fail "summary reports count and freed size (got: $OUT)" ;;
esac
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] || fail "summary is a single line"
[ -z "$ERR" ] || fail "a clean run prints nothing on stderr (got: $ERR)"
pass "stale unused sandbox is removed with one summary line"

# --- nothing to do prints nothing -------------------------------------------
run_gc
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] || fail "an empty sweep is silent"
pass "empty sweep is silent"

# --- recent directory is kept -----------------------------------------------
reset
make_sandbox drill-execution-policy-fresh 0
run_gc
[ -d "$SANDBOX_ROOT/drill-execution-policy-fresh" ] || fail "recent sandbox is kept"
[ -z "$OUT" ] || fail "keeping everything prints nothing (got: $OUT)"
pass "recent sandbox is kept"

# --- old top level but recent nested activity is kept -----------------------
reset
make_sandbox drill-execution-policy-busy 7
touch "$SANDBOX_ROOT/drill-execution-policy-busy/cache/deep/blob"
run_gc
[ -d "$SANDBOX_ROOT/drill-execution-policy-busy" ] || fail "sandbox with recent nested writes is kept"
pass "nested recent activity keeps an otherwise old sandbox"

# --- grace window defaults to six hours and is configurable ------------------
reset
make_sandbox drill-execution-policy-grace 3
run_gc
[ -d "$SANDBOX_ROOT/drill-execution-policy-grace" ] || fail "the default grace window keeps a 3h sandbox"
# A shorter flag window must remove what the default would keep, so a flag that
# is ignored (or rejected before the sweep) fails here.
run_gc --grace-minutes 120
[ ! -e "$SANDBOX_ROOT/drill-execution-policy-grace" ] || fail "--grace-minutes 120 removes a 3h sandbox"
reset
make_sandbox drill-execution-policy-grace-old 7
run_gc --grace-minutes 600
[ -d "$SANDBOX_ROOT/drill-execution-policy-grace-old" ] || fail "--grace-minutes 600 keeps a 7h sandbox"
run_gc
[ ! -e "$SANDBOX_ROOT/drill-execution-policy-grace-old" ] || fail "the default grace window removes a 7h sandbox"
reset
make_sandbox drill-execution-policy-grace-env 3
SQUAD_DRILL_SANDBOX_GRACE_MINUTES=120 run_gc
[ ! -e "$SANDBOX_ROOT/drill-execution-policy-grace-env" ] || fail "the environment grace window applies"
pass "default grace window is six hours and configurable by flag and environment"

# --- dry run removes nothing ------------------------------------------------
reset
make_sandbox drill-execution-policy-old1 7
make_sandbox drill-execution-policy-old2 8
make_sandbox drill-execution-policy-new 0
run_gc --dry-run
[ "$RC" -eq 0 ] || fail "dry run exits 0"
[ -d "$SANDBOX_ROOT/drill-execution-policy-old1" ] && [ -d "$SANDBOX_ROOT/drill-execution-policy-old2" ] || fail "dry run removes nothing"
case "$OUT" in
  *"would remove $SANDBOX_ROOT/drill-execution-policy-old1"*) ;;
  *) fail "dry run lists old1 (got: $OUT)" ;;
esac
case "$OUT" in
  *"would remove $SANDBOX_ROOT/drill-execution-policy-old2"*) ;;
  *) fail "dry run lists old2 (got: $OUT)" ;;
esac
case "$OUT" in
  *drill-execution-policy-new*) fail "dry run lists only stale directories" ;;
esac
pass "dry run lists exactly the stale directories and removes nothing"

# --- a directory referenced by a live process is kept even when old ----------
hold() {
  # hold <mode> <dir>: start a process that references <dir> and wait until it is up.
  local mode=$1 dir=$2 ready="$TMP_ROOT/ready.$$.$RANDOM"
  case "$mode" in
    cwd) (cd "$dir" && : >"$ready" && exec sleep 300) >/dev/null 2>&1 & ;;
    fd) (exec 9<"$dir/home/.profile" && : >"$ready" && exec sleep 300) >/dev/null 2>&1 & ;;
    env) (HOME="$dir/home" && export HOME && : >"$ready" && exec sleep 300) >/dev/null 2>&1 & ;;
  esac
  HOLDERS+=("$!")
  local i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "holder process ($mode) started"
  sleep 0.1
}

for mode in cwd fd env; do
  reset
  make_sandbox drill-execution-policy-held 7
  make_sandbox drill-execution-policy-free 7
  hold "$mode" "$SANDBOX_ROOT/drill-execution-policy-held"
  run_gc
  [ -d "$SANDBOX_ROOT/drill-execution-policy-held" ] || fail "sandbox referenced by $mode is kept"
  [ ! -e "$SANDBOX_ROOT/drill-execution-policy-free" ] || fail "unreferenced sibling is still removed ($mode)"
  run_gc --dry-run
  case "$OUT" in
    *drill-execution-policy-held*) fail "dry run does not list a sandbox referenced by $mode" ;;
  esac
  pass "old sandbox referenced by a live process ($mode) is kept"
done

# A reference to one id never shields a sibling whose name only shares a prefix.
reset
make_sandbox drill-execution-policy-1 7
make_sandbox drill-execution-policy-10 7
hold cwd "$SANDBOX_ROOT/drill-execution-policy-1"
run_gc
[ -d "$SANDBOX_ROOT/drill-execution-policy-1" ] || fail "referenced -1 is kept"
[ ! -e "$SANDBOX_ROOT/drill-execution-policy-10" ] || fail "-10 is not shielded by a reference to -1"
pass "references match whole names, not prefixes"

# --- names that do not match, and symlinks, are untouched --------------------
reset
make_sandbox other-execution-policy-x 7
make_sandbox drill-execution-policy 7
make_sandbox drill-execution-policy-a+b 7
make_sandbox drill-execution-policyx 7
mkdir -p "$TMP_ROOT/victim"
printf 'keep\n' >"$TMP_ROOT/victim/file"
touch -d '7 hours ago' "$TMP_ROOT/victim" "$TMP_ROOT/victim/file"
ln -s "$TMP_ROOT/victim" "$SANDBOX_ROOT/drill-execution-policy-link"
printf 'f\n' >"$SANDBOX_ROOT/drill-execution-policy-file"
touch -d '7 hours ago' "$SANDBOX_ROOT/drill-execution-policy-file"
run_gc
[ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "nothing matching means nothing removed (got: $OUT)"
for n in other-execution-policy-x drill-execution-policy drill-execution-policy-a+b drill-execution-policyx; do
  [ -d "$SANDBOX_ROOT/$n" ] || fail "$n is untouched"
done
[ -L "$SANDBOX_ROOT/drill-execution-policy-link" ] && [ -f "$TMP_ROOT/victim/file" ] || fail "a symlink and its target are untouched"
[ -f "$SANDBOX_ROOT/drill-execution-policy-file" ] || fail "a plain file with a matching name is untouched"
pass "non-matching names, symlinks, and plain files are untouched"

# --- read-only cache trees are still removed ---------------------------------
reset
make_sandbox drill-execution-policy-ro 7
chmod -R a-w "$SANDBOX_ROOT/drill-execution-policy-ro"
run_gc
[ ! -e "$SANDBOX_ROOT/drill-execution-policy-ro" ] || fail "read-only sandbox is removed"
pass "read-only cache trees are removed"

# --- a failed size measurement warns but does not hide the removal -----------
reset
make_sandbox drill-execution-policy-unmeasurable 7
mkdir -p "$TMP_ROOT/failbin"
cat >"$TMP_ROOT/failbin/du" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP_ROOT/failbin/du"
OUT=$(PATH="$TMP_ROOT/failbin:$PATH" "$GC" 2>"$TMP_ROOT/err")
RC=$?
ERR=$(cat "$TMP_ROOT/err")
[ "$RC" -eq 0 ] || fail "a failed size measurement still exits 0 (got $RC)"
[ ! -e "$SANDBOX_ROOT/drill-execution-policy-unmeasurable" ] \
  || fail "a sandbox whose size cannot be measured is still removed"
case "$ERR" in
  *"warning"*"could not measure"*) ;;
  *) fail "a failed size measurement warns on stderr (got: $ERR)" ;;
esac
case "$OUT" in
  *"removed 1 stale drill sandbox"*) ;;
  *) fail "the removal is still summarized (got: $OUT)" ;;
esac
pass "a failed size measurement warns on stderr and still removes"

# --- permission repair cannot reach files outside the sandbox ----------------
reset
make_sandbox drill-execution-policy-linked 7
printf 'keep\n' >"$TMP_ROOT/victim-file"
chmod 0444 "$TMP_ROOT/victim-file"
ln "$TMP_ROOT/victim-file" "$SANDBOX_ROOT/drill-execution-policy-linked/victim-link"
touch -d '7 hours ago' "$SANDBOX_ROOT/drill-execution-policy-linked" \
  "$SANDBOX_ROOT/drill-execution-policy-linked/victim-link"
run_gc
[ ! -e "$SANDBOX_ROOT/drill-execution-policy-linked" ] || fail "sandbox holding a read-only hard link is removed"
[ -f "$TMP_ROOT/victim-file" ] || fail "a file hard-linked from the sandbox survives the sweep"
[ "$(stat -c %a "$TMP_ROOT/victim-file")" = 444 ] || fail "permission repair leaves outside files untouched"
pass "permission repair cannot reach files outside the sandbox"

# --- a failed reference scan keeps every candidate ---------------------------
reset
make_sandbox drill-execution-policy-unscannable 7
mkdir -p "$TMP_ROOT/no-proc"
SQUAD_DRILL_SANDBOX_PROC="$TMP_ROOT/no-proc" run_gc
[ "$RC" -eq 0 ] || fail "a failed reference scan still exits 0 (got $RC)"
[ -d "$SANDBOX_ROOT/drill-execution-policy-unscannable" ] || fail "a failed reference scan keeps candidates"
case "$ERR" in *warning*) ;; *) fail "a failed reference scan warns on stderr (got: $ERR)" ;; esac
pass "a failed live-reference scan keeps every candidate and warns"

# --- a failing reference-scan stage keeps every candidate -------------------
# A stage that dies or errors mid-scan (OOM kill, read error) truncates the
# stream; that must not read as "no references" and let the sweep delete live
# sandboxes from a partial snapshot.
reset
make_sandbox drill-execution-policy-partial 7
mkdir -p "$TMP_ROOT/failscan"
cat >"$TMP_ROOT/failscan/grep" <<'SH'
#!/usr/bin/env bash
exit 2
SH
chmod +x "$TMP_ROOT/failscan/grep"
OUT=$(PATH="$TMP_ROOT/failscan:$PATH" "$GC" 2>"$TMP_ROOT/err")
RC=$?
ERR=$(cat "$TMP_ROOT/err")
[ "$RC" -eq 0 ] || fail "a failed reference-scan stage still exits 0 (got $RC)"
[ -d "$SANDBOX_ROOT/drill-execution-policy-partial" ] \
  || fail "a failed reference-scan stage keeps candidates"
case "$ERR" in *warning*) ;; *) fail "a failed reference-scan stage warns on stderr (got: $ERR)" ;; esac
pass "a failed reference-scan stage keeps every candidate and warns"

# --- an unreadable process entry stays silent ---------------------------------
# Other-user processes (or hidepid proc mounts) make per-pid files unreadable;
# the sweep tolerates that without leaking shell errors onto stderr and still
# honours references it could read.
reset
make_sandbox drill-execution-policy-readable 7
FAKE_PROC="$TMP_ROOT/proc-fake"
mkdir -p "$FAKE_PROC/self" "$FAKE_PROC/4242" "$FAKE_PROC/4343"
ln -s "$TMP_ROOT" "$FAKE_PROC/self/cwd"
: >"$FAKE_PROC/self/mountinfo"
printf '\0' >"$FAKE_PROC/self/environ"
ln -s "$SANDBOX_ROOT/drill-execution-policy-readable" "$FAKE_PROC/4242/cwd"
: >"$FAKE_PROC/4242/mountinfo"
printf 'x\0' >"$FAKE_PROC/4242/environ"
: >"$FAKE_PROC/4343/mountinfo"
printf 'y\0' >"$FAKE_PROC/4343/environ"
chmod 000 "$FAKE_PROC/4343/environ"
SQUAD_DRILL_SANDBOX_PROC="$FAKE_PROC" run_gc
[ "$RC" -eq 0 ] || fail "an unreadable process entry still exits 0 (got $RC)"
[ -z "$ERR" ] || fail "an unreadable process entry prints nothing on stderr (got: $ERR)"
[ -d "$SANDBOX_ROOT/drill-execution-policy-readable" ] || fail "a readable cwd reference still keeps the sandbox"
chmod 600 "$FAKE_PROC/4343/environ"
pass "an unreadable process entry is silent and does not hide readable references"

# --- missing target and bad input always exit 0 ------------------------------
SQUAD_DRILL_SANDBOX_ROOT="$TMP_ROOT/does-not-exist" run_gc
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] || fail "missing root is a silent success"
pass "missing target exits 0 silently"

run_gc --bogus
[ "$RC" -eq 0 ] || fail "unknown flag exits 0"
case "$ERR" in *warning*) ;; *) fail "unknown flag warns on stderr (got: $ERR)" ;; esac
run_gc --grace-minutes abc
[ "$RC" -eq 0 ] || fail "bad grace exits 0"
case "$ERR" in *warning*) ;; *) fail "bad grace warns on stderr (got: $ERR)" ;; esac
run_gc --grace-minutes
[ "$RC" -eq 0 ] || fail "missing grace value exits 0"
case "$ERR" in *warning*) ;; *) fail "missing grace value warns on stderr (got: $ERR)" ;; esac
run_gc --help
[ "$RC" -eq 0 ] && [ -n "$OUT" ] || fail "--help prints usage and exits 0"
pass "bad input warns on stderr and still exits 0"

# --- a sandbox bind-mounted into a live process is kept -----------------------
# Needs unprivileged user namespaces; report rather than silently pass without them.
if unshare -Urm true 2>/dev/null; then
  reset
  make_sandbox drill-execution-policy-mounted 7
  make_sandbox drill-execution-policy-unmounted 7
  mkdir -p "$TMP_ROOT/target"
  READY="$TMP_ROOT/ready.mount"
  unshare -Urm bash -c 'mount --bind "$1" "$2" && : >"$3" && exec sleep 300' _ \
    "$SANDBOX_ROOT/drill-execution-policy-mounted" "$TMP_ROOT/target" "$READY" >/dev/null 2>&1 &
  HOLDERS+=("$!")
  i=0
  while [ ! -e "$READY" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$READY" ] || fail "bind-mount holder started"
  sleep 0.1
  run_gc
  [ -d "$SANDBOX_ROOT/drill-execution-policy-mounted" ] || fail "sandbox bind-mounted into a live process is kept"
  [ ! -e "$SANDBOX_ROOT/drill-execution-policy-unmounted" ] || fail "unmounted sibling is still removed"
  pass "old sandbox bind-mounted into a live process is kept"
else
  pass "skip - unprivileged user namespaces unavailable, bind-mount case not exercised"
fi
