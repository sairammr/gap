#!/usr/bin/env bash
# sync-spot.sh — pull the REAL NVDA share price and move the Base Sepolia v4
# NVDAx/USDC pool onto it, so the demo prices options off a price that actually moves.
#
#   fetch NVDA quote -> WAD -> SyncSpot.s.sol (price-limited v4 swap) -> read spot back
#
# Price source: Yahoo Finance's public chart endpoint (no API key, no signup):
#   https://query1.finance.yahoo.com/v8/finance/chart/NVDA?range=1d&interval=1d
# We read `chart.result[0].meta.regularMarketPrice`. Stooq's CSV endpoint was tried
# first and now 404s, so it is not used.
#
# Requires contracts/.env with PRIVATE_KEY + BASE_SEPOLIA_RPC_URL, and a populated
# deployments/base-sepolia.json.
#
# Usage:
#   bash script/sync-spot.sh                 # one sync, then exit
#   bash script/sync-spot.sh --loop 60       # re-sync every 60s until Ctrl-C
#   NVDA_SYMBOL=TSLA bash script/sync-spot.sh
set -euo pipefail

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${CONTRACTS_DIR}"

FORGE="${FORGE:-$HOME/.foundry/bin/forge}"
SYMBOL="${NVDA_SYMBOL:-NVDA}"
QUOTE_URL="https://query1.finance.yahoo.com/v8/finance/chart/${SYMBOL}?range=1d&interval=1d"

# Sanity band for a believable share price. NVDA has split twice (4:1 in 2021,
# 10:1 in 2024), so the absolute level is not stable across years — this band is
# deliberately wide and exists only to reject nulls, zeros and HTML error pages.
PRICE_MIN=5
PRICE_MAX=10000

LOOP_SECONDS=0
if [ "${1:-}" = "--loop" ]; then
  LOOP_SECONDS="${2:?--loop needs an interval in seconds}"
  case "${LOOP_SECONDS}" in
    ''|*[!0-9]*) echo "FAIL: --loop interval must be a whole number of seconds." >&2; exit 1 ;;
  esac
elif [ -n "${1:-}" ]; then
  echo "FAIL: unknown argument '${1}'. Usage: sync-spot.sh [--loop <seconds>]" >&2
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

if [ ! -x "${FORGE}" ]; then
  echo "FAIL: forge not found at ${FORGE} - set FORGE=/path/to/forge." >&2
  exit 1
fi
if [ ! -f deployments/base-sepolia.json ]; then
  echo "FAIL: deployments/base-sepolia.json missing - run DeployGap.s.sol first." >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "FAIL: python3 is required to parse the quote." >&2; exit 1; }

# --- helpers -----------------------------------------------------------------

# Echoes the live share price as a plain decimal, or exits non-zero with a reason.
fetch_price() {
  local raw
  raw="$(curl -sS --max-time 20 -H 'User-Agent: Mozilla/5.0' "${QUOTE_URL}")" || {
    echo "FAIL: could not reach the quote endpoint (${QUOTE_URL})." >&2; return 1; }

  PRICE_MIN="${PRICE_MIN}" PRICE_MAX="${PRICE_MAX}" SYMBOL="${SYMBOL}" \
  python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    meta = json.loads(raw)["chart"]["result"][0]["meta"]
except Exception:
    sys.exit("FAIL: quote endpoint returned garbage (not the expected JSON): " + raw[:200])
px = meta.get("regularMarketPrice")
if not isinstance(px, (int, float)):
    sys.exit("FAIL: no regularMarketPrice in quote for " + os.environ["SYMBOL"])
lo, hi = float(os.environ["PRICE_MIN"]), float(os.environ["PRICE_MAX"])
if not (lo <= px <= hi):
    sys.exit("FAIL: implausible %s price %r (outside %s..%s) - refusing to move the pool."
             % (os.environ["SYMBOL"], px, lo, hi))
print(px)
' <<<"${raw}"
}

# Echoes the pool's current spot in WAD, read back through StateView + UniV4Spot.
read_spot_wad() {
  "${FORGE}" script script/SyncSpot.s.sol --sig "spot()" --rpc-url "${BASE_SEPOLIA_RPC_URL}" 2>/dev/null \
    | sed -n 's/^  spotWad \([0-9]*\)$/\1/p' | tail -1
}

# Pretty-prints a WAD as a dollar figure.
fmt_wad() { python3 -c "import sys;print('%.6f' % (int(sys.argv[1])/1e18))" "${1:-0}"; }

sync_once() {
  local price target before after
  price="$(fetch_price)"
  target="$(python3 -c "import sys;from decimal import Decimal;print(int(Decimal(sys.argv[1])*10**18))" "${price}")"

  before="$(read_spot_wad)"
  [ -n "${before}" ] || { echo "FAIL: could not read pool spot - is the RPC up?" >&2; return 1; }

  echo "--------------------------------------------------------------"
  echo "  $(date '+%Y-%m-%d %H:%M:%S')  ${SYMBOL} = \$${price}  (Yahoo Finance)"
  echo "  pool spot before : \$$(fmt_wad "${before}")"

  TARGET_SPOT_WAD="${target}" "${FORGE}" script script/SyncSpot.s.sol \
    --rpc-url "${BASE_SEPOLIA_RPC_URL}" --broadcast \
    | grep -vE '^\s+[│├└╰╭]' | sed -n '/== Logs ==/,/^$/p;/^Error/p'

  after="$(read_spot_wad)"
  echo "  pool spot after  : \$$(fmt_wad "${after}")   (target \$${price})"
  echo "--------------------------------------------------------------"
}

# --- run ---------------------------------------------------------------------
if [ "${LOOP_SECONDS}" -eq 0 ]; then
  sync_once
else
  echo "keeper loop: re-syncing ${SYMBOL} every ${LOOP_SECONDS}s (Ctrl-C to stop)"
  # The frontend chart also wants the NVDA history *behind* the live print. Refresh it
  # here at most every HISTORY_REFRESH_SECONDS (default 5m, matching the 5m candles).
  # Strictly best-effort: a failure here never touches the pool sync above.
  HISTORY_REFRESH_SECONDS="${HISTORY_REFRESH_SECONDS:-300}"
  history_last=0
  while true; do
    if [ "${HISTORY_REFRESH_SECONDS}" -gt 0 ] && [ -f script/fetch-history.sh ] \
       && [ $(( $(date +%s) - history_last )) -ge "${HISTORY_REFRESH_SECONDS}" ]; then
      history_last="$(date +%s)"
      bash script/fetch-history.sh || echo "WARN: history refresh failed (chart will use the last file)" >&2
    fi
    # A single bad quote or a dropped RPC should not kill a demo that has been
    # running all day; log it and try again on the next tick.
    sync_once || echo "WARN: sync failed, retrying in ${LOOP_SECONDS}s" >&2
    sleep "${LOOP_SECONDS}"
  done
fi
