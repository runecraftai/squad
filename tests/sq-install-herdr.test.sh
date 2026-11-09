#!/usr/bin/env bash
# Behavior tests for bin/sq-install-herdr.sh's transient-download recovery.
#
# The required real-Herdr lane failed when the release CDN returned a single
# HTTP 504; the installer must retry transient failures and still verify and
# install the pinned binary rather than failing the whole job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/sq-install-herdr.sh"
PIN_SHA256=b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28

# fm_installer_fakebin <tmp-dir>: build a Linux/x86_64 fixture whose fake curl
# fails CURL_FAILURES times before writing a runnable stand-in for the pinned
# herdr binary. The downloaded file reports the pinned version and protocol, so
# the installer's real checksum and post-install gates still execute.
fm_installer_fakebin() {
  local tmp=$1 fakebin=$1/fakebin
  mkdir -p "$fakebin"

  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  *) exit 1 ;;
esac
SH

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt "$CURL_FAILURES" ] || exit 22
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    cat > "$2" <<'HERDR'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'herdr 0.8.0\n' ;;
  status) printf '{"client":{"version":"0.8.0","protocol":19}}\n' ;;
  *) exit 1 ;;
esac
HERDR
    exit 0
  fi
  shift
done
exit 2
SH

  cat > "$fakebin/sha256sum" <<SH
#!/usr/bin/env bash
printf '$PIN_SHA256  %s\\n' "\$1"
SH

  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  chmod +x "$fakebin/uname" "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

run_installer() {
  local tmp=$1 failures=$2 destination=$3
  CURL_COUNT="$tmp/curl-count" CURL_FAILURES="$failures" PATH="$FAKEBIN:$PATH" \
    "$INSTALLER" "$destination"
}

test_retries_a_transient_download_failure() {
  local tmp destination out
  tmp=$(fm_test_tmproot sq-install-herdr-retry)
  FAKEBIN=$(fm_installer_fakebin "$tmp")
  destination="$tmp/bin"

  out=$(run_installer "$tmp" 1 "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 2 ] || fail "installer did not retry exactly once after recovery"
  assert_contains "$out" "download attempt 1 failed; retrying" "installer did not disclose its retry"
  [ -x "$destination/herdr" ] || fail "installer did not install herdr after retrying"
  assert_contains "$out" "herdr 0.8.0" "installer did not verify the pinned herdr version"
  pass "Herdr installer retries a transient download failure"
}

test_rides_out_a_burst_of_transient_failures() {
  local tmp destination out
  tmp=$(fm_test_tmproot sq-install-herdr-burst)
  FAKEBIN=$(fm_installer_fakebin "$tmp")
  destination="$tmp/bin"

  out=$(run_installer "$tmp" 6 "$destination" 2>&1) \
    || fail "installer gave up under a burst of transient download failures"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 7 ] || fail "installer did not keep retrying through the failure burst"
  assert_contains "$out" "download attempt 6 failed; retrying" "installer did not disclose retry 6"
  [ -x "$destination/herdr" ] || fail "installer did not install herdr after the burst"
  pass "Herdr installer rides out a burst of transient download failures"
}

test_retries_a_transient_download_failure
test_rides_out_a_burst_of_transient_failures
