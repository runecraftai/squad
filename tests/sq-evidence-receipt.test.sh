#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/state" "$BASE/data"
printf 'alpha\nbeta\ngamma\n' > "$BASE/source.log"
export SQUAD_BASE="$BASE"
cli="$ROOT/bin/sq-evidence-receipt.sh"
out=$("$cli" create --task alpha --source "$BASE/source.log" --range 3:3 --range 1:2)
receipt="$BASE/$(awk '{print $2}' <<<"$out")"
[[ $(stat -c %a "$receipt") == 600 ]]
"$cli" verify "$receipt" | grep -qx verified
"$cli" render "$receipt" | grep -q 'range: 3:3'
second=$("$cli" create --task alpha --source "$BASE/source.log" --range 3:3 --range 1:2)
[[ "$out" == "$second" ]]
if "$cli" create --task alpha --source "$BASE/source.log" --range 1:2 --range 2:3 >/dev/null 2>&1; then exit 1; fi
printf 'changed\n' >> "$BASE/source.log"
set +e
result=$("$cli" verify "$receipt"); rc=$?
set -e
[[ $rc == 3 && $result == stale ]]
ln -s /etc/passwd "$BASE/escape"
set +e
"$cli" create --task alpha --source "$BASE/escape" --range 1:1 >/dev/null 2>&1; rc=$?
set -e
[[ $rc == 2 ]]
echo 'ok - create, verify, render, limits, deduplication, private mode and escaped source'
