#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BASE="$TMP/base"; mkdir -p "$BASE/state" "$BASE/data"; export SQUAD_BASE="$BASE"
CLI="$ROOT/bin/sq-observation-pack.sh"
python3 - "$BASE/input" <<'PY'
import sys
with open(sys.argv[1], 'w') as f:
    for i in range(3000): f.write(f'{i:04d} '+('x'*20)+'\n')
PY
id=$($CLI create --task alpha --source "$BASE/input")
raw="$BASE/data/alpha/artifacts/observations/$id.raw"
manifest="${raw%.raw}.json"
[[ $(stat -c %a "$raw") == 600 && $(stat -c %a "$manifest") == 600 ]]
[[ $($CLI create --task alpha --source "$BASE/input") == "$id" ]]
card=$($CLI card "$id")
[[ ${#card} -le 8192 ]]
grep -q "read $id --offset 1 --limit 200" <<<"$card"
page=$($CLI read "$id" --offset 1 --limit 200 --receipt)
grep -q '^next_offset: 201$' <<<"$page"; grep -q '^receipt: ' <<<"$page"
for ((offset=1; offset<=3000; offset+=200)); do
  $CLI read "$id" --offset "$offset" --limit 200 | sed -n 's/^[0-9]*: //p' >> "$TMP/recovered"
done
cmp -s "$raw" "$TMP/recovered" || { echo 'pagination did not recover all data' >&2; exit 1; }
cp "$manifest" "$TMP/manifest"; printf bad >> "$manifest"
set +e; $CLI card "$id" >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 3 ]]; mv "$TMP/manifest" "$manifest"
head -c 100 "$BASE/input" > "$BASE/small"
set +e; $CLI create --task alpha --source "$BASE/small" >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 2 ]]
# 9: ten independent fixtures each keep their card under one quarter and recover byte-for-byte.
for i in $(seq 1 10); do
  fixture="$BASE/fixture$i"
  python3 - "$fixture" <<'PY'
import sys
with open(sys.argv[1], 'w') as f:
    for n in range(1000): f.write(f'{n:04d} '+('z'*24)+'\n')
PY
  fixture_id=$($CLI create --task alpha --source "$fixture")
  input_bytes=$(wc -c < "$fixture")
  card_bytes=$("$CLI" card "$fixture_id" | wc -c)
  (( card_bytes * 4 <= input_bytes )) || { echo "card budget failed for fixture $i" >&2; exit 1; }
  : > "$TMP/fixture-recovered"
  for ((offset=1; offset<=1000; offset+=200)); do
    $CLI read "$fixture_id" --offset "$offset" --limit 200 | sed -n 's/^[0-9]*: //p' >> "$TMP/fixture-recovered"
  done
  cmp -s "$fixture" "$TMP/fixture-recovered" || { echo "recovery failed for fixture $i" >&2; exit 1; }
done
echo 'ok - criteria 1-7 and 9: private deduplicated packs, bounded card, page, receipt, integrity, source limits and 10-fixture recovery'
