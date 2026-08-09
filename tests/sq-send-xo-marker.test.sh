#!/usr/bin/env bash
# sq-send from-squad marker for XO targets.
#
# An XO is itself a Squad, so a request relayed to it lands in its own
# chat - which the main Squad never reads (the only channel back is the terse
# status file). sq-send therefore prepends a from-squad marker
# (bin/sq-marker-lib.sh) when, and only when, the resolved target is a task
# selector whose meta records kind=xo, so the XO can recognize
# the request and route its reply via the status path. These tests pin that
# behavior hermetically (stubbed tmux, no real agent):
#   1. Exact-id and stable-label kind=xo selectors prepend the marker.
#   2. Exact-id and stable-label ordinary operator selectors stay unmarked.
#   3. Explicit endpoints stay unmarked, with or without matching local meta.
#   4. The --key path never carries the marker.
#   5. Direct commander text stays unmarked, and already-marked text is idempotent.
#   6. The marker is the label plus terminal-safe U+2063 INVISIBLE SEPARATOR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/sq-marker-lib.sh"

SEND="$ROOT/bin/sq-send.sh"

TMP_ROOT=$(fm_test_tmproot sq-send-marker)

# A fake tmux that (a) records the literal text of every `send-keys -l` to
# SQUAD_SEND_LOG and (b) lets sq-send's submit path reach a clean "empty" verdict.
# display-message yields a numeric cursor_y; capture-pane returns an empty
# bordered composer so fm_tmux_composer_state reads "empty" (submit landed) on the
# first Enter. Only the literal (-l) text is logged; Enter retries and --key sends
# are not, so the log holds exactly what was typed into the composer.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$SQUAD_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> -- <sq-send args...>
# Runs sq-send.sh with the stubs on PATH against the given home (which holds
# state/<id>.meta). SQUAD_ROOT_OVERRIDE points at the same non-repo home so
# sq-guard's tangle check stays silent; guard noise goes to stderr (discarded).
# SQUAD_SEND_SETTLE=0 keeps the run fast. Truncates the log first; returns sq-send's
# exit code.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    SQUAD_ROOT_OVERRIDE="$home" SQUAD_HOME="$home" SQUAD_SEND_LOG="$log" SQUAD_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

# setup_home <name> -> echoes a fresh home dir with an empty state/.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_XO_target_is_marked() {
  local dir fb log home rc got corr
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_XO_meta "$home/state/domain.meta" "$home" "sess:sq-domain"
  run_send "$fb" "$home" "$log" "sq-domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to an XO target should succeed"
  got=$(cat "$log")
  case "$got" in
    "$SQUAD_FROMFIRST_MARK"corr=[a-f0-9][a-f0-9]*) : ;;
    *) fail "XO send: literal text should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  case "$got" in
    *audit\ the\ build) : ;;
    *) fail "XO send lost the request body"$'\n'"$got" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/sq-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  [ -f "$(fm_pending_reply_path "$home/state" "$corr")" ] \
    || fail "marked XO send should create a parent pending-reply record"
  pass "sq-send: a kind=xo target gets the from-squad marker and corr prepended"
}

test_exact_XO_task_id_is_marked() {
  local dir fb log home rc got already_marked corr
  dir="$TMP_ROOT/sm-exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-exact)
  fm_write_XO_meta "$home/state/domain.meta" "$home" "sess:sq-domain"
  run_send "$fb" "$home" "$log" "domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to an exact XO task id should succeed"
  got=$(cat "$log")
  case "$got" in
    "$SQUAD_FROMFIRST_MARK"corr=[a-f0-9]*) : ;;
    *) fail "exact XO send: literal text should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/sq-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  # Resend with the same corr already present: embed is idempotent for that corr.
  already_marked="${SQUAD_FROMFIRST_MARK}corr=${corr} already routed"
  run_send "$fb" "$home" "$log" "domain" "$already_marked"; rc=$?
  expect_code 0 "$rc" "send of already-marked exact-id content should succeed"
  got=$(cat "$log")
  case "$got" in
    "${SQUAD_FROMFIRST_MARK}corr=${corr} already routed") : ;;
    *) fail "exact XO send altered already-correlated content"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -tx1)" ;;
  esac
  pass "sq-send: an exact kind=xo task id is marked with corr exactly once"
}

test_operator_target_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/crew"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home crew)
  fm_write_meta "$home/state/build.meta" \
    "window=sess:sq-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=strike" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "sq-build" "fix the test"; rc=$?
  expect_code 0 "$rc" "send to a stable-label operator target should succeed"
  got=$(cat "$log")
  [ "$got" = "fix the test" ] \
    || fail "stable-label operator send: expected bare text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  run_send "$fb" "$home" "$log" "build" "fix the exact test"; rc=$?
  expect_code 0 "$rc" "send to an exact-id operator target should succeed"
  got=$(cat "$log")
  [ "$got" = "fix the exact test" ] \
    || fail "exact-id operator send: expected bare text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "sq-send: exact-id and stable-label kind=strike selectors are sent unmarked"
}

