#!/bin/sh
# Runs a throwaway API server with demo data, for the simulator and the UI tests.
# Usage: scripts/dev-server.sh [port]
#
# Needs the web repo (octax-app/solobill) cloned next to this one, with `pnpm install` run, or
# SOLOBILL_WEB set to its path.
#
# It never loads the web repo's .env, so it cannot reach the real R2 bucket, and each run gets an empty
# database in a temporary folder. Log in with owner@example.com and demo-password.
set -eu

port="${1:-3100}"
web="$(cd "${SOLOBILL_WEB:-$(dirname "$0")/../../solobill}" && pwd)"
data="$(mktemp -d)"
export DATA_DIR="$data" PORT="$port"

cd "$web"
node src/server/scripts/admin.ts owner@example.com demo-password > /dev/null
node src/server/index.ts &
server=$!
trap 'kill "$server" 2>/dev/null; rm -rf "$data"' EXIT INT TERM

until curl -sf "http://localhost:$port/health" > /dev/null; do sleep 0.2; done
node src/server/scripts/demo-data.ts owner@example.com demo-password "http://localhost:$port"
# The daily job runs at startup, before the demo data exists, so run it once more.
node --input-type=module -e "
  const { runRenewals, runReminders } = await import('./src/server/services/renewals.ts')
  runRenewals()
  runReminders()
"
echo "Server ready at http://localhost:$port"
wait "$server"
