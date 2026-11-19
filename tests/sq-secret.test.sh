#!/usr/bin/env bash
# Behavior tests for bin/sq-secret.sh, the unit's secret broker.
#
# Every case runs against a fake `bw` on PATH and a throwaway SQUAD_BASE, so the
# suite is offline, repeatable, and never touches a real vault. It covers:
#   (a) `get` writes the value and nothing else
#   (b) `get` refuses a terminal without --to-tty and honors --to-tty
#   (c) `run` puts the value in the child's environment while its cmdline holds none
#   (d) the audit log takes one line per resolution and never a value
#   (e) scope policy allows a listed name, denies an unlisted one, denies a task
#       with no entry, refuses a missing or malformed policy, and requires the
#       fetched item to be the listed name's own sq/<name> item
#   (f) fail-closed behaviour for missing bw, missing jq, a locked session, a
#       stale session key, an unknown item, an item with no usable password
#       field, an item or vault that bw cannot resolve unambiguously, and a
#       stalled backend that never answers
#   (g) `check` reports each backend fact and exits non-zero when unusable
#   (h) `list` prints names and metadata only
#   (i) nothing is cached on disk beyond the audit log, under HOME or TMPDIR
#   (j) shellcheck-clean
#   (k) a value's bytes reach `get` stdout and the child environment unchanged
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SECRET="$ROOT/bin/sq-secret.sh"
TMP_ROOT=$(fm_test_tmproot sq-secret)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
VAULT="$TMP_ROOT/vault"
BASE="$TMP_ROOT/base"
LOG="$BASE/state/secrets-audit.log"
POLICY="$BASE/config/secrets-policy.json"
VALUE="s3cr3t-token-value"
SPACED="p@ss word/with=chars"
mkdir -p "$VAULT" "$BASE/state" "$BASE/config"

# A supervised or AFK session exports these for its children, so pin every path
# the broker derives from them to the fixture unless a case overrides it.
unset SQUAD_HOME SQUAD_ROOT_OVERRIDE
SQUAD_BASE="$BASE"
export SQUAD_BASE SQUAD_STATE_OVERRIDE="$BASE/state" SQUAD_CONFIG_OVERRIDE="$BASE/config"

# ── fake Bitwarden CLI ─────────────────────────────────────────────────────
#
# It answers the four calls sq-secret.sh makes and keeps the "vault" in one JSON
# file, so item lookup, the locked refusal, and the list shape all come from
# data the test controls.
cat > "$FAKEBIN/bw" <<'SH'
#!/usr/bin/env bash
set -u
vault=${FAKE_BW_VAULT:?}
default_server=https://bw.example.invalid
url=${FAKE_BW_SERVER_URL-$default_server}
status=${FAKE_BW_STATUS:-unlocked}
lockfile=$vault/locked-during-get
[ -e "$lockfile" ] && status=locked

# A stalled backend: the fake never answers, so the broker's bound must fire.
if [ "${FAKE_BW_HANG:-0}" = 1 ]; then
  sleep 30
fi

# The broker's per-call contract: every call carries --nointeraction, reads its
# stdin from /dev/null, and receives the session key in the environment. A
# regression in any of those must fail here instead of passing silently.
die() {
  printf 'fake bw: %s: %s\n' "$1" "$2" >&2
  exit 1
}
case " $* " in
  *' --nointeraction '*) ;;
  *) die nointeraction "call without --nointeraction: $*" ;;
esac
[ ! -t 0 ] || die stdin "stdin is a terminal: $*"
if [ -r /proc/self/fd/0 ] && command -v readlink >/dev/null 2>&1; then
  [ "$(readlink /proc/self/fd/0)" = /dev/null ] \
    || die stdin "stdin is not /dev/null: $*"
fi
require_session_key() {
  [ -n "${BW_SESSION:-}" ] || die session "no BW_SESSION for a vault call: $*"
}

