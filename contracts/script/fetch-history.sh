#!/usr/bin/env bash
# fetch-history.sh — pull REAL NVDA OHLC history and park it where the frontend can read it.
#
#   Yahoo chart endpoint -> normalise -> app/public/nvda-history.json
#
# Companion to sync-spot.sh: that one pins the *pool* to the live NVDA print, this one
# gives the chart the history *behind* that print, so the frontend stops drawing a random
# walk. Yahoo sends no CORS headers, so the browser cannot fetch it directly — we write a
# static JSON into app/public/ and the app fetches it at runtime, exactly like
# app/public/deployments/base-sepolia.json.
#
# Source (no API key, needs a User-Agent — same endpoint sync-spot.sh quotes from):
#   https://query1.finance.yahoo.com/v8/finance/chart/NVDA?range=5d&interval=5m
# Shape: chart.result[0].timestamp[] + chart.result[0].indicators.quote[0].{open,high,low,close}[]
# (parallel arrays; Yahoo nulls the OHLC of buckets with no trades — those are dropped).
#
# Usage:
#   bash script/fetch-history.sh                 # 5d of 5m candles
#   bash script/fetch-history.sh 1mo 30m         # range interval
#   NVDA_SYMBOL=TSLA bash script/fetch-history.sh
set -euo pipefail

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${CONTRACTS_DIR}/.." && pwd)"
OUT="${HISTORY_OUT:-${REPO_DIR}/app/public/nvda-history.json}"

SYMBOL="${NVDA_SYMBOL:-NVDA}"
RANGE="${1:-5d}"
INTERVAL="${2:-5m}"
CHART_URL="https://query1.finance.yahoo.com/v8/finance/chart/${SYMBOL}?range=${RANGE}&interval=${INTERVAL}"

# Same deliberately wide band as sync-spot.sh: it exists to reject nulls, zeros and HTML
# error pages parsed as numbers, not to second-guess the market.
PRICE_MIN=5
PRICE_MAX=10000
MIN_CANDLES=20

command -v python3 >/dev/null || { echo "FAIL: python3 is required to parse the history." >&2; exit 1; }
[ -d "$(dirname "${OUT}")" ] || { echo "FAIL: output dir $(dirname "${OUT}") does not exist." >&2; exit 1; }

raw="$(curl -sS --max-time 30 -H 'User-Agent: Mozilla/5.0' "${CHART_URL}")" || {
  echo "FAIL: could not reach the chart endpoint (${CHART_URL})." >&2; exit 1; }

SYMBOL="${SYMBOL}" RANGE="${RANGE}" INTERVAL="${INTERVAL}" OUT="${OUT}" \
PRICE_MIN="${PRICE_MIN}" PRICE_MAX="${PRICE_MAX}" MIN_CANDLES="${MIN_CANDLES}" \
python3 -c '
import json, os, sys, time

raw = sys.stdin.read()
try:
    res = json.loads(raw)["chart"]["result"][0]
    ts = res["timestamp"]
    q = res["indicators"]["quote"][0]
    o, h, l, c = q["open"], q["high"], q["low"], q["close"]
except Exception:
    sys.exit("FAIL: chart endpoint returned garbage (not the expected JSON): " + raw[:200])

if not (len(ts) == len(o) == len(h) == len(l) == len(c)):
    sys.exit("FAIL: Yahoo timestamp/quote arrays disagree in length - refusing to write history.")

# Bucket size in seconds, so live on-chain samples can be snapped onto the same grid.
unit = {"m": 60, "h": 3600, "d": 86400, "wk": 604800, "mo": 2592000}
iv = os.environ["INTERVAL"]
num = "".join(ch for ch in iv if ch.isdigit())
suf = "".join(ch for ch in iv if not ch.isdigit())
if not num or suf not in unit:
    sys.exit("FAIL: cannot parse interval %r (expected like 5m, 30m, 1h, 1d)." % iv)
step = int(num) * unit[suf]

lo, hi = float(os.environ["PRICE_MIN"]), float(os.environ["PRICE_MAX"])
out = {}   # bucket -> candle; later entries win, which collapses Yaho’s trailing partial bar
for i, t in enumerate(ts):
    vals = (o[i], h[i], l[i], c[i])
    # Yahoo nulls out buckets with no trades. Passing those through breaks the chart.
    if t is None or any(not isinstance(v, (int, float)) for v in vals):
        continue
    if not all(lo <= float(v) <= hi for v in vals):
        sys.exit("FAIL: implausible %s price %r at ts %s (outside %s..%s) - refusing to write history."
                 % (os.environ["SYMBOL"], vals, t, lo, hi))
    bucket = (int(t) // step) * step
    out[bucket] = {
        "time": bucket,
        "open": round(float(o[i]), 4),
        "high": round(float(h[i]), 4),
        "low": round(float(l[i]), 4),
        "close": round(float(c[i]), 4),
    }

candles = [out[k] for k in sorted(out)]
if len(candles) < int(os.environ["MIN_CANDLES"]):
    sys.exit("FAIL: only %d usable candles (need >= %s) - refusing to write a stub history."
             % (len(candles), os.environ["MIN_CANDLES"]))
assert all(candles[i]["time"] < candles[i + 1]["time"] for i in range(len(candles) - 1))

doc = {
    "symbol": os.environ["SYMBOL"],
    "source": "Yahoo Finance /v8/finance/chart",
    "range": os.environ["RANGE"],
    "interval": iv,
    "intervalSeconds": step,
    "fetchedAt": int(time.time()),
    "candles": candles,
}
with open(os.environ["OUT"], "w") as f:
    json.dump(doc, f, separators=(",", ":"))
    f.write("\n")

first, last = candles[0], candles[-1]
fmt = lambda t: time.strftime("%Y-%m-%d %H:%M", time.localtime(t))
print("  wrote %s" % os.environ["OUT"])
print("  %s  %s %s  %d candles" % (doc["symbol"], doc["range"], doc["interval"], len(candles)))
print("  first  %s  O %.2f H %.2f L %.2f C %.2f" % (fmt(first["time"]), first["open"], first["high"], first["low"], first["close"]))
print("  last   %s  O %.2f H %.2f L %.2f C %.2f" % (fmt(last["time"]), last["open"], last["high"], last["low"], last["close"]))
' <<<"${raw}"
