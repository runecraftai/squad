#!/usr/bin/env bash
# tests/sq-claude-account-live-e2e.test.sh - opt-in credentialed guard proving
# the Claude account axis against the REAL installed claude CLI: CLAUDE_CONFIG_DIR
# isolation, bin/sq-claude-account.sh verify, and bin/sq-spawn.sh --account.
#
# `claude auth status` behavior is exactly the harness-dependent-check class
# squad-coding-guidelines calls out: its verdict comes from something the
# vendor CLI emits, so a portable regression using a fake claude binary
# (tests/sq-claude-account.test.sh) can only confirm the assumption already
# written into that fake. This guard drives the real installed CLI instead.
#
# This sandbox has exactly one commander-registered Claude account, so the
# second "account" registered here is a fresh, never-authenticated
# CLAUDE_CONFIG_DIR rather than a second paid subscription - it still proves
# CLAUDE_CONFIG_DIR isolation (the load-bearing mechanism: two different
# config dirs, one real claude CLI, two distinguishable identities) and the
# whole sq-spawn.sh --account pipeline against that real CLI. Re-run this
# guard once a genuine second account is registered to extend the evidence;
# docs/verification/claude-accounts.md records the exact commands and output.
#
# Real claude is used only for the read-only `auth status --json` call; tmux is
# faked throughout, so this never starts an interactive Claude Code session or
# spends model tokens.
set -u

if [ "${SQUAD_CLAUDE_ACCOUNT_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set SQUAD_CLAUDE_ACCOUNT_LIVE_E2E=1 to run the credentialed Claude account guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCOUNT="$ROOT/bin/sq-claude-account.sh"
SPAWN="$ROOT/bin/sq-spawn.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v claude >/dev/null 2>&1 || fail "claude not found"
note "claude version: $(claude --version 2>&1)"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/sq-claude-account-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

REAL_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
COLD_DIR="$LAB/never-authenticated"
mkdir -p "$COLD_DIR" "$LAB/config"

# --- prove the real CLI reports the two config dirs as distinguishable -----

REAL_STATUS=$(CLAUDE_CONFIG_DIR="$REAL_DIR" claude auth status --json 2>&1)
REAL_RC=$?
note "real account auth status: $REAL_STATUS"
[ "$REAL_RC" -eq 0 ] || fail "the ambient Claude account ($REAL_DIR) is not logged in; log in with 'claude auth login' before running this guard"
case "$REAL_STATUS" in
  *'"loggedIn": true'*|*'"loggedIn":true'*) : ;;
  *) fail "real claude auth status --json did not report loggedIn:true for $REAL_DIR" ;;
esac

COLD_STATUS=$(CLAUDE_CONFIG_DIR="$COLD_DIR" claude auth status --json 2>&1)
COLD_RC=$?
note "fresh config dir auth status: $COLD_STATUS"
[ "$COLD_RC" -ne 0 ] || fail "a freshly created, never-authenticated CLAUDE_CONFIG_DIR unexpectedly reported success"
case "$COLD_STATUS" in
  *'"loggedIn": false'*|*'"loggedIn":false'*) : ;;
  *) fail "real claude auth status --json did not report loggedIn:false for a fresh config dir" ;;
esac
pass "the real claude CLI distinguishes an authenticated CLAUDE_CONFIG_DIR from a fresh, never-authenticated one"

# --- bin/sq-claude-account.sh verify against the real CLI -------------------

printf 'real %s\ncold %s\n' "$REAL_DIR" "$COLD_DIR" > "$LAB/config/claude-accounts"

VERIFY_REAL_OUT=$(SQUAD_ROOT_OVERRIDE='' SQUAD_CONFIG_OVERRIDE="$LAB/config" "$ACCOUNT" verify real)
VERIFY_REAL_RC=$?
[ "$VERIFY_REAL_RC" -eq 0 ] || fail "sq-claude-account.sh verify real failed against the real CLI: $VERIFY_REAL_OUT"
[ "$VERIFY_REAL_OUT" = "$REAL_DIR" ] || fail "verify real printed '$VERIFY_REAL_OUT', expected '$REAL_DIR'"
pass "sq-claude-account.sh verify confirms the real logged-in account via the real claude CLI"

VERIFY_COLD_OUT=$(SQUAD_ROOT_OVERRIDE='' SQUAD_CONFIG_OVERRIDE="$LAB/config" "$ACCOUNT" verify cold 2>&1)
VERIFY_COLD_RC=$?
[ "$VERIFY_COLD_RC" -ne 0 ] || fail "sq-claude-account.sh verify cold unexpectedly succeeded"
case "$VERIFY_COLD_OUT" in
  *"is not logged in"*) : ;;
  *) fail "verify cold did not report the account as not logged in: $VERIFY_COLD_OUT" ;;
