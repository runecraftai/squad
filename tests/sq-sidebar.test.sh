#!/usr/bin/env bash
# Behavior tests for bin/sq-sidebar.sh - the Squad ground-truth tmux sidebar.
#
# The sidebar is a CONSUMER of the ground-truth contract: it reads
# state/window-states (published by bin/sq-window-state.sh, whose own suite
# covers the derivation) plus state/<id>.meta, state/<id>.busy-gen, and
# state/<id>.status, and renders operator cards, a per-session rollup, and an
# INBOX section for operators needing attention. These cases pin the
# rendering and the tmux wiring hermetically, over fake state dirs with a fake
# reconciler and a fake tmux:
#   (a) publish + cards end-to-end: labels/details come from window-states
#       unchanged (no invented states), elapsed comes from the busy-gen mtime
#       (meta mtime fallback), model/effort come from meta
#   (b) render emits two display lines per card driven by configurable tokens,
#       spinner frames are a pure function of the clock, and long detail never
#       wraps past the pane width
#   (c) rollup + INBOX: the session rollup shows the worst (most-actionable)
#       state and attention count; attention operators sort above routine ones
#       under an INBOX header and a separator
#   (d) unread marker: a done card shows the unread glyph until ack writes
#       state/<id>.sidebar-ack; the badge and render both reflect it
#   (e) filter: SQ_SIDEBAR_FILTER restricts cards to one label; the filter
#       subcommand cycles the global option
#   (f) badge emits a colored state icon (plus unread glyph) for a window tab
#   (g) next-inbox cycles through the attention set (fake tmux logs the target)
#   (h) click <line> maps through the frame to the card's window; empty/non-
#       numeric/out-of-range lines are no-ops
#   (i) toggle opens a 25-wide left sidebar pane on first use and kills the
#       tagged pane on the second; the run loop self-tags the pane
#   (j) the .tmux loader binds the toggle/ack/filter/next-inbox keys, the
#       click action, and the window-tab badge format
#   (k) fail-closed: unknown subcommands and tmux-gated commands without
#       tmux exit non-zero with a stderr note
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIDEBAR="$ROOT/bin/sq-sidebar.sh"
TMP_ROOT=$(fm_test_tmproot sq-sidebar)
FIXTURE="$TMP_ROOT/crew-state.fixture"