case "${1:-}" in
  status)
    if [ "${FAKE_BW_STATUS_FAIL:-0}" = 1 ]; then
      printf 'Failed to read status.\n' >&2
      exit 1
    fi
    [ "$status" != unlocked ] || require_session_key
    if [ -n "$url" ]; then
      printf '{"serverUrl":"%s","status":"%s"}\n' "$url" "$status"
    else
      printf '{"serverUrl":null,"status":"%s"}\n' "$status"
    fi
    ;;
  config)
    [ "${2:-}" = server ] || exit 1
    if [ "${FAKE_BW_CONFIG_FAIL:-0}" = 1 ]; then
      printf 'Could not read the configured server.\n' >&2
      exit 1
    fi
    printf '%s' "${FAKE_BW_CONFIG_SERVER-https://bw.example.invalid}"
    ;;
  get)
    [ "${2:-}" = item ] || exit 1
    require_session_key
    if [ -n "${FAKE_BW_ENV_PROBE:-}" ]; then
      if [ -n "${!FAKE_BW_ENV_PROBE:-}" ]; then
        printf 'inherited\n' >> "$vault/env-probe.log"
      else
        printf 'clean\n' >> "$vault/env-probe.log"
      fi
    fi
    if [ "${FAKE_BW_STALE_SESSION:-0}" = 1 ]; then
      printf 'Invalid or expired session key.\n' >&2
      exit 1
    fi
    [ "$status" = unlocked ] || { printf 'Vault is locked.\n' >&2; exit 1; }
    if [ "${FAKE_BW_LOCK_GET:-0}" = 1 ]; then
      : > "$lockfile"
      printf 'Vault is locked.\n' >&2
      exit 1
    fi
    found=$(jq -c --arg t "${3:-}" '[.[] | select(.id == $t or .name == $t)]' "$vault/items.json") || exit 1
    case "$(printf '%s' "$found" | jq 'length')" in
      0) printf 'Not found.\n' >&2; exit 1 ;;
      1) printf '%s' "$found" | jq '.[0]' ;;
      *) printf 'More than one result was found.\n' >&2; exit 1 ;;
    esac
    ;;
  list)
    [ "${2:-}" = items ] || exit 1
    require_session_key
    if [ "${FAKE_BW_STALE_SESSION:-0}" = 1 ]; then
      printf 'Invalid or expired session key.\n' >&2
      exit 1
    fi
    if [ "${FAKE_BW_LIST_FAIL:-0}" = 1 ]; then
      printf 'Network error.\n' >&2
      exit 1
    fi
    if [ "${FAKE_BW_LIST_EMPTY:-0}" = 1 ]; then
      exit 0
    fi
    if [ "${FAKE_BW_LIST_GARBAGE:-0}" = 1 ]; then
      printf 'this is not json\n'
      exit 0
    fi
    [ "$status" = unlocked ] || { printf 'Vault is locked.\n' >&2; exit 1; }
    jq -c '.' "$vault/items.json"
    ;;
  *)
    printf 'fake bw: unsupported call: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/bw"

cat > "$VAULT/items.json" <<JSON
[
  {"id":"11111111-1111-1111-1111-111111111111","name":"sq/github-token","login":{"password":"$VALUE"}},
  {"id":"22222222-2222-2222-2222-222222222222","name":"sq/db-password","login":{"password":"$SPACED"}},
  {"id":"33333333-3333-3333-3333-333333333333","name":"sq/no-password","login":{"username":"someone"}},
  {"id":"44444444-4444-4444-4444-444444444444","name":"plain-item","login":{"password":"not-managed-here"}},
  {"id":"55555555-5555-5555-5555-555555555555","name":"sq/duplicated","login":{"password":"first"}},
  {"id":"66666666-6666-6666-6666-666666666666","name":"sq/duplicated","login":{"password":"second"}},
  {"id":"77777777-7777-7777-7777-777777777777","name":"sq/trailing-newline","login":{"password":"tail-value\n"}},
  {"id":"88888888-8888-8888-8888-888888888888","name":"sq/newlines","login":{"password":"\n\n"}}
]
JSON

# A PATH with the tools sq-secret.sh needs and a bw that answers, but no jq.
NOJQBIN="$TMP_ROOT/nojqbin"
mkdir -p "$NOJQBIN"
TOOLS="bash env basename dirname date sed grep mkdir cat sort head sh tr wc ps readlink cp"
for tool in $TOOLS; do
  resolved=$(command -v "$tool" 2>/dev/null) && ln -s "$resolved" "$NOJQBIN/$tool"
done
ln -s "$FAKEBIN/bw" "$NOJQBIN/bw"

# A PATH with the tools sq-secret.sh needs and no bw at all.
MINBIN="$TMP_ROOT/minbin"
mkdir -p "$MINBIN"
for tool in $TOOLS jq; do
  resolved=$(command -v "$tool" 2>/dev/null) && ln -s "$resolved" "$MINBIN/$tool"
done

# sq_secret <path> <args...>: run the script against the fake backend.
# BW_SESSION_TEST unset means a plausible session; set empty means no session.
sq_secret() {
  local path=$1
  shift
  [ "${FAKE_BW_LOCK_GET:-0}" = 1 ] || rm -f "$VAULT/locked-during-get"
  PATH="$path" \
    FAKE_BW_VAULT="$VAULT" \
    FAKE_BW_STATUS="${FAKE_BW_STATUS:-unlocked}" \
    FAKE_BW_LOCK_GET="${FAKE_BW_LOCK_GET:-0}" \
    FAKE_BW_HANG="${FAKE_BW_HANG:-0}" \
    SQUAD_SECRET_BW_TIMEOUT="${SECRET_BW_TIMEOUT:-}" \
    BW_SESSION="${BW_SESSION_TEST-fake-session}" \
    SQUAD_BASE="$BASE" \
    SQUAD_STATE_OVERRIDE="$BASE/state" \
    SQUAD_CONFIG_OVERRIDE="$BASE/config" \
    "$SECRET" "$@"
}

# run_pty <command...>: run one command with stdout on a real terminal, so the
# terminal guard is exercised instead of simulated. Prints the pty output.
run_pty() {
  local quoted
  if script -qec true /dev/null >/dev/null 2>&1; then
    quoted=$(printf '%q ' "$@")
    script -qec "$quoted" /dev/null
  elif script -q /dev/null true >/dev/null 2>&1; then
    script -q /dev/null "$@"
  else
    return 127
  fi
}

audit_count() {
  [ -f "$LOG" ] || { printf '0'; return 0; }
  wc -l < "$LOG" | tr -d ' '
}

# ── (a) get writes the value and nothing else ──────────────────────────────

