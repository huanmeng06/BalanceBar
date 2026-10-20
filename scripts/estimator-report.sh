#!/usr/bin/env bash
# Prints the per-scenario estimator error report for a shadow log (JSONL).
# Usage: scripts/estimator-report.sh <shadow-log.jsonl>
set -euo pipefail
cd "$(dirname "$0")/.."
tool="$(mktemp -d)/estimator-report"
swiftc -O -module-name EstimatorReport -o "$tool" \
  Sources/Quota/Estimator/*.swift Sources/Quota/Model/*.swift \
  Sources/Quota/Account/*.swift Sources/Quota/IO/*.swift \
  scripts/estimator-report/main.swift
exec "$tool" "$@"
