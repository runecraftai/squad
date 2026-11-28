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
#   ./install.sh --uninstall  remove the copy or link it created, plus the editor
#                             files the app regenerates beside a copy, and nothing else
#   ./install.sh --print      print the target path, then exit
#   ./install.sh --help       print this usage
#
# App home is $HERDR_APP_HOME, else $HOME/.config/herdr-app.
# A copy is owned by the marker file .squad-board-install, which is written last,
# after main.js and mod.json, so an interrupted copy never carries one. Installing
# over an existing folder and --uninstall both require that marker, and both
# refuse a folder holding any other entry; the refusal names the manual removal
# (delete the folder, then install). The script is idempotent: a second run of the
# same mode changes nothing and exits 0.
set -euo pipefail

NAME=squad-board
SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_HOME="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
TARGET="$APP_HOME/mods/$NAME"
FILES=(main.js mod.json)
# `herdr-app check` writes these beside any mod folder it validates; the app
# regenerates them, so they are as much the installer's to remove as its copies.
GENERATED=(gpui-kit.d.ts jsconfig.json)
MARKER=.squad-board-install
OWNED=("${FILES[@]}" "${GENERATED[@]}" "$MARKER")
MODE="copy"
ACTION="install"

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# Print the physical directory <path> resolves to, or fail when it is not one.
physical_dir() {
  (cd -P "$1" 2>/dev/null && pwd -P)
}

# True when the target is a link this folder created. The comparison is
# physical on both sides and uses only `cd -P`/`pwd -P`, so it works on macOS,
# on a checkout reached through a symlink, and when the link dangles.
is_our_link() {
  [ -L "$TARGET" ] || return 1
  local resolved
  resolved="$(physical_dir "$TARGET")" || return 1
  [ "$resolved" = "$SELF_DIR" ]
}

# True when <name> is an entry this script or `herdr-app check` writes.
is_known_file() {
  local name=$1 known
  for known in "${OWNED[@]}"; do
    [ "$name" = "$known" ] && return 0
  done
  return 1
}

# Print the entries of <dir> that neither this script nor `herdr-app check` wrote.
strays() {
  local dir=$1 entry
  while IFS= read -r entry; do
    is_known_file "${entry##*/}" || printf '%s\n' "${entry##*/}"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)
}

has_marker() {
  [ -f "$1/$MARKER" ]
}

write_marker() {
  printf 'squad-board: this folder was copied by herdr-mods/squad-board/install.sh\n' >"$1/$MARKER"
}

do_print() {
  printf '%s\n' "$TARGET"
}

do_uninstall() {
  local file stray
  if is_our_link; then
    rm "$TARGET"
    printf 'removed link %s\n' "$TARGET"
    return
  fi
  if [ -L "$TARGET" ]; then
    die "refusing to remove $TARGET: it links to $(readlink "$TARGET"), not to this folder; delete the link by hand if you are sure"
  fi
  if [ ! -e "$TARGET" ]; then
    printf 'nothing to remove: %s does not exist\n' "$TARGET"
    return
  fi
  if [ ! -d "$TARGET" ]; then
    die "refusing to remove $TARGET: it is not the folder this script installed; delete it by hand if you are sure"
  fi
  if ! has_marker "$TARGET"; then
    die "refusing to remove $TARGET: it has no $MARKER from this script; delete the folder by hand if you are sure, then install"
  fi
  stray="$(strays "$TARGET")"
  if [ -n "$stray" ]; then
    die "refusing to remove $TARGET: it also holds files this script did not write: ${stray//$'\n'/ }; delete the folder by hand if you are sure, then install"
  fi
  for file in "${OWNED[@]}"; do
    rm -f "$TARGET/$file"
  done
  printf 'removed the mod files from %s\n' "$TARGET"
  if rmdir "$TARGET" 2>/dev/null; then
    printf 'removed %s\n' "$TARGET"
  else
    printf 'left %s in place: it still holds files this script did not write\n' "$TARGET"
  fi
}

do_install() {
  local file stray
  mkdir -p "$APP_HOME/mods"
  if is_our_link; then
    printf 'already linked: %s\n' "$TARGET"
  elif [ -L "$TARGET" ]; then
    die "refusing to replace $TARGET: it links to $(readlink "$TARGET"); delete the link by hand if you are sure"
  elif [ -d "$TARGET" ]; then
    if ! has_marker "$TARGET"; then
      die "refusing to overwrite $TARGET: it has no $MARKER from this script; delete the folder by hand if you are sure, then install"
    fi
    stray="$(strays "$TARGET")"
    if [ -n "$stray" ]; then
      die "refusing to overwrite $TARGET: it also holds files this script did not write: ${stray//$'\n'/ }; delete the folder by hand if you are sure, then install"
    fi
    if [ "$MODE" = link ]; then
      for file in "${OWNED[@]}"; do
        rm -f "$TARGET/$file"
      done
      rmdir "$TARGET" ||
        die "refusing to replace $TARGET: it still holds files this script did not write"
      ln -s "$SELF_DIR" "$TARGET"
      printf 'linked %s -> %s\n' "$TARGET" "$SELF_DIR"
    else
      rm -f "$TARGET/$MARKER"
      cp "${FILES[@]/#/$SELF_DIR/}" "$TARGET/"
      write_marker "$TARGET"
      printf 'updated copy %s\n' "$TARGET"
    fi
  elif [ "$MODE" = link ]; then
    ln -s "$SELF_DIR" "$TARGET"
    printf 'linked %s -> %s\n' "$TARGET" "$SELF_DIR"
  else
    mkdir -p "$TARGET"
    cp "${FILES[@]/#/$SELF_DIR/}" "$TARGET/"
    write_marker "$TARGET"
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
