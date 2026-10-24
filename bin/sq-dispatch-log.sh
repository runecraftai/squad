#!/usr/bin/env bash
# Append a private dispatch event to data/<id>/dispatch.jsonl (0600).
# Usage:
#   sq-dispatch-log.sh <id> decision --harness H --model M --effort E \
#     (--profile NAME | --reason TEXT) [--quota-summary JSON]
#   sq-dispatch-log.sh <id> spawn --harness H --model M --effort E
#   sq-dispatch-log.sh <id> outcome --source status-notify|pr-merge|teardown \
#     --result done|failed|landed|released
# Base: SQUAD_BASE > SQUAD_HOME > SQUAD_ROOT_OVERRIDE > repository root;
# SQUAD_DATA_OVERRIDE overrides its data directory.
# decision is written at intake by sq-spawn.sh or directly by a dispatcher;
# spawn records actual choices.
# Only pass non-sensitive profile names or short reasons, never brief text.
# quota-summary is a JSON object of numeric remaining_percent, reset_seconds,
# remaining_tokens, remaining_requests and/or status (available/tight/unknown).
# An omitted quota summary records {"status":"unknown"}; raw quota/auth payloads
# are not accepted. No brief, environment credentials, or status text is read.
# harness, model and effort values that look like a credential or token are
# refused and nothing is written.
# outcome may carry failure_class=provider|quota|guard|other, and only on failed rows
# and on released rows sourced from a blocked or paused line; landed and done rows
# carry none. status-notify passes --failure-class for the line it reports (none
# for done). Without the flag the writer derives it from state/<id>.status with the
# reader's rule: only done and failed lines decide, the last one in order wins, and
# a failed row keeps a class only when that last decisive line is failed. Blocked or
# paused lines supply a class only when no done or failed line exists, so a released
# row takes its class only from that case. Only the bucket is stored, never the
# status text. Teardown and status-notify write outcome before removing status.
# Every record includes timestamp, id and event. Appends survive task teardown.
# Writers serialize on the file with a bounded lock wait of at most 500 ms;
# unsafe paths, lock contention beyond that budget, missing dependencies and
# write failures emit one generic warning, then exit 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}}"
DATA="${SQUAD_DATA_OVERRIDE:-$BASE/data}"
STATE="${SQUAD_STATE_OVERRIDE:-$BASE/state}"

if ! SQ_DISPATCH_LIB="$SCRIPT_DIR" python3 - "$DATA" "$STATE" "$@" 2>/dev/null <<'PY'
import argparse
import datetime
import fcntl
import json
import math
import os
import re
import stat
import sys
import time

sys.path.insert(0, os.environ["SQ_DISPATCH_LIB"])
from sq_dispatch_failure import FAILURE_CLASSES, status_verdict

SECRET_SHAPE = re.compile(
    r"(?<![A-Za-z0-9])(sk|pk|ghp|gho|ghs|ghu|ghr|xox[abprs]|glpat)[-_][A-Za-z0-9_-]{8,}"
    r"|github_pat_[A-Za-z0-9_]{8,}|AKIA[0-9A-Z]{12,}|AIza[0-9A-Za-z_-]{20,}"
    r"|eyJ[A-Za-z0-9_-]{8,}[.]|bearer[ ]"
    r"|(token|secret|passwd|password|api[_-]?key|credential)[=:]"
    r"|(?<![A-Za-z0-9_+/])(?!(?:[0-9a-f]{40}|[0-9a-f]{64})(?![A-Za-z0-9_+/]))[A-Za-z0-9_+/]{32,}",
    re.IGNORECASE)


parser = argparse.ArgumentParser(description="Append one private dispatch event (best effort).")
parser.add_argument("id")
commands = parser.add_subparsers(dest="event", required=True)
for event in ("decision", "spawn"):
    command = commands.add_parser(event)
    for field in ("harness", "model", "effort"):
        command.add_argument("--" + field, required=True)
    if event == "decision":
        reason = command.add_mutually_exclusive_group(required=True)
        reason.add_argument("--profile")
        reason.add_argument("--reason")
        command.add_argument("--quota-summary", default='{"status":"unknown"}')
command = commands.add_parser("outcome")
command.add_argument("--source", required=True, choices=("status-notify", "pr-merge", "teardown"))
command.add_argument("--result", required=True, choices=("done", "failed", "landed", "released"))
command.add_argument("--failure-class", choices=FAILURE_CLASSES + ("none",))
args = parser.parse_args(sys.argv[3:])
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", args.id):
    raise ValueError("invalid id")
record = {"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "id": args.id, "event": args.event}
if args.event in ("decision", "spawn"):
    for field in ("harness", "model", "effort"):
        value = getattr(args, field)
        if not re.fullmatch(r"[!-~]{1,128}", value) or SECRET_SHAPE.search(value):
            raise ValueError("invalid choice")
        record[field] = value
if args.event == "decision":
    field = "profile" if args.profile is not None else "reason"
    value = getattr(args, field)
    if not value or len(value) > 256 or any(ord(c) < 32 for c in value) or SECRET_SHAPE.search(value):
        raise ValueError("invalid rationale")
    record[field] = value
    quota = json.loads(args.quota_summary)
    if not isinstance(quota, dict):
        raise ValueError("invalid quota summary")
    for key, value in quota.items():
        if key == "status":
            if value not in ("available", "tight", "unknown"):
                raise ValueError("invalid quota status")
        elif key not in ("remaining_percent", "reset_seconds", "remaining_tokens", "remaining_requests") \
                or type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise ValueError("invalid quota field")
    record["quota_summary"] = quota
if args.event == "outcome":
    record.update(source=args.source, result=args.result)
    status = os.path.join(sys.argv[2], args.id + ".status")
    kind, derived = status_verdict(status)
    if args.result == "failed":
        bucket = args.failure_class if args.failure_class is not None else derived if kind == "failed" else None
    elif args.result == "released":
        bucket = derived if kind in ("blocked", "paused") else None
    else:
        bucket = None
    if bucket not in (None, "none"):
        record["failure_class"] = bucket
line = (json.dumps(record, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
os.umask(0o077)
os.makedirs(sys.argv[1], mode=0o700, exist_ok=True)
# Open each task path component relative to the checked directory, refusing
# symlinks and non-regular or hard-linked logs before chmod or append.
with_fd = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
data_fd = os.open(sys.argv[1], with_fd)
try:
    os.mkdir(args.id, mode=0o700, dir_fd=data_fd)
except FileExistsError:
    pass
task_fd = os.open(args.id, with_fd, dir_fd=data_fd)
fd = os.open("dispatch.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND |
             os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=task_fd)
info = os.fstat(fd)
if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
    raise ValueError("unsafe log")
deadline = time.monotonic() + 0.5
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() >= deadline:
            raise
        time.sleep(0.01)
os.fchmod(fd, 0o600)
offset = os.lseek(fd, 0, os.SEEK_END)
if os.write(fd, line) != len(line):
    os.ftruncate(fd, offset)
    os.fsync(fd)
    raise OSError("short append")
os.fsync(fd)
os.close(fd)
os.close(task_fd)
os.close(data_fd)
PY
then
  printf '%s\n' 'sq-dispatch-log: could not append dispatch event' >&2
fi
exit 0
