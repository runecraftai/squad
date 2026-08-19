#!/usr/bin/env bash
# Tests for the Pi loop-context-guardrail extension.
# Covers: Guardrail A (repeated identical tool calls), Guardrail B (context budget), and fail-open.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-loop-context-guardrail)
EXT="$ROOT/.pi/extensions/sq-loop-context-guardrail.ts"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

# --- Guardrail A: Repeated identical tool calls ---

test_streak_below_5_never_warns_or_blocks() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/streak-below-5"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const warnings = [];
const blocks = [];
const handlers = new Map();
const fakePi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => undefined,
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => undefined,
  compact: () => {},
};

// Send 4 identical calls.
for (let i = 1; i <= 4; i++) {
  const result = await handler(
    { type: "tool_call", toolName: "bash", input: { command: "ls" } },
    ctx,
  );
  if (result?.block) {
    blocks.push(`call ${i} blocked`);
  }
}

if (blocks.length > 0) {
  throw new Error(`streak below 5 should never block: ${blocks.join(", ")}`);
}
if (warnings.length > 0) {
  throw new Error(`streak below 5 should never warn: ${JSON.stringify(warnings)}`);
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "streak below 5 test failed: $out"
  [ -z "$out" ] || fail "streak below 5 test printed output: $out"
  pass "streak of 4 identical calls never warns or blocks"
}

test_streak_5_warns_once_not_again() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/streak-5"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const warnings = [];
const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => undefined,
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => undefined,
  compact: () => {},
};

// Send 9 identical calls (streak 1-9).
for (let i = 1; i <= 9; i++) {
  await handler(
    { type: "tool_call", toolName: "bash", input: { command: "ls" } },
    ctx,
  );
}

// Should have exactly 1 warning (at streak 5), not 5 warnings (one per call from 5-9).
const warningCount = warnings.filter((w) => w.type === "warning").length;
if (warningCount !== 1) {
  throw new Error(`expected exactly 1 warning for streak 5-9, got ${warningCount}`);
}
if (!warnings.some((w) => w.msg.includes("streak: 5"))) {
  throw new Error("warning should mention streak count 5");
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "streak 5 warns-once test failed: $out"
  [ -z "$out" ] || fail "streak 5 warns-once test printed output: $out"
  pass "streak of 5+ identical calls warns exactly once, not every call"
}

test_streak_10_blocks_every_call() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/streak-10"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify() {} },
  getContextUsage: () => undefined,
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify() {} },
  getContextUsage: () => undefined,
  compact: () => {},
};

// Send 12 identical calls.
const results = [];
for (let i = 1; i <= 12; i++) {
  const result = await handler(
    { type: "tool_call", toolName: "bash", input: { command: "sleep 999" } },
    ctx,
  );
  results.push({ call: i, blocked: result?.block === true });
}

// Calls 1-9 should not be blocked, calls 10-12 should be blocked.
for (const r of results) {
  if (r.call <= 9 && r.blocked) {
    throw new Error(`call ${r.call} should not be blocked (streak < 10)`);
  }
  if (r.call >= 10 && !r.blocked) {
    throw new Error(`call ${r.call} should be blocked (streak >= 10)`);
  }
}

// Verify block reason mentions the count.
const block10 = await handler(
  { type: "tool_call", toolName: "bash", input: { command: "sleep 999" } },
  ctx,
);
if (!block10?.reason?.includes("13")) {
  throw new Error(`block reason should mention count, got: ${block10?.reason}`);
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "streak 10 blocks test failed: $out"
  [ -z "$out" ] || fail "streak 10 blocks test printed output: $out"
  pass "streak of 10+ identical calls blocks every call from 10 onward"
}

test_different_call_resets_streak() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/reset-streak"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const warnings = [];
const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => undefined,
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => undefined,
  compact: () => {},
};

// 4 identical calls (streak 1-4), then a different call resets, then 3 more.
for (let i = 1; i <= 4; i++) {
  await handler(
    { type: "tool_call", toolName: "bash", input: { command: "ls" } },
    ctx,
  );
}
// Different call resets streak.
await handler(
  { type: "tool_call", toolName: "bash", input: { command: "pwd" } },
  ctx,
);
// 3 more identical calls (streak 1-3 after reset).
for (let i = 1; i <= 3; i++) {
  await handler(
    { type: "tool_call", toolName: "bash", input: { command: "pwd" } },
    ctx,
  );
}

