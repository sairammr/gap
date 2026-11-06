# Weekend Options — Frontend Integration Handoff

> For an agent building the UI in a separate worktree. You need no prior context.
> Contracts live in `contracts/src/`. **Do not edit them** — another agent owns that tree.
>
> Spec: `docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md`
> (Part I = option mechanics, Part II = the SwapVM trading layer.)

---

## 1. What the product is

Fully collateralised options on tokenised stocks (NVDAx), priced in one quote token (USDC).

Two kinds only:

- **CALL** (`Kind.CALL = 0`, token symbol `UP-<id>`) — the writer locks the **underlying**. A covered call.
- **PUT** (`Kind.PUT = 1`, token symbol `FLOOR-<id>`) — the writer locks **USDC**. A cash-secured put.

Four properties that shape every screen:

1. **Nothing can be liquidated.** The writer locks exactly what they could owe, before the option exists. No margin, no health factor, no liquidation UI — ever.
2. **Exercise reads no oracle.** A holder pays the strike and takes the stock (CALL), or delivers the stock and takes the strike (PUT), any time before expiry. American, partial allowed.
3. **The oracle is read once**, at settlement, and only for whatever nobody exercised.
4. **An option is a plain ERC-20.** One token contract per series. It transfers, it trades anywhere, and the protocol does not care how you got it.

---

## 2. Actors

| Actor | Does |
|---|---|
| **Maker** | Ships collateral to Aqua (no tokens move) + commits one `volWad`. Becomes the **writer** when someone buys. Can unwind early with `close`. Can quote both sides (ask + bid) once the desk ships. |
| **Taker** | Buys options. Exercises them, sells them back, or redeems after expiry. Always ends up the **holder**. |
| **Anyone** | Records the settlement price and calls `settle`. Can also call `redeemFor` / `claimFor` to pay someone else. Earns nothing — it is a button, not a job. |

**Maker/taker and writer/holder are different axes.** On the direct write path the maker is always the writer and the taker always the holder. On the SwapVM path a maker quoting a *bid* becomes a holder instead.

---

## 3. Build status — read this before planning screens

### Built and tested

| What | Where |
|---|---|
| Series registry, `collateralFor`, `quotePremium`, `makerCapacity`, `hashStrategy` | `WeekendOptions.sol` |
| Direct Aqua write path `buyOption` | `WeekendOptions.sol` |
| EOA router for buying | `WeekendTaker.sol` |
| One ERC-20 per series | `OptionToken.sol` |
| v4 spot + recorded settlement price | `oracle/V4SpotOracle.sol` |
| SwapVM pricing + direction gate | `desk/WeekendPricer.sol` |

### Not built yet — do not build against these without checking

| What | Status |
|---|---|
| `exercise`, `close`, `settle`, `redeem`/`redeemFor`, `claim`/`claimFor` | **PENDING** — planned signatures in §5. Another agent is writing them now. |
| `WeekendDesk.sol` (SwapVM maker hooks) | **PENDING** |
| SwapVM order builders (JS) | **PENDING** |
| Deploy script for the new contracts | **PENDING** |

### Deployment addresses are STALE

`contracts/deployments/base-sepolia.json` and `app/public/deployments/base-sepolia.json` both still point at `gapOptionsApp` / `gapTaker` — **a deleted product**. There are no live addresses for `WeekendOptions` yet.

Expect the JSON to gain roughly: `weekendOptions`, `weekendTaker`, `weekendPricer`, `weekendDesk`, `optionTokenFactory`, `oracle`, plus the existing `aqua`, `swapVmRouter`, `usdc`, `nvdax`, `stateView`, `makers[]`. **Confirm the final key names before wiring.**

---

## 4. Units — get this wrong and everything is wrong

| Quantity | Decimals | Meaning |
|---|---|---|
| Option amounts | **18** | `1e18` = the right on `1e18` wei of underlying |
| Underlying (NVDAx) | **18** | |
| `strike`, `settlePrice`, oracle prices, premiums | **6 (quote units)** | USDC units **per 1e18 of underlying** |
| `volWad` | **18 (WAD)** | `1e18` = 100% annualised IV |

