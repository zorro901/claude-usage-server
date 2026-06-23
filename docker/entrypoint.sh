#!/usr/bin/env bash
set -euo pipefail

interval_seconds="${CLAUDE_USAGE_INTERVAL_SECONDS:-300}"
run_once="${CLAUDE_USAGE_RUN_ONCE:-0}"

run_report() {
  CLAUDE_USAGE_SCAN_TRANSCRIPTS=1 \
  CLAUDE_HOME="${CLAUDE_HOME:-/claude-home}" \
  CLAUDE_USAGE_STATE_DIR="${CLAUDE_USAGE_STATE_DIR:-/state}" \
  /app/scripts/claude-usage-report.sh
}

if [[ "$run_once" == "1" ]]; then
  run_report
  exit 0
fi

while true; do
  run_report
  sleep "$interval_seconds"
done
