#!/usr/bin/env bash
# Durable custody consultation point (durable-core plan section 12).
#
# Usage: . bin/sq-durable-custody.sh
#   durable_custody_check <id> <responsibility>...
#       0 when every named responsibility of <id> may be exercised by this legacy
#       writer; 3 when custody refuses, with the refusal message on stderr and a
#       line appended to data/durable/custody-refusals.log. Call it before any
#       mutation, inside the lock the writer already uses, and stop on refusal.
#   durable_custody_reserved <id>
#       0 when <id> is a durable mission ID (^dm[0-9]+-), 1 for a legacy ID.
#   durable_custody_publish_signal <name>
#       Record, in state/.custody-signal-<name>, the pid of this long-running
#       process and the custody generation it loaded, so admission of a newer
#       generation can name a live writer that never loaded its table
#       (`sq-durable custody signals`).
#
# A legacy ID returns 0 at once, with no file read and no subprocess, so legacy
# work behaves exactly as before.
# A durable mission ID carries its custody generation, which never changes. The
# owner of each responsibility comes only from that generation's immutable table,
# published in packages/sq-durable/src/adapter/legacy-writers.ts and evaluated
# by `sq-durable custody check`; a stopped service, a missing projection or a
# missing state/<id>.meta never grants legacy authority.
#
# Generation signal: sourcing pins the generation this process loaded. Every
# check rereads the generation of the library installed on disk; a process that
# loaded an older generation (it started before the change) or a newer one (the
# library regressed) is refused on every durable mission until it restarts.
# Sourcing again never refreshes the pinned value, because the rest of the
# process's in-memory code would still be the old one.
#
# Responsibilities, tables and the inventory of writers that consult this file
# are owned by the adapter above; `sq-durable custody inventory` lists them.
# SQ_DURABLE_STORE overrides the store a conditioned responsibility asks
# (default: <base>/data/durable/store).

# Newest custody generation this library was written for. A slice that publishes
# a new table bumps it together with the adapter's tables.
SQ_DURABLE_CUSTODY_GENERATION=2

# Resolved with parameter expansion only: sourcing runs no subprocess.
_SQ_DURABLE_CUSTODY_LIB=${BASH_SOURCE[0]}
case "$_SQ_DURABLE_CUSTODY_LIB" in
  /*) ;;
  *) _SQ_DURABLE_CUSTODY_LIB="$PWD/$_SQ_DURABLE_CUSTODY_LIB" ;;
esac
_SQ_DURABLE_CUSTODY_ROOT="${_SQ_DURABLE_CUSTODY_LIB%/bin/*}"
: "${_SQ_DURABLE_CUSTODY_LOADED:=$SQ_DURABLE_CUSTODY_GENERATION}"
: "${_SQ_DURABLE_CUSTODY_REFUSALS:=0}"

durable_custody_reserved() {  # <id>
  [[ ${1-} =~ ^dm[0-9]+- ]]
}

# Whether this process has refused any durable mission since it started. A batch
# or housekeeping sweep uses it to keep processing the other items and still
# report the refusal with exit 3 at the end.
durable_custody_refused() {
  [ "$_SQ_DURABLE_CUSTODY_REFUSALS" -gt 0 ]
}

_durable_custody_base() {
  printf '%s' "${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$_SQ_DURABLE_CUSTODY_ROOT}}}"
}

# Print the refusal and keep a durable record of it; the record is best effort,
# the refusal itself never is.
_durable_custody_refuse() {  # <id> <responsibilities> <message>
  local log
  _SQ_DURABLE_CUSTODY_REFUSALS=$((_SQ_DURABLE_CUSTODY_REFUSALS + 1))
  printf '%s\n' "$3" >&2
  log="$(_durable_custody_base)/data/durable/custody-refusals.log"
  {
    mkdir -p "${log%/*}" &&
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${0##*/}" "$$" "$3" >>"$log"
  } 2>/dev/null || true
  return 3
}

durable_custody_check() {  # <id> <responsibility>...
  local id=${1-} responsibilities installed cli out rc
  durable_custody_reserved "$id" || return 0
  shift
  if [ "$#" -eq 0 ]; then
    _durable_custody_refuse "$id" - "refused: no responsibility named for mission $id"
    return 3
  fi
  responsibilities=$(IFS=,; printf '%s' "$*")
  installed=$(sed -n 's/^SQ_DURABLE_CUSTODY_GENERATION=\([0-9][0-9]*\)$/\1/p' "$_SQ_DURABLE_CUSTODY_LIB" 2>/dev/null | head -n 1)
  if [ -z "$installed" ]; then
    _durable_custody_refuse "$id" "$responsibilities" "refused: the custody library $_SQ_DURABLE_CUSTODY_LIB is missing or unreadable; mission $id is refused"
    return 3
  fi
  if [ "$installed" -gt "$_SQ_DURABLE_CUSTODY_LOADED" ]; then
    _durable_custody_refuse "$id" "$responsibilities" "refused: this writer loaded custody generation $_SQ_DURABLE_CUSTODY_LOADED but generation $installed is installed; restart it before it acts on mission $id"
    return 3
  fi
  if [ "$installed" -lt "$_SQ_DURABLE_CUSTODY_LOADED" ]; then
    _durable_custody_refuse "$id" "$responsibilities" "refused: this writer loaded custody generation $_SQ_DURABLE_CUSTODY_LOADED but only generation $installed is installed; the custody library regressed, so mission $id is refused"
    return 3
  fi
  cli="$_SQ_DURABLE_CUSTODY_ROOT/packages/sq-durable/dist/cli.js"
  if [ ! -f "$cli" ] || ! command -v node >/dev/null 2>&1; then
    _durable_custody_refuse "$id" "$responsibilities" "refused: the custody core is not available (node and $cli are required for durable mission $id)"
    return 3
  fi
  if out=$(node --disable-warning=ExperimentalWarning "$cli" custody check --mission "$id" \
    --responsibility "$responsibilities" --loaded-generation "$_SQ_DURABLE_CUSTODY_LOADED" \
    --store "${SQ_DURABLE_STORE:-$(_durable_custody_base)/data/durable/store}" 2>&1); then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -ne 3 ]; then
    out="refused: the custody check of mission $id failed (exit $rc): $out"
  fi
  _durable_custody_refuse "$id" "$responsibilities" "$out"
}

durable_custody_publish_signal() {  # <name>
  local name=${1-} dir tmp
  case "$name" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  dir="${SQUAD_STATE_OVERRIDE:-$(_durable_custody_base)/state}"
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.custody-signal-$name.XXXXXX") || return 1
  if printf 'pid=%s\ngeneration=%s\nupdated=%s\n' "$$" "$_SQ_DURABLE_CUSTODY_LOADED" "$(date +%s)" >"$tmp"; then
    mv -f -- "$tmp" "$dir/.custody-signal-$name"
  else
    rm -f -- "$tmp"
    return 1
  fi
}
