#!/usr/bin/env bash
# Behavior tests for bin/sq-window-state.sh - the per-window tmux sidebar
# truth publisher.
#
# The script derives each tmux task window's current state through the
# authoritative reconciler (bin/sq-crew-state.sh) and publishes one TSV line
# per window. These cases pin the derivation and file contract hermetically,
# with a fake reconciler answering from a fixture map and throwaway state
# dirs:
#   (a) only tmux-backend tasks with a recorded window= are published (orca,
#       herdr, no-window, and symlinked metas are excluded)
#   (b) the crew-state verb -> sidebar label translation is exact for every
#       verb (working/parked/blocked/done/paused/failed/unknown)
#   (c) detail prose is sanitized (tabs and newlines never leak into the TSV);
#       a reconciler line outside the known verb set is relayed with an
#       unknown label; a failed reconciler call is still published as unknown
#   (d) output is deterministic: sorted by window target
#   (e) publish writes the file atomically, byte-identical to list, with no
#       temp leftovers, and is idempotent
#   (f) an empty state dir publishes an empty file
#   (g) an unknown or missing subcommand fails closed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WS="$ROOT/bin/sq-window-state.sh"
TMP_ROOT=$(fm_test_tmproot sq-window-state)
FIXTURE="$TMP_ROOT/crew-state.fixture"

# Fake reconciler: answers one "state: <verb> · source: status-log · <detail>"
# line per task from SQUAD_FAKE_CREW_STATE (a "<id>\t<verb>\t<detail>" map);
# an unknown id exits non-zero, like the real binary failing. The <NL> and
# <TAB> tokens let a fixture inject a real newline or tab into detail so the
# sanitization path is driven with real control characters.
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

# Real meta shape: window= first, optional backend=, then the rest.
write_meta() {  # <state-dir> <id> [backend] [window]; window defaults to squad:sq-<id>
  local dir=$1 id=$2 backend=${3:-} window
  if [ "$#" -ge 4 ]; then window=$4; else window="squad:sq-$id"; fi
  {
    if [ -n "$window" ]; then printf 'window=%s\n' "$window"; fi
    [ -n "$backend" ] && printf 'backend=%s\n' "$backend"
    printf 'worktree=/tmp/wt-%s\n' "$id"
  } > "$dir/$id.meta"
}

write_fixture() {  # <id> <verb> [detail]
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$FIXTURE"
}

run_list_in() {  # <state-dir>
  SQUAD_STATE_OVERRIDE="$1" SQUAD_CREW_STATE_BIN="$FAKE" \
    SQUAD_FAKE_CREW_STATE="$FIXTURE" "$WS" list
}

run_publish_in() {  # <state-dir>
  SQUAD_STATE_OVERRIDE="$1" SQUAD_CREW_STATE_BIN="$FAKE" \
    SQUAD_FAKE_CREW_STATE="$FIXTURE" "$WS" publish
}

assert_eq() {  # <label> <actual> <expected>
  local label=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label: got [$(printf '%s' "$actual" | tr '\n' '|')], want [$(printf '%s' "$expected" | tr '\n' '|')]"
  fi
}

# (a) only tmux-backend tasks with a recorded window are published
S1="$TMP_ROOT/state-a"; mkdir -p "$S1"
write_meta "$S1" alpha "" "squad:sq-alpha"
write_meta "$S1" orca orca "term-1"
write_meta "$S1" herdr herdr "herdr:pane"
write_meta "$S1" nowin tmux ""
write_fixture alpha working "doing stuff"
write_fixture orca working "ignored"
ln -s alpha.meta "$S1/evil.meta"
assert_eq "publishes only tmux windows with window=" "$(run_list_in "$S1")" \
  "squad:sq-alpha	alpha	working	working	doing stuff"

# (b) verb -> label translation is exact for every verb
S2="$TMP_ROOT/state-b"; mkdir -p "$S2"
write_meta "$S2" m1; write_fixture m1 working "w"
write_meta "$S2" m2; write_fixture m2 parked "p"
write_meta "$S2" m3; write_fixture m3 blocked "b"
write_meta "$S2" m4; write_fixture m4 "done" "d"
write_meta "$S2" m5; write_fixture m5 paused "x"
write_meta "$S2" m6; write_fixture m6 failed "f"
write_meta "$S2" m7; write_fixture m7 unknown "u"
expected=$(printf '%s\n' \
  "squad:sq-m1	m1	working	working	w" \
  "squad:sq-m2	m2	awaiting-decision	parked	p" \
  "squad:sq-m3	m3	blocked	blocked	b" \
  "squad:sq-m4	m4	done	done	d" \
  "squad:sq-m5	m5	idle	paused	x" \
  "squad:sq-m6	m6	failed	failed	f" \
  "squad:sq-m7	m7	unknown	unknown	u")
assert_eq "label mapping for every verb" "$(run_list_in "$S2")" "$expected"

# (c) detail sanitized; out-of-set verbs relayed with unknown label; a failed
# reconciler call still publishes an unknown row
S3="$TMP_ROOT/state-c"; mkdir -p "$S3"
write_meta "$S3" t1; write_fixture t1 working "line1<NL>with<TAB>tab"
write_meta "$S3" t2; write_fixture t2 broken "junk"
write_meta "$S3" t3
write_meta "$S3" t4; write_fixture t4 working NODETAIL
expected=$(printf '%s\n' \
  "squad:sq-t1	t1	working	working	line1 with tab" \
  "squad:sq-t2	t2	unknown	broken	junk" \
  "squad:sq-t3	t3	unknown	unknown	" \
  "squad:sq-t4	t4	working	working	")
assert_eq "detail sanitized and unknown rows kept" "$(run_list_in "$S3")" "$expected"

# (d) deterministic sort by window target
S4="$TMP_ROOT/state-d"; mkdir -p "$S4"
write_meta "$S4" omega; write_fixture omega working "o"
write_meta "$S4" delta; write_fixture delta working "d"
expected=$(printf '%s\n' \
  "squad:sq-delta	delta	working	working	d" \
  "squad:sq-omega	omega	working	working	o")
assert_eq "output sorted by window" "$(run_list_in "$S4")" "$expected"

# (e) publish is atomic, byte-identical to list, idempotent, no tmp leftover
out_list=$(run_list_in "$S2")
run_publish_in "$S2"
assert_eq "publish writes list output" "$(<"$S2/window-states")" "$out_list"
if ls "$S2"/window-states.tmp.* >/dev/null 2>&1; then
  fail "publish left a temp file behind"
fi
pass "publish leaves no temp file"
run_publish_in "$S2"
assert_eq "publish is idempotent" "$(<"$S2/window-states")" "$out_list"

# (f) an empty state dir publishes an empty file
S5="$TMP_ROOT/state-empty"; mkdir -p "$S5"
run_publish_in "$S5"
[ -f "$S5/window-states" ] || fail "publish did not create the file"
[ ! -s "$S5/window-states" ] || fail "empty state dir published rows"
pass "empty state dir publishes an empty file"

# (g) unknown and missing subcommands fail closed
if SQUAD_STATE_OVERRIDE="$S2" "$WS" bogus >/dev/null 2>&1; then
  fail "unknown subcommand should exit non-zero"
fi
pass "unknown subcommand fails closed"
if SQUAD_STATE_OVERRIDE="$S2" "$WS" >/dev/null 2>&1; then
  fail "missing subcommand should exit non-zero"
fi
pass "missing subcommand fails closed"