esac
pass "sq-claude-account.sh verify refuses the never-authenticated account via the real claude CLI"

# --- bin/sq-spawn.sh --account end to end, real claude CLI + faked tmux -----

HOME_DIR="$LAB/home"
PROJ_DIR="$LAB/project"
WT_DIR="$LAB/wt"
FAKEBIN="$LAB/fakebin"
LAUNCH_LOG="$LAB/launch.log"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$FAKEBIN"
cp -r "$LAB/config" "$HOME_DIR/config"
git -C "$LAB" init -q "$PROJ_DIR" 2>/dev/null || true
mkdir -p "$PROJ_DIR"
git -C "$PROJ_DIR" init -q
printf '# fixture\n' > "$PROJ_DIR/README.md"
git -C "$PROJ_DIR" add README.md
git -C "$PROJ_DIR" -c user.name='Squad Tests' -c user.email='tests@example.invalid' commit -qm initial >/dev/null
git -C "$PROJ_DIR" worktree add --quiet -b sq/claude-account-live "$WT_DIR"
touch "$HOME_DIR/state/.last-sentry-beat"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${SQUAD_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'Squad\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${SQUAD_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$SQUAD_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
for tool in fob claude; do
  case "$tool" in
    claude) ln -s "$(command -v claude)" "$FAKEBIN/claude" ;;
    *) printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$tool"; chmod +x "$FAKEBIN/$tool" ;;
  esac
done

id1="claude-acct-live-real-$$"
mkdir -p "$HOME_DIR/data/$id1"
printf 'brief\necho done >> %s.status\n' "$HOME_DIR/data/$id1" > "$HOME_DIR/data/$id1/brief.md"
: > "$LAUNCH_LOG"
OUT1=$(SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$HOME_DIR" \
  SQUAD_STATE_OVERRIDE="$HOME_DIR/state" SQUAD_DATA_OVERRIDE="$HOME_DIR/data" \
  SQUAD_PROJECTS_OVERRIDE="$HOME_DIR/projects" SQUAD_CONFIG_OVERRIDE="$HOME_DIR/config" \
  SQUAD_SPAWN_NO_GUARD=1 SQUAD_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
  SQUAD_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN:$PATH" \
  "$SPAWN" "$id1" "$PROJ_DIR" claude --account real --mode drill --yolo off 2>&1)
STATUS1=$?
[ "$STATUS1" -eq 0 ] || fail "sq-spawn.sh --account real should succeed against the real CLI: $OUT1"
grep -qF "account=real" "$HOME_DIR/state/$id1.meta" || fail "meta did not record account=real"
grep -qF "CLAUDE_CONFIG_DIR='$REAL_DIR'" "$LAUNCH_LOG" || fail "launch did not forward the real account's config dir"
pass "sq-spawn.sh --account real authenticates the operator as the real registered account and forwards its config dir"

id2="claude-acct-live-cold-$$"
mkdir -p "$HOME_DIR/data/$id2"
printf 'brief\necho done >> %s.status\n' "$HOME_DIR/data/$id2" > "$HOME_DIR/data/$id2/brief.md"
: > "$LAUNCH_LOG"
OUT2=$(SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$HOME_DIR" \
  SQUAD_STATE_OVERRIDE="$HOME_DIR/state" SQUAD_DATA_OVERRIDE="$HOME_DIR/data" \
  SQUAD_PROJECTS_OVERRIDE="$HOME_DIR/projects" SQUAD_CONFIG_OVERRIDE="$HOME_DIR/config" \
  SQUAD_SPAWN_NO_GUARD=1 SQUAD_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
  SQUAD_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN:$PATH" \
  "$SPAWN" "$id2" "$PROJ_DIR" claude --account cold --mode drill --yolo off 2>&1)
STATUS2=$?
[ "$STATUS2" -ne 0 ] || fail "sq-spawn.sh --account cold should refuse against the real CLI: $OUT2"
case "$OUT2" in
  *"is not logged in"*) : ;;
  *) fail "spawn refusal did not report the cold account as not logged in: $OUT2" ;;
esac
[ ! -e "$HOME_DIR/state/$id2.meta" ] || fail "spawn created an endpoint before refusing the never-authenticated account"
pass "sq-spawn.sh --account cold refuses the never-authenticated account against the real CLI, before creating an endpoint"

echo "# all Claude account axis live behavior tests passed"
