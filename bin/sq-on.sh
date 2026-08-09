#!/usr/bin/env bash
# Execute one tracked Squad command in a configured remote XO home.
#
# Usage:
#   sq-on.sh <XO-id|unambiguous-ssh-alias> <sq-command> [args...]
#
# Routes come only from remote records in data/XOs.md. A record names an
# SSH config alias, remote Squad code root, and remote SQUAD_HOME. A host alias
# may be used directly only when exactly one record selects it; an ambiguous
# alias is refused. The command must be a genuine executable in this checkout's
# bin/sq-*.sh namespace. No per-command table exists.
#
# argv is encoded as one NUL-delimited stream and passed through the fixed
# sq-remote-entrypoint.sh. stdin remains the caller's stdin, stdout and stderr
# remain separate, and ssh's exit status is returned unchanged. OpenSSH never
# receives an auto-retry instruction here. Exit 255 therefore means unavailable
# transport or unknown remote completion and must be reconciled by the semantic
# caller, never blindly repeated by this layer.
#
# The SSH alias keeps normal public-key and strict host-key policy in ~/.ssh.
# This command explicitly disables agent forwarding, forwarding setup, and
# configured SendEnv patterns. The remote entrypoint executes the selected
# command under an empty environment with only its fixed runtime values.
#
# ServerAliveInterval/ServerAliveCountMax arm dead-peer detection so a vanished
# peer (a reboot, a dropped link) becomes a bounded ssh failure (exit 255)
# instead of an indefinite hang on a half-open TCP connection. The remote
# sshd answers keepalive probes independently of whatever the remote command
# is doing, so a legitimately long-but-alive remote command is never falsely
# killed. SQUAD_SSH_ALIVE_INTERVAL and SQUAD_SSH_ALIVE_COUNT_MAX override the
# defaults; the worst-case detection window is roughly interval * count.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_HOME="${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}"
DATA="${SQUAD_DATA_OVERRIDE:-$SQUAD_HOME/data}"
REG="$DATA/XOs.md"
PROTOCOL=1

# shellcheck source=bin/sq-xo-registry-lib.sh
. "$SCRIPT_DIR/sq-xo-registry-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

encode_base64() {
  base64 | tr -d '\n'
}

[ "$#" -ge 2 ] || usage
ROUTE=$1
COMMAND=$2
shift 2

case "$ROUTE" in ''|-*|*[!A-Za-z0-9._-]*) die "remote route must be a safe XO id or SSH alias: $ROUTE" ;; esac
case "$COMMAND" in
  sq-*.sh) ;;
  *) die "remote command must be a basename in the sq-*.sh namespace: $COMMAND" ;;
esac
case "$COMMAND" in */*|*..*) die "remote command must not contain a path or traversal: $COMMAND" ;; esac
LOCAL_COMMAND="$SQUAD_ROOT/bin/$COMMAND"
[ -f "$LOCAL_COMMAND" ] && [ ! -L "$LOCAL_COMMAND" ] && [ -x "$LOCAL_COMMAND" ] \
  || die "remote command is not a genuine tracked executable in this Squad checkout: $COMMAND"
git -C "$SQUAD_ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
  || die "remote command is not tracked by this Squad checkout: $COMMAND"
[ -f "$REG" ] && [ ! -L "$REG" ] || die "no safe XO registry at $REG"

MATCHES=0
HOST=
ROOT=
HOME_PATH=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  XO_registry_parse_line "$line" || die "malformed XO registry entry: $line"
  [ "$XO_REGISTRY_REMOTE" -eq 1 ] || continue
  if [ "$XO_REGISTRY_ID" = "$ROUTE" ] || [ "$XO_REGISTRY_HOST" = "$ROUTE" ]; then
    MATCHES=$((MATCHES + 1))
    HOST=$XO_REGISTRY_HOST
    ROOT=$XO_REGISTRY_ROOT
    HOME_PATH=$XO_REGISTRY_HOME
  fi
done < "$REG"
[ "$MATCHES" -gt 0 ] || die "no remote XO or SSH alias matches '$ROUTE'"
[ "$MATCHES" -eq 1 ] || die "remote route '$ROUTE' is ambiguous across $MATCHES configured XOs; use an XO id"
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "configured SSH alias is unsafe: $HOST" ;; esac
case "$ROOT" in /*) ;; *) die "configured remote root is not absolute: $ROOT" ;; esac
case "$HOME_PATH" in /*) ;; *) die "configured remote home is not absolute: $HOME_PATH" ;; esac
case "$ROOT$HOME_PATH" in *$'\n'*|*$'\r'*|*$'\t'*) die "configured remote root or home contains control characters" ;; esac
for configured_path in "$ROOT" "$HOME_PATH"; do
  case "/$configured_path/" in */../*|*/./*) die "configured remote root or home contains traversal components" ;; esac
  case "$configured_path" in *'//'*) die "configured remote root or home contains an empty path component" ;; esac
done

ROOT_B64=$(printf '%s' "$ROOT" | encode_base64)
HOME_B64=$(printf '%s' "$HOME_PATH" | encode_base64)
ARGV_B64=$(printf '%s\0' "$COMMAND" "$@" | encode_base64)
SSH_BIN=${SQUAD_SSH_BIN:-ssh}
ALIVE_INTERVAL=${SQUAD_SSH_ALIVE_INTERVAL:-15}
ALIVE_COUNT_MAX=${SQUAD_SSH_ALIVE_COUNT_MAX:-3}
case "$ALIVE_INTERVAL" in ''|*[!0-9]*) die "SQUAD_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL" ;; esac
case "$ALIVE_COUNT_MAX" in ''|*[!0-9]*) die "SQUAD_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX" ;; esac
[ "$ALIVE_INTERVAL" -gt 0 ] || die "SQUAD_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL"
[ "$ALIVE_COUNT_MAX" -gt 0 ] || die "SQUAD_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX"

"$SSH_BIN" \
  -o ForwardAgent=no \
  -o ClearAllForwardings=yes \
  -o 'SendEnv=-*' \
  -o "ServerAliveInterval=$ALIVE_INTERVAL" \
  -o "ServerAliveCountMax=$ALIVE_COUNT_MAX" \
  -- "$HOST" sq-remote-entrypoint.sh "$PROTOCOL" "$ROOT_B64" "$HOME_B64" "$ARGV_B64"
