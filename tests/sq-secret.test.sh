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
#   (f) fail-closed behaviour for missing bw, a locked session, an unknown item,
#       and an item with no usable password field
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

# ── fake Bitwarden CLI ─────────────────────────────────────────────────────
#
# It answers the four calls sq-secret.sh makes and keeps the "vault" in one JSON
# file, so item lookup, the locked refusal, and the list shape all come from
# data the test controls.
cat > "$FAKEBIN/bw" <<'SH'
#!/usr/bin/env bash
set -u
vault=${FAKE_BW_VAULT:?}
status=${FAKE_BW_STATUS:-unlocked}
case "${1:-}" in
  status)
    printf '{"serverUrl":"%s","status":"%s"}\n' "${FAKE_BW_SERVER_URL:-https://bw.example.invalid}" "$status"
    ;;
  config)
    [ "${2:-}" = server ] || exit 1
    printf '%s' "${FAKE_BW_SERVER_URL:-https://bw.example.invalid}"
    ;;
  get)
    [ "${2:-}" = item ] || exit 1
    [ "$status" = unlocked ] || { printf 'Vault is locked.\n' >&2; exit 1; }
    found=$(jq -c --arg t "${3:-}" '[.[] | select(.id == $t or .name == $t)]' "$vault/items.json") || exit 1
    case "$(printf '%s' "$found" | jq 'length')" in
      0) printf 'Not found.\n' >&2; exit 1 ;;
      1) printf '%s' "$found" | jq '.[0]' ;;
      *) printf 'More than one result was found.\n' >&2; exit 1 ;;
    esac
    ;;
  list)
    [ "${2:-}" = items ] || exit 1
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
  {"id":"44444444-4444-4444-4444-444444444444","name":"plain-item","login":{"password":"not-managed-here"}}
]
JSON

# A PATH with the tools sq-secret.sh needs and no bw at all.
MINBIN="$TMP_ROOT/minbin"
mkdir -p "$MINBIN"
for tool in bash env basename dirname date sed grep jq mkdir cat sort head sh tr wc; do
  resolved=$(command -v "$tool" 2>/dev/null) && ln -s "$resolved" "$MINBIN/$tool"
done

# sq_secret <path> <args...>: run the script against the fake backend.
# BW_SESSION_TEST unset means a plausible session; set empty means no session.
sq_secret() {
  local path=$1
  shift
  PATH="$path" \
    FAKE_BW_VAULT="$VAULT" \
    FAKE_BW_STATUS="${FAKE_BW_STATUS:-unlocked}" \
    BW_SESSION="${BW_SESSION_TEST-fake-session}" \
    SQUAD_BASE="$BASE" \
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
    sh -c 'printf "%s" "$GH_TOKEN" > "$1"; tr "\0" "\n" < "/proc/$$/cmdline" > "$2"' \
    _ "$envfile" "$cmdline" \
    || fail "run failed"
  [ "$(cat "$envfile")" = "$VALUE" ] || fail "run must place the value in the child environment"
  assert_grep "sh" "$cmdline" "the child cmdline is recorded"
  assert_no_grep "$VALUE" "$cmdline" "the child argv must not carry the value"
  pass "run places the value in the child environment and never in its argv"

  # shellcheck disable=SC2016  # the child shell expands these, not the test
  sq_secret "$FAKEBIN:$PATH" run --with A=github-token --with B=db-password -- \
    sh -c 'test -n "$A" && test -n "$B"' \
    || fail "run must resolve every --with pair"
  pass "run resolves every requested name"
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
  assert_contains "$last" 'caller="sq-secret.sh:' "the audit line records the caller script and pid"
  assert_contains "$last" 'command="true"' "the audit line records the child command"
  assert_contains "$last" "outcome=ok" "the audit line records the outcome"
  assert_no_grep "$VALUE" "$LOG" "the audit log must never contain a value"
  assert_no_grep "$SPACED" "$LOG" "the audit log must never contain a value"
  pass "the audit log records one value-free line per resolution"

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

  out=$(sq_secret "$MINBIN" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero when bw is missing"
  assert_contains "$out" "bw: missing" "check names a missing bw"
  pass "check exits non-zero when the backend is unusable"

  out=$(FAKE_BW_STATUS=locked sq_secret "$FAKEBIN:$PATH" check 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "check must exit non-zero on a locked session"
  assert_contains "$out" "bw unlock" "check names the unlock remedy"
  pass "check reports a locked session as unusable"
}

# ── (h) list ───────────────────────────────────────────────────────────────

test_list() {
  local out
  out=$(sq_secret "$FAKEBIN:$PATH" list)
  assert_contains "$out" "github-token	11111111-1111-1111-1111-111111111111" "list prints a name with its item id"
  assert_contains "$out" "db-password	22222222-2222-2222-2222-222222222222" "list prints every managed name"
  assert_not_contains "$out" "plain-item" "list ignores items outside the sq/ convention"
  assert_not_contains "$out" "$VALUE" "list never prints a value"
  assert_not_contains "$out" "$SPACED" "list never prints a value"
  pass "list prints names and metadata only"
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
test_fail_closed
test_check
test_list
test_no_cache_on_disk
test_shellcheck

printf 'all sq-secret tests passed\n'
