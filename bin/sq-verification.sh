#!/usr/bin/env bash
# Record and report escaped-defect links stored in existing GitHub issue bodies.
# Usage: sq-verification.sh record <issue-url> --discovered-at <ISO-8601> --pr <url> --sha <full-sha> [reproduction/reason] [regression/reason] --gate <name> --missed-reason <reason>
#        sq-verification.sh report <owner/repo>
exec python3 "$(dirname "$0")/sq-verification.py" "$@"
