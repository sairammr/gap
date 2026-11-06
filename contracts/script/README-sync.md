# Spot sync keeper — making NVDAx track the real NVDA share price

`DeployGap.s.sol` seeds the Uniswap v4 NVDAx/USDC pool at a flat, fake **100.00 USDC/NVDAx**
and then nothing ever moves it. Any premium priced off that spot is therefore priced off a
constant, and the chart on the frontend is a flat line.

This keeper fixes that. It reads the **live NVDA share price** off a public quote endpoint and
pushes the pool's spot onto it with a single Uniswap v4 swap.

```
script/SyncSpot.s.sol   forge script: moves the pool to TARGET_SPOT_WAD (and a read-only spot() probe)
script/sync-spot.sh     shell wrapper: fetch price -> WAD -> broadcast -> read back, with --loop
```

---

## 1. The price source

**Yahoo Finance's public chart endpoint.** No API key, no signup, no rate-limit headaches at
demo cadence:

```
https://query1.finance.yahoo.com/v8/finance/chart/NVDA?range=1d&interval=1d
```

We read `chart.result[0].meta.regularMarketPrice`. Raw response (trimmed):

```json
{"chart":{"result":[{"meta":{"currency":"USD","symbol":"NVDA","exchangeName":"NMS",
"fullExchangeName":"NasdaqGS","instrumentType":"EQUITY","regularMarketTime":1793977888,
"regularMarketPrice":191.5,"regularMarketChangePercent":5.452,
"fiftyTwoWeekHigh":243.37,"fiftyTwoWeekLow":164.27,
"regularMarketDayHigh":194.895,"regularMarketDayLow":190.0,
"longName":"NVIDIA Corporation","chartPreviousClose":181.6, ...}}],"error":null}}
```

A `User-Agent` header is required; without it Yahoo sometimes serves a challenge page.

**Rejected: Stooq.** The CSV endpoint `https://stooq.com/q/l/?s=nvda.us&f=sd2t2ohlcv&h&e=csv`
now returns an HTML 404 page ("The page you requested does not exist or has been moved"), so it
is not used.

**Sanity gate.** NVDA has split twice (4:1 in 2021, 10:1 in 2024), so there is no stable
"expected" level to hard-code. The wrapper only rejects obvious garbage — a `null`, a zero, or
an HTML error page parsed as a number — by requiring `5 <= price <= 10000` and refusing to move
the pool otherwise. It fails loudly rather than silently syncing to nonsense.

**No Chainlink feed is available.** Base Sepolia carries ~11 push feeds (ETH, BTC, LINK, USDC,
USDT, DAI, wstETH, cbETH variants) and **no equities**. Chainlink does publish `NVDA/USD`, but
only as a **Data Stream** — a pull-based signed report you fetch off-chain and hand to a
verifier contract, gated behind a subscription — not as an `AggregatorV3Interface` you can
`latestRoundData()` from Base Sepolia. So an off-chain keeper is the right answer here, and this
is it.

---

## 2. How the move works

### The swap trick

A Uniswap v4 swap takes a `sqrtPriceLimitX96`. The swap loop stops the instant the pool price
reaches that limit. Combine that with an **effectively unbounded exact-input amount**
(`amountSpecified = -1e30`) and the swap *self-sizes*: it walks the curve to exactly the target
price, consumes only the tokens that walk required, and stops. We never have to compute the
trade size ourselves.

Direction falls out of the comparison. In v4, `zeroForOne == true` pushes the
currency1-per-currency0 price **down**:

| target vs current | `zeroForOne` | sells into pool | takes out |
| --- | --- | --- | --- |
| target > current (NVDA up) | `false` | USDC (currency1) | NVDAx (currency0) |
| target < current (NVDA down) | `true`  | NVDAx (currency0) | USDC (currency1) |

If the pool is already within `MIN_SQRT_MOVE` (1e6 wei of sqrtPriceX96) of the target, the
script sends nothing. That guard is load-bearing: a limit on the wrong side of the current price
makes v4 revert `PriceLimitAlreadyExceeded`.

