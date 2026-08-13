#!/usr/bin/env bash
# Register and provision a whole XO base on an SSH-reachable host.
#
# Usage:
#   sq-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>[=<origin-url>]...|--no-projects}
#
# The SSH alias must already reach a host whose non-interactive PATH exposes the
# fixed sq-remote-entrypoint.sh from <remote-root>. The command records the
# remote host dimension in data/XOs.md, gates the host on
# sq-remote-doctor.sh readiness before touching it, sends a bounded provisioning
# manifest through sq-on.sh, and lets the remote host clone its own Squad
# base and project origins. No project tree or secret environment is copied.
#
# Each project needs an origin the remote account can clone. Squad resolves
# that origin and names it as <project>=<origin-url>, so seeding never requires
# a clone of that project in this base; a bare <project> is accepted only when
# this base already has projects/<project>, whose origin is then read instead.
# bin/sq-project-origin-lib.sh owns which URLs are accepted, and this base's
# data/projects.md still owns the project's registered delivery mode, so an
# unregistered or local-only project is refused rather than provisioned.
# Seeding writes nothing under projects/ and needs no unit sync first.
#
# Known provisioning failure rolls the registry back. SSH status 255 preserves
# the route and any newly scaffolded brief because completion is unknown and a same-route rerun converges.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
DATA="${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}"
PROJECTS="${SQUAD_PROJECTS_OVERRIDE:-$SQUAD_BASE/projects}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
REG="$DATA/XOs.md"
MAX_MANIFEST_BYTES=1048576

# shellcheck source=bin/sq-xo-registry-lib.sh
. "$SCRIPT_DIR/sq-xo-registry-lib.sh"
# shellcheck source=bin/sq-xo-charter-lib.sh
. "$SCRIPT_DIR/sq-xo-charter-lib.sh"
# shellcheck source=bin/sq-stand-to-lib.sh
. "$SCRIPT_DIR/sq-stand-to-lib.sh"
# shellcheck source=bin/sq-remote-readiness-lib.sh
. "$SCRIPT_DIR/sq-remote-readiness-lib.sh"
# shellcheck source=bin/sq-project-origin-lib.sh
. "$SCRIPT_DIR/sq-project-origin-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
encode() { base64 | tr -d '\n'; }
safe_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

