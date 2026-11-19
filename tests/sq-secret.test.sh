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
#       with no entry, and refuses a missing or malformed policy
#   (f) fail-closed behaviour for missing bw, missing jq, a locked session, a
#       stale session key, an unknown item, an item with no usable password
#       field, and an item or vault that bw cannot resolve unambiguously
#   (g) `check` reports each backend fact and exits non-zero when unusable
#   (h) `list` prints names and metadata only
#   (i) nothing is cached on disk beyond the audit log
#   (j) shellcheck-clean
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
case "${1:-}" in
  status)
    if [ "${FAKE_BW_STATUS_FAIL:-0}" = 1 ]; then
      printf 'Failed to read status.\n' >&2
      exit 1
    fi
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
  {"id":"66666666-6666-6666-6666-666666666666","name":"sq/duplicated","login":{"password":"second"}}
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
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when the session cannot be read"
  assert_contains "$out" "server: https://bw.example.invalid" \
    "an unreadable session does not hide the server fact"
  assert_contains "$out" "session: unknown" "check reports an unreadable session"
  pass "check separates the server fact from an unreadable session"

  out=$(sq_secret "$MINBIN" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when bw is missing"
  assert_contains "$out" "bw: missing" "check names a missing bw"
  assert_contains "$out" "server: unknown (bw is not installed)" "check names the server as unknown when bw is missing"
  assert_contains "$out" "jq: present" "check still reports jq when bw is missing"
  pass "check exits non-zero when the backend is unusable"

  out=$(sq_secret "$NOJQBIN" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when jq is missing"
  assert_contains "$out" "jq: missing" "check names a missing jq"
  pass "check reports a missing jq as unusable"

  out=$(FAKE_BW_STATUS=locked sq_secret "$FAKEBIN:$PATH" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero on a locked session"
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
  assert_contains "$out" "item-listing" "an unlistable vault names its reason"
  pass "list fails closed with a named reason when bw cannot list the vault"

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
  local listing
  rm -rf "${BASE:?}/state"
  mkdir -p "$BASE/state"
  sq_secret "$FAKEBIN:$PATH" get github-token >/dev/null
  sq_secret "$FAKEBIN:$PATH" run --with T=db-password -- true
  listing=$(cd "$BASE" && find . -type f | LC_ALL=C sort)
  [ "$listing" = "./state/secrets-audit.log" ] \
    || fail "resolution must cache nothing but the audit log, found: $listing"
  assert_no_grep "$VALUE" "$LOG" "the audit log never carries a value"
  pass "resolution caches nothing on disk beyond the audit log"
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
test_shellcheck

printf 'all sq-secret tests passed\n'
