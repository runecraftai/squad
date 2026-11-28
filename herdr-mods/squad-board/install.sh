#!/usr/bin/env bash
# install.sh - install or remove the squad-board mod from the Herdr app.
#
# The app loads a mod by NAME from its own mods directory, so the folder has to
# live at <app home>/mods/squad-board. This script touches exactly that one
# path and nothing else: no layout, no other mod, no app or core state.
#
# Usage:
#   ./install.sh              copy main.js and mod.json to <app home>/mods/squad-board
#   ./install.sh --link       symlink the target to this folder instead, so edits
#                             here reload live (not verified on herdr-app 0.1.18)
#   ./install.sh --uninstall  remove exactly what an install created
#   ./install.sh --print      print the target path, then exit
#   ./install.sh --help       print this usage
#
# App home is $HERDR_APP_HOME, else $HOME/.config/herdr-app.
# The script is idempotent: a second run of the same mode changes nothing and
# exits 0. It refuses rather than deleting or overwriting anything it cannot
# prove is its own copy.
set -euo pipefail

NAME=squad-board
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
TARGET="$APP_HOME/mods/$NAME"
FILES=(main.js mod.json)
MODE="copy"
ACTION="install"

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# True when <dir> holds byte-identical copies of the files this mod ships.
is_our_copy() {
  local dir=$1 file
  for file in "${FILES[@]}"; do
    cmp -s "$SELF_DIR/$file" "$dir/$file" || return 1
  done
}

is_our_link() {
  [ -L "$TARGET" ] && [ "$(readlink -f "$TARGET")" = "$SELF_DIR" ]
}

do_print() {
  printf '%s\n' "$TARGET"
}

do_uninstall() {
  if is_our_link; then
    rm "$TARGET"
    printf 'removed link %s\n' "$TARGET"
  elif [ -d "$TARGET" ]; then
    is_our_copy "$TARGET" || die "refusing to delete $TARGET: it is not a copy of this folder"
    rm -rf "$TARGET"
    printf 'removed copy %s\n' "$TARGET"
  else
    printf 'nothing to remove: %s does not exist\n' "$TARGET"
  fi
}

do_install() {
  mkdir -p "$APP_HOME/mods"
  if is_our_link; then
    printf 'already linked: %s\n' "$TARGET"
  elif [ -L "$TARGET" ]; then
    die "refusing to replace $TARGET: it links to $(readlink "$TARGET")"
  elif [ -d "$TARGET" ]; then
    is_our_copy "$TARGET" || die "refusing to overwrite $TARGET: it holds files this folder did not write"
    if [ "$MODE" = link ]; then
      rm -rf "$TARGET"
      ln -s "$SELF_DIR" "$TARGET"
      printf 'linked %s -> %s\n' "$TARGET" "$SELF_DIR"
    else
      cp "${FILES[@]/#/$SELF_DIR/}" "$TARGET/"
      printf 'updated copy %s\n' "$TARGET"
    fi
  elif [ "$MODE" = link ]; then
    ln -s "$SELF_DIR" "$TARGET"
    printf 'linked %s -> %s\n' "$TARGET" "$SELF_DIR"
  else
    mkdir -p "$TARGET"
    cp "${FILES[@]/#/$SELF_DIR/}" "$TARGET/"
    printf 'copied %s\n' "$TARGET"
  fi
  cat <<'EOF'

Open it as its own tab (the id comes from `herdr-app ls`):

  herdr-app do tab.new --space <space-id> --mod squad-board --name "Squad board"

Close it like any other tab:

  herdr-app do tab.close --id <tab-id>
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --link) MODE="link" ;;
    --copy) MODE="copy" ;;
    --uninstall) ACTION="uninstall" ;;
    --print) ACTION="print" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ -n "$APP_HOME" ] || die "app home is empty; set HERDR_APP_HOME or HOME"

case "$ACTION" in
  print) do_print ;;
  uninstall) do_uninstall ;;
  install) do_install ;;
esac
