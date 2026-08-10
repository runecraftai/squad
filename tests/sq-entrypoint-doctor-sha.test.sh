#!/usr/bin/env bash
# The entrypoint's git-less bootstrap trusts the doctor only when its embedded
# DOCTOR_SHA256 matches the tracked doctor byte-for-byte. Keep the two in
# sync: any rebrand or behavior edit to bin/sq-remote-doctor.sh must update
# bin/sq-remote-entrypoint.sh's DOCTOR_SHA256 (this test is the tripwire).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_embedded_doctor_sha_matches_tracked_doctor() {
  local actual embedded
  actual=$(sha256sum "$ROOT/bin/sq-remote-doctor.sh" | awk '{print $1}')
  embedded=$(sed -n 's/^DOCTOR_SHA256=//p' "$ROOT/bin/sq-remote-entrypoint.sh" | head -1)
  [ -n "$embedded" ] || fail "entrypoint has no DOCTOR_SHA256 pin"
  [ "$actual" = "$embedded" ] \
    || fail "entrypoint DOCTOR_SHA256 ($embedded) does not match bin/sq-remote-doctor.sh ($actual); update the pin"
  pass "entrypoint doctor pin matches the tracked doctor"
}

test_embedded_doctor_sha_matches_tracked_doctor
