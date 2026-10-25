#!/usr/bin/env python3
"""Bounded reader for TUIOS agent-state events.

The CLI owns the socket protocol. This process only projects subscribed event
identity and state; the Bash adapter re-reads authoritative state before acting.
"""
import json
import selectors
import subprocess
import sys
import time


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
            text=True,
            bufsize=1,
        )
    except OSError:
        return 2

    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    known = set(windows)
    subscribed = False
    result = 2
    try:
        while time.monotonic() < deadline:
            ready = selector.select(max(0, deadline - time.monotonic()))
            if not ready:
                result = 0 if subscribed else 2
                break
            line = proc.stdout.readline()
            if not line:
                result = 2
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
                result = 1
                break
        else:
            result = 0 if subscribed else 2
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
        sys.exit(0)
