#!/usr/bin/env bash
# sq-install-fob.sh - install CI's pinned, verified FOB build.
#
# Used only by the required real-Herdr CI lane for E2E scripts that genuinely
# need fob (spawn worktree acquisition). Same pin/checksum discipline as
# sq-install-herdr.sh: official release URL, exact asset, SHA-256, bounded
# download, post-install version check. Never a floating package-manager latest.
#
# Usage:
#   sq-install-fob.sh <destination-directory>
#
# Pins FOB v2.1.1 (fork version; release asset built by the Squad release pipeline).
set -eu

SQUAD_FOB_CI_VERSION=2.1.1
SQUAD_FOB_CI_TAG="v${SQUAD_FOB_CI_VERSION}"
# Bounded download ceiling (bytes). Official 2.0.1 archives are under 8 MiB.
SQUAD_FOB_CI_MAX_BYTES=15000000
SQUAD_FOB_CI_REPO=runecraftai/squad

die() {
  printf 'sq-install-fob.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: sq-install-fob.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ARCHIVE=fob-v${SQUAD_FOB_CI_VERSION}-linux-amd64.tar.gz
    SHA256=e05a35a7d23464508417237b48b6ebee019f1e68270c8f28ded41e3bfec15e56
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE=fob-v${SQUAD_FOB_CI_VERSION}-linux-arm64.tar.gz
    SHA256=eaccc9c5b98125df8bd77425598eeecee66cb0371db4eb1cf75f0d813c18fab9
    ;;
  Darwin-arm64)
    ARCHIVE=fob-v${SQUAD_FOB_CI_VERSION}-darwin-arm64.tar.gz
    SHA256=7ee5078f3d1f33c01196548797fce65408e459d53530b77d4ba56e074fa1c1a2
    ;;
  Darwin-x86_64)
    ARCHIVE=fob-v${SQUAD_FOB_CI_VERSION}-darwin-amd64.tar.gz
    SHA256=1cf44580a5837f995e1d3bb74f4fbd3112b642acd20406087d9735a8106112fd
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official FOB assets are linux/darwin amd64 and arm64"
    ;;
esac

URL="https://github.com/${SQUAD_FOB_CI_REPO}/releases/download/${SQUAD_FOB_CI_TAG}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sq-fob.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'sq-install-fob.sh: downloading %s from %s\n' "$ARCHIVE" "$URL" >&2
curl -fsSL --max-filesize "$SQUAD_FOB_CI_MAX_BYTES" "$URL" -o "$TMP/$ARCHIVE" \
  || die "download failed for $URL (bounded at $SQUAD_FOB_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the FOB archive"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ARCHIVE (expected $SHA256, got $ACTUAL_SHA256)"

tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
# Archive layout: a single `fob` binary at the archive root (verified for v2.0.1).
if [ -f "$TMP/fob" ]; then
  BIN="$TMP/fob"
elif [ -f "$TMP/fob-v${SQUAD_FOB_CI_VERSION}/fob" ]; then
  BIN="$TMP/fob-v${SQUAD_FOB_CI_VERSION}/fob"
else
  BIN=$(find "$TMP" -type f -name fob | head -n 1)
  [ -n "$BIN" ] || die "archive $ARCHIVE did not contain a fob binary"
fi

mkdir -p "$DESTINATION"
install -m 0755 "$BIN" "$DESTINATION/fob"

installed_version=$("$DESTINATION/fob" --version 2>/dev/null | tr -d '[:space:]')
# fob prints "v2.0.1" (leading v) on --version.
case "$installed_version" in
  "v${SQUAD_FOB_CI_VERSION}"|"${SQUAD_FOB_CI_VERSION}") ;;
  *)
    die "installed fob version is '${installed_version:-<empty>}', expected exact pin v${SQUAD_FOB_CI_VERSION}"
    ;;
esac

printf 'sq-install-fob.sh: installed fob %s to %s\n' \
  "$installed_version" "$DESTINATION/fob" >&2
"$DESTINATION/fob" --version