### The router

v4's `PoolManager` only accepts swaps inside a lock/unlock callback, so an EOA cannot call it
directly. We use the canonical v4-core **`PoolSwapTest`** helper already deployed on Base Sepolia
at `0x8B5bcC363ddE2614281aD875bad385E0A785D3B9` — verified live: it has bytecode, and its
`manager()` returns our `PoolManager` `0x05E7…3408`. It settles by `transferFrom`-ing from
`msg.sender`, so the keeper approves it once (the script checks the allowance and skips the
approve tx when it is already set). No custom `IUnlockCallback` contract was needed.

### sqrtPriceX96 ↔ spot

`UniV4Spot.spotWad` converts the pool's `sqrtPriceX96` into WAD quote-per-underlying. For this
pool's orientation — underlying = NVDAx = **currency0** (18 dp), quote = USDC = **currency1**
(6 dp) — that is:

```
spotWad = (p² / 2⁹⁶) · 1e18 · 10^18 / (2⁹⁶ · 10^6)        where p = sqrtPriceX96
```

`SyncSpot._sqrtPriceForSpot` is the exact algebraic inverse, and deliberately **mirrors
`DeployGap._sqrtPriceForSpot`** (same expression, same Babylonian `_sqrt`) so the keeper and the
deploy land on identical prices for identical inputs:

```
p² = spotWad · 2⁹⁶ · 2⁹⁶ · 10^6 / (1e18 · 10^18)
p  = sqrt(p²)
```

The non-currency0 branch (invert first) is carried over too, so the script stays correct if the
mock addresses are ever redeployed and the sort order flips. The result is clamped into
`[MIN_SQRT_PRICE+1, MAX_SQRT_PRICE-1]`.

As a safety net, `_poolKey` rebuilds the `PoolKey` from `deployments/base-sepolia.json` and
asserts `keccak256(abi.encode(key)) == poolId` before any swap — if the deployment record and
the on-chain pool ever disagree, the script reverts instead of trading the wrong pool.

### Funding

Moving 100 → ~191 on this pool's liquidity takes roughly **38 million USDC** of input. The
deployer only held 10M. Both mocks expose a permissionless `mint(address,uint256)`, so the
script tops the keeper's input token up to a floor of 1e9 whole tokens before swapping. The
top-up is self-limiting — after the first run it only re-mints what the previous run consumed.

---

## 3. Running it

Needs `contracts/.env` with `PRIVATE_KEY` and `BASE_SEPOLIA_RPC_URL`, and a populated
`deployments/base-sepolia.json`. `forge` is expected at `~/.foundry/bin/forge` (override with
`FORGE=...`).

```bash
# one sync
bash script/sync-spot.sh

# keeper loop — this is what makes the frontend chart move during a demo
bash script/sync-spot.sh --loop 60

# a different ticker, if you want to demo something else
NVDA_SYMBOL=TSLA bash script/sync-spot.sh
```

The wrapper prints the fetched price and the pool spot before and after, both read back through
`StateView` + `UniV4Spot` — i.e. the exact code path `quotePremium` prices with, not a
reimplementation.

### The chart's history — `fetch-history.sh`

The keeper pins the pool to the *latest* NVDA print, but the frontend chart also needs the
history **behind** that print, or it has nothing to draw but a flat line (it used to draw a
random walk instead). `script/fetch-history.sh` pulls real OHLC off the same Yahoo endpoint:

```
https://query1.finance.yahoo.com/v8/finance/chart/NVDA?range=5d&interval=5m
  -> chart.result[0].timestamp[]  +  chart.result[0].indicators.quote[0].{open,high,low,close}[]
```

and writes `app/public/nvda-history.json`. It goes in `/public` (not through a build) for the
same reason `deployments/base-sepolia.json` does — and because **Yahoo sends no CORS headers**,
so the browser cannot call it directly and a public CORS proxy would be a third-party MITM on
the demo.

```bash
bash script/fetch-history.sh            # 5d of 5m candles (default)
bash script/fetch-history.sh 1mo 30m    # range interval
```