### Worked conversion, both ways

A $205.00 strike on 10 options:

```
strike  = 205 * 1e6      = 205_000_000          // 205e6, NOT 205e18
amount  =  10 * 1e18     = 10_000_000_000_000_000_000
```

Exercising a CALL costs `amount * strike / 1e18`:

```
10e18 * 205e6 / 1e18 = 2_050_000_000 = $2,050.00 USDC
```

Display from raw:

```
strikeUsd  = Number(strike)  / 1e6      // 205e6      -> 205
optionsQty = Number(amount)  / 1e18     // 10e18      -> 10
volPct     = Number(volWad)  / 1e16     // 0.5e18     -> 50 (%)
```

**The most likely bug in this codebase is putting a strike in WAD.** It is 6dp. An earlier, now-deleted product used WAD strikes; ignore anything that says otherwise.

---

## 5. Every user action

Revert names below are the exact Solidity custom errors — decode them and map to the plain-English column.

### 5.1 Create a series — permissionless

```solidity
WeekendOptions.createSeries(address underlying, uint64 expiry, Kind kind, uint256 strike)
  external returns (uint256 id)
```

Idempotent: the same `(underlying, expiry, kind, strike)` returns the existing id instead of reverting. Approvals: none.

| Revert | Means |
|---|---|
| `BadSeries()` | Expiry is in the past, more than 400 days out, or the strike is 0. |

UI: a "new series" form is optional — most users pick from existing series. Show `seriesCount()` and let them open one if their strike/expiry isn't listed yet.

### 5.2 Ship collateral — maker

Two transactions:

```solidity
IERC20(collateralToken).approve(AQUA, amount)
IAqua.ship(address app, bytes strategy, address[] tokens, uint256[] amounts) returns (bytes32 strategyHash)
```

where `strategy = abi.encode(WeekendOptions.Strategy{ app, maker, underlying, quote, volWad, salt })`.

Field order is load-bearing — `hashStrategy` is `keccak256(abi.encode(s))` and must match the bytes Aqua hashes.

**Tell the user plainly: `ship` moves no tokens.** It writes a commitment. Their collateral stays in their wallet until someone actually buys.

**A CALL maker must include the quote token in `tokens[]` with amount `0`.** Otherwise the premium leg reverts `PushToNonActiveStrategyPrevented` — Aqua's `push` only lands on a token that is part of the shipped strategy. This is the single easiest way to brick a maker.

Verify after shipping: `WeekendOptions.hashStrategy(s)` must equal the hash `ship` returned.

| Revert | Means |
|---|---|
| `StrategiesMustBeImmutable` | This exact strategy was already shipped. Change the `salt` to re-offer. |
| `ERC20InsufficientAllowance` | Approve Aqua first. |

Aqua strategies are **immutable**. A shipped amount is a permanent cap; to change vol or restock, ship again with a new `salt`.

### 5.3 Buy an option — taker (BUILT, direct path)

This is the path that works today. It does **not** go through SwapVM. The taker names a specific maker's `Strategy`.

```solidity
IERC20(usdc).approve(weekendTaker, maxPremium)

WeekendTaker.buy(
    WeekendOptions app,
    WeekendOptions.Strategy calldata s,   // the maker you are buying from
    uint256 seriesId,
    uint256 amount,                        // 18dp
    uint256 maxPremium,                    // 6dp, your slippage cap
    address to,                            // who receives the option tokens
    bytes calldata takerData               // abi.encode(maker, strategyHash)
) external returns (uint256 premium)
```

An EOA cannot call `WeekendOptions.buyOption` directly — the protocol calls back into `msg.sender` to collect the premium, so the caller must be a contract. `WeekendTaker` is that contract and holds no funds between transactions.

Before: show the quote from `quotePremium`. After: the user holds `amount` of the series' `OptionToken`; the maker's wallet is down the collateral and up the premium.

