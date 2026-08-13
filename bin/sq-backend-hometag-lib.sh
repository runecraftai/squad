#!/usr/bin/env bash
# bin/sq-backend-hometag-lib.sh - shared per-installation base-tag derivation
# for session-provider backends whose container has ONE namespace shared by
# every Squad base on the machine, with no native per-base split (cmux's
# one app-global workspace list, zellij's one shared "Squad" session's
# tab bar). Without a per-base discriminator embedded in the actual
# title/name, two Squad bases (two XOs, a primary plus a
# XO, or two independent primary installations) whose task ids
# happen to collide can send/peek/close each other's tabs - the gap a
# commander-directed drill review gate caught for cmux
# (docs/cmux-backend.md) and this same tag mechanism was later ported to
# zellij to close for the same reason (docs/zellij-backend.md "Base-scoped
# tab titles").
#
# fm_backend_hometag() derives a short, stable tag: a readable prefix
# ("Squad" for the primary base, "xo-<id>" for an XO base
# carrying .sq-xo-home) plus a short hash of the resolved SQUAD_ROOT
# path, so distinct installations - including multiple primaries on one
# machine - never collide even though they share one backend-global
# namespace. Callers source this file AFTER resolving their own
# SQUAD_BASE/SQUAD_ROOT fallbacks (both adapters already do this for their own
# purposes before any other function runs).
#
# Moving/relocating a Squad installation changes its SQUAD_ROOT path and
# therefore its tag; titles created under the old tag simply stop matching -
# an accepted limitation, no worse than the existing fact that a task's
# recorded absolute worktree path does not survive a move either.

SQUAD_BACKEND_HOMETAG_XO_MARKER=".sq-xo-home"

fm_backend_hometag() {
  local marker="$SQUAD_BASE/$SQUAD_BACKEND_HOMETAG_XO_MARKER" id prefix root hash
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="xo-$id"
    else
      prefix="Squad"
    fi
  else
    prefix="Squad"
  fi
  root=$(cd "$SQUAD_ROOT" 2>/dev/null && pwd -P) || root=$SQUAD_ROOT
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$root" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}
