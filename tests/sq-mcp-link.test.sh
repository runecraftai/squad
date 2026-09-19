#!/usr/bin/env bash
# Focused behavior tests for MCP request-to-task correlation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-mcp-link-tests)

new_task() {
  local base=$1 id=$2
  mkdir -p "$base/state"
  printf 'status=working\nwindow=task-window\n' > "$base/state/$id.meta"
}

test_writes_link_and_reply() {
  local base reply meta
  base="$TMP_ROOT/with-request"
  new_task "$base" task-001
  SQUAD_BASE="$base" "$ROOT/bin/sq-mcp-link.sh" task-001 mcp-001 >/dev/null
  reply="$base/state/mcp-outbox/mcp-001.reply"
  meta="$base/state/task-001.meta"
  [ "$(cat "$reply")" = '{"taskId":"task-001"}' ] \
    || fail "reply must be the exact machine-readable task id object"
  grep -Fx 'mcp_request=mcp-001' "$meta" >/dev/null \
    || fail "task metadata must retain the originating MCP request id"
  pass "MCP link writes task metadata and exact task-id reply"
}

test_is_idempotent() {
  local base meta reply
  base="$TMP_ROOT/repeated"
  new_task "$base" task-002
  SQUAD_BASE="$base" "$ROOT/bin/sq-mcp-link.sh" task-002 mcp-002 >/dev/null
  SQUAD_BASE="$base" "$ROOT/bin/sq-mcp-link.sh" task-002 mcp-002 >/dev/null
  meta="$base/state/task-002.meta"
  reply="$base/state/mcp-outbox/mcp-002.reply"
  [ "$(grep -c '^mcp_request=' "$meta")" = 1 ] \
    || fail "repeated linking must keep one metadata link"
  [ "$(wc -c < "$reply")" = 21 ] \
    || fail "repeated linking must not append a second reply"
  [ "$(cat "$reply")" = '{"taskId":"task-002"}' ] \
    || fail "repeated linking must preserve the valid reply object"
  pass "MCP link is idempotent"
}

test_no_request_is_noop() {
  local base
  base="$TMP_ROOT/without-request"
  new_task "$base" task-003
  SQUAD_BASE="$base" "$ROOT/bin/sq-mcp-link.sh" task-003
  [ ! -e "$base/state/mcp-outbox" ] \
    || fail "ordinary dispatch must not create an MCP outbox"
  ! grep -q '^mcp_request=' "$base/state/task-003.meta" \
    || fail "ordinary dispatch must not add an MCP metadata link"
  pass "MCP link without request id is a no-op"
}

test_writes_link_and_reply
test_is_idempotent
test_no_request_is_noop
