#!/usr/bin/env bash
# Behavior tests for the workmux sidebar integration.
#
# The workmux sidebar reads from Squad's ground-truth state directory.
# These tests verify:
#   (a) tmux/workmux-sidebar.tmux loads and binds C-M-s to workmux sidebar
#   (b) The plugin fails closed when workmux is not in PATH
#   (c) The plugin file is valid shell (shellcheck-clean)
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

# --- (c) plugin is shellcheck-clean ---

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$ROOT/tmux/workmux-sidebar.tmux"; then
    pass "shellcheck passes"
  else
    fail "shellcheck failed on tmux/workmux-sidebar.tmux"
  fi
else
  pass "shellcheck not available (skipped)"
fi
