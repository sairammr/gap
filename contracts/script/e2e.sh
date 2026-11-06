#!/usr/bin/env bash
# e2e.sh — full live end-to-end test of the deployed Gap stack on Base Sepolia.
#
#   preflight -> buy -> wait past expiry -> settle
#
# Every phase asserts on real chain state inside script/E2E.s.sol and reverts on
# mismatch, so a green run means the money path actually worked.
#
# Requires contracts/.env with PRIVATE_KEY + BASE_SEPOLIA_RPC_URL, and a populated
# deployments/base-sepolia.json (run DeployGap.s.sol then Ship.s.sol first).
#
# Usage:  bash script/e2e.sh [expiry_seconds]      (default 120)
set -euo pipefail

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${CONTRACTS_DIR}"

FORGE="${FORGE:-$HOME/.foundry/bin/forge}"
EXPIRY_SECONDS="${1:-120}"
export E2E_EXPIRY_SECONDS="${EXPIRY_SECONDS}"

if [ -f .env ]; then set -a; . ./.env; set +a; fi

: "${PRIVATE_KEY:?set PRIVATE_KEY in contracts/.env}"
: "${BASE_SEPOLIA_RPC_URL:?set BASE_SEPOLIA_RPC_URL in contracts/.env}"

if [ ! -f deployments/base-sepolia.json ]; then
  echo "FAIL: deployments/base-sepolia.json missing - run DeployGap.s.sol first." >&2
  exit 1
fi

run() { # run <label> <sig> [--broadcast]
  local label="$1" sig="$2"; shift 2
  echo
  echo "=============================================================="
  echo "  ${label}"
  echo "=============================================================="
  "${FORGE}" script script/E2E.s.sol --sig "${sig}" --rpc-url "${BASE_SEPOLIA_RPC_URL}" "$@" \
    | grep -vE '^\s+[│├└╰╭]' | sed -n '/== Logs ==/,/^$/p;/Error/p'
}

run "PHASE 0 - preflight (read-only)" "checks()"
run "PHASE 1 - buy option via GapTaker" "buy()" --broadcast

EXPIRY="$(python3 -c "import json;print(json.load(open('deployments/e2e-state.json'))['expiry'])")"
NOW="$(date +%s)"
WAIT=$(( EXPIRY - NOW + 15 ))   # +15s so the settle tx is mined comfortably past expiry
if [ "${WAIT}" -gt 0 ]; then
  echo
  echo "waiting ${WAIT}s for the option to expire (expiry=${EXPIRY})..."
  sleep "${WAIT}"
fi

run "PHASE 2 - settle after expiry" "settle()" --broadcast

echo
echo "=============================================================="
echo "  E2E PASSED - buy and settle both asserted against chain state"
echo "=============================================================="
