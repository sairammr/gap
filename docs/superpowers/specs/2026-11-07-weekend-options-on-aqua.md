# Weekend Options on 1inch Aqua — Spec

## Goal

Re-implement Weekend Options' option mechanism **exactly** — series, pooled collateral,
CALL/PUT only, American physical exercise, oracle read only after expiry, pro-rata
redeem/claim — with 1inch Aqua as the collateral layer. Delete the existing
capped-spread `GapOptionsApp` product entirely.

## Source of truth

`/Users/sairammr/Documents/GitHub/Claude sessions/weekend-options (1)/contracts/src/core/OptionsProtocol.sol`
and `core/OptionToken.sol`. Behaviour is pinned by their own test names
(`contracts/test/OptionsProtocol.test.js`, `Advanced.test.js`), reproduced in §6.

## 1. What is ported verbatim

| Mechanism | Rule |
|---|---|
| `Kind` | `CALL`, `PUT` only. No spreads, no cap, no gap/binary product. |
| Series | `(underlying, expiry, kind, strike)` deduped by `keccak256`; one ERC-20 `OptionToken` per series; `1e18` units = the right on 1 token of underlying. |
| Collateral | CALL locks `amount` **underlying** (covered). PUT locks `amount * strike` **USDC** (cash-secured). Rounds UP. |
| Pooled custody | Writers write into shared `poolUnderlying` / `poolCash` per series. `written[id][writer]` and `totalWritten` track who owes what. Option tokens are fungible — a holder exercises against the pool, not against a named writer. |
| `exercise(id, amount)` | American, partial, **reads no oracle**. CALL: holder pays `amount*strike` USDC, receives `amount` underlying. PUT: holder delivers `amount` underlying, receives `amount*strike` USDC. |
| `close(id, amount)` | Writer unwinds before expiry by returning option tokens, unlocking collateral. |
| `settle(id)` | After expiry. Reads the oracle **once**. Splits the pools into holder/writer shares. |
| `redeem` / `claim` | Pro-rata against `supplyAtSettle` / `writtenAtSettle`. `redeemFor` / `claimFor` let a keeper pay anyone. |
| Grace | If no settlement price within `SETTLEMENT_GRACE = 7 days`, unexercised options settle worthless — holders always had the oracle-free exercise route. |
| Collateralisation | Full, both sides, before a position can exist. No margin. Nothing to liquidate. |

