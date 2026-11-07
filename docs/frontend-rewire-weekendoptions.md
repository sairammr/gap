# Frontend rewire → WeekendOptions (Kuru-style trade UI)

Date: 2026-11-07

## What this change does

Rewired `app/` from the deleted **Gap options** product to the live **Weekend Options
on 1inch Aqua** contracts (Base Sepolia, chain 84532), and rebuilt the trade screen 1:1
in the style of kuru.io: resting orders listed by side on the left, order-entry ticket
on the right, chart + position tabs in the center.

## The shipped product

Fully-collateralised, physically-settled options on tokenized stock (NVDAx), priced and
settled in USDC. One ERC-20 per series. CALL writers lock the underlying; PUT writers lock
USDC. Physical American exercise reads **no oracle** — the oracle is touched once, at
settlement (`settle(id)`). Fills clear through the real **1inch AquaSwapVMRouter**.

## Key decisions

- **Buy & Sell both route the real `AquaSwapVMRouter.swap`** — the path proven in
  `contracts/script/Lifecycle.s.sol`. `WeekendTaker` was never deployed, so it is not used.
- **Every fill is gated:** the in-app rebuilt SwapVM order must satisfy
  `router.hash(order) == shipped strategyHash` from the deployment JSON, or the trade aborts.
- **Left panel = discrete quote rows** — one row per shipped maker strategy (ask series 0,
  ask series 1, bid series 1), not a synthetic continuous book.
- **Maker is the `WeekendDesk` contract**, not an EOA — it mints option tokens inside the
  Aqua hooks mid-fill. The Earn page is therefore a read-only monitor of the desk's books,
  not a "ship as yourself" form.

## Files changed

- `app/src/App.tsx` — Kuru-style 3-column trade layout; `handleBuy`/`handleSell` via
  `router.quote` → approve → `router.swap`; exercise/close/settle/redeem/claim handlers.
- `app/src/pages/Earn.tsx` — read-only "desk's books on Aqua" monitor
  (`rawBalances` committed vs. `balanceOf` wallet, router-hash gate check).
- `app/src/lib/deployment.ts` — `Deployment` shape + `makerQuotes()` keyed to the live JSON.
- `app/src/lib/strategy.ts` — real 8-field Strategy tuple + `volPct` helpers.
- `app/src/lib/abi.ts` — `weekendOptionsAbi`, `routerAbi` (hash/quote/swap), `optionTokenAbi`,
  `aquaAbi`.
- `app/src/lib/orders.ts` (new) — SwapVM order builder + `takerTraits` encoder.
- `app/src/lib/pricing.ts` — uncapped Black-Scholes preview (binding number is the on-chain
  `quotePremium` read).
- `app/src/hooks/usePositions.ts` + `positions.ts` — ERC-20-per-series model: walk
  `seriesCount`→`getSeries` + `balanceOf` (holder) + `written` (writer); history via the
  publicnode logs endpoint.
- `app/public/deployments/base-sepolia.json` — copied byte-identical from the contracts source.

## Units

Option amounts & underlying: 18 dp. Strike / oracle prices / premiums: 6 dp (quote units).
`volWad`: WAD (1e18 = 100%). CALL `collateralFor` = `amount` underlying; PUT = `ceil(amount*strike/1e18)` USDC.

## Verification

Headless, against the live chain:

- Deployment JSON byte-identical to `contracts/deployments/base-sepolia.json`.
- `seriesCount` = 2; `quotePremium(1 option, series 0)` = 3.288953 USDC (ticket read path works).
- **Router-hash gate GREEN for all 3 shipped orders** (ask-0, ask-1, bid-1) — fills clear,
  not revert. This is the single most important correctness check.
- `tsc -b` + `vite build` clean.

Not verified: a live browser screenshot of the running UI (CUA automation was blocked by a
locked machine / wrong window). To confirm visually: `cd app && npm run dev`.
