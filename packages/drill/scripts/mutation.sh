#!/usr/bin/env bash
# Manual mutation testing for the drill module, invoked by `make mutation`.
#
# gremlins is a development tool, never a module dependency: the pinned version
# is installed on demand with `go install` into a tool directory outside the
# repository, so go.mod, go.sum, and vendor state stay untouched. The Go
# toolchain is required either way, because gremlins runs `go test` per mutant.
#
# There are no --threshold-* flags on purpose: this is a measuring instrument,
# not a gate, so a low score is printed and never fails the run. It is also not
# wired into `make test`, `make lint`, or any workflow.
#
# The timeout coefficient is the load-sensitive knob, not decoration. With the
# gremlins default, a loaded machine turns surviving mutants into timeouts and
# inflates the score (./internal/types reads 89.66% with 24 timeouts instead of
# 84.91% with none). 30 keeps the baseline stable, and the timed-out count is
# printed next to efficacy on every run so a slow or busy machine stays visible
# instead of quietly raising the number.
#
# The recorded baseline lives with the target, in the Makefile.
set -euo pipefail

GREMLINS_VERSION=v0.6.0
TIMEOUT_COEFFICIENT=30

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool_dir="${XDG_CACHE_HOME:-$HOME/.cache}/drill-tools/gremlins/$GREMLINS_VERSION"
gremlins="$tool_dir/bin/gremlins"
out_dir="$repo_dir/tmp/mutation"

if ! command -v go >/dev/null 2>&1; then
	echo "mutation: go is not on PATH. gremlins installs on demand with 'go install' and runs 'go test', so the Go toolchain is required." >&2
	exit 1
fi

if [ ! -x "$gremlins" ]; then
	echo "mutation: installing gremlins $GREMLINS_VERSION into $tool_dir"
	mkdir -p "$tool_dir/bin"
	GOBIN="$tool_dir/bin" go install "github.com/go-gremlins/gremlins/cmd/gremlins@$GREMLINS_VERSION"
fi

if [ ! -x "$gremlins" ]; then
	echo "mutation: install did not produce $gremlins" >&2
	exit 1
fi

mkdir -p "$out_dir"

# Gremlins prints its totals as a human summary while the machine-readable
# report goes to the JSON file, and the JSON has no timed-out counter, so the
# printed summary is the source for the numbers this target reports.
summarize() {
	local package=$1 log=$2 report_rel=$3
	local efficacy counts timed_out killed lived not_covered
	efficacy=$(sed -n 's/^Test efficacy: \(.*\)%$/\1/p' "$log" | tail -n 1)
	counts=$(sed -n 's/^Killed: \([0-9][0-9]*\), Lived: \([0-9][0-9]*\), Not covered: \([0-9][0-9]*\)$/\1 \2 \3/p' "$log" | tail -n 1)
	timed_out=$(sed -n 's/^Timed out: \([0-9][0-9]*\),.*$/\1/p' "$log" | tail -n 1)
	if [ -z "$efficacy" ] || [ -z "$counts" ] || [ -z "$timed_out" ]; then
		echo "mutation: could not read the gremlins summary for $package; see $log" >&2
		return 1
	fi
	read -r killed lived not_covered <<<"$counts"
	printf '%s: efficacy %s%% | timed out %s | killed %s, lived %s, not covered %s | report %s\n' \
		"$package" "$efficacy" "$timed_out" "$killed" "$lived" "$not_covered" "$report_rel"
}

status=0
for package in ./internal/agent ./internal/types; do
	name=${package#./internal/}
	report_rel="tmp/mutation/$name.json"
	log="$out_dir/$name.log"
	echo "mutation: $package (timeout coefficient $TIMEOUT_COEFFICIENT)"
	if ! (cd "$repo_dir" && "$gremlins" unleash --timeout-coefficient "$TIMEOUT_COEFFICIENT" --output "$report_rel" "$package") >"$log" 2>&1; then
		echo "mutation: gremlins failed on $package; last lines of $log:" >&2
		tail -n 20 "$log" >&2
		status=1
		continue
	fi
	summarize "$package" "$log" "$report_rel" || status=1
done

exit "$status"