Settlement of an in-the-money unexercised CALL pays the holder **in stock**, not cash
(their test: *"auto net settlement: unexercised in-the-money Upside pays the profit in
stock"*). PUT mirrors it in USDC. No swap venue is needed at the settlement instant.

## 2. What Aqua changes, and why

Aqua's premise: collateral stays in the maker's wallet until a fill pulls it. Two
consequences, both already settled by the team's own `AQUA.md`:

**2.1 No `deposit` / `freeBalance`.** Weekend Options has writers deposit into protocol
custody first. Under Aqua the writer calls `AQUA.ship(app, abi.encode(strategy), [token],
[amount])`, which moves **no tokens** — it records a commitment. The cover leaves their
wallet only when a buy calls `AQUA.pull`. A writer who is never hit never moves a token.

**2.2 No resting order book, no RFQ signatures.** A posted quote must reserve collateral,
which requires custody. So price is **parametric**: the maker ships one `volWad` and the
chain prices Black-Scholes (r = 0) off the Uniswap v4 spot at fill time. Shipping on-chain
IS the authorisation — the maker signs nothing and need not be online.

**2.3 Solvency is `min(promise, means)`.** Because `ship` moves nothing, a maker can be
committed on Aqua's books and broke in their wallet; the pull then reverts inside Aqua
with `ERC20InsufficientBalance`. Every solvency check uses
`min(AQUA.rawBalances(...), IERC20.balanceOf(maker))`.

**2.4 Aqua is the registry.** Every maker is recoverable from `IAqua.Shipped(maker, app,
strategyHash, strategy)` logs, which carry the full abi-encoded `Strategy`. No indexer,
no CLOB. Quoting across makers picks the cheapest solvent one; since pricing ignores
`s.maker`, makers differ only by `volWad` — implied vol is the competitive axis.

**2.5 The premium path is a callback.** The app snapshots the maker's Aqua balance, calls
`IGapOptionCallback.gapOptionCallback` on `msg.sender`, then asserts the push landed via
`_safeCheckAquaPush`. `msg.sender` must therefore be a contract; an EOA routes through
`GapTaker`.

## 3. Units

- Option and underlying amounts: **18 dp**. `1e18` options = the right on `1e18` wei of underlying.
- `strike` and all prices: **USDC units (6 dp) per 1e18 of the asset** — matching
  `IPriceOracle`'s "Prices are USDC (6 decimals) per 1e18 units of the asset".
  **This differs from the deleted product, which used WAD strikes.**
- `volWad`: WAD (1e18 == 100% annualised IV).

## 4. Oracle

`IPriceOracle` as they define it:

```solidity
function spot(address asset) external view returns (uint256 price, uint256 updatedAt);
function settlementPrice(address asset, uint64 expiry) external view returns (uint256 price, bool ok);
```

`spot` is for quoting and display — their comment: *"Never for exercise."*
`settlementPrice` gates `settle`: `ok == false` until final.

This port keeps the Uniswap v4 `StateView.getSlot0` reader as the `spot` implementation
and the settlement source. Instantaneous `slot0` is manipulable on a thin pool; that risk
is materially reduced here because exercise — the holder's primary route — never reads it.
A Pyth-style time-weighted window is a later swap behind the same interface.

## 5. Reused from the existing repo

- `lib/GapPricing.sol` — `call`, `put`, `normalCdf`, `_sigmaRootT` are vanilla
  Black-Scholes (r = 0, Abramowitz-Stegun 26.2.17) and are kept as-is. The capped
  `premium(kind, …)` entry point goes with the deleted product.
- `lib/UniV4Spot.sol` — kept.
- `GapTaker.sol` — **deleted**: it is hard-typed on `GapOptionsApp.Strategy` and forwards a
  `cap` argument. Replaced by `WeekendTaker.sol` against the new app. The callback
  interface `IGapOptionCallback` itself is unchanged and kept.
- `mocks/MockERC20.sol`, `test/helpers/MockStateView.sol`, `test/helpers/TakerStub.sol` — kept.

## 6. Behaviour pinned by their tests (ported case-for-case)

**Upside (CALL)**
1. Quotes cannot exist without collateral.
2. A Saturday wick changes nothing: no margin, no liquidation, collateral stays.
3. Buyer exercises physically, pays strike, receives real stock — **no oracle read**.
4. Unexercised in-the-money Upside auto-settles, paying the profit **in stock**.
5. Out of the money: buyer loses only the premium, writer gets the stock back.
6. Cannot trade or exercise after expiry; settlement waits for the window.
7. If the oracle never reports, unexercised options settle worthless after the grace period.
8. Writer can buy back and close to unlock collateral early.

**Floor (PUT)**
9. Maker locks USDC; buyer exits on a Saturday at the strike.
10. Net settles an unexercised Floor in USDC.

**Keeper**
11. Anyone can pay out holders and credit writers after expiry (`redeemFor` / `claimFor`).

## 7. Explicitly out of scope

Two-sided order book, bids, sell-back, signed RFQ, maker bots, atomic hedging, vaults,
`ShieldedLender`, the pooled gap/binary market, passkey accounts, Pyth, corporate-action
multipliers, and the SwapVM `WeekendGap` opcode. None are part of the option mechanism.

## 8. Deletion

The capped-spread product is removed: `GapOptionsApp.sol`, its tests, its scripts, and
every frontend surface carrying a `cap` parameter. Inventory is produced by reconnaissance
before any edit lands.

## 9. Golden test vectors (lifted from their suite)

Underlying NVDAx (18 dp), quote USDC (6 dp), CALL series strike `205` (= `usd(205)`,
6 dp per 1e18), size `sh(10)` = `10e18` options.

**Physical exercise (no oracle):**
- holder pays `usd(2050)` = `10 * 205` USDC
- holder receives `sh(10)` = `10e18` NVDAx
- after settle with no exercises outstanding, the writer claims `usd(2050)` USDC and `0` NVDAx

**In-the-money unexercised CALL, settlePrice `212`:**
- holder redeems `10 * (212 - 205) / 212` = `sh("0.330188679245283018")` NVDAx (±10 wei)
- writer claims `sh("9.669811320754716981")` NVDAx (±10 wei)
- i.e. `holderUnderlying = amount * (settlePrice - strike) / settlePrice`

**Out-of-the-money CALL, settlePrice `201`:**
- holder redeems `0` NVDAx
- writer claims the full `sh(10)` NVDAx back

These exact numbers must be reproduced by the port's tests.

## 10. Exact post-expiry arithmetic (verbatim from their implementation)

**Rounding:** every post-expiry formula **floors**. `Math.mulDiv(a,b,c)` with no rounding
arg is floor; there is not one `Ceil` in the settlement block. The only `Ceil` is
`collateralFor`, which rounds the writer's obligation **against** the writer.

### `_settle(id)`

Oracle sequence:
1. `settlementPrice(underlying, expiry)` → if `ok`, use `p`.
2. `!ok` and `now < expiry + SETTLEMENT_GRACE` → revert `OracleNotReady`.
3. `!ok` and past grace → `spot(underlying)`; `p = updatedAt >= expiry ? sp : 0`.
   A spot published *before* expiry is rejected and `p` becomes 0.

Then, with `supply = token.totalSupply()`:

```
if p > 0:
    CALL: hU = p > strike ? floor(supply * (p - strike) / p) : 0
    PUT:  hC = floor(supply * (strike > p ? strike - p : 0) / 1e18)
hU = min(hU, poolUnderlying)
hC = min(hC, poolCash)

settled          = true
settlePrice      = p
supplyAtSettle   = supply
holderUnderlying = hU
holderCash       = hC
writerUnderlying = poolUnderlying - hU     // exact subtraction, not a second mulDiv
writerCash       = poolCash - hC
writtenAtSettle  = totalWritten
```

Three behaviours that MUST be preserved:
- `_settle` does **not** zero or decrement `poolUnderlying`/`poolCash`. They are frozen
  stale after settle; all payouts run off the six snapshot fields.
- `if (p > 0)` gates both branches, so a genuine settlement price of exactly `0` pays PUT
  holders nothing even though intrinsic is then the full strike. Zero is overloaded as
  "no price". Ported as-is; noted in Review Focus.
- Caps are applied at settle, not at payout, and truncate silently.

### `_redeem(id, holder, amount)`

```
outU = floor(holderUnderlying * amount / supplyAtSettle)
outC = floor(holderCash       * amount / supplyAtSettle)
```
Lazy-settles if `!settled`. Burns `amount` from `holder`. Denominator is the **snapshot**
`supplyAtSettle`, never live `totalSupply()` — that is what keeps partial redemptions
pro-rata-stable. Pays by **direct ERC-20 transfer**. `redeemFor(id, holder)` reads the
holder's full balance, returns `(0,0)` when zero, and is permissionless.
Guard `supplyAtSettle == 0`.

### `_claim(id, writer)`

```
w    = written[id][writer]                      // the whole position, always
outU = floor(writerUnderlying * w / writtenAtSettle)
outC = floor(writerCash       * w / writtenAtSettle)
written[id][writer] = 0                         // cache w FIRST, then zero
```
**One-shot, all-or-nothing** — no partial claim; a second call returns `(0,0)` early.
Lazy-settles. `claimFor` is permissionless and always credits the writer, never the caller.

### `close(id, amount)` — pre-expiry writer unwind

```
require now < expiry, amount > 0, written[id][msg.sender] >= amount
burn `amount` option tokens from msg.sender      // writer must have bought them back
outU = floor(poolUnderlying * amount / totalWritten)   // PRE-decrement totalWritten
outC = floor(poolCash       * amount / totalWritten)
written[id][msg.sender] -= amount; totalWritten -= amount
poolUnderlying -= outU; poolCash -= outC
```
Ordering is critical: the pro-rata uses the **pre-close** `totalWritten`. Both legs pay,
because a CALL's `poolUnderlying` converts to `poolCash` as holders exercise (and vice
versa for a PUT) — a closer takes a slice of whatever mix is left, not their original
collateral.

