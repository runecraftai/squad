#!/usr/bin/env bash
# Configure Pi context compaction for operator sessions
#
# This script manages compaction settings for Pi operators to prevent
# stalls after context compaction. It can:
# - Enable/disable compaction
# - Configure compaction thresholds
# - Load/unload the compaction-resilience extension
# - Show current compaction status
#
# Usage:
#   sq-pi-compaction-config.sh enable [--reserve-tokens N] [--keep-recent N]
#   sq-pi-compaction-config.sh disable
#   sq-pi-compaction-config.sh status
#   sq-pi-compaction-config.sh configure [OPTIONS]
#
# Options:
#   --reserve-tokens N    Tokens to reserve for LLM response (default: 16384)
#   --keep-recent N       Recent tokens to keep without summarization (default: 20000)
#   --enabled             Enable compaction
#   --disabled            Disable compaction
#
# The compaction-resilience extension is loaded automatically when compaction
# is enabled. It prevents operator stalls by preserving critical state and
# re-engaging operators after compaction.
#
# This script modifies settings in ~/.pi/agent/settings.json or
# <project-dir>/.pi/settings.json depending on the context.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Default settings
RESERVE_TOKENS=16384
KEEP_RECENT=20000
EXTENSION_PATH=".pi/extensions/compaction-resilience.ts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check if jq is available
check_dependencies() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    exit 1
  fi
}

# Get the appropriate settings file
get_settings_file() {
  local project_dir="$1"
  
  # Project settings take precedence if they exist
  if [ -f "$project_dir/.pi/settings.json" ]; then
    echo "$project_dir/.pi/settings.json"
  elif [ -f "$HOME/.pi/agent/settings.json" ]; then
    echo "$HOME/.pi/agent/settings.json"
  else
    # Create agent settings if neither exists
    mkdir -p "$HOME/.pi/agent"
    echo "$HOME/.pi/agent/settings.json"
  fi
}

# Read current settings
read_settings() {
  local settings_file="$1"
  
  if [ ! -f "$settings_file" ]; then
    echo "{}"
    return
  fi
  
  cat "$settings_file"
}

# Update compaction settings
update_compaction_settings() {
  local settings_file="$1"
  local enabled="$2"
  local reserve_tokens="$3"
  local keep_recent="$4"
  
  local current_settings
  current_settings=$(read_settings "$settings_file")
  
  # Update compaction settings
  local updated_settings
  updated_settings=$(echo "$current_settings" | jq \
    --argjson enabled "$enabled" \
    --argjson reserve "$reserve_tokens" \
    --argjson keep "$keep_recent" \
    '.compaction = {
      "enabled": $enabled,
      "reserveTokens": $reserve,
      "keepRecentTokens": $keep
    }')
  
  # Ensure extension is loaded
  local extension_name
  extension_name=$(basename "$EXTENSION_PATH")
  
  # Check if extension is already in the list
  local has_extension
  has_extension=$(echo "$updated_settings" | jq --arg ext "$extension_name" \
    'if .extensions then (.extensions | index($ext) != null) else false end')
  
  if [ "$has_extension" = "false" ] && [ "$enabled" = "true" ]; then
    # Add extension to the list
    updated_settings=$(echo "$updated_settings" | jq --arg ext "$extension_name" \
      '.extensions = ((.extensions // []) + [$ext] | unique)')
  elif [ "$has_extension" = "true" ] && [ "$enabled" = "false" ]; then
    # Remove extension from the list when disabling
    updated_settings=$(echo "$updated_settings" | jq --arg ext "$extension_name" \
      '.extensions = ((.extensions // []) - [$ext])')
  fi
  
  echo "$updated_settings"
}