test_get_writes_only_the_value() {
  local out="$TMP_ROOT/get.out" err="$TMP_ROOT/get.err"
  sq_secret "$FAKEBIN:$PATH" get github-token > "$out" 2> "$err" \
    || fail "get failed: $(cat "$err")"
  printf '%s' "$VALUE" > "$TMP_ROOT/get.expected"
  cmp -s "$TMP_ROOT/get.expected" "$out" \
    || fail "get must write the value and nothing else: $(od -c "$out" | head -3)"
  [ ! -s "$err" ] || fail "get must stay quiet on success: $(cat "$err")"
  pass "get writes the value and nothing else"

  # --item overrides the sq/<name> convention for one call.
  out_item=$(sq_secret "$FAKEBIN:$PATH" get arbitrary-logical-name --item sq/db-password)
  [ "$out_item" = "$SPACED" ] || fail "--item resolves the named item: '$out_item'"
  pass "get --item overrides the item lookup for one call"
}

# ── (b) the terminal guard ─────────────────────────────────────────────────

test_get_refuses_a_terminal() {
  local out rc
  out=$(PATH="$FAKEBIN:$PATH" FAKE_BW_VAULT="$VAULT" BW_SESSION=fake-session \
    SQUAD_BASE="$BASE" run_pty "$SECRET" get github-token 2>&1)
  rc=$?
  if [ "$rc" -eq 127 ]; then
    pass "no pty tool available; terminal guard covered by the refusal path only"
    return 0
  fi
  [ "$rc" -ne 0 ] || fail "get must refuse a terminal without --to-tty: $out"
  assert_contains "$out" "tty-refused" "the terminal refusal names its reason"
  assert_not_contains "$out" "$VALUE" "the terminal refusal must not print the value"
  pass "get refuses a terminal without --to-tty"

  out=$(PATH="$FAKEBIN:$PATH" FAKE_BW_VAULT="$VAULT" BW_SESSION=fake-session \
    SQUAD_BASE="$BASE" run_pty "$SECRET" get github-token --to-tty 2>&1)
  rc=$?
  expect_code 0 "$rc" "get --to-tty on a terminal"
  assert_contains "$out" "$VALUE" "get --to-tty writes the value to the terminal"
  pass "get honors an explicit --to-tty"
}

# ── (c) run keeps the value out of argv ────────────────────────────────────

test_run_keeps_the_value_out_of_argv() {
  local envfile="$TMP_ROOT/run.env" cmdline="$TMP_ROOT/run.cmdline"
  # shellcheck disable=SC2016  # the child shell expands these, not the test
  sq_secret "$FAKEBIN:$PATH" run --with GH_TOKEN=github-token -- \
    sh -c 'printf "%s" "$GH_TOKEN" > "$1"
           if [ -r "/proc/$$/cmdline" ]; then
             tr "\0" "\n" < "/proc/$$/cmdline" > "$2"
           elif ps -o args= -p $$ > "$2" 2>/dev/null; then :
           else printf "%s\n" unavailable > "$2"
           fi' \
    _ "$envfile" "$cmdline" \
    || fail "run failed"
  [ "$(cat "$envfile")" = "$VALUE" ] || fail "run must place the value in the child environment"
  if [ "$(cat "$cmdline")" = unavailable ]; then
    pass "no cmdline probe on this host; child argv check skipped (environment verified)"
  else
    assert_grep "sh" "$cmdline" "the child cmdline is recorded"
    assert_no_grep "$VALUE" "$cmdline" "the child argv must not carry the value"
    pass "run places the value in the child environment and never in its argv"
  fi

  # shellcheck disable=SC2016  # the child shell expands these, not the test
  sq_secret "$FAKEBIN:$PATH" run --with A=github-token --with B=db-password -- \
    sh -c 'test -n "$A" && test -n "$B"' \
    || fail "run must resolve every --with pair"
  pass "run resolves every requested name"

  # A helper spawned while resolving a later name must not inherit an earlier
  # value: only the consuming child sees any of them.
  local probe="$VAULT/env-probe.log"
  rm -f "$probe"
  FAKE_BW_ENV_PROBE=A sq_secret "$FAKEBIN:$PATH" \
    run --with A=github-token --with B=db-password -- true \
    || fail "run failed while probing the helper environment"
  assert_present "$probe" "the helper environment probe ran"
  assert_no_grep "inherited" "$probe" \
    "a helper spawned for a later name must not inherit an earlier value"
  pass "run exports resolved values only to the consuming child"
}

# ── (d) the audit log ──────────────────────────────────────────────────────

