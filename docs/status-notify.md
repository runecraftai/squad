# Desktop status notifications (sq-status-notify)

`bin/sq-status-notify.sh` posts a desktop notification (notify-send, on Linux/mako) when an operator appends a `done:`, `needs-decision:`, `blocked:`, or `failed:` wake event to `state/<id>.status`.
It mirrors the herdr "blocked/done" notification behavior for operators running in tmux panes, so the commander does not have to keep an eye on every task window.

The script header owns the full command, environment, and behavior reference.
This page covers setup and the operational contract.

## Requirements

- notify-send from libnotify (the notification daemon is mako or any other notify-send-compatible server).
- tmux, the runtime backend that hosts the operator windows the notification focuses.

## Install and run

The script runs in place from the repo, so there is no build step.
For a per-user service, point a systemd user unit at the repo copy and let it drive the `watch` subcommand:

```ini
[Unit]
Description=Squad operator status notifications (tmux -> mako)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/home/you/squad/bin/sq-status-notify.sh watch /home/you/squad
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

The `watch` BASE argument is optional; when omitted, the script resolves `$SQUAD_BASE`, then the legacy `$SQUAD_HOME`, then this repo root.
A base that lives outside the standard layout passes the path explicitly, as in the unit above.
Enable the service with `systemctl --user enable --now sq-status-notify.service` and check it with `journalctl --user -u sq-status-notify.service`.
Each notification also logs `notify: <title>` to stderr, so the unit's journal shows every notification the watcher posted.

## What notifies

Only `done`, `needs-decision`, `blocked`, and `failed` lines notify by default, with a distinct title per verb.
A status file first seen, or its pre-existing history, never notifies; only new appended lines after the baseline fire.
Truncated or rotated status files reset the offset without re-notifying history.
Override the verb set with `SQ_NOTIFY_VERBS` (for example `done blocked`) and the poll interval with `SQ_NOTIFY_POLL` seconds (default 5).
A `done` notification (and any other notified verb) shows for 15 seconds; `needs-decision`, `blocked`, and `failed` notifications persist until dismissed (notify-send -t 0).

## Focus and suppression

A notification for an operator whose meta records a `window=` carries a click action that selects that tmux window.
Clicking the body focuses the operator's pane; the click handler forks per notification so the watcher never blocks on an unacknowledged popup.
When the operator's window is already the focused window, the notification is suppressed entirely (herdr-like active-tab suppression).

## Optional tmux status-line channel

Set `SQ_NOTIFY_TMUX=1` to also flash each notification in the operator's terminal, in addition to the desktop popup.
The watcher runs `tmux display-message` on the operator's recorded window, or on the calling client's status line when no window is recorded.
The channel is best-effort: it fails silently when tmux is unavailable or the target window is gone, and the focused-window suppression above applies to it too.
The tmux focus action on the desktop notification is unaffected.

## Limits

- Linux/notify-send only; macOS specifics are out of scope.
- notify-send is best-effort: when it is missing, the watcher prints one warning to stderr and keeps polling rather than dying.
- Per-base notification offsets live under `$XDG_STATE_HOME/sq-status-notify/` (default `~/.local/state/sq-status-notify/`), one subdirectory per base; deleting that directory re-baselines every status file without notifying history.

## Regression entry point

```sh
tests/sq-status-notify.test.sh
```
