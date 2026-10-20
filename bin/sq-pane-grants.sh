#!/usr/bin/env bash
# sq-pane-grants.sh - show, grant, and verify exactly one TUIOS pane grant.
#
# Usage:
#   sq-pane-grants.sh show [<target>]
#   sq-pane-grants.sh grant respond <target>
#   sq-pane-grants.sh verify <target>
#
# <target> is a task id (resolved through state/<id>.meta, which must record
# backend=tuios) or an explicit <session>:<window> target. show without a
# target reports the grants of the pane this command runs in, which is the
# fast way to answer "does the pane that answers prompts hold respond?"; a
# caller that runs in no pane of the daemon is told so and given the target
# form to name instead.
#
# verify is the read-only gate that follows a grant: it exits 0 when the pane
# holds respond and non-zero otherwise, printing the person command to run, so a
# supervisor confirms the delegation landed and retries its key send instead of
# guessing. show, verify, and a refused grant all print that same command, with
# the resolved window id filled in and the wrapper named by absolute path, so it
# is copy-paste ready for the person's own shell outside TUIOS.
#
# Least privilege is the point, so this wrapper is not a TUIOS proxy:
#   - grant accepts exactly one grant name, `respond`, and ADDS it to what the
#     pane already holds. It never replaces a pane's grants, never grants
#     admin, read, write, fan, or none, and never addresses a whole session.
#   - A target is resolved and verified against the live window inventory
#     before the daemon is asked for anything, so an unknown, ambiguous, or
#     unreadable target fails closed with an actionable message.
#   - show is read-only.
#   - The grant is verified by re-reading the inventory instead of trusting the
#     daemon's success line.
#
# Authority (verified against TUIOS 0.9.1): the `respond` grant belongs to the
# pane that TYPES the answer, not to the blocked pane. Typing into a pane that
# waits on a prompt is refused for a caller that does not hold respond, `admin`
# includes read, write, and fan but never respond, and a pane can never give
# more than it holds. So a supervised pane can only be given respond by a
# caller that runs in no pane of that daemon (the person's own shell outside
# TUIOS), or by a pane that already holds it - one person delegation, which the
# delegated pane can then propagate. This wrapper never reaches around that
# rule: when the daemon refuses, it reports the refusal and the exact
# outside-pane command, and changes nothing.
#
# docs/tuios-backend.md owns the operator flow; the raw-session guard names this
# wrapper as the one sanctioned pane-grant path in its refusals.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"
STATE="${SQUAD_STATE_OVERRIDE:-$BASE/state}"
TUIOS_BIN="${SQUAD_TUIOS_BIN:-tuios}"

fm_pane_grants_usage() {
  cat >&2 <<'USAGE'
Usage: sq-pane-grants.sh show [<target>]
       sq-pane-grants.sh grant respond <target>
       sq-pane-grants.sh verify <target>

<target> is a task id (resolved through state/<id>.meta) or <session>:<window>.
Only the respond grant can be added, and only to that one pane.
verify exits non-zero when that pane does not hold respond.
USAGE
}

fm_pane_grants_fail() {  # <message...>
  printf 'error: %s\n' "$*" >&2
  exit 1
}

fm_pane_grants_refuse() {  # <message...>
  printf 'error: %s\n' "$*" >&2
  fm_pane_grants_usage
  exit 2
}