| Revert | Means |
|---|---|
| `PremiumTooHigh()` | Price moved past your cap. Re-quote and retry. |
| `InsufficientMakerCollateral()` | This maker can't back the trade — their wallet was drained since shipping, or they're out of capacity. Try another maker. |
| `NoPrice()` | The oracle has no price for this underlying. Pool unconfigured or uninitialised. |
| `Expired()` | Series has expired. |
| `StrategyMismatch()` | The strategy's `underlying`/`quote` don't match this series. |
| `NotThisApp()` | `strategy.app` isn't this contract. |
| `BadAmount()` | Amount is 0. |
| `PremiumTransferFailed()` | USDC `transferFrom` failed — check the allowance to `WeekendTaker`. |

### 5.4 Buy / sell through SwapVM — **PENDING**

Needs `WeekendDesk`. See §7 for the order shape. The sell side does not exist until that lands — **today a holder's only exits are exercise, transfer, or wait for expiry.**

### 5.5 Exercise — holder — **PENDING**

Planned (from spec §1):

```solidity
WeekendOptions.exercise(uint256 id, uint256 amount) external
```

American, partial, **reads no oracle**. Must be before expiry.

- **CALL:** holder pays `amount * strike / 1e18` USDC → receives `amount` underlying. Approve USDC first.
- **PUT:** holder delivers `amount` underlying → receives `amount * strike / 1e18` USDC. Approve the underlying first.

This is the headline feature. The UI should say, on every position: *"Exercise — no price feed involved."*

### 5.6 Close — writer unwind — **PENDING**

```solidity
WeekendOptions.close(uint256 id, uint256 amount) external
```

Requires: before expiry, `written[id][msg.sender] >= amount`, **and the caller must actually hold `amount` option tokens** — they have to buy them back off the market first. Burns them against their written position and returns a pro-rata slice of **both** pools.

Both legs pay, because a CALL's `poolUnderlying` converts to `poolCash` as holders exercise. A closer takes a slice of whatever mix is left, not their original collateral. **Show both amounts.**

### 5.7 Record the settlement price — anyone (BUILT)

```solidity
V4SpotOracle.recordSettlement(address asset, uint64 expiry) external
```

Permissionless, once only, at or after expiry.

| Revert | Means |
|---|---|
| `TooEarly()` | Not expired yet. |
| `AlreadyRecorded()` | Already done — someone beat you to it, which is fine. |
| `NotConfigured()` | No pool configured for this asset. |

### 5.8 Settle — anyone — **PENDING**

```solidity
WeekendOptions.settle(uint256 id) external
```

Reads the oracle once, snapshots six fields, splits the pools. Pays the caller nothing.

`redeem` and `claim` lazy-settle, so an explicit settle button is a convenience, not a requirement.

| Revert | Means |
|---|---|
| `NotExpired()` | Too early. |
| `AlreadySettled()` | Done. |
| `OracleNotReady()` | No settlement price yet and still inside the 7-day grace window. Call `recordSettlement` first, or wait. |

**Grace behaviour, worth surfacing:** if no price arrives within `SETTLEMENT_GRACE = 7 days`, unexercised options settle **worthless** and writers take the entire pool. `settled` is one-way. A late correct price cannot fix it. This is only acceptable because holders always had the oracle-free exercise route — say so in the UI.

### 5.9 Redeem — holder, after expiry — **PENDING**

```solidity
WeekendOptions.redeem(uint256 id, uint256 amount) external returns (uint256 outU, uint256 outC)
WeekendOptions.redeemFor(uint256 id, address holder) external returns (uint256, uint256)
```

Burns tokens, pays pro-rata by direct transfer. `redeemFor` reads the holder's full balance, is permissionless, and returns `(0,0)` instead of reverting when they hold nothing.

**An in-the-money CALL pays out in stock, not cash** — `amount * (settlePrice - strike) / settlePrice` of the underlying. Do not render it as a USDC figure.

### 5.10 Claim — writer, after expiry — **PENDING**

```solidity
WeekendOptions.claim(uint256 id) external returns (uint256 outU, uint256 outC)
WeekendOptions.claimFor(uint256 id, address writer) external returns (uint256, uint256)
```

