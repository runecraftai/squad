import os
import re
import sys

FAILURE_BUCKETS = (
    ("quota", re.compile(r"quota|usage limit|session limit|rate[ -]?limit|insufficient credit", re.IGNORECASE)),
    ("provider", re.compile(r"provider|overloaded|outage|unavailable|server error", re.IGNORECASE)),
    ("guard", re.compile(r"guard|policy|refus|denied", re.IGNORECASE)),
)
TERMINAL_LINE = re.compile(r"^(done|failed|blocked|paused):[ \t]*(.*)$")


def line_failure_class(text):
    for bucket, pattern in FAILURE_BUCKETS:
        if pattern.search(text):
            return bucket
    return "other"


def status_failure_class(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    outcome = None
    stall = None
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = TERMINAL_LINE.match(line.rstrip("\n"))
                if not match:
                    continue
                if match.group(1) in ("done", "failed"):
                    outcome = match
                else:
                    stall = match
    except OSError:
        return None
    last = outcome or stall
    if last is None or last.group(1) == "done":
        return None
    return line_failure_class(last.group(2))


if __name__ == "__main__":
    print(line_failure_class(sys.stdin.read().rstrip("\n")))
