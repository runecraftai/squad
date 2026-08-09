#!/usr/bin/env bash
# Push the declared inherited-material allowlist to one remote XO route.
# Usage: sq-remote-inherit-push.sh <XO-id> <generation>
#
# The item set is derived from the ONE declared owner
# (SQUAD_INHERITABLE_CONFIG in bin/sq-config-inherit-lib.sh), the same declaration
# the receiving bin/sq-remote-inherit.sh enforces, so the two implementations in
# one code revision cannot drift silently. Different local and remote revisions
# fail closed as documented by that owner. SQUAD_CONFIG_INHERIT_LIVE=1 marks a live
# convergence push into an already-running home and skips session-scoped items,
# exactly as the local propagation path does.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_HOME="${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}"
CONFIG="${SQUAD_CONFIG_OVERRIDE:-$SQUAD_HOME/config}"
DATA="${SQUAD_DATA_OVERRIDE:-$SQUAD_HOME/data}"

# shellcheck source=bin/sq-xo-registry-lib.sh
. "$SCRIPT_DIR/sq-xo-registry-lib.sh"
# shellcheck source=bin/sq-config-inherit-lib.sh
. "$SCRIPT_DIR/sq-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
file_link_count() {
  if [ "$(uname)" = Darwin ]; then stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
shared_commander_header_valid() {
  local head
  head=$(sed -n '1,12p' "$1" 2>/dev/null) || return 1
  case "$head" in *main-authoritative*) ;; *) return 1 ;; esac
  case "$head" in *"read-only in XO homes"*) ;; *) return 1 ;; esac
  case "$head" in *"must not be edited there"*) ;; *) return 1 ;; esac
  case "$head" in *"main Squad"*) ;; *) return 1 ;; esac
  case "$head" in *"marked status"*|*"document pointer"*) ;; *) return 1 ;; esac
}
[ "$#" -eq 2 ] || { echo "usage: sq-remote-inherit-push.sh <XO-id> <generation>" >&2; exit 2; }
ID=$1
GENERATION=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid XO id: $ID" ;; esac
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
REMOTE=$(XO_registry_field "$DATA/XOs.md" "$ID" remote 2>/dev/null || true)
[ "$REMOTE" = 1 ] || die "XO $ID is not a remote route"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sq-remote-inherit-push.XXXXXX") || die "cannot create inheritance staging directory"
trap 'rm -rf -- "$TMP"' EXIT
EMPTY="$TMP/empty"
: > "$EMPTY"
EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"

ITEMS=$(fm_config_inherit_items)
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ "${SQUAD_CONFIG_INHERIT_LIVE:-0}" = 1 ]; then
    case "$rel" in
      config/*)
        if fm_config_inherit_item_session_scoped "${rel#config/}"; then
          printf 'unchanged: %s\n' "$rel"
          continue
        fi
        ;;
    esac
  fi
  case "$rel" in
    config/*) source="$CONFIG/${rel#config/}" ;;
    data/*) source="$DATA/${rel#data/}" ;;
  esac
  if [ -e "$source" ] || [ -L "$source" ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || die "inherited source is unsafe: $source"
    [ "$(file_link_count "$source")" = 1 ] || die "inherited source is hardlinked: $source"
    if [ "$rel" = data/commander-shared.md ]; then
      shared_commander_header_valid "$source" || die "shared commander preferences have no valid primary-authoritative header"
    fi
    snapshot="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
    cp -p -- "$source" "$snapshot" || die "cannot snapshot inherited source: $source"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || die "inherited source snapshot is unsafe: $source"
    bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
    hash=$(sha256_file "$snapshot") || die "cannot hash inherited source: $source"
    "$SCRIPT_DIR/sq-on.sh" "$ID" sq-remote-inherit.sh put "$rel" "$bytes" "$hash" "$GENERATION" < "$snapshot"
  else
    # This loop's heredoc is its control stream, not remote command input.
    "$SCRIPT_DIR/sq-on.sh" "$ID" sq-remote-inherit.sh absent "$rel" 0 "$EMPTY_HASH" "$GENERATION" < /dev/null
  fi
done <<EOF
$ITEMS
EOF
