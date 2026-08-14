# Telegram bridge verification

Audience: maintainer verification.

This record supports two active guarantees for the Telegram bridge:

1. The shipped user service starts the bridge at boot and restarts it after a crash or a stop/start cycle.
2. A bridge restart never re-ingests an already-offered message and never re-answers an answered request, because the persisted state survives byte-identical.

[`docs/configuration.md`](../configuration.md#telegram-bridge-configtelegram-bridgeenv) owns the operator-facing contract (setup, the dual channel, removal), and `bin/sq-tg-bridge.py`'s header owns the connector and config mechanics.
The bounded-send behavior (a stalled Telegram API surfaces as the contract's 502 instead of hanging the answer) is pinned by the connector suite below.
Task chronology and delivery evidence stay outside this record.

## Environment

Recorded 2026-08-13 on Linux 7.1.4-arch1-1 with systemd 261.1-1-arch (user manager, linger enabled), Python 3.14.3, and ShellCheck 0.11.0 (the version `bin/sq-lint.sh` pins).
The base under test is the standard `~/Projects/squad` layout with `systemd/sq-tg-bridge.service` installed as `~/.config/systemd/user/sq-tg-bridge.service`.

## Connector regressions

```sh
bash tests/sq-tg-bridge.test.sh
bash tests/sq-tg-notify.test.sh
```

The cases below are the relevant lines excerpted from those suites' full `ok` output (the bridge suite runs 30 cases, the mirror suite 7):

```
ok - a stalled Telegram send times out into the 502 contract, keeps serving, and stays pending
ok - concurrent answers cannot double-post a thread
ok - concurrent follow-ups cannot exceed the 3-post contract
ok - a mid-read network failure on send returns 502 and keeps the request pending
ok - restart keeps the offset, never duplicates a request, and keeps pending work
ok - sq-tg-notify posts the text argument to the commander's chat
ok - sq-tg-notify reads the message from stdin with '-'
ok - sq-tg-notify fails closed without the bridge env file
```

Both suites exit 0 and run entirely on localhost (the bridge test uses a fake Telegram Bot API server; the mirror test stubs `curl`).

## Service stop/start and crash-restart cycle

State baseline before every cycle (6 answered requests, nothing pending):

```sh
sha256sum state/telegram-bridge/state.json   # b8fe0b192dd7de9e...
python3 -c "import json; d=json.load(open('state/telegram-bridge/state.json')); print(d['offset'], sorted(set(r['status'] for r in d['requests'].values())))"
# 760634679 ['answered']
```

Stop/start cycle (the bearer token is read from the base's gitignored `.env`, never stored in this record):

```sh
systemctl --user stop sq-tg-bridge
systemctl --user start sq-tg-bridge
systemctl --user is-active sq-tg-bridge          # active
curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $SQX_PAIRING_TOKEN" http://127.0.0.1:8787/connector/poll   # 204
sha256sum state/telegram-bridge/state.json       # b8fe0b192dd7de9e... (unchanged)
```

Crash restart:

```sh
kill -9 "$(systemctl --user show -p MainPID --value sq-tg-bridge)"
sleep 8
systemctl --user is-active sq-tg-bridge          # active, new MainPID
curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $SQX_PAIRING_TOKEN" http://127.0.0.1:8787/connector/poll   # 204
sha256sum state/telegram-bridge/state.json       # b8fe0b192dd7de9e... (unchanged)
journalctl --user -u sq-tg-bridge | grep -c 'Started Squad Telegram bridge'   # 3
```

The offset and the answered statuses survive every restart byte-identically, the poll keeps returning 204 (nothing re-offered), and systemd records each of the three starts (initial enable, stop/start, crash recovery).
`Restart=on-failure` and `RestartSec=5s` are in effect on the installed unit.