test_explicit_window_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home explicit)
  # An explicit endpoint is not a task selector, so even matching XO
  # metadata must not make sq-send guess the caller's intent and mark it.
  fm_write_XO_meta "$home/state/win.meta" "$home" "other:win"
  run_send "$fb" "$home" "$log" "other:win" "ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with matching meta should succeed"
  got=$(cat "$log")
  [ "$got" = "ping" ] \
    || fail "explicit session:window send with meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"

  home=$(setup_home explicit-no-meta)
  run_send "$fb" "$home" "$log" "outside:window" "outside ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with no local meta should succeed"
  got=$(cat "$log")
  [ "$got" = "outside ping" ] \
    || fail "explicit session:window send without meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "sq-send: explicit endpoints stay unmarked with or without local metadata"
}

test_key_path_is_not_marked() {
  local dir fb log home rc
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home key)
  fm_write_XO_meta "$home/state/domain.meta" "$home" "sess:sq-domain"
  run_send "$fb" "$home" "$log" "sq-domain" --key Escape; rc=$?
  expect_code 0 "$rc" "--key send to an XO should succeed"
  [ ! -s "$log" ] \
    || fail "--key path logged a literal send (marker leaked into a keypress)"$'\n'"--- bytes ---"$'\n'"$(od -An -c "$log")"
  pass "sq-send: the --key path carries no marker (no literal text is typed)"
}

test_marker_is_label_plus_invisible_separator() {
  local separator hex
  separator=$(printf '\342\201\243')
  [ "$SQUAD_FROMFIRST_MARK" = "[sq-from-squad]$separator" ] \
    || fail "marker is not the expected label + U+2063 sequence"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$SQUAD_FROMFIRST_MARK" | od -An -tx1)"
  hex=$(printf '%s' "$SQUAD_FROMFIRST_MARK" | od -An -tx1 | tr -d ' \n')
  case "$hex" in
    *e281a3) : ;;
    *) fail "marker does not end in UTF-8 U+2063 bytes e2 81 a3; bytes were: $hex" ;;
  esac
  fm_message_from_Squad "${SQUAD_FROMFIRST_MARK}do the work" \
    || fail "detector should recognize a marked message"
  fm_message_from_Squad "do the work" \
    && fail "direct commander input must remain unmarked"
  fm_message_from_Squad "[sq-from-squad]do the work" \
    && fail "detector must reject the label without U+2063"
  pass "sq-send: the marker is '[sq-from-squad]' + terminal-safe U+2063, while direct commander text stays unmarked"
}

test_marker_transformation_is_idempotent() {
  local once twice
  fm_message_mark_from_Squad "do the work" once
  fm_message_mark_from_Squad "$once" twice
  [ "$once" = "$twice" ] \
    || fail "already-marked content was double-prefixed"$'\n'"--- once ---"$'\n'"$(printf '%s' "$once" | od -An -tx1)"$'\n'"--- twice ---"$'\n'"$(printf '%s' "$twice" | od -An -tx1)"
  [ "$once" = "${SQUAD_FROMFIRST_MARK}do the work" ] \
    || fail "marker transformation did not prefix bare content exactly once"
  pass "sq-marker: from-squad transformation is idempotent"
}

test_marked_send_preserves_trailing_newlines() {
  local dir fb log home rc payload got_hex body_hex corr
  dir="$TMP_ROOT/sm-trailing-newlines"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-trailing-newlines)
  fm_write_XO_meta "$home/state/domain.meta" "$home" "sess:sq-domain"
  payload=$'audit the build\n\n'
  run_send "$fb" "$home" "$log" "domain" "$payload"; rc=$?
  expect_code 0 "$rc" "marked send with trailing newlines should succeed"
  # shellcheck source=/dev/null
  . "$ROOT/bin/sq-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$(cat "$log")")
  [ -n "$corr" ] || fail "marked send should embed a corr id"
  # Body after marker+corr+space must preserve the original trailing newlines.
  body_hex=$(printf '%s' "$payload" | od -An -tx1 | tr -d ' \n')
  got_hex=$(od -An -tx1 "$log" | tr -d ' \n')
  case "$got_hex" in
    *"$body_hex") : ;;
    *) fail "marked send lost trailing newline body bytes: got $got_hex expected to end with $body_hex" ;;
  esac
  pass "sq-send: marked XO payload preserves trailing newline bytes"
}

test_XO_target_is_marked
test_exact_XO_task_id_is_marked
test_operator_target_is_not_marked
test_explicit_window_is_not_marked
test_key_path_is_not_marked
test_marker_is_label_plus_invisible_separator
test_marker_transformation_is_idempotent
test_marked_send_preserves_trailing_newlines