Normalisation, all of it load-bearing: timestamps are floored onto the interval grid so live
on-chain samples can be bucketed onto the same grid, buckets Yahoo returns `null` OHLC for are
dropped (they break lightweight-charts), duplicate buckets collapse to the later one (Yahoo's
trailing partial bar), the result is asserted strictly increasing, and every price must sit in
the same wide `5..10000` sanity band `sync-spot.sh` uses. Fewer than 20 usable candles is a
hard failure rather than a stub file.

`--loop` mode runs this automatically at most every `HISTORY_REFRESH_SECONDS` (default 300, set
it to `0` to disable). It is best-effort: a failed refresh logs a `WARN` and never touches the
pool sync. A one-shot `sync-spot.sh` does **not** refresh history — run `fetch-history.sh`
yourself before a demo, or just use the loop.

Direct forge usage, if you want to set a price by hand:

```bash
set -a; . ./.env; set +a
TARGET_SPOT_WAD=191500000000000000000 \
  ~/.foundry/bin/forge script script/SyncSpot.s.sol --rpc-url "$BASE_SEPOLIA_RPC_URL" --broadcast

# read-only probe
~/.foundry/bin/forge script script/SyncSpot.s.sol --sig "spot()" --rpc-url "$BASE_SEPOLIA_RPC_URL"
```

Dropping `--broadcast` gives a dry run that simulates the move against a fork and prints the
resulting spot — useful for checking a target before spending gas.

### Observed accuracy

Live on Base Sepolia:

| run | target | spot after | error |
| --- | --- | --- | --- |
| 100.00 → 191.08 | `191080000000000000000` | `191079999999999999995` | 5 wei of WAD (5e-18 USDC) |
| 191.08 → 188.263 | `188263000000000000000` | `188262999999999999995` | 5 wei of WAD |

Better than feared. Tick snapping does **not** apply here: when a swap terminates on its price
limit, v4 sets `sqrtPriceX96` to the limit *exactly* rather than to a tick boundary, so the only
error is the truncation in the integer `_sqrt` — about 5 parts in 1e20. Expect agreement to
~1e-17 USDC, not to the nearest tick.

---

## 4. Limitations — read these before trusting it

- **It is a centralised off-chain keeper, not an oracle.** Whoever holds `PRIVATE_KEY` decides
  what the pool thinks NVDA is worth. There is no signature, no aggregation, no dispute window,
  and nothing on-chain checks the number. This is a demo affordance. A real deployment wants a
  Chainlink equity feed (or Data Stream + verifier) or a hook-maintained TWAP instead of raw
  v4 spot.
- **The pool is a mock with thin liquidity.** ~1M NVDAx / 100M USDC of full-range liquidity.
  Any third party can move the spot with a modest swap, and the keeper will happily move it back
  on its next tick. Nothing here is manipulation-resistant.
- **The keeper prints money.** It mints unbacked mock USDC/NVDAx to fund each move. Total supply
  grows without limit across a long demo. Harmless for mocks; obviously not a real-world pattern.
- **Yahoo is an undocumented endpoint.** No SLA, no versioning, and it can start rate-limiting or
  serving challenge pages at any time. The wrapper fails loudly and, in `--loop` mode, logs a
  `WARN` and retries on the next tick rather than dying — but a sustained outage means a stale
  pool, and nothing on-chain can tell you the price has gone stale.
- **It syncs to the last trade, not a live one.** `regularMarketPrice` is the last regular-session
  print. Outside US market hours it does not move, so a weekend or overnight demo will see the
  keeper repeatedly no-op (which is, fittingly, exactly the overnight gap the product is about).
- **Each sync costs gas and leaves a real swap in the pool's history.** A tight `--loop` interval
  burns Base Sepolia ETH and churns LP fees. 30–60s is plenty for a demo.
- **No slippage or sanity bound on the move itself.** If the quote endpoint returned a price
  inside the sanity band but still wrong, the keeper would move the pool there without
  complaint. Only the `5..10000` band stands between a bad quote and a mispriced book.
