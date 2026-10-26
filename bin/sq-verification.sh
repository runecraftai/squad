#!/usr/bin/env bash
# Record and report escaped-defect links stored in existing GitHub issue bodies.
#
# A defect that shipped keeps exactly one linkage section in its own issue body,
# below the marker "<!-- squad-escaped-defect:v1 -->", so the linkage lives with
# the issue identity instead of in a separate store.
# Recording replaces only that section and keeps every line of the body before
# it, so human prose and earlier edits survive a re-record.
# Issue bodies are read in bounded chunks, and a chunked read whose length does
# not match the reported body length is refused rather than written back short.
# Reproduction and regression take either a value or an explicit unknown reason;
# a genuinely absent field is rejected at record time and reported as unknown,
# never as a pass or a zero.
#
# Usage: sq-verification.sh record <issue-url> --discovered-at <ISO-8601> --pr <pull-url> --sha <full-sha>
#                                     (--reproduction <text> | --no-reproduction-reason <reason>)
#                                     (--regression <scenario> | --no-regression-reason <reason>)
#                                     --gate <pre-merge gate> --missed-reason <reason>
#        sq-verification.sh report <owner/repo>
#
# --discovered-at must be ISO-8601 with a timezone, and --sha must be a full
# 40- or 64-character lowercase hexadecimal commit id, so the affected commit is
# never a guess. `report` scans the repo's open and closed issues (never pull
# requests) and prints one block per recorded defect; an empty result states
# that nothing is recorded instead of claiming there is nothing to find.
# Both commands go through `sq-gh` and decode its TOON output with
# bin/sq-factory-collect-toon.mjs, so node must be on PATH.
exec python3 "$(dirname "$0")/sq-verification.py" "$@"
