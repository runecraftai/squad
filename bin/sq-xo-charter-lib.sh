#!/usr/bin/env bash
# Shared extraction of XO registry summary and scope from a charter.
# Source only. SQUAD_XO_CHARTER and SQUAD_XO_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${SQUAD_XO_CHARTER:-}" ]; then
    printf '%s\n' "$SQUAD_XO_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${SQUAD_XO_SCOPE:-}" ]; then
    printf '%s\n' "$SQUAD_XO_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}
