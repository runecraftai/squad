#!/usr/bin/env bash
# sq-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Single owner of the exact ShellCheck version and SHA-256 pin used by CI's
# lint and behavior lanes. Downloads the official GitHub Releases asset with
# bounded curl-level retries for transient HTTP failures (5xx/408/429) and an
# outer attempt loop with exponential backoff, then verifies the checksum
# before install; never installs a floating package-manager latest.
#
# Usage:
#   sq-install-shellcheck.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/sq-lint.sh" --required-version)"
SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: sq-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sq-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# The release CDN intermittently drops mid-transfer connections (curl error 56
# after its own five reconnect tries). curl retries those transient failures
# itself with bounded exponential backoff (2, 4, 8, 16s), and the outer loop
# adds a second, wider retry horizon with jitter so parallel CI shards do not
# re-hit the CDN in lockstep.
DOWNLOAD_ATTEMPTS=4
download_attempt=1
while ! curl -fsSL --retry 4 --retry-all-errors --retry-connrefused \
    --retry-delay 2 --connect-timeout 15 --max-time 120 \
    "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'sq-install-shellcheck.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'sq-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  # Exponential backoff with jitter: 1-3s, 2-4s, 4-6s, then 8-10s.
  sleep "$((2 ** (download_attempt - 1) + RANDOM % 3))"
  download_attempt=$((download_attempt + 1))
done
ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'sq-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"
"$DESTINATION/shellcheck" --version
