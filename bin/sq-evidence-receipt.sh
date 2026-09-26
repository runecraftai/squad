#!/usr/bin/env bash
# Shell launcher for the Python evidence-receipt implementation.
exec python3 "$(dirname "$0")/sq-evidence-receipt.py" "$@"
