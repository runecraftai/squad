#!/usr/bin/env bash
# Mirror one commander-facing message to the commander's Telegram chat.
# Usage: sq-tg-notify.sh <text-or-'-'>   ('-' reads the message from stdin)
#
# The dual channel: when the commander wants chat replies to also arrive on
# Telegram, Squad calls this helper with the same text it just posted here, so
# the message lands in chat and in Telegram (docs/configuration.md, "Telegram
# bridge (config/telegram-bridge.env)").  The helper is a proactive ping, not
# part of the relay request lifecycle: it uses the Telegram Bot API directly
# (sendMessage) and works even when the bridge is down.
#
# Config comes from the base's gitignored config/telegram-bridge.env, the same
# file the bridge uses: TG_BOT_TOKEN (required) and TG_ALLOWED_CHAT_IDS
# (required; the first id is the mirror target).  The base home resolves like
# the other sq-* scripts: $SQUAD_BASE, then legacy $SQUAD_HOME, then this repo
# root.  Fail-closed: missing or unreadable config exits 1 with the reason on
# stderr and sends nothing.
#
# Output: one line "telegram HTTP <code>" with the Bot API HTTP status, so a
# caller can tell a delivered mirror from a failed one.  Exit 0 when the HTTP
# exchange completed (any status), non-zero on curl failure.
set -u

base=${SQUAD_BASE:-${SQUAD_HOME:-}}
if [ -z "$base" ]; then
  base=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi
cfg="$base/config/telegram-bridge.env"
[ -r "$cfg" ] || { echo "sq-tg-notify: no $cfg" >&2; exit 1; }

token=$(grep -E '^TG_BOT_TOKEN=' "$cfg" | head -1 | cut -d= -f2-)
chat=$(grep -E '^TG_ALLOWED_CHAT_IDS=' "$cfg" | head -1 | cut -d= -f2- | cut -d, -f1)
[ -n "$token" ] || { echo "sq-tg-notify: TG_BOT_TOKEN missing in $cfg" >&2; exit 1; }
[ -n "$chat" ] || { echo "sq-tg-notify: TG_ALLOWED_CHAT_IDS missing in $cfg" >&2; exit 1; }

if [ "${1:-}" = "-" ]; then
  text=$(cat)
else
  text=${1:?usage: sq-tg-notify.sh <text-or-'-'>}
fi

curl -s -m 15 -X POST "https://api.telegram.org/bot$token/sendMessage" \
  --data-urlencode "chat_id=$chat" \
  --data-urlencode "text=$text" \
  -o /dev/null -w "telegram HTTP %{http_code}\n"
