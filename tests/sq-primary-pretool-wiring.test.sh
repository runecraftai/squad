#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavioral wiring test for the Pi primary extension's PreToolUse chain.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot sq-primary-pretool-wiring)
REPO=$TMP_ROOT/repo
HOME_DIR=$TMP_ROOT/home
mkdir -p "$REPO/.pi/extensions/lib" "$REPO/bin" "$HOME_DIR/state"
cp "$ROOT/.pi/extensions/sq-primary-turnend-guard.ts" "$REPO/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/sq-operational-input.ts" "$REPO/.pi/extensions/lib/"
cp "$ROOT/bin/sq-operational-input.sh" "$REPO/bin/"

cat > "$REPO/bin/sq-handoff-surface.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$REPO/bin/sq-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
cat > "$REPO/bin/sq-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$REPO/bin/sq-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${CHECK_LOG:?}"
exit 0
SH
cat > "$REPO/bin/sq-backend-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'backend:%s\n' "$*" >> "${CHECK_LOG:?}"
case "$*" in *tmux*) exit 2;; esac
exit 0
SH
cat > "$REPO/bin/sq-poll-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'poll:%s\n' "$*" >> "${CHECK_LOG:?}"
case "$*" in *state/*) exit 2;; esac
exit 0
SH
chmod +x "$REPO/bin/"*.sh
git init -q "$REPO"
: > "$REPO/AGENTS.md"

out=$(PLUGIN="$REPO/.pi/extensions/sq-primary-turnend-guard.ts" SQUAD_BASE="$HOME_DIR" \
  CHECK_LOG="$TMP_ROOT/check.log" node --input-type=module 2>&1 <<'NODE'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const call = handlers.get("tool_call");
if (!call) throw new Error("Pi tool_call handler was not registered");
const run = (command) => call({ type: "tool_call", toolName: "bash", input: { command } }, {});
let result = await run("tmux send-keys task x");
if (!result.block) throw new Error("backend guard was not wired");
result = await run("sleep 1; cat state/task.status");
if (!result.block) throw new Error("poll guard was not wired");
result = await run("echo ordinary");
if (result.block) throw new Error("ordinary command was blocked");
NODE
)
status=$?
expect_code 0 "$status" "Pi extension wires backend and state-poll guards"
[ -z "$out" ] || fail "Pi pretool wiring test printed output: $out"
assert_grep 'backend:--command tmux send-keys task x' "$TMP_ROOT/check.log" "backend checker ran"
assert_grep 'poll:--command sleep 1; cat state/task.status' "$TMP_ROOT/check.log" "poll checker ran"
assert_grep 'arm' "$TMP_ROOT/check.log" "arm checker remains wired after new guards"
[ "$(grep -c '^arm$' "$TMP_ROOT/check.log")" = 1 ] || fail "arm checker ran after a new guard denied a command"

pass "Pi primary PreToolUse guard wiring"