test_audit_log_records_every_resolution() {
  local before after mode
  rm -f "$LOG"
  before=$(audit_count)
  sq_secret "$FAKEBIN:$PATH" get github-token >/dev/null
  after=$(audit_count)
  [ "$after" -eq $((before + 1)) ] || fail "get appends exactly one audit line"
  assert_present "$LOG" "the audit log is created on demand"
  mode=$(stat -c %a "$LOG" 2>/dev/null || stat -f %Lp "$LOG")
  [ "$mode" = 600 ] || fail "the audit log must be user-only, got $mode"

  printf '%s' '{"audit-task":["github-token"]}' > "$POLICY"
  sq_secret "$FAKEBIN:$PATH" run --for audit-task --with T=github-token -- true
  [ "$(audit_count)" -eq $((after + 1)) ] || fail "run appends exactly one line per resolution"
  local last
  last=$(tail -n 1 "$LOG")
  assert_contains "$last" 'name="github-token"' "the audit line names the logical secret"
  assert_contains "$last" 'item="sq/github-token"' "the audit line names the backing item"
  assert_contains "$last" 'task="audit-task"' "the audit line records the resolved task id"
  assert_contains "$last" 'caller="sq-secret.sh:' "the audit line records the broker script and pid"
  assert_contains "$last" 'command="true"' "the audit line records the child command"
  assert_contains "$last" "outcome=ok" "the audit line records the outcome"
  assert_no_grep "$VALUE" "$LOG" "the audit log must never contain a value"
  assert_no_grep "$SPACED" "$LOG" "the audit log must never contain a value"
  pass "the audit log records one value-free line per resolution"

  # The caller field must name the process that asked for the secret, not only
  # the broker, so a resolution stays attributable after that process exits.
  local caller_pid
  rm -f "$LOG"
  ( printf '%s' "$BASHPID" > "$TMP_ROOT/caller.pid"
    sq_secret "$FAKEBIN:$PATH" get github-token >/dev/null ) \
    || fail "get from a known parent process failed"
  caller_pid=$(cat "$TMP_ROOT/caller.pid")
  last=$(tail -n 1 "$LOG")
  assert_contains "$last" "parent=bash:$caller_pid" \
    "the audit line records the invoking process and its pid"
  assert_contains "$last" 'caller="sq-secret.sh:' "the audit line also records the broker itself"
  pass "the audit line records the invoking process alongside the broker"

  rm -f "$LOG"
  sq_secret "$FAKEBIN:$PATH" get nope >/dev/null 2>&1 || true
  assert_contains "$(cat "$LOG")" "outcome=failed" "a failed resolution is audited too"
  pass "a failed resolution is audited"
}

# ── (e) scope policy ───────────────────────────────────────────────────────

test_scope_policy() {
  local out rc
  rm -f "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --for some-task 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a --for call without a policy file must fail"
  assert_contains "$out" "policy-missing" "a missing policy names its reason"
  assert_not_contains "$out" "$VALUE" "a policy refusal must not print the value"
  pass "a --for call without a policy file fails closed"

  printf '%s' 'not json' > "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --for some-task 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed policy must fail"
  assert_contains "$out" "policy-invalid" "a malformed policy names its reason"
  pass "a malformed policy fails instead of bypassing the check"

  printf '%s' '{"other-task":["github-token"]}' > "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --for some-task 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a task with no policy entry must be denied"
  assert_contains "$out" "policy-unknown-task" "an unscoped task names its reason"
  pass "a task with no policy entry is denied"

  # An empty --for value must never collapse into "no scope": it is rejected at
  # the option boundary, so it can neither skip the policy gate nor clear an
  # earlier task.
  local empty_marker="$TMP_ROOT/empty-task.marker" ok_before ok_after
  rm -f "$POLICY" "$empty_marker"
  ok_before=$(grep -c 'outcome=ok' "$LOG" 2>/dev/null || true)
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --for '' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "get with an empty --for must fail instead of resolving unscoped"
  assert_not_contains "$out" "$VALUE" "an empty --for get must not print the value"
  # shellcheck disable=SC2016  # the child shell expands these, not the test
  out=$(sq_secret "$FAKEBIN:$PATH" run --for '' --with T=github-token -- \
    sh -c 'touch "$1"' _ "$empty_marker" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "run with an empty --for must fail instead of resolving unscoped"
  assert_not_contains "$out" "$VALUE" "an empty --for run must not print the value"
  [ ! -e "$empty_marker" ] || fail "an empty --for run must never execute the child"
  printf '%s' '{"some-task":["github-token"]}' > "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --for some-task --for '' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a later empty --for must not clear an earlier valid task"
  assert_not_contains "$out" "$VALUE" "a cleared task must not print the value"
  ok_after=$(grep -c 'outcome=ok' "$LOG" 2>/dev/null || true)
  [ "${ok_before:-0}" = "${ok_after:-0}" ] \
    || fail "an empty --for must not record a successful resolution"
  pass "an empty --for value is refused instead of disabling the scope policy"

  printf '%s' '{"some-task":["db-password"]}' > "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --for some-task 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted name must be denied"
  assert_contains "$out" "policy-denied" "an unlisted name names its reason"
  pass "an unlisted name is denied"

  # shellcheck disable=SC2016  # the child shell expands these, not the test
  out=$(sq_secret "$FAKEBIN:$PATH" run --for some-task --with T=github-token -- \
    sh -c 'printf "%s" "$T"' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "run must deny an unlisted name"
  assert_contains "$out" "policy-denied" "a denied run names its reason"
  assert_not_contains "$out" "$VALUE" "a denied run must not resolve the value"
  pass "run denies an unlisted name under the same scope policy"

  # A scope denial must gate the whole call: a listed name that precedes the
  # denied one must not be resolved, audited as ok, or handed to a child.
  local marker="$TMP_ROOT/run-gate.marker" ok_before ok_after
  printf '%s' '{"gate-task":["github-token"]}' > "$POLICY"
  rm -f "$marker"
  ok_before=$(grep -c 'outcome=ok' "$LOG" 2>/dev/null || true)
  # shellcheck disable=SC2016  # the child shell expands this, not the test
  out=$(sq_secret "$FAKEBIN:$PATH" run --for gate-task \
    --with A=github-token --with B=db-password -- \
    sh -c 'touch "$1"' _ "$marker" 2>&1)
  rc=$?
  ok_after=$(grep -c 'outcome=ok' "$LOG" 2>/dev/null || true)
  [ "$rc" -ne 0 ] || fail "run must deny a call whose later name is unscoped"
  assert_contains "$out" "policy-denied" "a multi-name denial names its reason"
  assert_not_contains "$out" "$VALUE" "a multi-name denial must not resolve the listed name"
  [ ! -e "$marker" ] || fail "a denied multi-name run must never execute the child"
  [ "${ok_before:-0}" = "${ok_after:-0}" ] \
    || fail "a denied multi-name run must resolve nothing before denying"
  pass "run denies the whole call before resolving any name"

  printf '%s' '{"some-task":["github-token"]}' > "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --item sq/db-password --for some-task 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an --item outside the task scope must be denied"
  assert_contains "$out" "policy-item-mismatch" "an out-of-scope --item names its reason"
  assert_not_contains "$out" "$SPACED" "an out-of-scope --item must not print the value"

  # A bare vault item whose name matches the listed logical name is not the
  # item the policy authorizes: the authorized backing item is sq/<name>.
  printf '%s' '{"some-task":["plain-item"]}' > "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get plain-item --item plain-item --for some-task 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a bare listed name must not resolve an unmanaged item"
  assert_contains "$out" "policy-item-mismatch" "a bare listed name names its reason"
  assert_not_contains "$out" "not-managed-here" "a bare listed name must not print the unmanaged value"

  # The item's documented id form still reaches the item the policy authorizes.
  printf '%s' '{"some-task":["github-token"]}' > "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token \
    --item 11111111-1111-1111-1111-111111111111 --for some-task 2>&1)
  rc=$?
  expect_code 0 "$rc" "the authorized item's id resolves under --for"
  [ "$out" = "$VALUE" ] || fail "an --item id of the authorized item resolves: '$out'"

  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --item sq/github-token --for some-task 2>&1)
  rc=$?
  expect_code 0 "$rc" "an --item that matches the scoped name"
  [ "$out" = "$VALUE" ] || fail "an in-scope --item resolves: '$out'"
  pass "the --for policy also constrains the resolved item"

  printf '%s' '{"some-task":["github-token"]}' > "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token --for some-task 2>&1)
  rc=$?
  expect_code 0 "$rc" "a listed name resolves"
  [ "$out" = "$VALUE" ] || fail "a listed name resolves to its value: '$out'"
  # shellcheck disable=SC2016  # the child shell expands these, not the test
  out=$(sq_secret "$FAKEBIN:$PATH" run --for some-task --with T=github-token -- \
    sh -c 'printf "%s" "$T"')
  [ "$out" = "$VALUE" ] || fail "run honors a listed name: '$out'"
  pass "a listed name resolves under its task scope"

  # A refusal must still name its reason when the audit log cannot be written.
  rm -f "$LOG"
  ln -s "$TMP_ROOT/audit-target" "$LOG"
  out=$(sq_secret "$FAKEBIN:$PATH" get db-password --for some-task 2>&1)
  rc=$?
  rm -f "$LOG"
  [ "$rc" -eq 1 ] || fail "a policy denial must still exit 1 when the audit log is unwritable"
  assert_contains "$out" "policy-denied" "a refusal names its reason even when the audit log is unwritable"
  pass "a refusal names its reason even when the audit log is unwritable"

  rm -f "$POLICY"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token)
  [ "$out" = "$VALUE" ] || fail "resolution without --for stays allowed: '$out'"
  pass "resolution without --for stays allowed and audited"
}

