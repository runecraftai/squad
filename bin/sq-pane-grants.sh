#!/usr/bin/env bash
# sq-pane-grants.sh - show, and add exactly one, TUIOS pane grant.
#
# Usage:
#   sq-pane-grants.sh show [<target>]
#   sq-pane-grants.sh grant respond <target>
#
# <target> is a task id (resolved through state/<id>.meta, which must record
# backend=tuios) or an explicit <session>:<window> target. show without a
# target reports the grants of the pane this command runs in, which is the
# fast way to answer "does the pane that answers prompts hold respond?".
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
# docs/tuios-backend.md owns the operator flow; bin/sq-backend-pretool-check.sh's
# raw-session guard admits this wrapper as its only TUIOS exception.
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

<target> is a task id (resolved through state/<id>.meta) or <session>:<window>.
Only the respond grant can be added, and only to that one pane.
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
  id=$(printf '%s' "$inventory" | jq -r --arg r "$ref" '
    (.windows // []) as $w
    | ([ $w[] | select(.window_id == $r) | .window_id ] | first // "") as $exact
    | if $exact != "" then $exact
      else ([ $w[] | select((.window_id // "") | startswith($r)) | .window_id ] | unique) as $prefix
      | if ($prefix | length) == 1 then $prefix[0]
        else ([ $w[] | select(((.display_name // .name // .title // "")) == $r) | .window_id ] | unique) as $named
        | if ($named | length) == 1 then $named[0] else "" end
        end
      end')
  if [ -z "$id" ]; then
    available=$(printf '%s' "$inventory" | jq -r '[.windows[].window_id] | join(", ")' 2>/dev/null || true)
    fm_pane_grants_fail "session '$GRANT_SESSION' has no unambiguous window '$ref' (available: ${available:-none})"
  fi
  printf '%s' "$id"
}

fm_pane_grants_explicit() {  # <inventory> <window-id> -> csv, empty for the daemon default
  printf '%s' "$1" | jq -r --arg w "$2" '
    [ .windows[] | select(.window_id == $w) | (.grants // []) | .[] ] | join(",")'
}

fm_pane_grants_default_grants() {  # -> the daemon's default pane grants as csv
  local out csv
  out=$("$TUIOS_BIN" pane-grants --json 2>&1) \
    || fm_pane_grants_fail "cannot read the daemon's default pane grants: $(printf '%s' "$out" | head -n 1)"
  csv=$(printf '%s' "$out" | jq -r '(.default_grants // [])[]' 2>/dev/null | paste -sd, -)
  [ -n "$csv" ] \
    || fm_pane_grants_fail 'the daemon reported no default pane grants, so the grants a pane already holds cannot be read'
  printf '%s' "$csv"
}

fm_pane_grants_with() {  # <csv> <grant> -> csv that holds both, order preserved
  local csv=$1 grant=$2
  case ",$csv," in
    *",$grant,"*) printf '%s' "$csv"; return 0 ;;
  esac
  printf '%s' "${csv:+$csv,}$grant"
}

fm_pane_grants_authority_hint() {  # <target>
  local target=$1
  if [ -n "${TUIOS_ENV:-}${TUIOS_PANE_ID:-}" ]; then
    printf "hint: this command runs inside a TUIOS pane, and a pane can never give more than it holds (admin never includes respond).\n" >&2
    printf "hint: grant it once from the person's own shell outside TUIOS, or from a pane that already holds respond:\n" >&2
  else
    printf 'hint: TUIOS grants respond only from a caller that runs in no pane of that daemon.\n' >&2
  fi
  printf '  %s/bin/sq-pane-grants.sh grant respond %s\n' "$ROOT" "$target" >&2
}

fm_pane_grants_show() {  # [<target>]
  local target=${1:-} out inventory window grants declared
  if [ -z "$target" ]; then
    out=$("$TUIOS_BIN" pane-grants --json 2>&1) \
      || fm_pane_grants_fail "cannot read this pane's grants: $(printf '%s' "$out" | head -n 1)"
    if [ "$(printf '%s' "$out" | jq -r 'if .pane == true then "yes" else "no" end' 2>/dev/null || true)" = yes ]; then
      printf 'target: %s:%s\n' \
        "$(printf '%s' "$out" | jq -r '.session // ""' 2>/dev/null || true)" \
        "$(printf '%s' "$out" | jq -r '.window // ""' 2>/dev/null || true)"
      declared=$(printf '%s' "$out" | jq -r 'if .explicit == true then "explicit" else "default" end' 2>/dev/null || true)
      [ -n "$declared" ] || declared=default
    else
      printf 'target: none (this command runs in no pane of the daemon)\n'
      declared=default
    fi
    grants=$(printf '%s' "$out" | jq -r '(.grants // []) | join(",")' 2>/dev/null || true)
    [ -n "$grants" ] || grants=$(fm_pane_grants_default_grants)
  else
    fm_pane_grants_resolve_target "$target"
    inventory=$(fm_pane_grants_inventory "$GRANT_SESSION")
    window=$(fm_pane_grants_canonical_window "$inventory" "$GRANT_WINDOW")
    grants=$(fm_pane_grants_explicit "$inventory" "$window")
    if [ -n "$grants" ]; then
      declared=explicit
    else
      declared=default
      grants=$(fm_pane_grants_default_grants)
    fi
    printf 'target: %s:%s\n' "$GRANT_SESSION" "$window"
  fi
  printf 'grants: %s\n' "$grants"
  printf 'declared: %s\n' "$declared"
  case ",$grants," in
    *",respond,"*) printf 'respond: present\n' ;;
    *) printf 'respond: absent\n' ;;
  esac
}

fm_pane_grants_grant() {  # <grant-name> <target>
  local grant=$1 target=$2 inventory window current desired out rc
  [ "$grant" = respond ] \
    || fm_pane_grants_refuse "only the respond grant can be added; '$grant' is refused because this wrapper is not a TUIOS grant proxy"
  fm_pane_grants_resolve_target "$target"
  inventory=$(fm_pane_grants_inventory "$GRANT_SESSION")
  window=$(fm_pane_grants_canonical_window "$inventory" "$GRANT_WINDOW")
  current=$(fm_pane_grants_explicit "$inventory" "$window")
  [ -n "$current" ] || current=$(fm_pane_grants_default_grants)
  case ",$current," in
    *",respond,"*)
      printf 'already granted: respond on %s:%s (holds %s)\n' "$GRANT_SESSION" "$window" "$current"
      return 0
      ;;
  esac
  desired=$(fm_pane_grants_with "$current" respond)
  out=$("$TUIOS_BIN" set-pane-grants --session "$GRANT_SESSION" --window "$window" \
    --grants "$desired" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error: TUIOS refused to add the respond grant on %s:%s: %s\n' \
      "$GRANT_SESSION" "$window" "$(printf '%s' "$out" | head -n 1)" >&2
    fm_pane_grants_authority_hint "$GRANT_SESSION:$window"
    exit 1
  fi
  inventory=$(fm_pane_grants_inventory "$GRANT_SESSION")
  current=$(fm_pane_grants_explicit "$inventory" "$window")
  case ",$current," in
    *",respond,"*) ;;
    *) fm_pane_grants_fail "TUIOS reported success, but $GRANT_SESSION:$window does not hold respond; nothing else was changed" ;;
  esac
  printf 'granted: respond on %s:%s (holds %s)\n' "$GRANT_SESSION" "$window" "$current"
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
  -h|--help|help) fm_pane_grants_usage ;;
  *) fm_pane_grants_refuse "unknown subcommand '$subcommand'" ;;
esac
