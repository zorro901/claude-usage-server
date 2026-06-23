#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy-cloudflare.sh

Environment:
  CLOUDFLARE_INGEST_TOKEN   Optional Worker secret value for INGEST_TOKEN.
  CLOUDFLARE_DASHBOARD_PASSWORD Optional Worker secret value for DASHBOARD_PASSWORD.
  CLOUDFLARE_WRANGLER_BIN   Wrangler command to run (defaults to npx wrangler).
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cloudflare_dir="$root_dir/cloudflare"
wrangler_bin="${CLOUDFLARE_WRANGLER_BIN:-npx wrangler}"

if [[ ! -d "$cloudflare_dir" ]]; then
  echo "Missing cloudflare/ directory" >&2
  exit 1
fi

cd "$cloudflare_dir"

echo "Applying D1 migrations..."
$wrangler_bin d1 migrations apply claude_usage --remote

if [[ -n "${CLOUDFLARE_INGEST_TOKEN:-}" ]]; then
  echo "Updating INGEST_TOKEN secret..."
  printf '%s' "$CLOUDFLARE_INGEST_TOKEN" | $wrangler_bin secret put INGEST_TOKEN
fi

if [[ -n "${CLOUDFLARE_DASHBOARD_PASSWORD:-}" ]]; then
  echo "Updating DASHBOARD_PASSWORD secret..."
  printf '%s' "$CLOUDFLARE_DASHBOARD_PASSWORD" | $wrangler_bin secret put DASHBOARD_PASSWORD
fi

echo "Deploying Worker..."
$wrangler_bin deploy