### `SETTLEMENT_GRACE = 7 days`

`p == 0` ⇒ `hU = hC = 0` ⇒ writers take the entire pool and unexercised options settle
worthless. `settled` is one-way; a late correct price cannot fix a worthless settlement.
This is acceptable precisely because holders always had the oracle-free exercise route.

### Write path

`collateralFor` uses `Math.Rounding.Ceil`. On each write: debit the writer, add to the
pool (`CALL → poolUnderlying`, `PUT → poolCash`), then
`written[id][maker] += amount; totalWritten += amount`.

Pools also mutate on `exercise` (value swaps legs) and `close` (both shrink), so
`poolUnderlying`/`poolCash` at settle are NOT simply `collateralFor(totalWritten)`.

### Dust

Every payout floors, so the sum over claimants is less than the snapshot. Holder-side
floor dust lands on the writer side by construction (exact subtraction). Per-claimant
floor dust is stranded; their contract has no sweep and neither will this one.

## 11. The one unavoidable Aqua deviation

Their `claim` and `close` credit an internal `freeBalance` the writer later withdraws.
Aqua has no such ledger — collateral came out of the writer's own wallet. So `claim` and
`close` **transfer directly to the writer's wallet** instead.

They deliberately do NOT `AQUA.push` the proceeds back into the writer's commitment:
`push` reverts with `PushToNonActiveStrategyPrevented` on a docked strategy, which would
strand a writer's claim behind their own revocation. Returning tokens to the wallet is
unconditional and always succeeds. Re-shipping to write again is the writer's choice.
