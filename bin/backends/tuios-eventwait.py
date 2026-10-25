#!/usr/bin/env python3
"""Bounded reader for TUIOS agent-state events.

The CLI owns the socket protocol. This process only projects subscribed event
identity and state; the Bash adapter re-reads authoritative state before acting.

It streams until its deadline: a matching event is a wake hint for the caller,
not the end of the wait, so the caller's poll-interval floor survives an event
that turns out not to be a fresh actionable edge.

Usage: tuios-eventwait.py <tuios-bin> <session> <timeout_seconds> <window> [...]

Output (one line each, flushed as it arrives):
  @subscribed
  <window>\tevent

Exit status:
  0  subscribed and waited out the deadline: a clean bounded wait
  2  bad arguments, the subscription failed, or the stream closed early
"""
import json
import os
import selectors
import signal
import subprocess
import sys
import time

READ_CHUNK = 65536


def _install_stop_handlers(proc):
    """Terminate the subscription child before this process exits.

    The Bash caller stops a reader that found its actionable edge with SIGTERM.
    Python's default SIGTERM disposition skips cleanup, and a leaked
    `tuios subscribe` holds a daemon connection until it next writes an event,
    so the child is killed from the handler itself.
    """

    def stop(_signum, _frame):
        if proc.poll() is None:
            proc.kill()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)


def main(argv):
    if len(argv) < 5:
        return 2
    binary, session, timeout_text, *windows = argv[1:]
    try:
        timeout = float(timeout_text)
    except ValueError:
        return 2
    if timeout <= 0 or not session or not windows or any(not item for item in windows):
        return 2

    try:
        proc = subprocess.Popen(
            [binary, "subscribe", "--session", session, "--types", "agent-state"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
    except OSError:
        return 2

    _install_stop_handlers(proc)

    stdout_fd = proc.stdout.fileno()
    selector = selectors.DefaultSelector()
    selector.register(stdout_fd, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    known = set(windows)
    subscribed = False
    result = 2
    buffered = b""

    def read_line(until):
        """One newline-terminated line from the stream, honoring a deadline."""
        nonlocal buffered
        while b"\n" not in buffered:
            remaining = until - time.monotonic()
            if remaining <= 0:
                return None, "timeout"
            if not selector.select(remaining):
                return None, "timeout"
            try:
                chunk = os.read(stdout_fd, READ_CHUNK)
            except OSError:
                return None, "closed"
            if not chunk:
                return None, "closed"
            buffered += chunk
        line, buffered = buffered.split(b"\n", 1)
        return line, "line"

    try:
        while True:
            line, outcome = read_line(deadline)
            if line is None:
                if outcome == "closed":
                    result = 2
                else:
                    result = 0 if subscribed else 2
                break
            try:
                event = json.loads(line)
            except (TypeError, ValueError):
                continue
            if not subscribed:
                if event.get("type") != "subscribed" or not event.get("boot_id"):
                    result = 2
                    break
                subscribed = True
                print("@subscribed", flush=True)
                continue
            if event.get("type") == "gap":
                result = 2
                break
            if event.get("type") != "agent-state":
                continue
            window = event.get("window")
            if window in known:
                print(f"{window}\tevent", flush=True)
    finally:
        selector.close()
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    return result


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        # The bash caller stopped reading (found its actionable edge and killed
        # us). That is a normal, successful end of the wait.
        sys.exit(0)
