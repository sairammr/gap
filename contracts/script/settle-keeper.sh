#!/usr/bin/env bash
# settle-keeper.sh — permissionless settlement keeper for the deployed Gap app.
#
#   scan OptionBought logs -> drop settled / unexpired -> settle(strategy, id, holder)
#
# `GapOptionsApp.settle` is permissionless by design: it pays the holder from the backing
# the app ALREADY pulled at buy time and returns the remainder to the maker, so the caller
# only ever spends gas. This script is that caller. It exists so a demo settles itself
# instead of someone clicking "collect".
#
# `settle` needs the full `Strategy` struct (the `Position` record stores only its hash,
# not the poolId / decimals / orientation needed to re-read spot). We rebuild every
# candidate strategy from the `makers` array in deployments/base-sepolia.json and match on
# `hashStrategy` — the same tuples the frontend reconstructs. Nothing bypasses Aqua: the
# collateral was committed through Aqua at ship and pulled through Aqua at buy.
#
# Requires contracts/.env with PRIVATE_KEY + BASE_SEPOLIA_RPC_URL, and a populated
# deployments/base-sepolia.json (DeployGap.s.sol then ShipMany.s.sol).
# PRIVATE_KEY is only a gas payer here — ANY funded key settles anyone's position.
#
# Usage:
#   bash script/settle-keeper.sh                 # one sweep, then exit
#   bash script/settle-keeper.sh --loop 60       # sweep every 60s until Ctrl-C
#   GAP_FROM_BLOCK=55296709 bash script/settle-keeper.sh
#   GAP_LOGS_RPC_URL=https://... bash script/settle-keeper.sh
set -euo pipefail

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${CONTRACTS_DIR}"

CAST="${CAST:-$HOME/.foundry/bin/cast}"
DEPLOY_JSON="deployments/base-sepolia.json"
BROADCAST_JSON="broadcast/DeployGap.s.sol/84532/run-latest.json"

LOOP_SECONDS=0
if [ "${1:-}" = "--loop" ]; then
  LOOP_SECONDS="${2:?--loop needs an interval in seconds}"
  case "${LOOP_SECONDS}" in
    ''|*[!0-9]*) echo "FAIL: --loop interval must be a whole number of seconds." >&2; exit 1 ;;
  esac
elif [ -n "${1:-}" ]; then
  echo "FAIL: unknown argument '${1}'. Usage: settle-keeper.sh [--loop <seconds>]" >&2
  exit 1
fi

# --- prerequisites -----------------------------------------------------------
if [ ! -f .env ]; then
  echo "FAIL: contracts/.env missing - need PRIVATE_KEY and BASE_SEPOLIA_RPC_URL." >&2
  exit 1
fi
set -a; . ./.env; set +a

: "${PRIVATE_KEY:?set PRIVATE_KEY in contracts/.env}"
: "${BASE_SEPOLIA_RPC_URL:?set BASE_SEPOLIA_RPC_URL in contracts/.env}"

if [ ! -x "${CAST}" ]; then
  echo "FAIL: cast not found at ${CAST} - set CAST=/path/to/cast." >&2
  exit 1
fi
if [ ! -f "${DEPLOY_JSON}" ]; then
  echo "FAIL: ${DEPLOY_JSON} missing - run DeployGap.s.sol first." >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "FAIL: python3 is required to parse logs." >&2; exit 1; }

APP="$(python3 -c "import json;print(json.load(open('${DEPLOY_JSON}'))['gapOptionsApp'])")"
if ! python3 -c "import json,sys;sys.exit(0 if json.load(open('${DEPLOY_JSON}')).get('makers') else 1)"; then
  echo "FAIL: ${DEPLOY_JSON} has no 'makers' array - run ShipMany.s.sol first." >&2
  exit 1
fi

# The log scan needs its own endpoint. Alchemy's free tier caps eth_getLogs at a 10-BLOCK
# range (Base Sepolia blocks are ~2s, so that is a 20-second window) and sepolia.base.org
# caps it at 200 — neither can reach back to the deploy block in one call, and chunking it
# would be thousands of requests per sweep. publicnode serves the full range in one shot.
# Reads and sends still go through BASE_SEPOLIA_RPC_URL.
LOGS_RPC="${GAP_LOGS_RPC_URL:-https://base-sepolia-rpc.publicnode.com}"

# eth_getLogs over all of time is rejected by most providers, so start at the deploy block.
if [ -z "${GAP_FROM_BLOCK:-}" ]; then
  if [ -f "${BROADCAST_JSON}" ]; then
    GAP_FROM_BLOCK="$(python3 -c "
import json
r=json.load(open('${BROADCAST_JSON}'))['receipts']
print(min(int(str(x['blockNumber']),16 if str(x['blockNumber']).startswith('0x') else 10) for x in r))
")"
  else
    echo "FAIL: no ${BROADCAST_JSON} - set GAP_FROM_BLOCK to the app's deploy block." >&2
    exit 1
  fi
fi

STRATEGY_TUPLE='(address,address,address,address,bytes32,bool,uint8,uint8,uint256,bytes32)'
OPTION_BOUGHT='OptionBought(uint256,address,uint8,uint256,uint256,uint64,uint256,uint256)'

# --- helpers -----------------------------------------------------------------

