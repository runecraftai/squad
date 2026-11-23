#!/usr/bin/env bash

fm_afk_decimal_setting() {
  local value=$1 fallback=$2 minimum=${3:-0}
  case "$value" in ''|*[!0123456789]*) printf '%s\n' "$fallback"; return ;; esac
  value=${value#"${value%%[!0]*}"}
  value=${value:-0}
  if [ "${#value}" -le 9 ] && [ "$value" -ge "$minimum" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

fm_afk_routine_ledger_limit() {
  fm_afk_decimal_setting "${SQUAD_ROUTINE_LEDGER_LIMIT:-}" 1000 1
}
