#!/usr/bin/env bash
# sq-mcp-link.sh - Link a dispatched task to an originating MCP request.
#
# Usage:
#   sq-mcp-link.sh <task-id> [request-id]
#
# With a request id, records mcp_request=<request-id> in state/<task-id>.meta and
# writes {"taskId":"<task-id>"} to the MCP reply outbox. Repeating the same
# invocation replaces both representations rather than appending duplicates.
# With no request id, it is a no-op for ordinary non-MCP dispatches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-$SQUAD_ROOT}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
# shellcheck source=bin/sq-pr-lib.sh
. "$SCRIPT_DIR/sq-pr-lib.sh"

ID=${1-}
RID=${2-}
if [ -z "$ID" ]; then
  printf 'Usage: sq-mcp-link.sh <task-id> [request-id]\n' >&2
  exit 2
fi
[ -n "$RID" ] || exit 0

fm_pr_task_id_valid "$ID" || {
  printf 'sq-mcp-link: unsafe task id: %s\n' "$ID" >&2
  exit 2
}
case "$RID" in
  ''|.*|*[!A-Za-z0-9._-]*)
    printf 'sq-mcp-link: unsafe request-id: %s\n' "$RID" >&2
    exit 2
    ;;
esac
[ "${#RID}" -le 64 ] || {
  printf 'sq-mcp-link: request-id too long: %s\n' "$RID" >&2
  exit 2
}

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  printf 'sq-mcp-link: no such task: state/%s.meta\n' "$ID" >&2
  exit 1
fi

TMP=$(mktemp "$STATE/.${ID}.mcp-link.XXXXXX")
cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT
if ! { grep -v '^mcp_request=' "$META" || true; } > "$TMP"; then
  printf 'sq-mcp-link: failed to read task metadata\n' >&2
  exit 1
fi
printf 'mcp_request=%s\n' "$RID" >> "$TMP"
mv -f "$TMP" "$META"

BODY=$(printf '{"taskId":"%s"}' "$ID")
SQUAD_BASE="$SQUAD_BASE" SQUAD_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/sq-mcp-outbox-write.sh" "$RID" "$BODY"
printf 'linked %s to MCP request %s\n' "$ID" "$RID"