# Echoes one `(...)` Strategy tuple per shipped maker, in deployments-file order.
strategy_tuples() {
  python3 -c "
import json
d = json.load(open('${DEPLOY_JSON}'))
for m in d['makers']:
    print('(%s,%s,%s,%s,%s,%s,18,6,%s,%s)' % (
        d['gapOptionsApp'], m['address'], d['nvdax'], d['usdc'], d['poolId'],
        str(d['underlyingIsCurrency0']).lower(), m['volWad'], m['salt']))
"
}

# Echoes `positionId holder` for every OptionBought ever emitted by the app.
# positionId and `to` are both indexed, so they are topics[1] and topics[2].
scan_positions() {
  "${CAST}" logs --rpc-url "${LOGS_RPC}" --from-block "${GAP_FROM_BLOCK}" \
      --address "${APP}" "${OPTION_BOUGHT}" --json \
    | python3 -c "
import json, sys
out = json.load(sys.stdin)
# cast wraps provider failures in an envelope instead of returning a list; surface the
# reason (almost always a getLogs block-range cap) rather than a TypeError.
if not isinstance(out, list):
    errs = '; '.join(e.get('message', '') for e in out.get('errors', []))
    sys.exit('FAIL: log scan rejected by ${LOGS_RPC}: ' + (errs or json.dumps(out))[:300])
for log in out:
    t = log['topics']
    if len(t) < 3: continue
    print(int(t[1], 16), '0x' + t[2][-40:])
"
}

sweep() {
  local now settled expiry shash tuple found pid holder seen=0 sent=0 pending=0 done_=0
  now="$(date +%s)"

  # Rebuild the candidate strategies once per sweep, and index them by hash.
  local -a tuples=() hashes=()
  while IFS= read -r t; do
    tuples+=("${t}")
    hashes+=("$("${CAST}" call "${APP}" "hashStrategy(${STRATEGY_TUPLE})(bytes32)" "${t}" \
                 --rpc-url "${BASE_SEPOLIA_RPC_URL}")")
  done < <(strategy_tuples)

  echo "--------------------------------------------------------------"
  echo "  $(date '+%Y-%m-%d %H:%M:%S')  app ${APP}  logs from block ${GAP_FROM_BLOCK}"

  while read -r pid holder; do
    [ -n "${pid}" ] || continue
    seen=$((seen+1))
    # positions(id) -> (strategyHash, maker, underlying, quote, kind, strike, cap,
    #                   expiry, size, settled, capBacking)
    local -a p=()
    while IFS= read -r line; do p+=("${line}"); done < <(
      "${CAST}" call "${APP}" "positions(uint256)(bytes32,address,address,address,uint8,uint256,uint256,uint64,uint256,bool,uint256)" \
        "${pid}" --rpc-url "${BASE_SEPOLIA_RPC_URL}")
    shash="${p[0]}"
    expiry="${p[7]%% *}"
    settled="${p[9]}"

    if [ "${settled}" = "true" ]; then done_=$((done_+1)); continue; fi
    if [ "${now}" -lt "${expiry}" ]; then
      pending=$((pending+1))
      echo "  position ${pid}: not expired yet (in $((expiry-now))s)"
      continue
    fi

    # The holder must still hold the ERC-1155 — `settle` burns from them, so a
    # transferred position would just waste gas reverting.
    if [ "$("${CAST}" call "${APP}" "balanceOf(address,uint256)(uint256)" "${holder}" "${pid}" \
            --rpc-url "${BASE_SEPOLIA_RPC_URL}" | awk '{print $1}')" = "0" ]; then
      echo "  position ${pid}: holder ${holder} no longer holds it - skipping"
      continue
    fi

    found=""
    for i in "${!hashes[@]}"; do
      if [ "${hashes[$i]}" = "${shash}" ]; then found="${tuples[$i]}"; break; fi
    done
    if [ -z "${found}" ]; then
      echo "  position ${pid}: no known strategy hashes to ${shash} - skipping" >&2
      continue
    fi

    echo "  position ${pid}: expired, settling for ${holder}..."
    if "${CAST}" send "${APP}" "settle(${STRATEGY_TUPLE},uint256,address)" "${found}" "${pid}" "${holder}" \
         --private-key "${PRIVATE_KEY}" --rpc-url "${BASE_SEPOLIA_RPC_URL}" --json \
       | python3 -c "import json,sys;d=json.load(sys.stdin);print('    tx',d['transactionHash'],'status',d['status'])"; then
      sent=$((sent+1))
    else
      echo "    FAILED to settle ${pid} - leaving it for the next sweep" >&2
    fi
  done < <(scan_positions)

  echo "  ${seen} position(s) seen: ${done_} already settled, ${pending} awaiting expiry, ${sent} settled now"
  echo "--------------------------------------------------------------"
}

# --- run ---------------------------------------------------------------------
if [ "${LOOP_SECONDS}" -eq 0 ]; then
  sweep
else
  echo "settle keeper: sweeping every ${LOOP_SECONDS}s (Ctrl-C to stop)"
  while true; do
    # One bad RPC response should not kill a keeper that has been up all day.
    sweep || echo "WARN: sweep failed, retrying in ${LOOP_SECONDS}s" >&2
    sleep "${LOOP_SECONDS}"
  done
fi
