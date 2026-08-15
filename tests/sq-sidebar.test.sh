#!/usr/bin/env bash
# Behavior tests for bin/sq-sidebar.sh - the Squad ground-truth tmux sidebar.
#
# The sidebar is a CONSUMER of the ground-truth contract: it reads
# state/window-states (published by bin/sq-window-state.sh, whose own suite
# covers the derivation) plus state/<id>.meta and state/<id>.busy-gen, and
# renders two display lines per operator card. These cases pin that rendering
# and the tmux wiring hermetically, over fake state dirs with a fake
# reconciler and a fake tmux:
#   (a) publish + cards end-to-end: labels/details come from window-states
#       unchanged (no invented states), elapsed comes from the busy-gen mtime
#       (meta mtime fallback), model/effort come from meta
#   (b) render emits exactly two display lines per card so the click line
#       mapping stays exact, spinner frames are a pure function of the clock,
#       and long detail never wraps past the pane width
#   (c) click <line> maps to the card at ((line + 1) / 2) and selects its
#       window; empty/non-numeric/out-of-range lines are no-ops
#   (d) toggle opens a 25-wide left sidebar pane on first use and kills the
#       tagged pane on the second; the run loop self-tags the pane
#   (e) fail-closed: unknown subcommands and tmux-gated commands without
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
    printf 'window=Squad:%s\n' "$id"
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

# fake tmux that logs every invocation and serves a canned list-panes answer,
# so the toggle/click tmux wiring is asserted on the real command lines.
make_fake_tmux() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$FAKE_TMUX_LOG"
case "${1:-}" in
  list-panes) printf '%s\n' "${FAKE_TMUX_PANES:-}" ;;
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
write_fixture beta blocked "needs the decision"
write_fixture gamma "done" "landed"
now=$(date +%s)
touch -d "@$((now - 3661))" "$S1/alpha.busy-gen"
touch -d "@$((now - 60))" "$S1/beta.meta" # no busy-gen: meta mtime fallback
touch -d "@$((now - 30))" "$S1/gamma.meta" # no busy-gen: meta mtime fallback
SQUAD_STATE_OVERRIDE="$S1" SQUAD_CREW_STATE_BIN="$FAKE" \
  SQUAD_FAKE_CREW_STATE="$FIXTURE" "$SIDEBAR" publish

assert_eq "publish wrote window-states" \
  "$(cat "$S1/window-states")" \
  "Squad:alpha	alpha	working	working	building the tmux sidebar
Squad:beta	beta	blocked	blocked	needs the decision
Squad:gamma	gamma	done	done	landed"

# Elapsed assertions pin the clock with SQ_SIDEBAR_ELAPSED_NOW to the same
# epoch the mtimes were set from, so no second-boundary wall-clock race can
# flake them; the unpinned path is a plain `date +%s` read (see the script
# header) and the pinned expectations prove the exact HH:MM:SS formatting.
C1=$(SQUAD_STATE_OVERRIDE="$S1" SQ_SIDEBAR_ELAPSED_NOW="$now" "$SIDEBAR" cards)
assert_eq "cards row carries label/state/detail/model/effort and busy-gen elapsed" \
  "$(printf '%s\n' "$C1" | sed -n '1p')" \
  "Squad:alpha	alpha	working	working	building the tmux sidebar	01:01:01	claude	low"
assert_eq "cards falls back to meta mtime for elapsed without busy-gen" \
  "$(printf '%s\n' "$C1" | sed -n '2p')" \
  "Squad:beta	beta	blocked	blocked	needs the decision	00:01:00	grok	xhigh"
assert_eq "cards keeps empty model/effort fields when absent; fresh meta counts as 00:00:00" \
  "$(printf '%s\n' "$C1" | sed -n '3p')" \
  "Squad:gamma	gamma	done	done	landed	00:00:30		"

# A card whose meta and busy-gen are both gone renders no elapsed at all.
S4="$TMP_ROOT/state-d"; mkdir -p "$S4"
printf 'Squad:orphan\torphan\tworking\tworking\tno files left\n' > "$S4/window-states"
assert_eq "no busy-gen and no meta means no elapsed field" \
  "$(SQUAD_STATE_OVERRIDE="$S4" "$SIDEBAR" cards)" \
  "Squad:orphan	orphan	working	working	no files left			"

