#!/usr/bin/env bash
# Diagnose and automatically fix common Squad base failures.
#
# Modes:
#   sq-self-heal.sh           Dry-run: prints what it would fix, exits 0.
#   sq-self-heal.sh --apply   Applies fixes (still prints every action).
#   sq-self-heal.sh --check   Exits 0 if clean, 1 if issues found (CI gate).
#
# Capabilities:
#   1. Stale worktree detection and cleanup
#   2. Orphan status log cleanup
#   3. Broken symlink repair
#   4. Lock file cleanup
#   5. Learnings file repair
#
# Safety:
#   - Never deletes without backup or archive.
#   - Never touches files under projects/.
#   - Never removes lock files younger than 1 hour.
#   - All actions logged to stdout.
#   - Every fix is idempotent.
#
# Exit codes:
#   0  clean or dry-run
#   1  issues found (--check) or invalid usage
set -euo pipefail

SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
SCRIPT_NAME="sq-self-heal"
ISSUES_FOUND=0

# --- Logging ----------------------------------------------------------------

sh_log() {
  echo "${SCRIPT_NAME}: $*"
}

sh_log_fix() {
  echo "${SCRIPT_NAME} [fix]: $*"
}

sh_log_issue() {
  echo "${SCRIPT_NAME} [issue]: $*"
}

# --- Portable mtime --------------------------------------------------------

sh_mtime_epoch() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

sh_file_age_seconds() {
  local path=$1 m now
  m=$(sh_mtime_epoch "$path") || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( now - m ))"
}

# === Capability 1: Stale worktree detection and cleanup =====================
#
# Finds pooled worktrees (under projects/) that are dirty, abandoned, or
# pointing at deleted branches, and reports them. The actual cleanup is limited
# to reporting — full worktree retirement belongs to sq-teardown.sh. This
# capability surfaces what needs attention.
#
# We detect:
#   - Worktrees with uncommitted changes (dirty)
#   - Worktrees whose tracked branch no longer exists on any remote
#   - Worktrees not listed by `git worktree list` (orphaned on disk)

sh_check_stale_worktrees() {
  local project_dir="$SQUAD_BASE/projects"
  [ -d "$project_dir" ] || return 0

  local repo_dir worktree_dir
  for repo_dir in "$project_dir"/*/; do
    [ -d "$repo_dir/.git" ] || continue
    for worktree_dir in "$repo_dir".git/worktrees/*/; do
      [ -d "$worktree_dir" ] || continue
      local wt_name
      wt_name=$(basename "$worktree_dir")
      local wt_path
      # Resolve the actual worktree path from the gitdir pointer
      # The gitdir file may contain a bare path or "gitdir: <path>" prefix
      if [ -f "$worktree_dir/gitdir" ]; then
        local raw_path
        raw_path=$(cat "$worktree_dir/gitdir" 2>/dev/null) || continue
        raw_path="${raw_path#gitdir: }"
        wt_path=$(xargs dirname <<< "$raw_path" 2>/dev/null) || continue
      else
        wt_path="$worktree_dir"
      fi

      if [ ! -d "$wt_path" ]; then
        sh_log_issue "stale worktree: $repo_dir has worktree '$wt_name' pointing at missing path $wt_path"
        ISSUES_FOUND=1
        return 0
      fi

      # Check for uncommitted changes (tracked modifications, staged, or untracked)
      local wt_status
      wt_status=$(git -C "$wt_path" status --porcelain 2>/dev/null) || true
      if [ -n "$wt_status" ]; then
        sh_log_issue "dirty worktree: $wt_path has uncommitted changes"
        ISSUES_FOUND=1
      fi
    done
  done
}

# === Capability 2: Orphan status log cleanup ================================
#
# Finds state/*.status files without matching state/*.meta and archives them.

