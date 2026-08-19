#!/usr/bin/env bash
# Behavior tests for the workmux sidebar integration.
#
# The workmux sidebar reads from Squad's ground-truth state directory.
# These tests verify:
#   (a) tmux/workmux-sidebar.tmux loads and binds C-M-s to the vendored binary
#   (b) The plugin fails closed when the vendored binary is not built
#   (c) The plugin pins any visible SQUAD_BASE/SQUAD_HOME into the tmux
#       server's global environment (so the run-shell binding always sees
#       the Squad data source even after attachments from other shells)
#   (d) The plugin issues no set-environment when no Squad base is visible
#   (e) The plugin starts the publish driver when sq-window-state.sh exists
#   (f) The plugin file is valid shell (shellcheck-clean)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot workmux-sidebar)

# --- helpers ---

# Fake tmux that logs commands to a file. It exits 1 for list-sessions
# so the plugin's background publish loop terminates after its first
# liveness check instead of spinning forever against an always-0 exit.
FAKE_TMUX_LOG="$TMP_ROOT/tmux.log"
FAKE_TMUX_BIN="$TMP_ROOT/tmux"
cat > "$FAKE_TMUX_BIN" <<SH
#!/usr/bin/env bash
echo "tmux \$*" >> "$FAKE_TMUX_LOG"
case " \$* " in
  *" list-sessions "*) exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKE_TMUX_BIN"

# Create a fake workmux binary (the vendored sidebar binary under test)
FAKE_WORKMUX_BIN="$TMP_ROOT/workmux"
cat > "$FAKE_WORKMUX_BIN" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_WORKMUX_BIN"

# --- (a) tmux plugin loads and binds C-M-s to the vendored binary ---

rm -f "$FAKE_TMUX_LOG"
PATH="$TMP_ROOT:$PATH" SQUAD_WORKMUX_BIN="$FAKE_WORKMUX_BIN" bash "$ROOT/tmux/workmux-sidebar.tmux"

assert_grep "bind-key -n C-M-s run-shell \"$FAKE_WORKMUX_BIN\" sidebar" "$FAKE_TMUX_LOG" \
  "C-M-s is bound to the vendored sidebar binary"

# --- (b) plugin fails closed when the vendored binary is not built ---

if SQUAD_WORKMUX_BIN="$TMP_ROOT/not-built-workmux" bash "$ROOT/tmux/workmux-sidebar.tmux" 2>/dev/null; then
  fail "plugin should exit non-zero when the vendored binary is not built"
else
  pass "plugin exits non-zero when the vendored binary is not built"
fi

# The default repo-local path resolves next to the plugin; a fresh checkout
# has no built binary to run.
if [ ! -x "$ROOT/packages/operation-board/sidebar/target/release/workmux" ]; then
  if bash "$ROOT/tmux/workmux-sidebar.tmux" 2>/dev/null; then
    fail "plugin should exit non-zero when the default vendored path is not built"
  else
    pass "plugin exits non-zero when the default vendored path is not built"
  fi
fi

# --- (c) plugin pins visible Squad base into the server environment ---

rm -f "$FAKE_TMUX_LOG"
PATH="$TMP_ROOT:$PATH" SQUAD_WORKMUX_BIN="$FAKE_WORKMUX_BIN" SQUAD_BASE=/squad/base SQUAD_HOME=/squad/home \
  bash "$ROOT/tmux/workmux-sidebar.tmux"

assert_grep "set-environment -g SQUAD_BASE /squad/base" "$FAKE_TMUX_LOG" \
  "loader pins SQUAD_BASE into the server environment"
assert_grep "set-environment -g SQUAD_HOME /squad/home" "$FAKE_TMUX_LOG" \
  "loader pins SQUAD_HOME into the server environment"
assert_grep "bind-key -n C-M-s run-shell \"$FAKE_WORKMUX_BIN\" sidebar" "$FAKE_TMUX_LOG" \
  "C-M-s is still bound when a Squad base is pinned"

# --- (d) plugin issues no set-environment when no Squad base is visible ---

rm -f "$FAKE_TMUX_LOG"
PATH="$TMP_ROOT:$PATH" SQUAD_WORKMUX_BIN="$FAKE_WORKMUX_BIN" env -u SQUAD_BASE -u SQUAD_HOME \
  bash "$ROOT/tmux/workmux-sidebar.tmux"

assert_no_grep "set-environment" "$FAKE_TMUX_LOG" \
  "loader does not pin when no Squad base is set"

# --- (e) plugin starts publish driver when sq-window-state.sh exists ---

# Create a fake sq-window-state.sh that logs calls
FAKE_WS_DIR="$TMP_ROOT/squad-base/bin"
mkdir -p "$FAKE_WS_DIR"
FAKE_WS_LOG="$TMP_ROOT/ws-publish.log"
cat > "$FAKE_WS_DIR/sq-window-state.sh" <<SH
#!/usr/bin/env bash
echo "publish" >> "$FAKE_WS_LOG"
SH
chmod +x "$FAKE_WS_DIR/sq-window-state.sh"

rm -f "$FAKE_TMUX_LOG" "$FAKE_WS_LOG"
PATH="$TMP_ROOT:$PATH" SQUAD_WORKMUX_BIN="$FAKE_WORKMUX_BIN" SQUAD_BASE="$TMP_ROOT/squad-base" \
  bash "$ROOT/tmux/workmux-sidebar.tmux"

# Verify the publish loop was started (pid was set)
assert_grep "set-option -g @workmux_publish_pid" "$FAKE_TMUX_LOG" \
  "publish driver pid is registered"

# --- (f) plugin is shellcheck-clean ---

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$ROOT/tmux/workmux-sidebar.tmux"; then
    pass "shellcheck passes"
  else
    fail "shellcheck failed on tmux/workmux-sidebar.tmux"
  fi
else
  pass "shellcheck not available (skipped)"
fi