# --- (b) render: two lines per card, spinner, truncation -------------------

R1=$(SQUAD_STATE_OVERRIDE="$S1" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NOW=0 \
  SQ_SIDEBAR_ELAPSED_NOW="$now" "$SIDEBAR" render)
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
  "!  beta        00:01:00"
assert_eq "spinner frame is a pure function of the clock" \
  "$(SQUAD_STATE_OVERRIDE="$S1" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NOW=5 "$SIDEBAR" render | sed -n '1p' | cut -c1)" \
  "⠴"

# A long detail must never wrap past the pane width (keeps the click mapping).
S2="$TMP_ROOT/state-b"; mkdir -p "$S2"
printf 'Squad:long\tlong\tworking\tworking\t%s\n' \
  "$(printf 'x%.0s' $(seq 1 80))" > "$S2/window-states"
R2=$(SQUAD_STATE_OVERRIDE="$S2" SQ_SIDEBAR_NO_COLOR=1 SQ_SIDEBAR_NOW=0 "$SIDEBAR" render)
maxlen=$(printf '%s\n' "$R2" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')
[ "$maxlen" -le 24 ] || fail "render line exceeded the 24-char pane width: $maxlen"
pass "long detail is truncated to the pane width"

# Empty state dir renders the placeholder, still one display line.
S3="$TMP_ROOT/state-c"; mkdir -p "$S3"
assert_eq "no operators renders the placeholder" \
  "$(SQUAD_STATE_OVERRIDE="$S3" SQ_SIDEBAR_NO_COLOR=1 "$SIDEBAR" render)" \
  "-- no Squad operators --"

# --- (c) click maps a rendered line to its card's window -------------------

FB=$(make_fake_tmux "$TMP_ROOT")
export FAKE_TMUX_LOG="$TMP_ROOT/tmux.log"
: > "$FAKE_TMUX_LOG"
export PATH="$FB:$PATH"
click_in() {  # <line>
  SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" click "$1"
}
click_in 1
assert_eq "click line 1 focuses card 1's window" \
  "$(grep -c 'select-window -t Squad:alpha' "$FAKE_TMUX_LOG")" "1"
click_in 2 # second display line of the same card
assert_eq "click line 2 (same card) also focuses card 1" \
  "$(grep -c 'select-window -t Squad:alpha' "$FAKE_TMUX_LOG")" "2"
click_in 3
assert_eq "click line 3 focuses card 2's window" \
  "$(grep -c 'select-window -t Squad:beta' "$FAKE_TMUX_LOG")" "1"
click_in 0
click_in ""
click_in 999
assert_eq "out-of-range and empty clicks never invoke tmux" \
  "$(wc -l < "$FAKE_TMUX_LOG")" "3"
pass "click line mapping is exact and no-ops safely out of range"

# --- (d) toggle opens and closes the sidebar pane --------------------------

: > "$FAKE_TMUX_LOG"
FAKE_TMUX_PANES="" SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" toggle
assert_eq "toggle opens a left 25-wide sidebar pane running the loop" \
  "$(grep -c 'split-window -bh -l 25' "$FAKE_TMUX_LOG")" "1"
assert_grep "SQ_SIDEBAR_BASE=" "$FAKE_TMUX_LOG" "toggle passes the base to the loop"
assert_grep "sq-sidebar.sh run" "$FAKE_TMUX_LOG" "toggle starts the run loop command"
FAKE_TMUX_PANES="%9 1" SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" toggle
assert_eq "toggle closes the already-open sidebar pane" \
  "$(grep -c 'kill-pane -t %9' "$FAKE_TMUX_LOG")" "1"
pass "toggle opens on first use and closes on the second"

# --- (e) fail-closed paths -------------------------------------------------

if SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" bogus >/dev/null 2>&1; then
  fail "unknown subcommand must exit non-zero"
fi
pass "unknown subcommand exits non-zero"

NOBIN="$TMP_ROOT/nobin"; mkdir -p "$NOBIN"
if env PATH="$NOBIN" SQUAD_STATE_OVERRIDE="$S1" "$SIDEBAR" toggle >/dev/null 2>&1; then
  fail "toggle without tmux must exit non-zero"
fi
pass "toggle without tmux fails closed"