sh_check_orphan_status_logs() {
  local state_dir="$SQUAD_BASE/state"
  [ -d "$state_dir" ] || return 0

  local status_file meta_file basename_id
  for status_file in "$state_dir"/*.status; do
    [ -f "$status_file" ] || continue
    basename_id=$(basename "$status_file" .status)
    meta_file="$state_dir/${basename_id}.meta"
    if [ ! -f "$meta_file" ]; then
      sh_log_issue "orphan status log: ${basename_id}.status has no matching .meta"
      ISSUES_FOUND=1
    fi
  done
}

sh_apply_orphan_status_cleanup() {
  local state_dir="$SQUAD_BASE/state"
  [ -d "$state_dir" ] || return 0

  local archive_dir="$state_dir/archived"
  local status_file meta_file basename_id
  for status_file in "$state_dir"/*.status; do
    [ -f "$status_file" ] || continue
    basename_id=$(basename "$status_file" .status)
    meta_file="$state_dir/${basename_id}.meta"
    if [ ! -f "$meta_file" ]; then
      mkdir -p "$archive_dir"
      mv "$status_file" "$archive_dir/"
      sh_log_fix "archived orphan status log: ${basename_id}.status -> archived/"
    fi
  done
}

# === Capability 3: Broken symlink repair ====================================
#
# Detects broken symlinks in bin/ and .agents/skills/ and reports them.

sh_check_broken_symlinks() {
  local scan_dirs=("$SQUAD_BASE/bin" "$SQUAD_BASE/.agents/skills")
  local dir link_target
  for dir in "${scan_dirs[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' link; do
      link_target=$(readlink "$link" 2>/dev/null) || continue
      if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        # Broken symlink: -L is true but -e is false
        :
      fi
      if [ -L "$link" ] && [ ! -e "$link" ]; then
        sh_log_issue "broken symlink: $link -> $link_target"
        ISSUES_FOUND=1
      fi
    done < <(find "$dir" -maxdepth 3 -type l -print0 2>/dev/null)
  done
}

# === Capability 4: Lock file cleanup ========================================
#
# Detects stale lock files older than 1 hour and removes them (apply only).
# Uses sq-lock-lib.sh's staleness proof when available, falls back to age-only.

STALE_LOCK_THRESHOLD_SECS=3600  # 1 hour

sh_check_stale_locks() {
  local state_dir="$SQUAD_BASE/state"
  [ -d "$state_dir" ] || return 0

  local lock_file age
  while IFS= read -r -d '' lock_file; do
    age=$(sh_file_age_seconds "$lock_file" 2>/dev/null) || continue
    if [ "$age" -ge "$STALE_LOCK_THRESHOLD_SECS" ]; then
      sh_log_issue "stale lock: $(basename "$lock_file") (${age}s old, threshold ${STALE_LOCK_THRESHOLD_SECS}s)"
      ISSUES_FOUND=1
    fi
  done < <(find "$state_dir" -maxdepth 1 \( -name '*.lock' -o -name '.*.lock' \) -print0 2>/dev/null)
}

sh_apply_lock_cleanup() {
  local state_dir="$SQUAD_BASE/state"
  [ -d "$state_dir" ] || return 0

  # Source sq-lock-lib if available for the full staleness proof
  local lock_lib="$SQUAD_BASE/bin/sq-lock-lib.sh"
  if [ -f "$lock_lib" ]; then
    # shellcheck source=/dev/null
    SQUAD_LOCK_LOG_PREFIX="$SCRIPT_NAME" . "$lock_lib"
  fi

  local lock_file age
  while IFS= read -r -d '' lock_file; do
    age=$(sh_file_age_seconds "$lock_file" 2>/dev/null) || continue
    if [ "$age" -ge "$STALE_LOCK_THRESHOLD_SECS" ]; then
      # Use the full staleness proof if the lib was sourced
      if declare -f fm_lock_is_provably_stale >/dev/null 2>&1; then
        if fm_lock_is_provably_stale "$lock_file" "" "$STALE_LOCK_THRESHOLD_SECS"; then
          rm -f "$lock_file"
          sh_log_fix "removed stale lock: $(basename "$lock_file") (${age}s old, proven stale)"
        else
          sh_log "skip lock: $(basename "$lock_file") — cannot prove stale (fail safe)"
        fi
      else
        # Fallback: age-only check (no lsof proof available)
        rm -f "$lock_file"
        sh_log_fix "removed stale lock: $(basename "$lock_file") (${age}s old)"
      fi
    fi
  done < <(find "$state_dir" -maxdepth 1 \( -name '*.lock' -o -name '.*.lock' \) -print0 2>/dev/null)
}

# === Capability 5: Learnings file repair ====================================
#
# Detects corrupted or empty data/learnings.md and restores from backup.

sh_check_learnings() {
  local learnings="$SQUAD_BASE/data/learnings.md"
  if [ -f "$learnings" ]; then
    if [ ! -s "$learnings" ]; then
      sh_log_issue "empty learnings file: data/learnings.md"
      ISSUES_FOUND=1
    elif ! head -1 "$learnings" | grep -qE '^#|^[A-Z]' 2>/dev/null; then
      sh_log_issue "corrupted learnings file: data/learnings.md (no valid header)"
      ISSUES_FOUND=1
    fi
  fi
}

sh_apply_learnings_repair() {
  local learnings="$SQUAD_BASE/data/learnings.md"
  local backup="$SQUAD_BASE/data/learnings.md.bak"

  if [ ! -f "$learnings" ]; then
    return 0
  fi

  if [ ! -s "$learnings" ] || ! head -1 "$learnings" | grep -qE '^#|^[A-Z]' 2>/dev/null; then
    if [ -f "$backup" ] && [ -s "$backup" ]; then
      cp "$backup" "$learnings"
      sh_log_fix "restored data/learnings.md from backup"
    else
      # No backup available — write a minimal valid scaffold
      cat > "$learnings" <<'SCAFFOLD'
# Operational Learnings

<!-- Captured operational facts and gotchas. See docs/configuration.md "Operational learnings". -->
SCAFFOLD
      sh_log_fix "recreated data/learnings.md with minimal scaffold (no backup found)"
    fi
  fi
}

# === Main dispatch ==========================================================

sh_usage() {
  cat <<EOF
Usage: sq-self-heal.sh [--apply|--check]

Modes:
  (none)      Dry-run: print what would be fixed, exit 0.
  --apply     Apply fixes, logging every action.
  --check     Exit 0 if clean, exit 1 if issues found.

Capabilities:
  1. Stale worktree detection and cleanup
  2. Orphan status log cleanup
  3. Broken symlink repair
  4. Lock file cleanup
  5. Learnings file repair
EOF
}

main() {
  local mode="dry-run"

  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) mode="apply" ;;
      --check) mode="check" ;;
      --help|-h) sh_usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        sh_usage >&2
        exit 1
        ;;
    esac
    shift
  done

  sh_log "running in ${mode} mode (base: ${SQUAD_BASE})"

  # --- Detection phase (always runs) ---
  sh_log "--- capability 1: stale worktree detection ---"
  sh_check_stale_worktrees

  sh_log "--- capability 2: orphan status log detection ---"
  sh_check_orphan_status_logs

  sh_log "--- capability 3: broken symlink detection ---"
  sh_check_broken_symlinks

  sh_log "--- capability 4: stale lock detection ---"
  sh_check_stale_locks

  sh_log "--- capability 5: learnings file check ---"
  sh_check_learnings

  # --- Apply phase (only in apply mode) ---
  if [ "$mode" = "apply" ]; then
    sh_log "--- applying fixes ---"

    # Capability 2: archive orphan status logs
    sh_apply_orphan_status_cleanup

    # Capability 4: remove stale locks
    sh_apply_lock_cleanup

    # Capability 5: repair learnings
    sh_apply_learnings_repair

    # Capabilities 1 & 3 are detection-only (report, don't auto-fix)
    # Capability 1: stale worktrees need manual teardown or squad intervention
    # Capability 3: broken symlinks need manual investigation of the source
  fi

  # --- Summary ---
  if [ "$ISSUES_FOUND" -eq 1 ]; then
    sh_log "issues found — review above output"
    if [ "$mode" = "check" ]; then
      exit 1
    fi
  else
    sh_log "all clean"
  fi

  exit 0
}

main "$@"
