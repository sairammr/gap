#!/usr/bin/env bash
# redeploy-base-sepolia.sh — Task 10, Step 5 (HARD-GATED, do NOT run without contracts/.env).
#
# Redeploys the MODIFIED swap-vm-fork AquaSwapVMRouter (carrying the new WeekendGap opcode at
# slot 0x52) to Base Sepolia via the fork's own Hardhat Ignition, then runs one WeekendGap
# strategy through the opcode as a smoke test, and records the router address into
# contracts/deployments/base-sepolia.json under the "swapVmRouter" key.
#
# This script is written and ready but is NOT broadcast as part of Task 10 — the live deploy is
# deferred to the user's gated deploy (same as Task 8 Step 6), because it needs secrets that do
# not exist in the repo yet:
#   BASE_SEPOLIA_RPC_URL   (RPC endpoint for Base Sepolia, chain 84532)
#   BASE_SEPOLIA_PRIVATE_KEY  (funded deployer key; the brief calls this PRIVATE_KEY in contracts/.env)
#
# Usage (only after contracts/.env is populated and you intend to broadcast):
#   bash contracts/script/redeploy-base-sepolia.sh
#
set -euo pipefail

# --- resolve paths relative to the worktree root (this script lives in contracts/script/) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FORK_DIR="${WORKTREE_ROOT}/swap-vm-fork"
DEPLOYMENTS="${WORKTREE_ROOT}/contracts/deployments/base-sepolia.json"
PARAMS="ignition/parameters/chain-84532.json"
MODULE="ignition/modules/AquaSwapVMRouter.ts"

# --- load contracts/.env if present (the brief's source of secrets) ---
if [ -f "${WORKTREE_ROOT}/contracts/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${WORKTREE_ROOT}/contracts/.env"
  set +a
fi

# Map the brief's PRIVATE_KEY onto the config-variable name the fork's baseSepolia network reads.
if [ -z "${BASE_SEPOLIA_PRIVATE_KEY:-}" ] && [ -n "${PRIVATE_KEY:-}" ]; then
  export BASE_SEPOLIA_PRIVATE_KEY="${PRIVATE_KEY}"
fi

# --- HARD GATE: refuse to broadcast without the secrets ---
if [ -z "${BASE_SEPOLIA_RPC_URL:-}" ] || [ -z "${BASE_SEPOLIA_PRIVATE_KEY:-}" ]; then
  echo "[redeploy-base-sepolia] BASE_SEPOLIA_RPC_URL / BASE_SEPOLIA_PRIVATE_KEY not set."
  echo "[redeploy-base-sepolia] SKIPPING live deploy — this step is deferred to the user's gated deploy."
  echo "[redeploy-base-sepolia] Populate contracts/.env (BASE_SEPOLIA_RPC_URL + PRIVATE_KEY), then re-run."
  exit 0
fi

echo "[redeploy-base-sepolia] Secrets present — deploying modified AquaSwapVMRouter to Base Sepolia (84532)..."

cd "${FORK_DIR}"

# hardhat CLI (node_modules/.bin may be unpopulated in this environment — call the entry directly).
HARDHAT="node node_modules/hardhat/dist/src/cli.js"

# 1) Deploy the router via Ignition (idempotent/resumable).
${HARDHAT} ignition deploy "${MODULE}" --network baseSepolia --parameters "${PARAMS}"

# 2) Extract the deployed address from Ignition's recorded addresses.
ROUTER_ADDR="$(node -e '
  const fs = require("fs");
  const p = "ignition/deployments/chain-84532/deployed_addresses.json";
  const a = JSON.parse(fs.readFileSync(p, "utf8"));
  const key = Object.keys(a).find(k => k.includes("AquaSwapVMRouter"));
  if (!key) { console.error("router address not found in " + p); process.exit(1); }
  process.stdout.write(a[key]);
')"

echo "[redeploy-base-sepolia] Deployed AquaSwapVMRouter at ${ROUTER_ADDR}"

# 3) Record the address into contracts/deployments/base-sepolia.json under "swapVmRouter".
mkdir -p "$(dirname "${DEPLOYMENTS}")"
node -e '
  const fs = require("fs");
  const path = process.argv[1];
  const addr = process.argv[2];
  let j = {};
  try { j = JSON.parse(fs.readFileSync(path, "utf8")); } catch (_) { j = {}; }
  j.swapVmRouter = addr;
  fs.writeFileSync(path, JSON.stringify(j, null, 2) + "\n");
  console.log("[redeploy-base-sepolia] Recorded swapVmRouter=" + addr + " into " + path);
' "${DEPLOYMENTS}" "${ROUTER_ADDR}"

# 4) Smoke test: run one WeekendGap strategy through the freshly deployed router.
#    The WeekendGap unit/integration coverage lives in swap-vm-fork/test/solidity/WeekendGap.t.sol;
#    this re-runs just that test against the modified build to prove the opcode executes end-to-end.
${HARDHAT} test solidity --build-profile fast test/solidity/WeekendGap.t.sol

echo "[redeploy-base-sepolia] Done."