**One-shot, all-or-nothing** — there is no partial claim, it zeroes the writer's whole `written` entry, and a second call returns `(0,0)`. Disable the button once `written[id][user] == 0`.

---

## 6. Read surface

| Screen | Call |
|---|---|
| Series list | `seriesCount()`, then `getSeries(i)` for each |
| One series | `getSeries(id)` → `{ underlying, expiry, kind, strike, token, totalWritten, poolUnderlying, poolCash, settled, settlePrice, supplyAtSettle, holderUnderlying, holderCash, writerUnderlying, writerCash, writtenAtSettle }` |
| Premium quote (direct path) | `quotePremium(Strategy s, uint256 seriesId, uint256 amount)` → quote units |
| Premium quote (SwapVM path) | `WeekendPricer.premiumPerOption(uint256 seriesId, uint256 volWad)` → quote units **per 1e18 options** |
| Writer's collateral requirement | `collateralFor(uint256 id, uint256 amount)` → `(token, need)` |
| Maker capacity | `makerCapacity(Strategy s, address token)` → `(committed, wallet, backable)` |
| Spot price | `V4SpotOracle.spot(address asset)` → `(price, updatedAt)`. Returns `(0,0)` when unconfigured — render "no price", not "$0". |
| Settlement state | `V4SpotOracle.settlementPrice(asset, expiry)` → `(price, ok)`; `recorded[asset][expiry]` |
| User's position | `OptionToken(series.token).balanceOf(user)` |
| User's written amount | `written(seriesId, user)` |

**`makerCapacity` is the one to understand.** `committed` is Aqua's books, `wallet` is the maker's actual balance, `backable = min(...)`. Because `ship` moves no tokens the two can disagree — a maker can look fully collateralised and be broke. **Always filter and display on `backable`.** A quote built on `committed` will revert at fill.

`WeekendPricer.premiumPerOption` reverts `SeriesExpired(expiry)` once expired. `quotePremium` does not — it floors time-to-expiry at 0 and keeps returning intrinsic. Use `quotePremium` for display and `premiumPerOption` for anything that must refuse an expired series.

---

## 7. The SwapVM order — **PENDING**, shape is fixed

On the Aqua path there is **no signature**. Shipping on-chain *is* the authorisation. `order.hash` is plain `keccak256(abi.encode(order))`, deliberately equal to Aqua's `strategyHash`.

### Order

```
Order { address maker; MakerTraits traits; bytes data; }
data = [hook slices] || program
```

### Program (same four instructions both directions)

```
Deadline  +  Salt  +  RequireMinRate  +  Extruction(WeekendPricer, args)
args = abi.encode(uint256 seriesId, uint256 volWad, uint8 side)
```

`side`: `WeekendPricer.SIDE_ASK = 0` (taker pays quote, receives options) · `SIDE_BID = 1` (taker delivers options, receives quote).

### Two sides, two separate ships

```
ASK   ship [optionToken @ cap, quote @ 0]     gate quote  → option
BID   ship [quote @ budget, optionToken @ 0]  gate option → quote
```

Both legs of the pair must be shipped — `AQUA.safeBalances` reverts unless both tokens are in an active strategy. The zero leg exists only to satisfy that; it is never a budget.

**Spread is expressed as vol.** A two-sided maker ships a *higher* `volWad` on the ask than on the bid. There is no spread parameter. Surface both numbers in the maker UI and make the relationship obvious, because nothing else stops a two-sided maker being arbitraged flat.

### Maker side vs taker side

| Built once, at ship (maker) | Built per fill (taker) |
|---|---|
| the whole `Order` (maker, traits, data) | `takerTraits`: exact-in flag + `minOut` threshold |
| `MakerTraits`: Aqua flag `1 << 254`, hook bits `1 << 250` (preTransferOut) and `1 << 251` (postTransferIn), hook data slice indexes | the `amount` |
| program bytes incl. the pricer address and args | — |
| **no signature** | **no signature** |

The maker cannot repoint pricing after shipping: a different Extruction target changes `order.data`, which changes the hash, and the Aqua ledger key no longer exists — `safeBalances` reverts before a single opcode runs.