// No warnings should have been emitted (streak never reached 5).
if (warnings.length > 0) {
  throw new Error(`streak reset should prevent warnings, got: ${JSON.stringify(warnings)}`);
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "streak reset test failed: $out"
  [ -z "$out" ] || fail "streak reset test printed output: $out"
  pass "a different tool call resets the streak and clears the warned flag"
}

test_different_tool_resets_streak() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/reset-tool"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const warnings = [];
const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => undefined,
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => undefined,
  compact: () => {},
};

// 7 bash calls, then a read call resets streak, then 3 bash calls.
for (let i = 1; i <= 7; i++) {
  await handler(
    { type: "tool_call", toolName: "bash", input: { command: "ls" } },
    ctx,
  );
}
await handler(
  { type: "tool_call", toolName: "read", input: { path: "file.txt" } },
  ctx,
);
for (let i = 1; i <= 3; i++) {
  await handler(
    { type: "tool_call", toolName: "bash", input: { command: "ls" } },
    ctx,
  );
}

// Exactly 1 warning (at streak 5 of the first bash streak).
const warningCount = warnings.filter((w) => w.type === "warning").length;
if (warningCount !== 1) {
  throw new Error(`expected 1 warning, got ${warningCount}`);
}
if (!warnings.some((w) => w.msg.includes("bash"))) {
  throw new Error("warning should mention bash");
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "different tool reset test failed: $out"
  [ -z "$out" ] || fail "different tool reset test printed output: $out"
  pass "a different tool name resets the streak"
}

# --- Guardrail B: Context budget ---

test_context_null_skips() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/context-null"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify() {} },
  getContextUsage: () => undefined,
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify() {} },
  getContextUsage: () => undefined,
  compact: () => {},
};

// Call with null context usage should pass through.
const result = await handler(
  { type: "tool_call", toolName: "bash", input: { command: "ls" } },
  ctx,
);
if (result?.block) {
  throw new Error("null context usage should not block");
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "context null test failed: $out"
  [ -z "$out" ] || fail "context null test printed output: $out"
  pass "null/undefined context usage is skipped (fail-open)"
}

test_context_below_40_noop() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/context-below-40"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const warnings = [];
const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => ({ tokens: 50000, percent: 39 }),
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => ({ tokens: 50000, percent: 39 }),
  compact: () => {},
};

const result = await handler(
  { type: "tool_call", toolName: "bash", input: { command: "ls" } },
  ctx,
);
if (result?.block) {
  throw new Error("39% should not block");
}
if (warnings.length > 0) {
  throw new Error("39% should not warn");
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "context below 40 test failed: $out"
  [ -z "$out" ] || fail "context below 40 test printed output: $out"
  pass "context usage at 39% is low zone (no-op)"
}

test_context_45_one_time_notice() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/context-45"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const warnings = [];
const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => ({ tokens: 80000, percent: 45 }),
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => ({ tokens: 80000, percent: 45 }),
  compact: () => {},
};

// Send 5 calls at 45% (different inputs to avoid repeated-call guardrail).
const commands = ["ls", "pwd", "echo hi", "cat file", "grep x"];
for (let i = 0; i < 5; i++) {
  await handler(
    { type: "tool_call", toolName: "bash", input: { command: commands[i] } },
    ctx,
  );
}

// Should have exactly 1 attention warning, not 5.
const attentionWarnings = warnings.filter((w) => w.type === "warning" && w.msg.includes("45%"));
if (attentionWarnings.length !== 1) {
  throw new Error(`expected 1 attention warning, got ${attentionWarnings.length}`);
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "context 45 test failed: $out"
  [ -z "$out" ] || fail "context 45 test printed output: $out"
  pass "context usage at 45% warns once, not on every call"
}

test_context_61_blocks_and_compacts() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/context-61"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

let compactCalled = 0;
const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify() {} },
  getContextUsage: () => ({ tokens: 120000, percent: 61 }),
  compact: () => { compactCalled++; },
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify() {} },
  getContextUsage: () => ({ tokens: 120000, percent: 61 }),
  compact: () => { compactCalled++; },
};

