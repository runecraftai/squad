#!/usr/bin/env bash
# sq-mcp-wake-append.sh - Append a wake record to the stand-to queue for MCP requests.
#
# This script sources sq-stand-to-lib.sh to reuse the canonical lock and append
# path. It is the sanctioned MCP→stand-to queue bridge: the MCP calls this script
# rather than hand-writing the queue file.
#
# Usage:
#   sq-mcp-wake-append.sh <key> <payload>
#
# The key must be a valid status-file basename (alphanumeric, hyphens, dots).
# The payload is the operational-input-encoded message body.
# Exit 0 on success, non-zero on failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-stand-to-lib.sh
. "$SCRIPT_DIR/sq-stand-to-lib.sh"

key=${1-}
payload=${2-}

if [ -z "$key" ] || [ -z "$payload" ]; then
  printf 'Usage: sq-mcp-wake-append.sh <key> <payload>\n' >&2
  exit 2
fi

# Validate key format: must look like a status-file basename.
case "$key" in
  ''|.*|*[!A-Za-z0-9._-]*)
    printf 'sq-mcp-wake-append.sh: invalid key: %s\n' "$key" >&2
    exit 2
    ;;
esac
[ "${#key}" -le 64 ] || {
  printf 'sq-mcp-wake-append.sh: key too long: %s\n' "$key" >&2
  exit 2
}

fm_wake_append signal "$key" "$payload"
