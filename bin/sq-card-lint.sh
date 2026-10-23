#!/usr/bin/env bash
# Warns about decision-card grammar drift in a report or decision record.
#
# The prose block is owned by AGENTS.md section 9 and rendered by bin/sq-ask.sh;
# docs/decision-card-standard.md owns the card schema. This script only reports
# lines that drift from the prose grammar. It never blocks anything: every
# warning goes to stderr as `warning: <file>:<line>: <CODE> <detail>`, and the
# exit status is always 0, so it cannot fail a pipeline.
#
# Grammar checked, with awk only:
#   D<n> - <title>         opens a decision block. The block ends at the next
#                          heading or header; blank lines do not end it, as in
#                          bin/sq-ask.sh.
#   O<m> - <label>: <desc> an option line, indented two spaces, inside the open
#                          block. Exactly one option per block ends with
#                          " (recommended)".
#   O0 - Your own words    the free-text escape. It is not sequenced and never
#                          counts as the recommended option.
#   C<n> - <title>         legacy header prefix from old reports. It opens a
#                          block like D<n>, with a warning.
#
# Codes:
#   RECOMENDACAO_AUSENTE       a block has no option ending in "(recommended)"
#   RECOMENDACAO_DUPLICADA     a block has two or more options ending in it
#   OPCAO_ORFA                 an O<m> line outside any decision block
#   OPCAO_FORA_DE_SEQUENCIA    an O<m> number that is not the next one (O1, O2, ...)
#   PREFIXO_LEGADO             a C<n> header, accepted but warned as legacy
#   ARQUIVO_ILEGIVEL           a file argument cannot be read; reported at line 0
#
# Known gap: O0 and D0 are not checked against the owner grammar. They need
# codes outside the four required, so they are not reported.
#
# Lines inside fenced code blocks are examples, not records, and are skipped.
#
# Usage: bin/sq-card-lint.sh <file>...
#        bin/sq-card-lint.sh --help
set -u

usage() {
  cat <<'EOF'
Usage: bin/sq-card-lint.sh <file>...
Print decision-card grammar warnings for each file to stderr.
Always exits 0, so it never fails a pipeline.
EOF
}

# shellcheck disable=SC2016 # The awk program's $0 and $1 are awk fields, not shell expansions.
LINT_AWK='
function warn(at, code, detail) {
  printf "warning: %s:%d: %s %s\n", name, at, code, detail
}
function close_block(   why) {
  if (!in_block) return
  if (recommended == 0) {
    if (options > 0) why = "no option ends with (recommended)"
    else why = "decision has no options"
    warn(header_line, "RECOMENDACAO_AUSENTE", why)
  } else if (recommended > 1) {
    warn(header_line, "RECOMENDACAO_DUPLICADA", recommended " options end with (recommended)")
  }
  in_block = 0
}
BEGIN {
  name = ENVIRON["LINT_NAME"]
  in_block = 0
  in_fence = 0
}
{
  sub(/\r$/, "")
}
/^[[:space:]]*(```|~~~)/ {
  line = $0
  sub(/^[[:space:]]*/, "", line)
  mark = substr(line, 1, 1)
  run = 0
  while (substr(line, run + 1, 1) == mark) run++
  if (!in_fence) {
    close_block()
    in_fence = 1
    fence_mark = mark
    fence_run = run
    next
  }
  if (mark == fence_mark && run >= fence_run && substr(line, run + 1) ~ /^[[:space:]]*$/) in_fence = 0
  next
}
in_fence {
  next
}
/^#/ {
  close_block()
  next
}
/^[CD][0-9]+ - / {
  close_block()
  in_block = 1
  header_line = FNR
  options = 0
  recommended = 0
  expected = 1
  if (substr($0, 1, 1) == "C") {
    warn(FNR, "PREFIXO_LEGADO", "legacy C prefix on decision header; write D<n> - ")
  }
  next
}
/^[[:space:]]*O[0-9]+ - / {
  match($0, /O[0-9]+ - /)
  num = substr($0, RSTART + 1, RLENGTH - 4) + 0
  if (!in_block) {
    warn(FNR, "OPCAO_ORFA", "O" num " is outside any decision block")
    next
  }
  if ($0 !~ /^  O[0-9]+ - /) {
    warn(FNR, "OPCAO_ORFA", "O" num " must be indented two spaces inside its decision block")
  }
  if (num == 0) {
    next
  }
  if (num != expected) {
    warn(FNR, "OPCAO_FORA_DE_SEQUENCIA", "found O" num ", expected O" expected)
  }
  expected = num + 1
  options++
  if ($0 ~ / \(recommended\)$/) {
    recommended++
  }
  next
}
END {
  close_block()
}
'

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 0
fi
case $1 in
  -h|--help)
    usage
    exit 0
    ;;
esac

for file in "$@"; do
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'warning: %s:0: ARQUIVO_ILEGIVEL cannot read file\n' "$file" >&2
    continue
  fi
  LINT_NAME="$file" awk "$LINT_AWK" < "$file" >&2
done
exit 0
