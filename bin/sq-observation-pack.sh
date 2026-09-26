#!/usr/bin/env bash
# Store and page private large text outputs; see --help for the CLI contract.
exec python3 "$(dirname "$0")/sq-observation-pack.py" "$@"
