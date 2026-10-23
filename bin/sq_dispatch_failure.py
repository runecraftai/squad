import os
import re

FAILURE_BUCKETS = (
    ("quota", re.compile(r"quota|usage limit|session limit|rate[ -]?limit|insufficient credit", re.IGNORECASE)),
    ("provider", re.compile(r"provider|overloaded|outage|unavailable|server error", re.IGNORECASE)),
    ("guard", re.compile(r"guard|policy|refus|denied", re.IGNORECASE)),
)
TERMINAL_LINE = re.compile(r"^(done|failed|blocked|paused): (.*)$")


def status_failure_class(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    last = None
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = TERMINAL_LINE.match(line.rstrip("\n"))
                if match:
                    last = match
    except OSError:
        return None
    if last is None or last.group(1) == "done":
        return None
    for bucket, pattern in FAILURE_BUCKETS:
        if pattern.search(last.group(2)):
            return bucket
    return "other"
