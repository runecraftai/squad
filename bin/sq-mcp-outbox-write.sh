#!/usr/bin/env bash
# sq-mcp-outbox-write.sh - Write a reply to the MCP outbox for a request.
#
# This is the Squad-side append path: Squad calls this after processing an MCP
# request to deliver the reply to the MCP outbox for later consumption.
#
# Usage:
#   sq-mcp-outbox-write.sh <request-id> <body>
#
# Creates state/mcp-outbox/<request-id>.reply with the reply body.
# Exit 0 on success, non-zero on failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-stand-to-lib.sh
. "$SCRIPT_DIR/sq-stand-to-lib.sh"

request_id=${1-}
body=${2-}

if [ -z "$request_id" ] || [ -z "$body" ]; then
  printf 'Usage: sq-mcp-outbox-write.sh <request-id> <body>\n' >&2
  exit 2
fi

# Validate request ID format.
case "$request_id" in
  ''|.*|*[!A-Za-z0-9._-]*)
    printf 'sq-mcp-outbox-write.sh: invalid request-id: %s\n' "$request_id" >&2
    exit 2
    ;;
esac
[ "${#request_id}" -le 64 ] || {
  printf 'sq-mcp-outbox-write.sh: request-id too long: %s\n' "$request_id" >&2
  exit 2
}

OUTBOX="$STATE/mcp-outbox"
mkdir -p "$OUTBOX"

reply_file="$OUTBOX/${request_id}.reply"
printf '%s' "$body" > "$reply_file"
