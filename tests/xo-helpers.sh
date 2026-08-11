#!/usr/bin/env bash
# tests/xo-helpers.sh - shared fixtures and mocks for the XO
# suites (sq-xo-lifecycle-e2e and sq-xo-safety).
#
# These mocks encode XO-lifecycle behavior (fake tmux that logs window
# ops, fake fob that leases/returns homes, fake drill that records
# init/doctor), so they live here rather than in the generic tests/lib.sh. The
# generic git/identity/meta primitives come from lib.sh, which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake tmux (window ops are logged to SQUAD_FAKE_TMUX_LOG, list-windows returns
# SQUAD_FAKE_TMUX_WINDOW, capture-pane echoes SQUAD_FAKE_TMUX_CAPTURE) plus a fake
# fob (durable lease of SQUAD_FAKE_FOB_HOME, recording the lease holder
# to SQUAD_FAKE_FOB_LEASE_FILE; `return` removes the target and lease unless
# SQUAD_FAKE_FOB_RETURN_FAIL is set). Echoes the fakebin dir.
make_fake_tmux() {
  local dir=$1 fakebin capture
  fakebin=$(fm_fakebin "$dir")
  capture="$dir/pane.txt"
  printf 'idle prompt\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys|kill-window)
    printf '%s\n' "$*" >> "$SQUAD_FAKE_TMUX_LOG"
    exit 0
    ;;
  list-windows)
    if [ -n "${SQUAD_FAKE_TMUX_WINDOW:-}" ]; then
      printf '%s\n' "$SQUAD_FAKE_TMUX_WINDOW"
    fi
    exit 0
    ;;
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '0\n' ;;
      *) printf 'Squad\n' ;;
    esac
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "$SQUAD_FAKE_TMUX_LOG"
    cat "$SQUAD_FAKE_TMUX_CAPTURE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/fob" <<'SH'
#!/usr/bin/env bash
set -u
printf 'fob %s\n' "$*" >> "${SQUAD_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  get)
    # Durable lease: print only the worktree path to stdout (banners to stderr),
    # and record the lease holder so tests can assert it is set and later cleared.
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ -n "${SQUAD_FAKE_FOB_HOME:-}" ]; then
      mkdir -p "$SQUAD_FAKE_FOB_HOME"
      [ -n "${SQUAD_FAKE_FOB_LEASE_FILE:-}" ] && printf '%s\n' "$holder" > "$SQUAD_FAKE_FOB_LEASE_FILE"
      printf 'leased worktree for %s\n' "${holder:-unknown}" >&2
      printf '%s\n' "$SQUAD_FAKE_FOB_HOME"
    fi
    exit 0
    ;;
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    [ -z "${SQUAD_FAKE_FOB_RETURN_FAIL:-}" ] || exit 17
    [ -n "${SQUAD_FAKE_FOB_LEASE_FILE:-}" ] && rm -f "$SQUAD_FAKE_FOB_LEASE_FILE"
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  chmod +x "$fakebin/fob"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

# A fake drill that touches .drill-init / .drill-doctor markers.
make_fake_drill() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/drill" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .drill-init ;;
  doctor) touch .drill-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/drill"
  printf '%s\n' "$fakebin"
}

# A fake drill that records each "<pwd>\t<verb>" call to
# SQUAD_FAKE_DRILL_LOG and fails for the project named SQUAD_FAKE_DRILL_FAIL_PROJECT.
make_recording_drill() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/drill" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$SQUAD_FAKE_DRILL_LOG"
if [ "$(basename "$PWD")" = "${SQUAD_FAKE_DRILL_FAIL_PROJECT:-}" ]; then
  exit 1
fi
case "${1:-}" in
  init) touch .drill-init ;;
  doctor) touch .drill-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/drill"
  printf '%s\n' "$fakebin"
}

# Make a directory look like a minimal Squad home (AGENTS.md + bin/).
mark_Squad_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Squad\n' > "$home/AGENTS.md"
}

# A Squad home that is also a real git repo (so it can host detached
# worktrees for teardown/lease tests).
make_Squad_git_root() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Squad\n' > "$home/AGENTS.md"
  cat > "$home/bin/sq-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/bin/sq-guard.sh"
  git -C "$home" init -q
  git -C "$home" add AGENTS.md bin/sq-guard.sh
  git -C "$home" -c user.name='Squad Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# Scaffold a filled XO charter brief under <home>/data/<id>/brief.md.
# Args: home id charter [project...]
scaffold_XO_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  SQUAD_HOME="$home" SQUAD_XO_CHARTER="$charter" "$ROOT/bin/sq-brief.sh" "$id" --xo "$@" >/dev/null
}

# Make a directory look like a genuine seeded XO home (for handoff tests).
seed_XO_home_marker() {
  local home=$1 id=$2
  mark_Squad_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.sq-xo-home"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive. Returns 1 if it dies.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
