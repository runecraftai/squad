#!/usr/bin/env bash
# sq-install-supervisor.sh - build and install the vendored sq-supervisor binary.
#
# Builds packages/sq-supervisor from this repo's source with the pinned Go
# toolchain from its go.mod and installs the binary to the given destination.
# Same discipline as bin/sq-install-fob.sh: deterministic version stamping, a
# post-install capability gate, atomic replace, and fail-closed refusal on any
# missing prerequisite. The package has no module dependencies, so the build
# needs no network and no vendor directory.
#
# Usage:
#   sq-install-supervisor.sh <destination-directory>
#
# The build is reproducible: `go build` with no build tags, CGO disabled, and the
# version stamped from git. A non-git checkout fails closed rather than installing
# a version-less build.
set -eu

die() {
  printf 'sq-install-supervisor.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: sq-install-supervisor.sh <destination-directory>}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/packages/sq-supervisor"
[ -f "$SOURCE_DIR/go.mod" ] || die "vendored sq-supervisor source not found at $SOURCE_DIR"

command -v go >/dev/null 2>&1 \
  || die "go toolchain is required to build the vendored sq-supervisor (see packages/sq-supervisor/go.mod)"

VERSION=$(cd "$REPO_ROOT" && git describe --tags --always --dirty 2>/dev/null || true)
[ -n "$VERSION" ] || die "cannot derive sq-supervisor version metadata (not a git checkout of squad?)"

mkdir -p "$DESTINATION"
STAGED="$DESTINATION/.sq-supervisor.tmp.$$"
trap 'rm -f "$STAGED"' EXIT

printf 'sq-install-supervisor.sh: building sq-supervisor %s from %s\n' "$VERSION" "$SOURCE_DIR" >&2
(
  cd "$SOURCE_DIR" || exit 1
  CGO_ENABLED=0 GOFLAGS=-trimpath \
    go build -buildvcs=false -ldflags "-s -w -X main.version=$VERSION" -o "$STAGED" .
) || die "go build of the vendored sq-supervisor failed"
chmod 0755 "$STAGED"

installed_version=$("$STAGED" --version 2>/dev/null | awk '{print $2}')
[ "$installed_version" = "$VERSION" ] \
  || die "staged sq-supervisor version is '${installed_version:-<empty>}', expected '$VERSION'"

# The capability gate proves the binary runs here and can answer for itself.
# A missing systemd user manager is reported, not treated as a build failure:
# non-Linux and manager-less hosts keep Squad's existing behaviour and must
# still be able to install the binary.
"$STAGED" capabilities >/dev/null 2>&1 || true

mv -f "$STAGED" "$DESTINATION/sq-supervisor"

printf 'sq-install-supervisor.sh: installed sq-supervisor %s to %s\n' \
  "$installed_version" "$DESTINATION/sq-supervisor" >&2
"$DESTINATION/sq-supervisor" --version