# Show current status
show_status() {
  local project_dir="${1:-.}"
  local settings_file
  settings_file=$(get_settings_file "$project_dir")
  
  log_info "Settings file: $settings_file"
  
  if [ ! -f "$settings_file" ]; then
    log_warn "No settings file found"
    return
  fi
  
  local compaction_enabled
  compaction_enabled=$(jq -r '.compaction.enabled // false' "$settings_file")
  
  local reserve_tokens
  reserve_tokens=$(jq -r '.compaction.reserveTokens // 16384' "$settings_file")
  
  local keep_recent
  keep_recent=$(jq -r '.compaction.keepRecentTokens // 20000' "$settings_file")
  
  local has_extension
  has_extension=$(jq --arg ext "$(basename "$EXTENSION_PATH")" \
    'if .extensions then (.extensions | index($ext) != null) else false end' "$settings_file")
  
  echo ""
  echo "=== Pi Compaction Status ==="
  echo "Enabled: $compaction_enabled"
  echo "Reserve tokens: $reserve_tokens"
  echo "Keep recent tokens: $keep_recent"
  echo "Resilience extension: $has_extension"
  echo ""
  
  if [ "$compaction_enabled" = "true" ] && [ "$has_extension" = "true" ]; then
    log_info "Compaction is enabled with resilience extension"
  elif [ "$compaction_enabled" = "true" ]; then
    log_warn "Compaction is enabled but resilience extension is NOT loaded"
    echo "  This may cause operator stalls after compaction"
  else
    log_info "Compaction is disabled"
  fi
}

# Enable compaction
enable_compaction() {
  local project_dir="${1:-.}"
  local settings_file
  settings_file=$(get_settings_file "$project_dir")
  
  log_info "Enabling compaction in: $settings_file"
  
  local updated_settings
  updated_settings=$(update_compaction_settings "$settings_file" "true" "$RESERVE_TOKENS" "$KEEP_RECENT")
  
  # Write updated settings
  echo "$updated_settings" | jq '.' > "$settings_file"
  
  log_info "Compaction enabled with:"
  echo "  Reserve tokens: $RESERVE_TOKENS"
  echo "  Keep recent tokens: $KEEP_RECENT"
  echo "  Resilience extension: loaded"
}

# Disable compaction
disable_compaction() {
  local project_dir="${1:-.}"
  local settings_file
  settings_file=$(get_settings_file "$project_dir")
  
  log_info "Disabling compaction in: $settings_file"
  
  local updated_settings
  updated_settings=$(update_compaction_settings "$settings_file" "false" "$RESERVE_TOKENS" "$KEEP_RECENT")
  
  # Write updated settings
  echo "$updated_settings" | jq '.' > "$settings_file"
  
  log_info "Compaction disabled"
}

# Configure with custom settings
configure_compaction() {
  local project_dir="${1:-.}"
  shift
  
  local enabled="true"
  local reserve_tokens="$RESERVE_TOKENS"
  local keep_recent="$KEEP_RECENT"
  
  while [ $# -gt 0 ]; do
    case "$1" in
      --enabled)
        enabled="true"
        shift
        ;;
      --disabled)
        enabled="false"
        shift
        ;;
      --reserve-tokens)
        reserve_tokens="$2"
        shift 2
        ;;
      --keep-recent)
        keep_recent="$2"
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        exit 1
        ;;
    esac
  done
  
  local settings_file
  settings_file=$(get_settings_file "$project_dir")
  
  log_info "Configuring compaction in: $settings_file"
  
  local updated_settings
  updated_settings=$(update_compaction_settings "$settings_file" "$enabled" "$reserve_tokens" "$keep_recent")
  
  # Write updated settings
  echo "$updated_settings" | jq '.' > "$settings_file"
  
  log_info "Compaction configured:"
  echo "  Enabled: $enabled"
  echo "  Reserve tokens: $reserve_tokens"
  echo "  Keep recent tokens: $keep_recent"
}

# Main function
main() {
  check_dependencies
  
  local command="${1:-status}"
  local project_dir="${2:-.}"
  
  case "$command" in
    enable)
      enable_compaction "$project_dir"
      ;;
    disable)
      disable_compaction "$project_dir"
      ;;
    status)
      show_status "$project_dir"
      ;;
    configure)
      shift
      configure_compaction "$project_dir" "$@"
      ;;
    *)
      log_error "Unknown command: $command"
      echo "Usage: $0 {enable|disable|status|configure} [project_dir]"
      exit 1
      ;;
  esac
}

# Run main function
main "$@"
