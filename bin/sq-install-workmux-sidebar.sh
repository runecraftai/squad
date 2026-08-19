#!/usr/bin/env bash
# sq-install-workmux-sidebar.sh - build the vendored workmux sidebar binary.
#
# Builds packages/operation-board/sidebar (vendored workmux source, MIT) from
# this repo and installs the release binary to that tree's own
# target/release/ directory, the exact path tmux/workmux-sidebar.tmux runs.
# Same discipline as the fob build (bin/sq-install-fob.sh): deterministic
# version gate on the produced binary and fail-closed refusal on any missing
# prerequisite - and never a silent build. Run this on the commander's
# consent, or accept the bootstrap offer: bin/sq-bootstrap.sh prints
# "MISSING: workmux-sidebar (install: ...)" on tmux backends until the
# binary is built.
#
# Usage:
#   sq-install-workmux-sidebar.sh
#
# Requires a Rust toolchain (cargo) on PATH. The vendored crate pins its
# dependencies in packages/operation-board/sidebar/Cargo.lock; the first
# build needs network access to fetch crates and the patched crossterm
# dependency (see packages/operation-board/sidebar/Cargo.toml).
set -eu

die() {
  printf 'sq-install-workmux-sidebar.sh: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDEBAR_DIR="$REPO_ROOT/packages/operation-board/sidebar"
BIN_PATH="$SIDEBAR_DIR/target/release/workmux"

[ -f "$SIDEBAR_DIR/Cargo.toml" ] \
  || die "vendored workmux source not found at $SIDEBAR_DIR"

command -v cargo >/dev/null 2>&1 \
  || die "cargo is required to build the vendored workmux sidebar (see $SIDEBAR_DIR/Cargo.toml)"

# The vendored crate version is the version gate for the produced binary:
# a build must report exactly the source it was built from.
VERSION=$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$SIDEBAR_DIR/Cargo.toml" | head -n 1)
[ -n "$VERSION" ] \
  || die "cannot derive workmux version metadata from $SIDEBAR_DIR/Cargo.toml"

printf 'sq-install-workmux-sidebar.sh: building vendored workmux %s from %s\n' \
  "$VERSION" "$SIDEBAR_DIR" >&2
(cd "$SIDEBAR_DIR" && cargo build --release) \
  || die "cargo build of the vendored workmux failed"
[ -x "$BIN_PATH" ] || die "cargo build succeeded but no binary at $BIN_PATH"

installed_version=$("$BIN_PATH" --version 2>/dev/null | tr -d '[:space:]')
case "$installed_version" in
  *"$VERSION"*) : ;;
  *) die "built workmux version is '${installed_version:-<empty>}', expected 'workmux $VERSION'" ;;
esac

printf 'sq-install-workmux-sidebar.sh: installed workmux %s at %s\n' \
  "$VERSION" "$BIN_PATH" >&2
"$BIN_PATH" --version
