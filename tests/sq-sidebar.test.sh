#!/usr/bin/env bash
# Behavior tests for the workmux sidebar integration.
#
# The workmux sidebar reads from Squad's ground-truth state directory.
# These tests verify:
#   (a) tmux/workmux-sidebar.tmux loads and binds C-M-s to workmux sidebar
#   (b) The plugin fails closed when workmux is not in PATH
#   (c) The plugin pins any visible SQUAD_BASE/SQUAD_HOME into the tmux
#       server's global environment (so the run-shell binding always sees
#       the Squad data source even after attachments from other shells)
#   (d) The plugin issues no set-environment when no Squad base is visible
#   (e) The plugin file is valid shell (shellcheck-clean)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot workmux-sidebar)

# --- helpers ---

# Fake tmux that logs commands to a file
FAKE_TMUX_LOG="$TMP_ROOT/tmux.log"
FAKE_TMUX_BIN="$TMP_ROOT/tmux"
cat > "$FAKE_TMUX_BIN" <<SH
#!/usr/bin/env bash
echo "tmux \$*" >> "$FAKE_TMUX_LOG"
exit 0
SH
chmod +x "$FAKE_TMUX_BIN"

# Create a fake workmux in PATH so the plugin loads
FAKE_WORKMUX_BIN="$TMP_ROOT/workmux"
cat > "$FAKE_WORKMUX_BIN" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_WORKMUX_BIN"

# --- (a) tmux plugin loads and binds C-M-s ---

rm -f "$FAKE_TMUX_LOG"
PATH="$TMP_ROOT:$PATH" bash "$ROOT/tmux/workmux-sidebar.tmux"

assert_grep "bind-key -n C-M-s run-shell workmux sidebar" "$FAKE_TMUX_LOG" \
  "C-M-s is bound to workmux sidebar"

# --- (b) plugin fails closed when workmux is missing ---

# Remove workmux from PATH by using empty dir
EMPTY_DIR="$TMP_ROOT/empty-bin"
mkdir -p "$EMPTY_DIR"

if PATH="$EMPTY_DIR" bash "$ROOT/tmux/workmux-sidebar.tmux" 2>/dev/null; then
  fail "plugin should exit non-zero when workmux is not found"
else
  pass "plugin exits non-zero when workmux is not found"
fi

# --- (c) plugin pins visible Squad base into the server environment ---

rm -f "$FAKE_TMUX_LOG"
PATH="$TMP_ROOT:$PATH" SQUAD_BASE=/squad/base SQUAD_HOME=/squad/home \
  bash "$ROOT/tmux/workmux-sidebar.tmux"

assert_grep "set-environment -g SQUAD_BASE /squad/base" "$FAKE_TMUX_LOG" \
  "loader pins SQUAD_BASE into the server environment"
assert_grep "set-environment -g SQUAD_HOME /squad/home" "$FAKE_TMUX_LOG" \
  "loader pins SQUAD_HOME into the server environment"
assert_grep "bind-key -n C-M-s run-shell workmux sidebar" "$FAKE_TMUX_LOG" \
  "C-M-s is still bound when a Squad base is pinned"

# --- (d) plugin issues no set-environment when no Squad base is visible ---

rm -f "$FAKE_TMUX_LOG"
PATH="$TMP_ROOT:$PATH" env -u SQUAD_BASE -u SQUAD_HOME \
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
PATH="$TMP_ROOT:$PATH" SQUAD_BASE="$TMP_ROOT/squad-base" \
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
