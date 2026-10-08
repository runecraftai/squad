#!/usr/bin/env bash
# Test suite for Pi compaction resilience extension
#
# Tests:
# 1. Extension loads without errors
# 2. Compaction state is preserved
# 3. Re-engagement message is generated correctly
# 4. State persists across compactions
#
# Usage:
#   tests/test-compaction-resilience.sh
#
# Requires:
# - Pi installed and available in PATH
# - jq for JSON processing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
EXTENSION_PATH="${SCRIPT_DIR}/../.pi/extensions/compaction-resilience.ts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test functions
log_test() {
  echo -e "${YELLOW}[TEST]${NC} $*"
}

log_pass() {
  echo -e "${GREEN}[PASS]${NC} $*"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
  echo -e "${RED}[FAIL]${NC} $*"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Cleanup function
# shellcheck disable=SC2329
cleanup() {
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT

# Test 1: Extension file exists and is valid TypeScript
test_extension_exists() {
  log_test "Extension file exists"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if [ ! -f "$EXTENSION_PATH" ]; then
    log_fail "Extension file not found: $EXTENSION_PATH"
    return
  fi
  
  # Check it's valid TypeScript (basic syntax check)
  if grep -q "export default function" "$EXTENSION_PATH"; then
    log_pass "Extension file exists and has valid structure"
  else
    log_fail "Extension file missing default export"
  fi
}

# Test 2: Extension has required event handlers
test_event_handlers() {
  log_test "Extension has required event handlers"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  local required_handlers=(
    "session_before_compact"
    "turn_end"
    "agent_before_settle"
    "session_start"
  )
  
  local missing=()
  for handler in "${required_handlers[@]}"; do
    if ! grep -q "pi.on(\"$handler\"" "$EXTENSION_PATH"; then
      missing+=("$handler")
    fi
  done
  
  if [ ${#missing[@]} -eq 0 ]; then
    log_pass "All required event handlers present"
  else
    log_fail "Missing event handlers: ${missing[*]}"
  fi
}

# Test 3: Extension has required commands
test_commands() {
  log_test "Extension has required commands"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  local required_commands=(
    "compaction-status"
    "compaction-reengage"
  )
  
  local missing=()
  for cmd in "${required_commands[@]}"; do
    if ! grep -q "pi.registerCommand(\"$cmd\"" "$EXTENSION_PATH"; then
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -eq 0 ]; then
    log_pass "All required commands present"
  else
    log_fail "Missing commands: ${missing[*]}"
  fi
}

# Test 4: Extension has state management
test_state_management() {
  log_test "Extension has state management"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if grep -q "OperatorState" "$EXTENSION_PATH" && \
     grep -q "operatorState" "$EXTENSION_PATH" && \
     grep -q "createDefaultState" "$EXTENSION_PATH"; then
    log_pass "State management functions present"
  else
    log_fail "State management functions missing"
  fi
}

# Test 5: Extension has summary generation
test_summary_generation() {
  log_test "Extension has summary generation"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if grep -q "generateCompactionSummary" "$EXTENSION_PATH" && \
     grep -q "generateReengagementMessage" "$EXTENSION_PATH"; then
    log_pass "Summary generation functions present"
  else
    log_fail "Summary generation functions missing"
  fi
}

# Test 6: Config script exists and is executable
test_config_script() {
  log_test "Config script exists and is executable"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  local config_script="${SCRIPT_DIR}/../bin/sq-pi-compaction-config.sh"
  
  if [ -f "$config_script" ] && [ -x "$config_script" ]; then
    log_pass "Config script exists and is executable"
  else
    log_fail "Config script missing or not executable"
  fi
}

# Test 7: Config script has required commands
test_config_commands() {
  log_test "Config script has required commands"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  local config_script="${SCRIPT_DIR}/../bin/sq-pi-compaction-config.sh"
  
  if grep -q "enable_compaction" "$config_script" && \
     grep -q "disable_compaction" "$config_script" && \
     grep -q "show_status" "$config_script"; then
    log_pass "Config script has required commands"
  else
    log_fail "Config script missing required commands"
  fi
}

# Test 8: Extension handles tool calls
test_tool_call_handling() {
  log_test "Extension handles tool calls"
  TESTS_RUN=$((TESTS_RUN + 1))
  
  if EXTENSION_PATH="$(realpath "$EXTENSION_PATH")" bun -e 'const {default:extension}=await import(process.env.EXTENSION_PATH);const handlers=new Map(),commands=new Map(),notify=[];extension({on:(n,h)=>handlers.set(n,h),registerCommand:(n,c)=>commands.set(n,c),sendUserMessage:()=>{}});const ctx={hasUI:true,ui:{notify:m=>notify.push(m)}};await handlers.get("tool_call")({type:"tool_call",toolName:"edit",input:{path:"tracked.txt"}},ctx);await commands.get("compaction-status").handler("",ctx);if(!notify.at(-1).includes("Files modified: 1")||!notify.at(-1).includes("Tool calls: 1"))throw Error(notify.at(-1));await handlers.get("tool_call")({type:"tool_call",toolName:"bash",input:{command:"pwd"}},ctx);await commands.get("compaction-status").handler("",ctx);if(!notify.at(-1).includes("Tool calls: 2"))throw Error(notify.at(-1));'; then
    log_pass "Public Pi tool_call event tracks file modifications and normal tool calls"
  else
    log_fail "Public Pi tool_call event regression"
  fi
}

# Test 9: Compaction handler persists state through the pi extension API
#
# Regression: the handler context is a real runtime context, which exposes
# sessionManager, ui, and hasUI but no appendEntry. Durable custom entries are
# appended with pi.appendEntry(customType, data). Before the fix the compaction
# handler called ctx.appendEntry and threw TypeError on every compaction.
test_compaction_handler_persists_via_api() {
  log_test "session_before_compact persists state via pi.appendEntry (real ctx shape)"
  TESTS_RUN=$((TESTS_RUN + 1))

  if EXTENSION_PATH="$(realpath "$EXTENSION_PATH")" bun -e '
    const { default: extension } = await import(process.env.EXTENSION_PATH);

    const appended = [];
    let handlers = new Map();
    let commands = new Map();
    const makePi = () => ({
      on: (n, h) => handlers.set(n, h),
      registerCommand: (n, c) => commands.set(n, c),
      sendUserMessage: () => {},
      sendMessage: () => {},
      appendEntry: (customType, data) => appended.push({ customType, data }),
    });

    // Exactly the real runtime context shape: no appendEntry method.
    const realContext = () => ({
      hasUI: false,
      ui: { notify: () => {} },
      sessionManager: { getBranch: () => [] },
    });

    extension(makePi());

    // Real Pi AssistantMessage shape: tool calls are content-array items
    // ({ type: "toolCall", name, arguments }), never an OpenAI-style
    // msg.tool_calls[].function.{name,arguments} field.
    const preparation = {
      messagesToSummarize: [
        { role: "user", content: "Fix the confirmed compaction defect in the extension now" },
        {
          role: "assistant",
          content: [
            { type: "text", text: "Editing" },
            { type: "toolCall", id: "call-1", name: "edit", arguments: { path: "a.ts" } },
          ],
        },
      ],
      turnPrefixMessages: [],
      previousSummary: null,
      firstKeptEntryId: "entry-1",
      tokensBefore: 100,
      fileOps: { readFiles: [], modifiedFiles: ["a.ts"] },
    };

    const result = await handlers.get("session_before_compact")(
      { type: "session_before_compact", preparation, signal: undefined },
      realContext()
    );

    if (appended.length !== 1) {
      throw new Error("expected exactly one appendEntry call, got " + appended.length);
    }
    if (appended[0].customType !== "compaction_resilience_state") {
      throw new Error("wrong customType: " + appended[0].customType);
    }
    const state = appended[0].data && appended[0].data.operatorState;
    if (!state || state.compactionCount !== 1) {
      throw new Error("operator state missing from appended entry: " + JSON.stringify(appended[0].data));
    }
    if (!state.currentTask || state.filesModified.indexOf("a.ts") === -1) {
      throw new Error("operator state not captured: " + JSON.stringify(state));
    }
    if (!result || !result.compaction || !result.compaction.summary) {
      throw new Error("compaction result was not returned");
    }

    // Round-trip: a fresh extension reconstructs state from a branch entry
    // shaped exactly as Pi stores a custom entry.
    const branch = [
      {
        type: "custom",
        id: "e1",
        parentId: null,
        timestamp: "2026-01-01T00:00:00.000Z",
        customType: "compaction_resilience_state",
        data: appended[0].data,
      },
    ];
    const notices = [];
    handlers = new Map();
    commands = new Map();
    extension({
      on: (n, h) => handlers.set(n, h),
      registerCommand: (n, c) => commands.set(n, c),
      sendUserMessage: () => {},
      sendMessage: () => {},
      appendEntry: () => {},
    });
    const startCtx = {
      hasUI: true,
      ui: { notify: (m) => notices.push(m) },
      sessionManager: { getBranch: () => branch },
    };
    await handlers.get("session_start")({ type: "session_start" }, startCtx);
    await commands.get("compaction-status").handler("", startCtx);
    const status = notices[notices.length - 1] || "";
    if (status.indexOf("Compactions tracked: 1") === -1) {
      throw new Error("session_start did not reconstruct persisted state: " + JSON.stringify(notices));
    }
  '; then
    log_pass "Compaction handler persists via pi.appendEntry and session_start reconstructs it"
  else
    log_fail "Compaction state persistence via the pi API regression"
  fi
}

# Test 10: Split-turn compaction (the real evidenced failure)
#
# Regression: Pi leaves preparation.messagesToSummarize EMPTY on a split-turn
# compaction (one oversized user-message span cut mid-tool-call, e.g. an
# overflow or length abort) and puts the whole span in
# preparation.turnPrefixMessages instead (docs/compaction.md "Split
# user-message spans" in the installed pi version). This is exactly the
# "cutting an in-flight tool call" case from the real compacted session that
# motivated this fix. Before the fix, the handler only ever read
# messagesToSummarize, so currentTask/checklistItems/filesModified came back
# empty precisely when a mid-task compaction happened - the task, its
# checklist, and the in-flight edit all lived only in turnPrefixMessages.
test_split_turn_compaction_payload() {
  log_test "session_before_compact captures turnPrefixMessages on a split-turn compaction"
  TESTS_RUN=$((TESTS_RUN + 1))

  if EXTENSION_PATH="$(realpath "$EXTENSION_PATH")" bun -e '
    const { default: extension } = await import(process.env.EXTENSION_PATH);

    const appended = [];
    const handlers = new Map();
    const pi = {
      on: (n, h) => handlers.set(n, h),
      registerCommand: () => {},
      sendUserMessage: () => {},
      sendMessage: () => {},
      appendEntry: (customType, data) => appended.push({ customType, data }),
    };
    extension(pi);

    const ctx = { hasUI: false, ui: { notify: () => {} }, sessionManager: { getBranch: () => [] } };

    // isSplitTurn=true shape: nothing to summarize yet, the whole span -
    // including the task and a dangling, never-closed tool call - sits in
    // turnPrefixMessages.
    const preparation = {
      messagesToSummarize: [],
      turnPrefixMessages: [
        { role: "user", content: "Fix the login session bug in login.ts. Add a regression test." },
        {
          role: "assistant",
          content: [
            { type: "text", text: "Plan:\n- [ ] inspect login.ts\n- [ ] patch the session check\n" },
            { type: "toolCall", id: "call-1", name: "write", arguments: { path: "notes.txt", content: "x" } },
          ],
        },
        {
          role: "assistant",
          content: [
            { type: "text", text: "Now patching the session check." },
            { type: "toolCall", id: "call-2", name: "edit", arguments: {} },
          ],
        },
      ],
      isSplitTurn: true,
      previousSummary: null,
      firstKeptEntryId: "entry-2",
      tokensBefore: 5000,
      fileOps: { readFiles: [], modifiedFiles: [] },
    };

    await handlers.get("session_before_compact")(
      { type: "session_before_compact", preparation, signal: undefined, reason: "overflow", willRetry: false },
      ctx
    );

    const state = appended[0] && appended[0].data && appended[0].data.operatorState;
    if (!state) throw new Error("no compaction_resilience_state entry appended");
    if (!state.currentTask || state.currentTask.indexOf("Fix the login session bug") === -1) {
      throw new Error("currentTask not captured from turnPrefixMessages: " + JSON.stringify(state));
    }
    if (state.checklistItems.length < 2) {
      throw new Error("checklistItems not captured from turnPrefixMessages: " + JSON.stringify(state));
    }
    if (state.filesModified.indexOf("notes.txt") === -1) {
      throw new Error("filesModified not captured from turnPrefixMessages: " + JSON.stringify(state));
    }
  '; then
    log_pass "Split-turn compaction (messagesToSummarize=[]) still captures task, checklist, and files"
  else
    log_fail "Split-turn compaction payload regression"
  fi
}

# Test 11: agent_before_settle re-engages immediately, not on a dead idle-time wait
#
# Regression: the handler used to gate re-engagement on
# `Date.now() - operatorState.lastActivity > 5000`, checked synchronously at
# the instant the run is about to settle - lastActivity was just updated by
# the very turn that is now settling, so that gap is always ~0 and the branch
# never ran. It also queued the message with deliverAs: "followUp", which
# only runs after a CURRENTLY STREAMING turn finishes; at settle time there is
# none, so a followUp is never drained (confirmed live: a plain
# sendUserMessage() at this point throws "Agent is already processing").
# "steer" delivers immediately instead.
test_agent_before_settle_reengages_immediately() {
  log_test "agent_before_settle re-engages immediately via deliverAs steer, no idle-time wait"
  TESTS_RUN=$((TESTS_RUN + 1))

  if EXTENSION_PATH="$(realpath "$EXTENSION_PATH")" bun -e '
    const { default: extension } = await import(process.env.EXTENSION_PATH);

    const sent = [];
    const handlers = new Map();
    const pi = {
      on: (n, h) => handlers.set(n, h),
      registerCommand: () => {},
      sendUserMessage: (msg, opts) => sent.push({ msg, opts }),
      sendMessage: () => {},
      appendEntry: () => {},
    };
    extension(pi);

    const branch = [
      { type: "compaction", id: "cmp-1", parentId: null, timestamp: "2026-01-01T00:00:00.000Z", summary: "s", firstKeptEntryId: "e1", tokensBefore: 10 },
    ];
    const ctx = { hasUI: false, ui: { notify: () => {} }, sessionManager: { getBranch: () => branch } };

    // Call immediately with no delay: a real sentry-killed-mid-cycle or
    // dead-idle-timer bug would show up here as zero sendUserMessage calls.
    await handlers.get("agent_before_settle")({ type: "agent_before_settle" }, ctx);

    if (sent.length !== 1) {
      throw new Error("expected exactly one sendUserMessage call immediately at settle, got " + sent.length);
    }
    if (!sent[0].opts || sent[0].opts.deliverAs !== "steer") {
      throw new Error("expected deliverAs: steer (immediate delivery), got " + JSON.stringify(sent[0].opts));
    }

    // A second settle with the same compaction entry must not re-send.
    await handlers.get("agent_before_settle")({ type: "agent_before_settle" }, ctx);
    if (sent.length !== 1) {
      throw new Error("expected no re-send on a repeated settle for the same compaction, got " + sent.length);
    }
  '; then
    log_pass "agent_before_settle re-engages immediately and only once per compaction"
  else
    log_fail "agent_before_settle re-engagement regression"
  fi
}

# Run all tests
main() {
  echo ""
  echo "=== Pi Compaction Resilience Extension Tests ==="
  echo ""
  
  test_extension_exists
  test_event_handlers
  test_commands
  test_state_management
  test_summary_generation
  test_config_script
  test_config_commands
  test_tool_call_handling
  test_compaction_handler_persists_via_api
  test_split_turn_compaction_payload
  test_agent_before_settle_reengages_immediately

  echo ""
  echo "=== Test Results ==="
  echo "Tests run: $TESTS_RUN"
  echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
  echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
  echo ""
  
  if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
  else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
  fi
}

main "$@"
