#!/usr/bin/env bash
# Run every perf scenario sequentially into one Markdown report.
# Usage: scripts/perf/run-all.sh [output.md] [extra bench.py args...]
set -euo pipefail
output="${1:-build/perf/report.md}"
shift || true
script_dir="$(cd "$(dirname "$0")" && pwd)"
rm -f "$output"
for scenario in idle single-writer multi-writer sleep-wake; do
    python3 "$script_dir/bench.py" "$scenario" --output "$output" --append "$@"
done