# Fake reconciler, same shape as the sq-window-state suite: answers one
# "state: <verb> · source: status-log · <detail>" line per task from
# SQUAD_FAKE_CREW_STATE; an unknown id exits non-zero like the real binary.
FAKE="$TMP_ROOT/fake-crew-state"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
line=$(grep -m1 "^${id}"$'\t' "${SQUAD_FAKE_CREW_STATE:-}" 2>/dev/null) || exit 1
[ -n "$line" ] || exit 1
verb=$(printf '%s' "$line" | cut -f2)
detail=$(printf '%s' "$line" | cut -f3-)
detail=${detail//<NL>/$'\n'}
detail=${detail//<TAB>/$'\t'}
if [ "$detail" = NODETAIL ]; then
  printf 'state: %s · source: status-log\n' "$verb"
else
  printf 'state: %s · source: status-log · %s\n' "$verb" "$detail"
fi
SH
chmod +x "$FAKE"

write_meta() {  # <state-dir> <id> [model] [effort]
  local dir=$1 id=$2 model=${3:-} effort=${4:-}
  {
    printf 'window=Squad:sq-%s\n' "$id"
    [ -n "$model" ] && printf 'model=%s\n' "$model"
    [ -n "$effort" ] && printf 'effort=%s\n' "$effort"
  } > "$dir/$id.meta"
}

write_fixture() {  # <id> <verb> [detail]
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$FIXTURE"
}

assert_eq() {  # <label> <actual> <expected>
  local label=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label: got [$(printf '%s' "$actual" | tr '\n' '|')], want [$(printf '%s' "$expected" | tr '\n' '|')]"
  fi
}

# line1_of <glyph> <id>: the exact padded card line-1 shape (glyph left-padded
# to 2, a space, then the id left-padded to 12) so ordering assertions never
# hand-count spaces.
line1_of() {  # <glyph> <id>
  printf '%-2s %s' "$1" "$(printf '%-12s' "$2")"
}

# fake tmux that logs every invocation and serves a canned list-panes answer,
# so the toggle/click/next-inbox/filter tmux wiring is asserted on the real
# command lines. Supports global sidebar (list-windows, show-option for
# @sq-sidebar-global, set-hook, display-message).
make_fake_tmux() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$FAKE_TMUX_LOG"
case "${1:-}" in
  list-panes) printf '%s\n' "${FAKE_TMUX_PANES:-}" ;;
  list-windows) printf '%s\n' "${FAKE_TMUX_WINDOWS:-}" ;;
  display-message) printf '%s\n' "${FAKE_TMUX_DISPLAY:-}" ;;
  show-option) case "${3:-}" in
      @sq-sidebar-filter) printf '%s\n' "${FAKE_TMUX_FILTER:-}" ;;
      @sq-sidebar-no-rollup) printf '%s\n' "${FAKE_TMUX_NO_ROLLUP:-}" ;;
      @sq-sidebar-no-inbox) printf '%s\n' "${FAKE_TMUX_NO_INBOX:-}" ;;
      @sq-sidebar-global) printf '%s\n' "${FAKE_TMUX_GLOBAL:-}" ;;
      @sq-sidebar-layout) printf '%s\n' "${FAKE_TMUX_LAYOUT:-tiles}" ;;
      @sq-sidebar-selected) printf '%s\n' "${FAKE_TMUX_SELECTED:--1}" ;;
      @sq-sidebar-last-window) printf '%s\n' "${FAKE_TMUX_LAST_WINDOW:-}" ;;
      *) printf '%s\n' "" ;;
    esac ;;
  set-option) ;; # accept all set-option calls silently
  set-hook) ;; # accept all set-hook calls silently
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# --- (a) publish + cards end-to-end ----------------------------------------

S1="$TMP_ROOT/state-a"; mkdir -p "$S1"
write_meta "$S1" alpha claude low
write_meta "$S1" beta grok xhigh
write_meta "$S1" gamma
write_fixture alpha working "building the tmux sidebar"
write_fixture beta paused "external wait"
write_fixture gamma "done" "landed"
now=$(date +%s)
touch -d "@$((now - 3661))" "$S1/alpha.busy-gen"
touch -d "@$((now - 60))" "$S1/beta.meta"
touch -d "@$((now - 30))" "$S1/gamma.meta"
SQUAD_STATE_OVERRIDE="$S1" SQUAD_CREW_STATE_BIN="$FAKE" \
  SQUAD_FAKE_CREW_STATE="$FIXTURE" "$SIDEBAR" publish

assert_eq "publish wrote window-states" \
  "$(cat "$S1/window-states")" \
  "Squad:sq-alpha	alpha	working	working	building the tmux sidebar
Squad:sq-beta	beta	idle	paused	external wait
Squad:sq-gamma	gamma	done	done	landed"

C1=$(SQUAD_STATE_OVERRIDE="$S1" SQ_SIDEBAR_ELAPSED_NOW="$now" "$SIDEBAR" cards)
assert_eq "cards row carries label/state/detail/model/effort and busy-gen elapsed" \
  "$(printf '%s\n' "$C1" | sed -n '1p')" \
  "Squad:sq-alpha	alpha	working	working	building the tmux sidebar	01:01:01	claude	low"
assert_eq "cards falls back to meta mtime for elapsed without busy-gen" \
  "$(printf '%s\n' "$C1" | sed -n '2p')" \
  "Squad:sq-beta	beta	idle	paused	external wait	00:01:00	grok	xhigh"
assert_eq "cards keeps empty model/effort fields when absent; fresh meta counts as 00:00:30" \
  "$(printf '%s\n' "$C1" | sed -n '3p')" \
  "Squad:sq-gamma	gamma	done	done	landed	00:00:30		"

