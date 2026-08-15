# Web dashboard (sq-web-view)

`bin/sq-web-view.sh` serves or renders a read-only web dashboard of a Squad base's operator state: one card per operator with the live busy classification, the last wake event, the window, the project, and the full status log.
It is the closest maintained equivalent to herdr's web dashboard for operators running in tmux panes, viewable from another machine or a phone on the LAN.

The script header owns the full command, environment, and behavior reference.
This page covers setup and the operational contract.

## Run

```sh
bin/sq-web-view.sh serve
```

The `serve` subcommand runs a tiny no-framework HTTP server in the foreground (Python 3 standard library only) that re-renders the page on every request, so the page is always current.
Ctrl-C stops it; there is no daemon.
By default it binds `127.0.0.1:8080` and prints its URL.

The page auto-reloads itself; `SQ_WEB_VIEW_REFRESH` sets the seconds between reloads (default 10).

## Remote access

Use `--bind` to choose the listen address and `--port` to choose the port:

```sh
bin/sq-web-view.sh serve --bind 0.0.0.0 --port 8080
```

Binding `0.0.0.0` makes the dashboard reachable from other devices on the LAN at the machine's LAN address.
There is no authentication framework, by design: the dashboard is read-only and reveals only operator status, wake events, project paths, window names, and the harness, mode, effort, and model metadata on each card.
Decide consciously before exposing it beyond the loopback interface, and keep the default `127.0.0.1` bind unless remote access is actually wanted.
If real authentication is required, that is outside this tool's scope; keep the viewer on loopback or behind an authenticated proxy instead.

## Static export

`render` prints the same HTML to stdout and needs no Python:

```sh
bin/sq-web-view.sh render > /tmp/squad-view/index.html
```

Serve the file with any static file server, for example `python3 -m http.server --bind 127.0.0.1 -d /tmp/squad-view 8080`; the stdlib server binds every interface by default, so pass `--bind 127.0.0.1` unless LAN access is intended.
A static export is a snapshot: regenerate it to refresh the page.

## What it shows

One card per `state/<id>.meta` record, newest activity first:

- The live busy classification read from `state/<id>.busy-state` via `bin/sq-busy-lib.sh`, with the reason when it is unknown (missing, malformed, or stale generation).
- The last wake event from the tail of `state/<id>.status`, with the full log expandable inline.
- The window, project, harness, mode, effort, and model from the meta record.

The busy-state record format is owned by `bin/sq-busy-lib.sh`, the status-event vocabulary by `bin/sq-classify-lib.sh`, and the base state layout by `docs/configuration.md`; this page does not restate them.
The page shows each operator's last wake event, which is history, not a reconciled current state; `bin/sq-crew-state.sh` owns that reconciliation.

## Read-only

The viewer never writes to the base: `render` only prints HTML, and `serve` only reads state records and answers HTTP requests.
The tests assert the state directory checksums are unchanged after both modes.

## Limits

- `serve` requires `python3` with the standard library; `render` works on any POSIX bash (bash 3.2 included).
- The page covers one base at a time; point `--state` at a different base's `state/` directory to watch that one.
- An empty base renders an empty-state page, not an error.

## Regression entry point

```sh
tests/sq-web-view.test.sh
```