### Reverts the taker will hit

| Revert | Means |
|---|---|
| `WrongSwapDirection(tokenIn, tokenOut)` | Filling an ask order as a sell, or vice versa. Each direction needs its own order. |
| `SeriesExpired(expiry)` | Series expired. |
| `ZeroPremium()` / `ZeroAmount()` | Degenerate inputs. |
| `SafeBalancesForTokenNotInActiveStrategy` | The maker docked this strategy, or never shipped both legs. |
| Aqua ledger underflow | The order's cumulative cap is exhausted. The maker must ship again with a new salt. |

---

## 8. State you must derive yourself

There is **no indexer and no backend**. Everything comes from chain reads and logs.

| Need | How |
|---|---|
| Series list | `seriesCount()` + `getSeries(i)`, or scan `SeriesCreated(seriesId, underlying, expiry, kind, strike, token)` |
| A user's positions | For each series, `OptionToken(series.token).balanceOf(user)`. Non-zero = they hold it. |
| A user's written positions | `written(seriesId, user)` per series |
| Available makers | Scan Aqua `Shipped(maker, app, strategyHash, strategy)` logs, filter `app == weekendOptions`, `abi.decode` the strategy. **Aqua is the registry — there is nothing else.** |
| Cheapest maker | Decode all shipped strategies, call `quotePremium` on each, filter by `makerCapacity(...).backable >= need`, take the minimum. Do this client-side. |
| Trade history | `OptionWritten(seriesId, to, maker, amount, premium)` logs |

**`eth_getLogs` range limits.** The previous frontend hit "eth_getLogs is limited to a 200 block range" on `sepolia.base.org` and used a separate endpoint for log queries. Expect to need one, and chunk your scans.

Series count is small (tens), so looping `getSeries` client-side is fine. Use multicall if it gets slow.

---

## 9. What does NOT exist

Do not design screens around any of these:

- **No on-chain order book.** No bid/ask depth, no price-time priority, no "walk the book". SwapVM orders are discrete resting quotes; the taker picks one.
- **No RFQ.** No signed quotes, no quote server.
- **No keeper.** Settlement is a button a human presses. Nobody is paid to do it. Positions do not auto-resolve.
- **No sell-to-open.** A taker cannot write options by selling into a bid.
- **No sell side at all until `WeekendDesk` ships.** Today: exercise, transfer, or wait.
- **No liquidations, no margin, no health factor.** By construction. Do not build a risk gauge.
- **No partial claim.** `claim` is one-shot.
- **No protocol fee** in the current contracts.
- **No vaults, no lending, no pooled gap market.** Out of scope.

---

## 10. Ask before you start

1. **Which addresses?** No deploy script exists yet and both deployment JSONs point at a deleted product. Get the new JSON and its final key names.
2. **Which buy path for v1?** The direct `WeekendTaker.buy` path works today and needs no desk. The SwapVM path is pending. Building both doubles the work — confirm whether v1 ships direct-only.
3. **Are `exercise`/`settle`/`redeem`/`claim` landed yet?** They were being written in parallel with this document. Re-read `WeekendOptions.sol` for their final signatures rather than trusting §5 verbatim.
4. **Reuse the old app or start clean?** `app/` is a Vite + React 19 + wagmi/viem app built for the deleted capped-spread product. Its chart, UI kit, wallet setup and deployment loader are product-agnostic and worth keeping; its ticket, positions and payoff code is not.
5. **Who seeds the demo?** Series must be created and makers must ship before any screen shows anything. Confirm whether a seed script exists.
6. **Testnet faucet?** The mock USDC/NVDAx have a public unpermissioned `mint(to, amount)` — confirm that is still true on the new deployment and whether the UI should expose a "get test funds" button.

---

## 11. One thing to get right

The pitch is **"no liquidations, and you don't need a price feed to get paid."**

Every screen should reinforce it:

- On a position: *"Exercise — no price feed involved."*
- On the maker flow: *"Your collateral stays in your wallet until someone buys."*
- Never show a liquidation price, a health factor, or a margin bar. There aren't any.