# A card whose meta and busy-gen are both gone renders no elapsed at all.
S4="$TMP_ROOT/state-d"; mkdir -p "$S4"
printf 'Squad:orphan\torphan\tworking\tworking\tno files left\n' > "$S4/window-states"
assert_eq "no busy-gen and no meta means no elapsed field" \
  "$(SQUAD_STATE_OVERRIDE="$S4" "$SIDEBAR" cards)" \
  "Squad:orphan	orphan	working	working	no files left			"

# --- (b) render: two lines per card, tokens, spinner, truncation -----------
# Rollup and INBOX are disabled here so the card rendering is isolated.

R1=$(SQUAD_STATE_OVERRIDE="$S1" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NO_ROLLUP=1 \
  SQ_SIDEBAR_NO_INBOX=1 SQ_SIDEBAR_NOW=0 SQ_SIDEBAR_ELAPSED_NOW="$now" "$SIDEBAR" render)
assert_eq "render emits exactly two display lines per card" \
  "$(printf '%s\n' "$R1" | wc -l | tr -d ' ')" "6"
assert_eq "line 1 carries glyph, id, and elapsed" \
  "$(printf '%s\n' "$R1" | sed -n '1p')" \
  "⠋ alpha       01:01:01"
assert_eq "line 2 carries label and detail" \
  "$(printf '%s\n' "$R1" | sed -n '2p')" \
  "working building the tmu"
assert_eq "non-working cards use a static glyph" \
  "$(printf '%s\n' "$R1" | sed -n '3p')" \
  "-  beta        00:01:00"
# gamma is done and unacknowledged, so the unread glyph trails its line 1.
assert_eq "done card without an ack marker shows the unread glyph" \
  "$(printf '%s\n' "$R1" | sed -n '5p')" \
  "✓ gamma       00:00:30●"
# The spinner frame must be a pure function of the clock: NOW=5 selects the
# fifth frame (⠴), the same card row the NOW=0 case above renders as ⠋. The
# whole line is compared (never cut -c1, which is byte-based under a POSIX
# locale and would slice the multibyte braille glyph in CI's C-locale runner).
assert_eq "spinner frame is a pure function of the clock" \
  "$(SQUAD_STATE_OVERRIDE="$S1" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NO_ROLLUP=1 \
    SQ_SIDEBAR_NO_INBOX=1 SQ_SIDEBAR_NOW=5 SQ_SIDEBAR_ELAPSED_NOW="$now" "$SIDEBAR" render | sed -n '1p')" \
  "⠴ alpha       01:01:01"

# The card templates are configurable: a custom line 1 drops id/elapsed in
# favor of the raw state verb and the model tag.
RC=$(SQUAD_STATE_OVERRIDE="$S1" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NO_ROLLUP=1 \
  SQ_SIDEBAR_NO_INBOX=1 SQ_SIDEBAR_NOW=0 SQ_SIDEBAR_LINE1='{glyph} {state} {model}' \
  "$SIDEBAR" render | sed -n '1p')
assert_eq "card line 1 honors a custom token template" "$RC" "⠋ working claude"

# A long detail must never wrap past the pane width (keeps the click mapping).
S2="$TMP_ROOT/state-b"; mkdir -p "$S2"
printf 'Squad:sq-long\tlong\tworking\tworking\t%s\n' \
  "$(printf 'x%.0s' $(seq 1 80))" > "$S2/window-states"
R2=$(SQUAD_STATE_OVERRIDE="$S2" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NO_ROLLUP=1 \
  SQ_SIDEBAR_NO_INBOX=1 SQ_SIDEBAR_NOW=0 "$SIDEBAR" render)