# ── (f) fail-closed paths ──────────────────────────────────────────────────

test_fail_closed() {
  local out rc
  out=$(sq_secret "$MINBIN" get github-token 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing bw must fail"
  assert_contains "$out" "bw-missing" "a missing bw names its reason"
  assert_not_contains "$out" "$VALUE" "a missing bw must not print the value"
  pass "a missing bw fails closed"

  out=$(sq_secret "$NOJQBIN" get github-token 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing jq must fail"
  assert_contains "$out" "jq-missing" "a missing jq names its reason"
  assert_not_contains "$out" "$VALUE" "a missing jq must not print the value"
  out=$(sq_secret "$NOJQBIN" run --with T=github-token -- printenv T 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "run must fail when jq is missing"
  assert_contains "$out" "jq-missing" "run names a missing jq as its reason"
  assert_not_contains "$out" "$VALUE" "run must not print the value when jq is missing"
  pass "a missing jq fails closed on both get and run"

  out=$(FAKE_BW_STATUS=locked sq_secret "$FAKEBIN:$PATH" get github-token 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a locked vault must fail"
  assert_contains "$out" "session-locked" "a locked vault names its reason"
  assert_contains "$out" "bw unlock" "a locked vault names the remedy"
  assert_not_contains "$out" "$VALUE" "a locked vault must not print the value"
  pass "a locked vault fails closed and names bw unlock"

  BW_SESSION_TEST=''
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token 2>&1)
  rc=$?
  unset BW_SESSION_TEST
  [ "$rc" -ne 0 ] || fail "an absent BW_SESSION must fail"
  assert_contains "$out" "session-missing" "an absent session names its reason"
  assert_contains "$out" "bw unlock" "an absent session names the remedy"
  pass "an absent BW_SESSION fails closed and names bw unlock"

  out=$(sq_secret "$FAKEBIN:$PATH" get no-such-name 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown name must fail"
  assert_contains "$out" "item-missing" "an unknown name names its reason"
  assert_not_contains "$out" "$VALUE" "an unknown name must not print a value"
  pass "an unknown name fails closed"

  out=$(sq_secret "$FAKEBIN:$PATH" get no-password 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an item with no password field must fail"
  assert_contains "$out" "item-no-password" "an unusable item names its reason"
  pass "an item with no usable password field fails closed instead of resolving empty"

  out=$(sq_secret "$FAKEBIN:$PATH" get duplicated 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an ambiguous item must fail"
  assert_contains "$out" "item-unreadable" "an ambiguous item is reported as unreadable"
  assert_not_contains "$out" "item-missing" "an existing item is never reported as missing"
  pass "an item bw resolves ambiguously fails closed as unreadable"

  out=$(FAKE_BW_LIST_FAIL=1 sq_secret "$FAKEBIN:$PATH" get no-such-name 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unlistable vault must fail the resolution"
  assert_contains "$out" "session-unreadable" "a vault that cannot be listed is reported as unreadable"
  assert_contains "$out" "bw unlock" "an unlistable vault names the unlock remedy"
  assert_not_contains "$out" "item-missing" "a failure to inspect the vault is never reported as a missing item"
  pass "a vault that cannot be listed is never reported as a missing item"

  out=$(FAKE_BW_LIST_EMPTY=1 sq_secret "$FAKEBIN:$PATH" get no-such-name 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unlistable vault must fail the resolution"
  assert_not_contains "$out" "item-missing" "an unparsable listing is never reported as a missing item"
  assert_contains "$out" "session-unreadable" "an unparsable listing is reported as unreadable"
  pass "an empty listing is not mistaken for a vault with no match"

  out=$(FAKE_BW_STALE_SESSION=1 sq_secret "$FAKEBIN:$PATH" get github-token 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a stale session key must fail the resolution"
  assert_contains "$out" "session-unreadable" "a stale session key is reported as a session failure"
  assert_contains "$out" "bw unlock" "a stale session key names the unlock remedy"
  assert_not_contains "$out" "item-unreadable" "a stale session key never blames the item"
  assert_not_contains "$out" "$VALUE" "a stale session key must not print the value"
  pass "a stale session key fails closed as a session failure with the remedy"

  # A resolution must stand on the item read it actually performs: a vault
  # listing the script never needed cannot veto a value the item read resolved.
  out=$(FAKE_BW_LIST_GARBAGE=1 sq_secret "$FAKEBIN:$PATH" get github-token 2>&1)
  rc=$?
  expect_code 0 "$rc" "a resolution whose item read succeeds"
  [ "$out" = "$VALUE" ] \
    || fail "an unusable bulk listing must not block a working item read: '$out'"
  pass "a resolution does not depend on a whole-vault listing"

  out=$(FAKE_BW_LOCK_GET=1 sq_secret "$FAKEBIN:$PATH" get github-token 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a vault that locks during the fetch must fail"
  assert_contains "$out" "session-locked" "a vault that locks mid-resolution names the session"
  assert_contains "$out" "bw unlock" "a vault that locks mid-resolution names the remedy"
  assert_not_contains "$out" "item-missing" "a lock is never reported as a missing item"
  assert_not_contains "$out" "$VALUE" "a lock must not print the value"
  pass "a vault that locks between the check and the fetch fails closed"
}

# ── (g) check ──────────────────────────────────────────────────────────────

test_check() {
  local out rc
  out=$(sq_secret "$FAKEBIN:$PATH" check)
  rc=$?
  expect_code 0 "$rc" "check on a usable backend"
  assert_contains "$out" "bw: present" "check reports bw"
  assert_contains "$out" "jq: present" "check reports jq"
  assert_contains "$out" "server: https://bw.example.invalid" "check reports the configured server"
  assert_contains "$out" "session: unlocked" "check reports the session"
  pass "check reports every backend fact on a usable backend"

  # `bw config server` reports the effective server, including the built-in
  # cloud default that `bw status` describes as serverUrl null.
  out=$(FAKE_BW_SERVER_URL='' FAKE_BW_CONFIG_SERVER=https://bitwarden.com \
    sq_secret "$FAKEBIN:$PATH" check 2>&1)
  rc=$?
  expect_code 0 "$rc" "check on a default-configured bw"
  assert_contains "$out" "server: https://bitwarden.com" \
    "check reports the server bw is configured with even when status reports null"
  assert_not_contains "$out" "server: unknown" "a default server is a configured server"
  assert_not_contains "$out" "server: not configured" "a default server is a configured server"
  pass "check reports the built-in default server instead of calling it unconfigured"

  out=$(FAKE_BW_CONFIG_FAIL=1 sq_secret "$FAKEBIN:$PATH" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when bw config server cannot be read"
  assert_contains "$out" "server: unknown" "check separates an unreadable server from a usable one"
  assert_contains "$out" "session: unlocked" "an unreadable server does not hide the session fact"
  pass "check reports an unreadable server as unusable"

  out=$(FAKE_BW_STATUS_FAIL=1 sq_secret "$FAKEBIN:$PATH" check 2>&1)
  rc=$?
  expect_code 0 "$rc" "check on a vault that a real read proves readable"
  assert_contains "$out" "server: https://bw.example.invalid" \
    "a status failure does not hide the server fact"
  assert_contains "$out" "session: unlocked" \
    "a real vault read proves the session without trusting bw status"
  pass "check proves the session with a vault read instead of bw status"

  out=$(FAKE_BW_STALE_SESSION=1 sq_secret "$FAKEBIN:$PATH" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when the vault read fails"
  assert_not_contains "$out" "session: unlocked" \
    "a stale session is never reported as unlocked"
  assert_contains "$out" "session: unreadable" "check names a session the vault read cannot prove"
  assert_contains "$out" "bw unlock" "check names the unlock remedy when the read fails"
  pass "check refuses to report a stale session as unlocked"

  out=$(FAKE_BW_LIST_FAIL=1 sq_secret "$FAKEBIN:$PATH" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when the vault cannot be read"
  assert_not_contains "$out" "session: unlocked" "an unreadable vault is never reported as unlocked"
  assert_contains "$out" "session: unreadable" "check names an unreadable vault"
  assert_contains "$out" "bw unlock" "check names the unlock remedy for an unreadable vault"
  pass "check fails when the vault cannot be read"

  out=$(sq_secret "$MINBIN" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when bw is missing"
  assert_contains "$out" "bw: missing" "check names a missing bw"
  assert_contains "$out" "server: unknown (bw is not installed)" "check names the server as unknown when bw is missing"
  assert_contains "$out" "jq: present" "check still reports jq when bw is missing"
  assert_contains "$out" "session: unknown" "check does not blame the session when bw is missing"
  pass "check exits non-zero when the backend is unusable"

  out=$(sq_secret "$NOJQBIN" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when jq is missing"
  assert_contains "$out" "jq: missing" "check names a missing jq"
  assert_contains "$out" "session: unknown" \
    "check names the missing jq, not the session, as the reason the probe cannot run"
  assert_not_contains "$out" "bw unlock" \
    "a missing jq never sends the operator to bw unlock"
  assert_not_contains "$out" "session: unreadable" \
    "a missing jq is not reported as an unreadable vault"
  pass "check reports a missing jq as unusable without blaming the session"

  out=$(FAKE_BW_STATUS=locked sq_secret "$FAKEBIN:$PATH" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero on a locked session"
  assert_contains "$out" "session: locked" "check reports a locked session"
  assert_contains "$out" "bw unlock" "check names the unlock remedy"
  pass "check reports a locked session as unusable"
}

# ── (h) list ───────────────────────────────────────────────────────────────

test_list() {
  local out rc
  out=$(sq_secret "$FAKEBIN:$PATH" list)
  assert_contains "$out" "github-token	11111111-1111-1111-1111-111111111111" "list prints a name with its item id"
  assert_contains "$out" "db-password	22222222-2222-2222-2222-222222222222" "list prints every managed name"
  assert_not_contains "$out" "plain-item" "list ignores items outside the sq/ convention"
  assert_not_contains "$out" "$VALUE" "list never prints a value"
  assert_not_contains "$out" "$SPACED" "list never prints a value"
  pass "list prints names and metadata only"

  out=$(FAKE_BW_LIST_FAIL=1 sq_secret "$FAKEBIN:$PATH" list 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "list must fail when bw cannot list the vault"
  assert_contains "$out" "session-unreadable" \
    "a vault that refuses a listing under an unlocked status is a session failure"
  assert_contains "$out" "bw unlock" "an unlistable vault names the unlock remedy"

  out=$(FAKE_BW_STALE_SESSION=1 sq_secret "$FAKEBIN:$PATH" list 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "list must fail on a stale session"
  assert_contains "$out" "session-unreadable" "a stale session is reported as a session failure"
  assert_contains "$out" "bw unlock" "a stale session names the unlock remedy"
  assert_not_contains "$out" "item-listing" "a stale session is not blamed on the listing"
  assert_not_contains "$out" "github-token" "a stale session prints no listing"
  pass "list fails closed with a named session reason when the vault cannot be listed"

  out=$(FAKE_BW_LIST_GARBAGE=1 sq_secret "$FAKEBIN:$PATH" list 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "list must fail when the listing cannot be read"
  assert_contains "$out" "item-listing" "an unparsable listing names its reason"
  assert_not_contains "$out" "parse error" "an unparsable listing is not a raw jq error"
  pass "list reports an unparsable listing as a named item-listing failure"
}

# ── (h2) an unauditable resolution is refused ──────────────────────────────

test_unauditable_resolution_is_refused() {
  local out rc
  rm -f "$LOG"
  ln -s "$TMP_ROOT/audit-target" "$LOG"
  out=$(sq_secret "$FAKEBIN:$PATH" get github-token 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "an unauditable get must exit 1, got $rc"
  assert_contains "$out" "audit-unwritable" "an unauditable get names its reason"
  assert_not_contains "$out" "$VALUE" "an unauditable get must not print the value"

  # shellcheck disable=SC2016  # the child shell expands these, not the test
  out=$(sq_secret "$FAKEBIN:$PATH" run --with T=github-token -- \
    sh -c 'printf "%s" "$T"' 2>&1)
  rc=$?
  rm -f "$LOG"
  [ "$rc" -eq 1 ] || fail "an unauditable run must exit 1, got $rc"
  assert_contains "$out" "audit-unwritable" "an unauditable run names its reason"
  assert_not_contains "$out" "$VALUE" "an unauditable run must not run the child with the value"
  pass "an unauditable resolution is refused instead of emitting an unaudited value"
}

# ── (i) nothing cached on disk ─────────────────────────────────────────────

test_no_cache_on_disk() {
  local listing home_listing tmp_listing fixture_home="$TMP_ROOT/home" fixture_tmp="$TMP_ROOT/tmp"
  rm -rf "${BASE:?}/state" "$fixture_home" "$fixture_tmp"
  mkdir -p "$BASE/state" "$fixture_home" "$fixture_tmp"
  HOME="$fixture_home" TMPDIR="$fixture_tmp" \
    sq_secret "$FAKEBIN:$PATH" get github-token >/dev/null
  HOME="$fixture_home" TMPDIR="$fixture_tmp" \
    sq_secret "$FAKEBIN:$PATH" run --with T=db-password -- true
  listing=$(cd "$BASE" && find . -type f | LC_ALL=C sort)
  [ "$listing" = "./state/secrets-audit.log" ] \
    || fail "resolution must cache nothing but the audit log, found: $listing"
  home_listing=$(cd "$fixture_home" && find . -mindepth 1 | LC_ALL=C sort)
  [ -z "$home_listing" ] \
    || fail "resolution must write nothing under HOME, found: $home_listing"
  tmp_listing=$(cd "$fixture_tmp" && find . -mindepth 1 | LC_ALL=C sort)
  [ -z "$tmp_listing" ] \
    || fail "resolution must cache nothing under TMPDIR, found: $tmp_listing"
  assert_no_grep "$VALUE" "$LOG" "the audit log never carries a value"
  pass "resolution caches nothing on disk beyond the audit log"
}

# ── (k) the value's bytes are preserved ───────────────────────────────────

test_value_bytes_are_preserved() {
  local out="$TMP_ROOT/bytes.out" envfile="$TMP_ROOT/bytes.env"
  local expected="$TMP_ROOT/bytes.expected"
  printf 'tail-value\n' > "$expected"
  sq_secret "$FAKEBIN:$PATH" get trailing-newline > "$out" \
    || fail "a value with a trailing newline must resolve"
  cmp -s "$expected" "$out" \
    || fail "get must hand over the bytes the vault holds: $(od -c "$out" | head -3)"
  # shellcheck disable=SC2016  # the child shell expands this, not the test
  sq_secret "$FAKEBIN:$PATH" run --with T=trailing-newline -- \
    sh -c 'printf "%s" "$T" > "$1"' _ "$envfile" \
    || fail "run must resolve a value with a trailing newline"
  cmp -s "$expected" "$envfile" \
    || fail "run must export the exact bytes: $(od -c "$envfile" | head -3)"
  pass "get and run preserve a trailing newline in the value"

  printf '\n\n' > "$expected"
  sq_secret "$FAKEBIN:$PATH" get newlines > "$out" \
    || fail "a newline-only password is a populated field, not an empty one"
  cmp -s "$expected" "$out" \
    || fail "a newline-only value must resolve unchanged: $(od -c "$out" | head -3)"
  pass "a newline-only value is resolved rather than refused as empty"
}

# ── (l) a stalled backend is bounded ───────────────────────────────────────

test_stalled_backend() {
  local out rc started elapsed
  started=$(date +%s)
  out=$(FAKE_BW_HANG=1 SECRET_BW_TIMEOUT=1 sq_secret "$FAKEBIN:$PATH" get github-token 2>&1)
  rc=$?
  elapsed=$(($(date +%s) - started))
  [ "$rc" -ne 0 ] || fail "a stalled backend must fail instead of hanging"
  assert_contains "$out" "bw-timeout" "a stalled backend names its reason"
  assert_not_contains "$out" "$VALUE" "a stalled backend must not print the value"
  [ "$elapsed" -lt 20 ] || fail "a stalled get must be bounded, took ${elapsed}s"

  started=$(date +%s)
  out=$(FAKE_BW_HANG=1 SECRET_BW_TIMEOUT=1 sq_secret "$FAKEBIN:$PATH" list 2>&1)
  rc=$?
  elapsed=$(($(date +%s) - started))
  [ "$rc" -ne 0 ] || fail "list must fail instead of hanging on a stalled backend"
  assert_contains "$out" "bw-timeout" "list names the stalled backend"
  [ "$elapsed" -lt 20 ] || fail "a stalled list must be bounded, took ${elapsed}s"
  pass "a stalled backend fails closed under the time bound"
}

# ── (j) shellcheck-clean ───────────────────────────────────────────────────

test_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --norc --external-sources "$SECRET" || fail "shellcheck failed on sq-secret.sh"
    shellcheck --norc --external-sources "$ROOT/tests/sq-secret.test.sh" \
      || fail "shellcheck failed on the test"
    pass "shellcheck passes on the broker and its test"
  else
    pass "shellcheck not available (skipped)"
  fi
}

test_get_writes_only_the_value
test_get_refuses_a_terminal
test_run_keeps_the_value_out_of_argv
test_audit_log_records_every_resolution
test_scope_policy
test_unauditable_resolution_is_refused
test_fail_closed
test_check
test_list
test_no_cache_on_disk
test_stalled_backend
test_value_bytes_are_preserved
test_shellcheck

printf 'all sq-secret tests passed\n'
