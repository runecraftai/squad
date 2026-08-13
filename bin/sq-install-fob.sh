#!/usr/bin/env bash
# sq-install-fob.sh - build and install the vendored FOB binary.
#
# Builds packages/fob from this repo's source and installs the binary to the
# given destination. Replaces the previous pinned GitHub Release download:
# the OQ-03 release channel is still a boundary, and building the vendored
# fork locally is the interim install per the M6 decision. Same discipline as
# before - deterministic version stamping, post-install version gate, and
# fail-closed refusal on any missing prerequisite - and never a floating
# package-manager latest.
#
# Usage:
#   sq-install-fob.sh <destination-directory>
#
# Version metadata is derived with `git describe --tags --always --dirty`, so
# a local build reports the fork tag plus commit distance instead of "dev".
set -eu

die() {
  printf 'sq-install-fob.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: sq-install-fob.sh <destination-directory>}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FOB_SOURCE_DIR="$REPO_ROOT/packages/fob"
[ -f "$FOB_SOURCE_DIR/go.mod" ] || die "vendored fob source not found at $FOB_SOURCE_DIR"

command -v go >/dev/null 2>&1 \
  || die "go toolchain is required to build the vendored fob (see packages/fob/go.mod)"

# Proper version metadata: git describe falls back to the tag-less commit and
# never yields "dev", so a local build always reports a real version. A
# non-git checkout fails closed rather than installing a version-less build.
VERSION=$(cd "$REPO_ROOT" && git describe --tags --always --dirty 2>/dev/null || true)
[ -n "$VERSION" ] || die "cannot derive fob version metadata (not a git checkout of squad?)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sq-fob.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'sq-install-fob.sh: building fob %s from %s\n' "$VERSION" "$FOB_SOURCE_DIR" >&2
(cd "$FOB_SOURCE_DIR" && go build -ldflags "-X main.version=$VERSION" -o "$TMP/fob" .) \
  || die "go build of the vendored fob failed"

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/fob" "$DESTINATION/fob"

installed_version=$("$DESTINATION/fob" --version 2>/dev/null | tr -d '[:space:]')
# fob prints the stamped version on --version.
[ "$installed_version" = "$VERSION" ] \
  || die "installed fob version is '${installed_version:-<empty>}', expected '$VERSION'"

printf 'sq-install-fob.sh: installed fob %s to %s\n' \
  "$installed_version" "$DESTINATION/fob" >&2
"$DESTINATION/fob" --version
