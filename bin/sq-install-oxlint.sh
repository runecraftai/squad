#!/usr/bin/env bash
# sq-install-oxlint.sh - install CI's pinned, verified oxlint build.
#
# Single owner of the exact oxlint version and tarball SHA-256 pins used by the
# behavior lanes and by the React filesystem-route proof. Downloads the npm
# tarballs for the CLI and the matching platform binding, verifies both
# checksums, and installs a self-contained tree plus an `oxlint` launcher under
# the destination directory; never installs a floating package-manager latest.
#
# Usage:
#   sq-install-oxlint.sh <destination-directory>
set -eu

VERSION=1.87.0
CLI_SHA256=04441961a07abc710dda63f798550b37169d7ad527acbe6e880785987b6116d4
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) BINDING=linux-x64-gnu; BINDING_SHA256=107eb7c1fc059c961dea25f4d8bdb6f8c0bba78b958e81c5c1b81033a71fcfdb ;;
  Linux-aarch64|Linux-arm64) BINDING=linux-arm64-gnu; BINDING_SHA256=f863377c09b41225b0a80226046d82c807bab3d52b9a2950a09913837e09afaf ;;
  Darwin-arm64) BINDING=darwin-arm64; BINDING_SHA256=ac46d31681986e5f99e2ee71c7d231cdbeb8289adaa013776063cbb8d337156a ;;
  Darwin-x86_64) BINDING=darwin-x64; BINDING_SHA256=b864da2b3706ae9093b1fb5e36bb6021744c5aa9ad3d030fe32e39eaa63dd546 ;;
  *)
    printf 'sq-install-oxlint.sh: unsupported platform for oxlint %s: %s-%s\n' \
      "$VERSION" "$(uname -s)" "$(uname -m)" >&2
    exit 1
    ;;
esac
DESTINATION=${1:?usage: sq-install-oxlint.sh <destination-directory>}
command -v node >/dev/null 2>&1 || {
  printf 'sq-install-oxlint.sh: node is required to run oxlint\n' >&2
  exit 1
}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sq-oxlint.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

download() {  # <url> <output>
  local attempt=1
  while ! curl -fsSL --retry 4 --retry-all-errors --retry-connrefused \
      --retry-delay 2 --connect-timeout 15 --max-time 120 "$1" -o "$2"; do
    [ "$attempt" -lt 4 ] || {
      printf 'sq-install-oxlint.sh: download failed: %s\n' "$1" >&2
      return 1
    }
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

sha256_file() {  # <file>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify() {  # <file> <expected-sha256>
  local actual
  actual=$(sha256_file "$1")
  [ "$actual" = "$2" ] || {
    printf 'sq-install-oxlint.sh: checksum mismatch for %s\n' "$(basename "$1")" >&2
    return 1
  }
}

CLI_ARCHIVE="oxlint-${VERSION}.tgz"
BINDING_ARCHIVE="binding-${BINDING}-${VERSION}.tgz"
download "https://registry.npmjs.org/oxlint/-/${CLI_ARCHIVE}" "$TMP/$CLI_ARCHIVE"
verify "$TMP/$CLI_ARCHIVE" "$CLI_SHA256"
download "https://registry.npmjs.org/@oxlint/binding-${BINDING}/-/${BINDING_ARCHIVE}" "$TMP/$BINDING_ARCHIVE"
verify "$TMP/$BINDING_ARCHIVE" "$BINDING_SHA256"

mkdir -p "$DESTINATION"
rm -rf "$DESTINATION/lib/oxlint"
mkdir -p "$DESTINATION/lib/oxlint/node_modules/@oxlint/binding-$BINDING"
tar -xzf "$TMP/$CLI_ARCHIVE" -C "$DESTINATION/lib/oxlint" --strip-components=1
tar -xzf "$TMP/$BINDING_ARCHIVE" -C "$DESTINATION/lib/oxlint/node_modules/@oxlint/binding-$BINDING" --strip-components=1
cat >"$DESTINATION/oxlint" <<'EOF'
#!/bin/sh
exec node "$(dirname "$0")/lib/oxlint/bin/oxlint" "$@"
EOF
chmod 0755 "$DESTINATION/oxlint"
INSTALLED=$("$DESTINATION/oxlint" --version | awk '{print $NF}')
[ "$INSTALLED" = "$VERSION" ] || {
  printf 'sq-install-oxlint.sh: expected oxlint %s, got %s\n' "$VERSION" "$INSTALLED" >&2
  exit 1
}
printf 'installed oxlint %s at %s\n' "$INSTALLED" "$DESTINATION/oxlint"
