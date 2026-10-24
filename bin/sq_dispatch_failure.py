import os
import re
import sys

FAILURE_BUCKETS = (
    ("quota", re.compile(r"quota|usage limit|session limit|rate[ -]?limit|insufficient credit", re.IGNORECASE)),
    ("provider", re.compile(r"provider|overloaded|outage|unavailable|server error", re.IGNORECASE)),
    ("guard", re.compile(r"guard|policy|refus|denied", re.IGNORECASE)),
)
FAILURE_CLASSES = tuple(bucket for bucket, _ in FAILURE_BUCKETS) + ("other",)
TERMINAL_LINE = re.compile(r"^(done|failed|blocked|paused):[ \t]*(.*)$")


def line_failure_class(text):
    for bucket, pattern in FAILURE_BUCKETS:
        if pattern.search(text):
            return bucket
    return "other"


def status_verdict(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return None, None
    decisive = None
    stopped = None
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = TERMINAL_LINE.match(line.rstrip("\n"))
                if match is None:
                    continue
                if match.group(1) in ("done", "failed"):
                    decisive = match
                else:
                    stopped = match
    except OSError:
        return None, None
    chosen = decisive or stopped
    if chosen is None:
        return None, None
    kind = chosen.group(1)
    if kind == "done":
        return kind, None
    return kind, line_failure_class(chosen.group(2))


if __name__ == "__main__":
    print(line_failure_class(sys.stdin.read().rstrip("\n")))