TMP=
REGISTRY_LOCK=
REGISTRY_LOCK_HELD=0
cleanup() {
  [ -z "$TMP" ] || rm -rf -- "$TMP"
  if [ "$REGISTRY_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REGISTRY_LOCK"
    REGISTRY_LOCK_HELD=0
  fi
}
trap cleanup EXIT

[ "$#" -ge 5 ] || usage
ID=$1
HOST=$2
REMOTE_ROOT=$3
REMOTE_HOME=$4
shift 4
safe_id "$ID" || die "invalid XO id: $ID"
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid SSH config alias: $HOST" ;; esac
for path in "$REMOTE_ROOT" "$REMOTE_HOME"; do
  case "$path" in /*) ;; *) die "remote root and home must be absolute paths" ;; esac
  case "$path" in *';'*|*')'*|*$'\n'*|*$'\r'*|*$'\t'*) die "remote root or home contains a registry delimiter" ;; esac
  case "/$path/" in */../*|*/./*) die "remote root or home contains traversal components" ;; esac
  case "$path" in *'//'*) die "remote root or home contains an empty path component" ;; esac
done
[ "$REMOTE_ROOT" != "$REMOTE_HOME" ] || die "remote root and home must be separate"
case "$REMOTE_HOME/" in "$REMOTE_ROOT/"*) die "remote home must not be inside the remote code root" ;; esac
case "$REMOTE_ROOT/" in "$REMOTE_HOME/"*) die "remote code root must not be inside the remote home" ;; esac

NO_PROJECTS=0
PROJECT_NAMES=()
PROJECT_ORIGINS=()
for arg in "$@"; do
  if [ "$arg" = --no-projects ]; then
    NO_PROJECTS=1
  else
    name=${arg%%=*}
    origin=
    case "$arg" in *=*) origin=${arg#*=} ;; esac
    safe_id "$name" || die "invalid project name: $name"
    case "$arg" in
      *=*) fm_project_origin_safe "$origin" \
        || die "project $name origin is not an accepted clone URL: $origin" ;;
    esac
    PROJECT_NAMES+=("$name")
    PROJECT_ORIGINS+=("$origin")
  fi
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ "${#PROJECT_NAMES[@]}" -eq 0 ] || die "--no-projects cannot be combined with project names"
else
  [ "${#PROJECT_NAMES[@]}" -gt 0 ] || die "at least one project or --no-projects is required"
fi

mkdir -p "$STATE" || die "cannot create parent state directory"
REGISTRY_LOCK=$(XO_registry_lock_path "$STATE")
fm_lock_acquire_wait "$REGISTRY_LOCK" || die "cannot lock the XO registry"
REGISTRY_LOCK_HELD=1

if [ -e "$REG" ] || [ -L "$REG" ]; then
  [ -f "$REG" ] && [ ! -L "$REG" ] || die "XO registry is unavailable or unsafe: $REG"
  XO_registry_validate_bindings "$REG" XO_registry_path_key \
    || die "$XO_REGISTRY_ERROR"
  if XO_registry_line_for_id "$REG" "$ID"; then
    [ "$XO_REGISTRY_REMOTE" -eq 1 ] \
      && [ "$XO_REGISTRY_HOST" = "$HOST" ] \
      && [ "$XO_REGISTRY_ROOT" = "$REMOTE_ROOT" ] \
      && [ "$XO_REGISTRY_HOME" = "$REMOTE_HOME" ] \
      || die "XO $ID is already registered to a different local or remote home"
  fi
fi

mkdir -p "$DATA"
BRIEF="$DATA/$ID/brief.md"
BRIEF_CREATED=0
if [ ! -f "$BRIEF" ]; then
  [ -n "${SQUAD_XO_CHARTER:-}" ] || die "no filled charter at $BRIEF; set SQUAD_XO_CHARTER or scaffold one first"
  if [ "$NO_PROJECTS" -eq 1 ]; then
    "$SCRIPT_DIR/sq-brief.sh" "$ID" --xo --no-projects >/dev/null
  else
    "$SCRIPT_DIR/sq-brief.sh" "$ID" --xo "${PROJECT_NAMES[@]}" >/dev/null
  fi
  BRIEF_CREATED=1
fi
if grep -F '{TASK}' "$BRIEF" >/dev/null 2>&1; then
  [ "$BRIEF_CREATED" -eq 0 ] || rm -f -- "$BRIEF"
  die "XO charter still contains {TASK}: $BRIEF"
fi
SUMMARY=$(registry_summary_for_brief "$BRIEF")
SCOPE=$(registry_scope_for_brief "$BRIEF")
[ -n "$SUMMARY" ] && [ -n "$SCOPE" ] || die "charter summary and routing scope must be nonempty"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sq-remote-home-seed.XXXXXX") || die "cannot create seed staging directory"
REG_EXISTED=0
[ -f "$REG" ] && { cp "$REG" "$TMP/registry.before"; REG_EXISTED=1; }

# Keep the parent charter as its durable source, but publish a remote copy whose
# status path is the remote append-only relay log rather than a local Mac path.
PARENT_STATUS="$STATE/$ID.status"
REMOTE_STATUS="$REMOTE_HOME/state/parent-replies.status"
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "${line//"$PARENT_STATUS"/"$REMOTE_STATUS"}"
done < "$BRIEF" > "$TMP/charter.remote"

PROJECTS_CSV=
: > "$TMP/project.records"
PROJECT_INDEX=0
for project in "${PROJECT_NAMES[@]}"; do
  ORIGIN=${PROJECT_ORIGINS[$PROJECT_INDEX]}
  PROJECT_INDEX=$((PROJECT_INDEX + 1))
  MODE_LINE=$(SQUAD_BASE="$SQUAD_BASE" SQUAD_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/sq-project-mode.sh" "$project")
  read -r MODE _ <<EOF
$MODE_LINE
EOF
  case "$MODE" in
    drill|direct-PR) ;;
    local-only) die "project $project is local-only and cannot be provisioned remotely" ;;
    *) die "project $project has unsupported delivery mode: $MODE" ;;
  esac
  # An origin named on the command line is authoritative. Reading one from a
  # clone this base happens to have is only a convenience for the already-cloned
  # case; it is never a reason to create one.
  if [ -z "$ORIGIN" ] && [ -d "$PROJECTS/$project/.git" ]; then
    ORIGIN=$(git -C "$PROJECTS/$project" remote get-url origin 2>/dev/null || true)
  fi
  [ -n "$ORIGIN" ] \
    || die "project $project has no origin; pass $project=<origin-url> so the remote host can clone it"
  fm_project_origin_safe "$ORIGIN" \
    || die "project $project origin is not an accepted clone URL: $ORIGIN"
  REGISTRY_LINE=$(awk -v p="$project" '$1 == "-" && $2 == p { print; exit }' "$DATA/projects.md" 2>/dev/null || true)
  [ -n "$REGISTRY_LINE" ] || die "project $project has no registry record"
  NAME_B64=$(printf '%s' "$project" | encode)
  ORIGIN_B64=$(printf '%s' "$ORIGIN" | encode)
  PROJECT_REG_B64=$(printf '%s' "$REGISTRY_LINE" | encode)
  MODE_B64=$(printf '%s' "$MODE" | encode)
  printf 'project=%s|%s|%s|%s\n' "$NAME_B64" "$ORIGIN_B64" "$PROJECT_REG_B64" "$MODE_B64" >> "$TMP/project.records"
  PROJECTS_CSV="${PROJECTS_CSV}${PROJECTS_CSV:+, }$project"
done

{
  printf 'schema=sq-remote-home-provision.v1\n'
  printf 'id_b64=%s\n' "$(printf '%s' "$ID" | encode)"
  printf 'charter_b64=%s\n' "$(encode < "$TMP/charter.remote")"
  # The SSH alias reaching this host from the parent's own config, carried
  # only so the remote-provisioned base can record durably that its parent
  # lives on another machine (bin/sq-teardown.sh's cleanup gate). It is
  # diagnostic identity, never a route the remote host could use to reach
  # back; the parent's real filesystem path is never sent, since it names
  # nothing on the remote filesystem.
  printf 'parent_host_b64=%s\n' "$(printf '%s' "$HOST" | encode)"
  printf 'project_count=%s\n' "${#PROJECT_NAMES[@]}"
  cat "$TMP/project.records"
} > "$TMP/manifest"
MANIFEST_BYTES=$(LC_ALL=C wc -c < "$TMP/manifest" | tr -d ' ')
[ "$MANIFEST_BYTES" -le "$MAX_MANIFEST_BYTES" ] \
  || die "remote provisioning manifest exceeds the $MAX_MANIFEST_BYTES-byte bound"

TODAY=$(date +%F)
REG_TMP="$TMP/XOs.next"
if [ -f "$REG" ]; then grep -vE "^- $ID( |$)" "$REG" > "$REG_TMP" || true; else : > "$REG_TMP"; fi
printf -- '- %s - %s (host: %s; root: %s; home: %s; scope: %s; projects: %s; added %s)\n' \
  "$ID" "$SUMMARY" "$HOST" "$REMOTE_ROOT" "$REMOTE_HOME" "$SCOPE" "$PROJECTS_CSV" "$TODAY" >> "$REG_TMP"
mv -f -- "$REG_TMP" "$REG"
if ! XO_registry_validate_bindings "$REG" XO_registry_path_key "$ID" "$REMOTE_HOME"; then
  if [ "$REG_EXISTED" -eq 1 ]; then cp "$TMP/registry.before" "$REG"; else rm -f -- "$REG"; fi
  die "$XO_REGISTRY_ERROR"
fi

restore_registry_and_brief() {
  if [ "$REG_EXISTED" -eq 1 ]; then cp "$TMP/registry.before" "$REG"; else rm -f -- "$REG"; fi
  [ "$BRIEF_CREATED" -eq 0 ] || rm -f -- "$BRIEF"
}

# Preflight and, where it can, repair the remote runtime before anything is
# created on that host. The doctor runs through the same fixed entrypoint as
# every later call, so it sees the exact PATH the remote base will run under.
set +e
fm_remote_readiness_ensure "$SCRIPT_DIR" "$ID"
PREFLIGHT_RC=$?
set -e
if [ "$PREFLIGHT_RC" -ne 0 ]; then
  if [ "$PREFLIGHT_RC" -ne 255 ]; then
    restore_registry_and_brief
  fi
  [ -z "$SQUAD_REMOTE_READINESS_OUT" ] || printf '%s\n' "$SQUAD_REMOTE_READINESS_OUT" >&2
  if [ "$PREFLIGHT_RC" -eq 255 ]; then
    die "remote readiness completion is unknown; route and brief preserved for same-host reconciliation"
  fi
  die "remote runtime preflight failed; nothing was provisioned. Close the gaps listed above, or update the remote code root if it predates the current sq-remote-doctor.sh"
fi

set +e
PROVISION_OUT=$("$SCRIPT_DIR/sq-on.sh" "$ID" sq-remote-home-provision.sh < "$TMP/manifest" 2>&1)
PROVISION_RC=$?
set -e
if [ "$PROVISION_RC" -ne 0 ]; then
  if [ "$PROVISION_RC" -ne 255 ]; then
    restore_registry_and_brief
  fi
  [ -z "$PROVISION_OUT" ] || printf '%s\n' "$PROVISION_OUT" >&2
  if [ "$PROVISION_RC" -eq 255 ]; then
    die "remote provisioning completion is unknown; route preserved for same-host reconciliation"
  fi
  die "remote provisioning failed; registry restored"
fi
printf '%s\n' "$PROVISION_OUT"
printf 'home=%s:%s\n' "$HOST" "$REMOTE_HOME"
