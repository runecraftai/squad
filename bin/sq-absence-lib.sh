#!/usr/bin/env bash

open_absence_records() {  # <data-dir>
  local file
  for file in "$1"/absence-*.md; do
    [ -f "$file" ] || continue
    grep -qE '^#*[[:space:]]*Retorno:' "$file" 2>/dev/null && continue
    printf '%s\n' "${file##*/}"
  done
}