fm_pane_grants_meta_get() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# fm_pane_grants_resolve_target: set GRANT_SESSION and GRANT_WINDOW from a task
# id or an explicit <session>:<window>. A bare session name is never a target.
fm_pane_grants_resolve_target() {  # <raw-target>
  local raw=$1 meta backend target id
  GRANT_SESSION=
  GRANT_WINDOW=
  case "$raw" in
    *:*)
      GRANT_SESSION=${raw%%:*}
      GRANT_WINDOW=${raw#*:}
      [ -n "$GRANT_SESSION" ] && [ -n "$GRANT_WINDOW" ] \
        || fm_pane_grants_fail "target '$raw' is not <session>:<window>"
      case "$GRANT_WINDOW" in
        *:*) fm_pane_grants_fail "target '$raw' is not <session>:<window>: exactly one colon is allowed" ;;
      esac
      ;;
    *)
      id=$raw
      meta=$STATE/$id.meta
      if [ ! -f "$meta" ] && [ "${raw#sq-}" != "$raw" ] && [ -f "$STATE/${raw#sq-}.meta" ]; then
        id=${raw#sq-}
        meta=$STATE/$id.meta
      fi
      [ -f "$meta" ] \
        || fm_pane_grants_fail "unknown target '$raw': no $STATE/$raw.meta (pass a live task id or <session>:<window>, never a bare session)"
      backend=$(fm_pane_grants_meta_get "$meta" backend)
      [ "${backend:-tmux}" = tuios ] \
        || fm_pane_grants_fail "'$raw' records backend=${backend:-tmux}; pane grants apply only to TUIOS tasks"
      target=$(fm_pane_grants_meta_get "$meta" window)
      [ -n "$target" ] || fm_pane_grants_fail "'$meta' records no window= target"
      GRANT_SESSION=${target%%:*}
      GRANT_WINDOW=${target#*:}
      [ -n "$GRANT_SESSION" ] && [ -n "$GRANT_WINDOW" ] && [ "$GRANT_WINDOW" != "$target" ] \
        || fm_pane_grants_fail "'$meta' records window='$target', which is not <session>:<window>"
      ;;
  esac
}

fm_pane_grants_inventory() {  # <session> -> validated inventory on stdout
  local session=$1 out rc
  out=$("$TUIOS_BIN" list-windows --session "$session" --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] \
    || fm_pane_grants_fail "cannot read the TUIOS window inventory for session '$session': $(printf '%s' "$out" | head -n 1)"
  printf '%s' "$out" | jq -e '
    type == "object" and (.success != false) and ((.error // "") == "") and (.windows | type == "array")
  ' >/dev/null 2>&1 \
    || fm_pane_grants_fail "the TUIOS window inventory for session '$session' is unreadable: $(printf '%s' "$out" | head -c 200)"
  printf '%s' "$out"
}

fm_pane_grants_canonical_window() {  # <inventory> <window-ref> -> exact window id
  local inventory=$1 ref=$2 id available
  # A window record is identified by window_id, id, or a nested window.id, the
  # same three shapes the backend adapter's own inventory reader accepts.
  id=$(printf '%s' "$inventory" | jq -r --arg r "$ref" '
    def wid: (.window_id // .id // (if (.window | type) == "object" then .window.id else empty end))
      | select(type == "string" and length > 0);
    def winlabel: (.display_name // .name // .title)
      | select(type == "string" and length > 0);
    (.windows // []) as $w
    | ([ $w[] | select(wid == $r) | wid ] | first // "") as $exact
    | if $exact != "" then $exact
      else ([ $w[] | select((wid // "") | startswith($r)) | wid ] | unique) as $prefix
      | if ($prefix | length) == 1 then $prefix[0]
        else ([ $w[] | select((winlabel // "") == $r) | wid ] | unique) as $named
        | if ($named | length) == 1 then $named[0] else "" end
        end
      end')
  if [ -z "$id" ]; then
    available=$(printf '%s' "$inventory" | jq -r '[(.windows // [])[] | (.window_id // .id // empty)] | join(", ")' 2>/dev/null || true)
    fm_pane_grants_fail "session '$GRANT_SESSION' has no unambiguous window '$ref' (available: ${available:-none})"
  fi
  printf '%s' "$id"
}

# fm_pane_grants_explicit: what the inventory says a pane holds, as a record so
# an absent grants field is never confused with an explicitly empty grant set.
# Prints "explicit<TAB><csv>", "default<TAB>" when the pane holds the daemon
# default, or "missing<TAB>" when the window is no longer in the inventory.
fm_pane_grants_explicit() {  # <inventory> <window-id>
  printf '%s' "$1" | jq -r --arg w "$2" '
    def wid: (.window_id // .id // (if (.window | type) == "object" then .window.id else empty end));
    [ .windows[] | select(wid == $w) ] | first
    | if . == null then "missing\t"
      elif has("grants") then "explicit\t\((.grants // []) | join(","))"
      else "default\t" end'
}

fm_pane_grants_caller() {  # -> validated pane-grants payload on stdout
  local out
  out=$("$TUIOS_BIN" pane-grants --json 2>&1) \
    || fm_pane_grants_fail "cannot read this pane's grants: $(printf '%s' "$out" | head -n 1)"
  printf '%s' "$out" | jq -e '
    type == "object" and (.success != false) and ((.error // "") == "") and (.pane | type == "boolean")
  ' >/dev/null 2>&1 \
    || fm_pane_grants_fail "the TUIOS pane-grants payload is unreadable: $(printf '%s' "$out" | head -c 200)"
  printf '%s' "$out"
}

# fm_pane_grants_default_grants: the grants a pane without an explicit set
# inherits, as csv. An explicitly empty default is a real answer (the pane holds
# nothing), so only a payload with no default_grants field at all fails closed.
fm_pane_grants_default_grants() {  # [<validated pane-grants payload>]
  local out=${1:-} present mode
  [ -n "$out" ] || out=$(fm_pane_grants_caller)
  present=$(printf '%s' "$out" | jq -r 'if has("default_grants") then "yes" else "no" end' 2>/dev/null || true)
  if [ "$present" != yes ]; then
    mode=$(printf '%s' "$out" | jq -r 'if (.mode | type) == "string" then .mode else "unknown" end')
    fm_pane_grants_fail "the daemon reported no default_grants field (mode=${mode}), so the grants this pane already holds cannot be read; refusing to guess or replace them"
  fi
  # An empty list is the daemon saying "this pane holds nothing"; anything that
  # is not a list at all is unreadable and must not be read as empty.
  printf '%s' "$out" | jq -e '(.default_grants | type) == "array"' >/dev/null 2>&1 \
    || fm_pane_grants_fail 'the daemon reported default_grants in an unreadable shape; refusing to guess the grants this pane already holds'
  printf '%s' "$out" | jq -r '(.default_grants // []) | join(",")'
}

fm_pane_grants_with() {  # <csv> <grant> -> csv that holds both, order preserved
  local csv=$1 grant=$2
  case ",$csv," in
    *",$grant,"*) printf '%s' "$csv"; return 0 ;;
  esac
  printf '%s' "${csv:+$csv,}$grant"
}

# fm_pane_grants_read: resolve <target>, canonicalize its window, and set
# GRANT_SESSION, GRANT_WINDOW, GRANT_CSV (what the pane holds: its explicit
# grants, or the daemon default when it holds no explicit set), and
# GRANT_DECLARED. Read-only, and the one path show, verify, and grant share.
fm_pane_grants_read() {  # <target>
  local inventory record
  GRANT_CSV=
  GRANT_DECLARED=
  fm_pane_grants_resolve_target "$1"
  inventory=$(fm_pane_grants_inventory "$GRANT_SESSION")
  GRANT_WINDOW=$(fm_pane_grants_canonical_window "$inventory" "$GRANT_WINDOW")
  record=$(fm_pane_grants_explicit "$inventory" "$GRANT_WINDOW")
  case "$record" in
    explicit$'\t'*)
      GRANT_DECLARED=explicit
      GRANT_CSV=${record#*$'\t'}
      ;;
    default$'\t'*)
      GRANT_DECLARED=default
      GRANT_CSV=$(fm_pane_grants_default_grants)
      ;;
    *) fm_pane_grants_fail "$GRANT_SESSION:$GRANT_WINDOW is no longer in the window inventory; re-read the target" ;;
  esac
}

# fm_pane_grants_person_command: the exact copy-paste command that gives a pane
# the grant it needs. TUIOS accepts it only from a caller outside every pane, so
# the wrapper is named by absolute path and the resolved window id is filled in.
# This function is the command's owner. bin/sq-send.sh composes the same string
# without sourcing this script, and tests/sq-pane-grants.test.sh asserts the two
# outputs are identical, so a drift between them fails a test instead of reaching
# an operator.
fm_pane_grants_person_command() {  # <session>:<window>
  printf '%s/bin/sq-pane-grants.sh grant respond %s' "$ROOT" "$1"
}

fm_pane_grants_person_hint() {  # <session>:<window>
  if [ -n "${TUIOS_ENV:-}${TUIOS_PANE_ID:-}" ]; then
    printf 'hint: a pane can never give more than it holds, and admin never includes respond, so this delegation is the person'\''s once:\n' >&2
  else
    printf 'hint: TUIOS accepts this grant only from a caller that runs in no pane of the daemon:\n' >&2
  fi
  printf 'person command: %s\n' "$(fm_pane_grants_person_command "$1")" >&2
}

fm_pane_grants_show() {  # [<target>]
  local target=${1:-} out label='' grants declared
  if [ -z "$target" ]; then
    out=$(fm_pane_grants_caller)
    if [ "$(printf '%s' "$out" | jq -r '.pane')" != true ]; then
      # A caller outside every pane has no pane to read, so the daemon default
      # is never reported as if this caller's pane held it. Naming a target is
      # the only way to read grants from there.
      printf 'target: none (this command runs in no pane of the daemon)\n'
      printf 'note: there is no pane here to read; name one:\n'
      printf '  %s/bin/sq-pane-grants.sh show <session>:<window>\n' "$ROOT"
      return 0
    fi
    # A pane the daemon reports without both fields cannot be named, and a
    # person command naming a partial target would be rejected by this same
    # parser, so it is never printed.
    label=$(printf '%s' "$out" | jq -r '
      select((.session | type) == "string" and (.session | length) > 0)
      | select((.window | type) == "string" and (.window | length) > 0)
      | "\(.session):\(.window)"' 2>/dev/null || true)
    [ -n "$label" ] || printf 'target: unreadable (the daemon reported a pane without a session and window)\n'
    declared=$(printf '%s' "$out" | jq -r 'if .explicit == true then "explicit" else "default" end' 2>/dev/null || true)
    grants=$(printf '%s' "$out" | jq -r '(.grants // []) | join(",")' 2>/dev/null || true)
    [ -n "$grants" ] || grants=$(fm_pane_grants_default_grants "$out")
    [ -z "$label" ] || printf 'target: %s\n' "$label"
  else
    fm_pane_grants_read "$target"
    label=$GRANT_SESSION:$GRANT_WINDOW
    grants=$GRANT_CSV
    declared=$GRANT_DECLARED
    printf 'target: %s\n' "$label"
  fi
  [ -n "$declared" ] || declared=default
  [ -n "$grants" ] || grants=none
  printf 'grants: %s\n' "$grants"
  printf 'declared: %s\n' "$declared"
  case ",$grants," in
    *",respond,"*) printf 'respond: present\n' ;;
    *)
      printf 'respond: absent\n'
      [ -z "$label" ] || printf 'person command: %s\n' "$(fm_pane_grants_person_command "$label")"
      ;;
  esac
}

# fm_pane_grants_verify: the read-only gate that follows a delegation. Exit 0
# only when the pane really holds respond, so the supervisor retries its key
# send instead of guessing whether the grant landed.
fm_pane_grants_verify() {  # <target>
  fm_pane_grants_read "$1"
  case ",$GRANT_CSV," in
    *",respond,"*)
      printf 'verified: %s:%s holds respond\n' "$GRANT_SESSION" "$GRANT_WINDOW"
      return 0
      ;;
  esac
  printf 'absent: %s:%s does not hold respond (holds %s)\n' \
    "$GRANT_SESSION" "$GRANT_WINDOW" "${GRANT_CSV:-none}" >&2
  printf 'person command: %s\n' "$(fm_pane_grants_person_command "$GRANT_SESSION:$GRANT_WINDOW")" >&2
  return 1
}

fm_pane_grants_grant() {  # <grant-name> <target>
  local grant=$1 target=$2 current desired out rc inventory
  [ "$grant" = respond ] \
    || fm_pane_grants_refuse "only the respond grant can be added; '$grant' is refused because this wrapper is not a TUIOS grant proxy"
  fm_pane_grants_read "$target"
  current=$GRANT_CSV
  case ",$current," in
    *",respond,"*)
      printf 'already granted: respond on %s:%s (holds %s)\n' "$GRANT_SESSION" "$GRANT_WINDOW" "$current"
      return 0
      ;;
  esac
  desired=$(fm_pane_grants_with "$current" respond)
  out=$("$TUIOS_BIN" set-pane-grants --session "$GRANT_SESSION" --window "$GRANT_WINDOW" \
    --grants "$desired" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error: TUIOS refused to add the respond grant on %s:%s: %s\n' \
      "$GRANT_SESSION" "$GRANT_WINDOW" "$(printf '%s' "$out" | head -n 1)" >&2
    fm_pane_grants_person_hint "$GRANT_SESSION:$GRANT_WINDOW"
    exit 1
  fi
  inventory=$(fm_pane_grants_inventory "$GRANT_SESSION")
  current=$(fm_pane_grants_explicit "$inventory" "$GRANT_WINDOW")
  current=${current#*$'\t'}
  case ",$current," in
    *",respond,"*) ;;
    *) fm_pane_grants_fail "TUIOS reported success, but $GRANT_SESSION:$GRANT_WINDOW does not hold respond; nothing else was changed" ;;
  esac
  printf 'granted: respond on %s:%s (holds %s)\n' "$GRANT_SESSION" "$GRANT_WINDOW" "$current"
}

command -v jq >/dev/null 2>&1 || fm_pane_grants_fail 'jq is required to read the TUIOS window inventory'
command -v "$TUIOS_BIN" >/dev/null 2>&1 || fm_pane_grants_fail "the TUIOS CLI '$TUIOS_BIN' is not on PATH"

[ "$#" -gt 0 ] || { fm_pane_grants_usage; exit 2; }
subcommand=$1
shift
case "$subcommand" in
  show)
    [ "$#" -le 1 ] || fm_pane_grants_refuse 'show takes at most one target'
    fm_pane_grants_show "${1:-}"
    ;;
  grant)
    [ "$#" -eq 2 ] || fm_pane_grants_refuse 'grant takes exactly one grant name and one target'
    fm_pane_grants_grant "$1" "$2"
    ;;
  verify)
    [ "$#" -eq 1 ] || fm_pane_grants_refuse 'verify takes exactly one target'
    fm_pane_grants_verify "$1"
    ;;
  -h|--help|help) fm_pane_grants_usage ;;
  *) fm_pane_grants_refuse "unknown subcommand '$subcommand'" ;;
esac