// Send 3 calls at 61% (different inputs to avoid repeated-call guardrail).
const cmds61 = ["ls", "pwd", "echo hi"];
for (let i = 0; i < 3; i++) {
  const result = await handler(
    { type: "tool_call", toolName: "bash", input: { command: cmds61[i] } },
    ctx,
  );
  if (!result?.block) {
    throw new Error(`call ${i + 1} at 61% should be blocked`);
  }
  if (!result.reason?.includes("61%")) {
    throw new Error(`block reason should mention percentage, got: ${result.reason}`);
  }
}

// Compaction should have been triggered exactly once (on first entry).
if (compactCalled !== 1) {
  throw new Error(`compact should be called once, got ${compactCalled}`);
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "context 61 blocks+compacts test failed: $out"
  [ -z "$out" ] || fail "context 61 blocks+compacts test printed output: $out"
  pass "context usage at 61% blocks and triggers compaction once"
}

test_context_drops_resets_state() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/context-drops"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const warnings = [];
let currentPercent = 65;
const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => ({ tokens: 100000, percent: currentPercent }),
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify(msg, type) { warnings.push({ msg, type }); } },
  getContextUsage: () => ({ tokens: 100000, percent: currentPercent }),
  compact: () => {},
};

// First: blocked at 65%.
await handler({ type: "tool_call", toolName: "bash", input: { command: "ls-a" } }, ctx);

// Simulate compaction dropping to 30%.
currentPercent = 30;
const lowResult = await handler(
  { type: "tool_call", toolName: "bash", input: { command: "ls-b" } },
  ctx,
);
if (lowResult?.block) {
  throw new Error("30% after compaction should not block");
}

// Re-enter attention zone at 45%.
currentPercent = 45;
await handler({ type: "tool_call", toolName: "bash", input: { command: "ls-c" } }, ctx);

// Should get a new attention warning (state was reset by dropping below 40%).
const attentionWarnings = warnings.filter(
  (w) => w.type === "warning" && w.msg.includes("45%"),
);
if (attentionWarnings.length !== 1) {
  throw new Error(`expected a new attention warning after dropping below 40%, got ${attentionWarnings.length}`);
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "context drops reset test failed: $out"
  [ -z "$out" ] || fail "context drops reset test printed output: $out"
  pass "context dropping below 40% resets state so re-entry notices again"
}

# --- Fail-open ---

test_fail_open_on_context_error() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for loop-context-guardrail test"
    return 0
  fi

  fixture="$TMP_ROOT/fail-open"
  mkdir -p "$fixture/project/.pi/extensions"
  cp "$EXT" "$fixture/project/.pi/extensions/sq-loop-context-guardrail.ts"

  out=$(cd "$fixture/project" && node --input-type=module 2>&1 <<'JS'
const ext = await import("./.pi/extensions/sq-loop-context-guardrail.ts");
const pi = ext.default;

const diagnostics = [];
const originalWarn = console.warn;
console.warn = (...args) => diagnostics.push(args.join(" "));

const handlers = new Map();
const fakePi = {
  on(event, handler) { handlers.set(event, handler); },
  hasUI: true,
  ui: { notify() {} },
  getContextUsage: () => { throw new Error("simulated context error"); },
  compact: () => {},
};
pi(fakePi);

const handler = handlers.get("tool_call");
const ctx = {
  hasUI: true,
  ui: { notify() {} },
  getContextUsage: () => { throw new Error("simulated context error"); },
  compact: () => {},
};

// Should not throw, should not block.
const result = await handler(
  { type: "tool_call", toolName: "bash", input: { command: "ls" } },
  ctx,
);
console.warn = originalWarn;

if (result?.block) {
  throw new Error("fail-open should not block on internal error");
}
// Should have logged the internal error.
const sawError = diagnostics.some((d) => d.includes("internal error"));
if (!sawError) {
  throw new Error("fail-open should log the internal error");
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "fail-open test failed: $out"
  [ -z "$out" ] || fail "fail-open test printed output: $out"
  pass "internal error in context usage does not block and logs a warning"
}

# --- Run all tests ---

test_streak_below_5_never_warns_or_blocks
test_streak_5_warns_once_not_again
test_streak_10_blocks_every_call
test_different_call_resets_streak
test_different_tool_resets_streak
test_context_null_skips
test_context_below_40_noop
test_context_45_one_time_notice
test_context_61_blocks_and_compacts
test_context_drops_resets_state
test_fail_open_on_context_error

echo "All loop-context-guardrail tests passed."