maxlen=$(printf '%s\n' "$R2" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')
[ "$maxlen" -le 24 ] || fail "render line exceeded the 24-char pane width: $maxlen"
pass "long detail is truncated to the pane width"

# Empty state dir renders the placeholder, still one display line.
S3="$TMP_ROOT/state-c"; mkdir -p "$S3"
assert_eq "no operators renders the placeholder" \
  "$(SQUAD_STATE_OVERRIDE="$S3" SQ_SIDEBAR_NO_COLOR=1 "$SIDEBAR" render)" \
  "-- no Squad operators --"

# --- (c) rollup + INBOX -----------------------------------------------------
# A multi-operator session mixes inbox and routine states: the rollup reports
# the worst state and attention count, and inbox cards sort above routine ones.

S5="$TMP_ROOT/state-e"; mkdir -p "$S5"
write_meta "$S5" alpha
write_meta "$S5" beta
write_meta "$S5" gamma
write_meta "$S5" delta
write_meta "$S5" eps
{
  printf 'Squad:sq-alpha\talpha\tworking\tworking\tbuilding\n'
  printf 'Squad:sq-beta\tbeta\tblocked\tblocked\tneeds the decision\n'
  printf 'Squad:sq-gamma\tgamma\tdone\tdone\tlanded\n'
  printf 'Squad:sq-delta\tdelta\tawaiting-decision\tparked\tgate ask-user\n'
  printf 'Squad:sq-eps\teps\tfailed\tfailed\trun cancelled\n'
} > "$S5/window-states"

R5=$(SQUAD_STATE_OVERRIDE="$S5" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NOW=0 \
  SQ_SIDEBAR_NO_ELAPSED=1 "$SIDEBAR" render)
# Line 1 is the session rollup: worst state failed, 5 ops, 3 needing attention.
assert_eq "rollup shows the session's worst state and operator count" \
  "$(printf '%s\n' "$R5" | sed -n '1p')" \
  "✗ Squad 5 ops"
assert_eq "INBOX header is pinned above the attention cards" \
  "$(printf '%s\n' "$R5" | sed -n '2p')" \
  "▸ INBOX"
# Attention cards sort most-actionable first: failed, blocked, awaiting-decision.
assert_eq "failed card sorts first in the INBOX" \
  "$(printf '%s\n' "$R5" | sed -n '3p')" \
  "$(line1_of '✗' eps)"
assert_eq "blocked card sorts second in the INBOX" \
  "$(printf '%s\n' "$R5" | sed -n '5p')" \
  "$(line1_of '!' beta)"
assert_eq "awaiting-decision card sorts third in the INBOX" \
  "$(printf '%s\n' "$R5" | sed -n '7p')" \
  "$(line1_of '?' delta)"

# Pin the elapsed clock for the inbox list: S5 has no busy-gen files, so
# elapsed comes from meta mtime, which the touch below fixes 5 seconds back.
touch -d "@$((now - 5))" "$S5"/*.meta

# The inbox subcommand exposes the same most-actionable-first list as raw rows
# (same 8-column shape as cards, with empty model/effort fields preserved).
IN5=$(SQUAD_STATE_OVERRIDE="$S5" SQ_SIDEBAR_ELAPSED_NOW="$now" "$SIDEBAR" inbox)
EXPECTED_IN5=$(printf 'Squad:sq-eps\teps\tfailed\tfailed\trun cancelled\t00:00:05\t\t\nSquad:sq-beta\tbeta\tblocked\tblocked\tneeds the decision\t00:00:05\t\t\nSquad:sq-delta\tdelta\tawaiting-decision\tparked\tgate ask-user\t00:00:05\t\t')
assert_eq "inbox lists attention operators most-actionable first" "$IN5" "$EXPECTED_IN5"

# NO_INBOX=1 reverts to plain window-order sorting: an attention card no
# longer sorts above a routine card (and no INBOX header is emitted).
RN=$(SQUAD_STATE_OVERRIDE="$S5" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NO_ROLLUP=1 \
  SQ_SIDEBAR_NO_INBOX=1 SQ_SIDEBAR_NOW=0 SQ_SIDEBAR_NO_ELAPSED=1 "$SIDEBAR" render)
assert_eq "NO_INBOX reverts to window order: the working card precedes the blocked one" \
  "$(printf '%s\n' "$RN" | sed -n '1p')" "$(line1_of '⠋' alpha)"
assert_eq "NO_INBOX keeps window order: the blocked card stays in window position" \
  "$(printf '%s\n' "$RN" | sed -n '3p')" "$(line1_of '!' beta)"

# With no attention operators there is no INBOX header and no separator.
S6="$TMP_ROOT/state-f"; mkdir -p "$S6"
{
  printf 'Squad:sq-alpha\talpha\tworking\tworking\tbuilding\n'
  printf 'Squad:sq-gamma\tgamma\tdone\tdone\tlanded\n'
} > "$S6/window-states"
R6=$(SQUAD_STATE_OVERRIDE="$S6" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NOW=0 \
  SQ_SIDEBAR_NO_ELAPSED=1 "$SIDEBAR" render)
assert_not_contains "$R6" "INBOX" "no INBOX header without attention operators"
assert_eq "rollup only, then routine cards" \
  "$(printf '%s\n' "$R6" | wc -l | tr -d ' ')" "5"

# --- (d) unread marker and ack --------------------------------------------
S7="$TMP_ROOT/state-g"; mkdir -p "$S7"
write_meta "$S7" done1
write_meta "$S7" done2
{
  printf 'Squad:sq-done1\tdone1\tdone\tdone\tlanded\n'
  printf 'Squad:sq-done2\tdone2\tdone\tdone\tlanded\n'
} > "$S7/window-states"
# done2 has a fresh ack marker; done1 does not.
touch "$S7/done2.sidebar-ack"

R7=$(SQUAD_STATE_OVERRIDE="$S7" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NO_ROLLUP=1 \
  SQ_SIDEBAR_NO_INBOX=1 SQ_SIDEBAR_NOW=0 SQ_SIDEBAR_NO_ELAPSED=1 "$SIDEBAR" render)
assert_eq "unacknowledged done card shows the unread glyph" \
  "$(printf '%s\n' "$R7" | sed -n '1p')" \
  "✓ done1       ●"
assert_eq "acknowledged done card hides the unread glyph" \
  "$(printf '%s\n' "$R7" | sed -n '3p')" \
  "✓ done2       "

assert_eq "ack writes a marker for every done task and reports the count" \
  "$(SQUAD_STATE_OVERRIDE="$S7" "$SIDEBAR" ack)" "2"
[ -f "$S7/done1.sidebar-ack" ] || fail "ack did not write done1's marker"
[ -f "$S7/done2.sidebar-ack" ] || fail "ack did not refresh done2's marker"
R7B=$(SQUAD_STATE_OVERRIDE="$S7" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NO_ROLLUP=1 \
  SQ_SIDEBAR_NO_INBOX=1 SQ_SIDEBAR_NOW=0 SQ_SIDEBAR_NO_ELAPSED=1 "$SIDEBAR" render)
assert_eq "after ack the unread glyph disappears" \
  "$(printf '%s\n' "$R7B" | sed -n '1p')" \
  "✓ done1       "

# --- (e) filter ------------------------------------------------------------
R8=$(SQUAD_STATE_OVERRIDE="$S5" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NOW=0 \
  SQ_SIDEBAR_NO_ELAPSED=1 SQ_SIDEBAR_FILTER=blocked "$SIDEBAR" render)
assert_contains "$R8" "beta" "filter shows the blocked card"
assert_not_contains "$R8" "eps" "filter hides the failed card"
assert_not_contains "$R8" "alpha" "filter hides the working card"

FB=$(make_fake_tmux "$TMP_ROOT")
export FAKE_TMUX_LOG="$TMP_ROOT/tmux.log"
: > "$FAKE_TMUX_LOG"
export PATH="$FB:$PATH"
SQUAD_STATE_OVERRIDE="$S5" "$SIDEBAR" filter >/dev/null
assert_eq "filter first cycle moves all -> awaiting-decision" \
  "$(grep -c 'set-option -g @sq-sidebar-filter awaiting-decision' "$FAKE_TMUX_LOG")" "1"

# --- (f) badge -------------------------------------------------------------
assert_eq "badge emits a colored blocked icon" \
  "$(SQUAD_STATE_OVERRIDE="$S5" "$SIDEBAR" badge 'Squad:sq-beta')" \
  "$(printf '\033[38;5;196m!\033[0m')"
assert_eq "badge for an unacknowledged done task prepends the unread glyph" \
  "$(SQUAD_STATE_OVERRIDE="$S5" "$SIDEBAR" badge 'Squad:sq-gamma')" \
  "$(printf '\033[38;5;45m●✓\033[0m')"
assert_eq "badge for an unknown window prints nothing" \
  "$(SQUAD_STATE_OVERRIDE="$S5" "$SIDEBAR" badge 'Squad:nope')" ""

# --- (g) next-inbox --------------------------------------------------------
: > "$FAKE_TMUX_LOG"
SQUAD_STATE_OVERRIDE="$S5" SQ_SIDEBAR_CURRENT='Squad:sq-eps' "$SIDEBAR" next-inbox
assert_eq "next-inbox from the first attention window advances to the second" \
  "$(grep -c 'select-window -t Squad:sq-beta' "$FAKE_TMUX_LOG")" "1"
: > "$FAKE_TMUX_LOG"
SQUAD_STATE_OVERRIDE="$S5" SQ_SIDEBAR_CURRENT='Squad:sq-delta' "$SIDEBAR" next-inbox
assert_eq "next-inbox from the last attention window wraps to the first" \
  "$(grep -c 'select-window -t Squad:sq-eps' "$FAKE_TMUX_LOG")" "1"
: > "$FAKE_TMUX_LOG"
SQUAD_STATE_OVERRIDE="$S5" SQ_SIDEBAR_CURRENT='Squad:sq-alpha' "$SIDEBAR" next-inbox
assert_eq "next-inbox from a non-attention window selects the first attention window" \
  "$(grep -c 'select-window -t Squad:sq-eps' "$FAKE_TMUX_LOG")" "1"

# --- (h) click maps through the frame --------------------------------------
: > "$FAKE_TMUX_LOG"
click_in() {  # <line>
  SQUAD_STATE_OVERRIDE="$S5" SQ_SIDEBAR_NOW=0 "$SIDEBAR" click "$1"
}
# With rollup + INBOX, line 1 is the rollup (non-clickable), line 3 is the
# failed card's first line.
click_in 1
click_in 2
assert_eq "click on rollup/header rows never selects a window" \
  "$(grep -c 'select-window' "$FAKE_TMUX_LOG")" "0"
click_in 3
click_in 4
assert_eq "click lines 3 and 4 (failed card) focus its window" \
  "$(grep -c 'select-window -t Squad:sq-eps' "$FAKE_TMUX_LOG")" "2"
click_in 0
click_in ""
click_in 999
assert_eq "out-of-range and empty clicks never select a window" \
  "$(grep -c 'select-window' "$FAKE_TMUX_LOG")" "2"
pass "click line mapping is exact and no-ops safely out of range"

# A click under an active filter must resolve through the same filtered frame
# the run loop renders (the click process reads the global filter option, the
# way run does each frame), not the unfiltered one. With the FAKE_TMUX_FILTER
# option answered as blocked, only the blocked card renders: line 3 is now the
# blocked card's first line, not the failed card's. The assert would fail on
# the unfiltered map, which puts the failed card on line 3.
: > "$FAKE_TMUX_LOG"
FAKE_TMUX_FILTER="blocked" click_in 3
assert_eq "click under a filter focuses the filtered frame's window" \
  "$(grep -c 'select-window -t Squad:sq-beta' "$FAKE_TMUX_LOG")" "1"
assert_eq "click under a filter no longer resolves to the unfiltered frame's row" \
  "$(grep -c 'select-window -t Squad:sq-eps' "$FAKE_TMUX_LOG")" "0"

# A click under a persisted layout toggle (NO_ROLLUP answered by the fake tmux,
# as run persists it each frame and renders with) must resolve through the same
# frame the run loop renders. With NO_ROLLUP the rollup row is gone, so the
# failed card's first line moves from line 3 to line 2; a click on line 2 thus
# selects sq-eps. On the default (rollup) frame line 2 is the INBOX header, a
# no-op, so the assert would fail without the click reading the toggle option.
: > "$FAKE_TMUX_LOG"
FAKE_TMUX_FILTER='' FAKE_TMUX_NO_ROLLUP=1 click_in 2
assert_eq "click under a persisted NO_ROLLUP resolves through the no-rollup frame" \
  "$(grep -c 'select-window -t Squad:sq-eps' "$FAKE_TMUX_LOG")" "1"
assert_eq "the NO_ROLLUP click does not auto-focus the rollup row's neighbour" \
  "$(grep -c 'select-window -t Squad:sq-beta' "$FAKE_TMUX_LOG")" "0"

# --- (i) toggle opens and closes the global sidebar ------------------------
# The new toggle is GLOBAL: it creates sidebar panes in ALL windows and
# installs a hook for new windows. The fake tmux must support list-windows
# and show-option for @sq-sidebar-global.

: > "$FAKE_TMUX_LOG"
FAKE_TMUX_PANES="" FAKE_TMUX_GLOBAL="" FAKE_TMUX_WINDOWS="Squad:0" \
  SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" toggle
assert_eq "toggle sets the global option" \
  "$(grep -c 'set-option -g @sq-sidebar-global 1' "$FAKE_TMUX_LOG")" "1"
assert_grep "set-hook -g after-new-window" "$FAKE_TMUX_LOG" "toggle installs the after-new-window hook"
assert_eq "toggle creates sidebar panes in each window" \
  "$(grep -c 'split-window.*-bh -l 25' "$FAKE_TMUX_LOG")" "1"
assert_grep "SQ_SIDEBAR_BASE=" "$FAKE_TMUX_LOG" "toggle passes the base to the pane"
assert_grep "sq-sidebar.sh run" "$FAKE_TMUX_LOG" "toggle starts the run loop command"
: > "$FAKE_TMUX_LOG"
FAKE_TMUX_PANES="" FAKE_TMUX_GLOBAL="" FAKE_TMUX_WINDOWS="Squad:0" \
  SQUAD_BASE="$TMP_ROOT/My Base" "$SIDEBAR" toggle
assert_grep "SQ_SIDEBAR_BASE=$TMP_ROOT/My Base" "$FAKE_TMUX_LOG" \
  "toggle passes a spaced base to the loop env unescaped"
assert_no_grep 'My\ Base' "$FAKE_TMUX_LOG" "toggle never %q-escapes the loop env base"
# Second toggle (global=1) should kill all panes and remove hook.
: > "$FAKE_TMUX_LOG"
FAKE_TMUX_PANES="%9 1" FAKE_TMUX_GLOBAL="1" SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" toggle
assert_eq "toggle closes all sidebar panes" \
  "$(grep -c 'kill-pane -t %9' "$FAKE_TMUX_LOG")" "1"
assert_grep "set-hook -gu after-new-window" "$FAKE_TMUX_LOG" "toggle removes the hook"
pass "toggle opens globally on first use and closes all on the second"

# --- (j) the .tmux loader binds keys and the badge format ------------------

: > "$FAKE_TMUX_LOG"
bash "$ROOT/tmux/sq-sidebar.tmux"
assert_grep "set-option -g @sq-sidebar-path" "$FAKE_TMUX_LOG" "loader records the tool path globally"
assert_grep "bind-key -n C-M-s run-shell" "$FAKE_TMUX_LOG" "loader binds the C-M-s toggle"
assert_grep "bind-key -n C-M-n run-shell" "$FAKE_TMUX_LOG" "loader binds the C-M-n next-inbox key"
assert_grep "bind-key -n C-M-a run-shell" "$FAKE_TMUX_LOG" "loader binds the C-M-a ack key"
assert_grep "bind-key -n C-M-f run-shell" "$FAKE_TMUX_LOG" "loader binds the C-M-f filter key"
assert_grep "bind-key -n C-M-d run-shell" "$FAKE_TMUX_LOG" "loader binds the C-M-d last-done key"
assert_grep "bind-key -n C-M-l run-shell" "$FAKE_TMUX_LOG" "loader binds the C-M-l last-agent key"
assert_grep "bind-key -n j if-shell" "$FAKE_TMUX_LOG" "loader binds sidebar-local j navigate"
assert_grep "bind-key -n k if-shell" "$FAKE_TMUX_LOG" "loader binds sidebar-local k navigate"
assert_grep "bind-key -n v if-shell" "$FAKE_TMUX_LOG" "loader binds sidebar-local v layout toggle"
assert_grep "bind-key -n q if-shell" "$FAKE_TMUX_LOG" "loader binds sidebar-local q quit"
assert_grep "q:@sq-sidebar-path" "$FAKE_TMUX_LOG" "bindings pass the tool path shell-quoted once at fire time"
assert_grep "bind-key -n MouseDown1Pane" "$FAKE_TMUX_LOG" "loader binds the click action"
assert_grep "e|+|:#{mouse_y},1" "$FAKE_TMUX_LOG" "click binding passes the 1-based mouse row"
assert_grep "q:@sq-sidebar-base" "$FAKE_TMUX_LOG" "click binding passes the base shell-quoted once"
assert_grep "window-status-format" "$FAKE_TMUX_LOG" "loader sets the window tab badge format"
assert_grep "window-status-current-format" "$FAKE_TMUX_LOG" "loader sets the current window tab badge format"
assert_grep 'badge "#{session_name}:#{window_name}"' "$FAKE_TMUX_LOG" \
  "badge format passes the session:window target"
assert_no_grep "mouse_line" "$FAKE_TMUX_LOG" "click binding no longer uses mouse_line"
pass "loader binds the keys, the click action, and the tab badge format"

# The bindings reference the tool path through the option at fire time, so
# a checkout path with spaces or shell specials survives run-shell's sh -c:
# the loader must record the literal path in the option and must not embed
# the raw path in any binding command.
SPACED="$TMP_ROOT/My Plugin \$x"
mkdir -p "$SPACED/tmux" "$SPACED/bin"
cp "$ROOT/tmux/sq-sidebar.tmux" "$SPACED/tmux/"
cp "$SIDEBAR" "$SPACED/bin/"
: > "$FAKE_TMUX_LOG"
bash "$SPACED/tmux/sq-sidebar.tmux"
assert_grep "set-option -g @sq-sidebar-path $SPACED/bin/sq-sidebar.sh" "$FAKE_TMUX_LOG" \
  "loader records a spaced tool path literally in the option"
assert_no_grep "$SPACED/bin/sq-sidebar.sh toggle" "$FAKE_TMUX_LOG" \
  "no binding embeds the raw tool path (fire-time quoting only)"
assert_no_grep "$SPACED/bin/sq-sidebar.sh click" "$FAKE_TMUX_LOG" \
  "click binding never embeds the raw tool path either"
assert_no_grep "$SPACED/bin/sq-sidebar.sh badge" "$FAKE_TMUX_LOG" \
  "badge format shells out through the quoted option, never the raw path"
pass "loader keeps the tool path literal in the option and out of the bindings"

# --- (k) fail-closed paths -------------------------------------------------

if SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" bogus >/dev/null 2>&1; then
  fail "unknown subcommand must exit non-zero"
fi
pass "unknown subcommand exits non-zero"

NOBIN="$TMP_ROOT/nobin"; mkdir -p "$NOBIN"
if env PATH="$NOBIN" SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" toggle >/dev/null 2>&1; then
  fail "toggle without tmux must exit non-zero"
fi
pass "toggle without tmux fails closed"
if env PATH="$NOBIN" SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" filter >/dev/null 2>&1; then
  fail "filter without tmux must exit non-zero"
fi
pass "filter without tmux fails closed"
if env PATH="$NOBIN" SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" next-inbox >/dev/null 2>&1; then
  fail "next-inbox without tmux must exit non-zero"
fi
pass "next-inbox without tmux fails closed"
