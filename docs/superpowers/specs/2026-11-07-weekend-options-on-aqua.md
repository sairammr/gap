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

**2.2 Trading is a SwapVM order, not an on-chain book.** A resting quote cannot reserve
collateral without custody, and custody is what Aqua exists to avoid. So the venue is the
**already-deployed `AquaSwapVMRouter`**: a SwapVM order IS a resting quote, and with
`useAquaInsteadOfSignature` the maker signs nothing — shipping on-chain is the authorisation.
`order.hash` is plain `keccak256(abi.encode(order))`, deliberately equal to Aqua's
`strategyHash`. Both directions are supported (§12).

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

## 7. Scope

**Part I — the option mechanism.** Series, pooled collateral, CALL/PUT, American physical
exercise, oracle-only-after-expiry settle, redeem/claim. Ported verbatim.

**Part II — trading (§12).** Both directions, through the already-deployed
`AquaSwapVMRouter`. A SwapVM order is the resting quote. Buying and selling back are both
supported.

> Note: an earlier revision of this section listed "two-sided order book, bids, sell-back"
> as out of scope. That predates Part II and is superseded — trading is now in scope, but
> delivered as SwapVM orders rather than as an on-chain CLOB.

**Deliberately NOT an on-chain order book.** There is no quote array, no price-time priority,
no automatic best-price walking, no eviction. Orders rest off-chain and a taker or solver picks
which to fill — 1inch's model. Anything that assumes depth or a matching engine is out.

**Deferred, not cut:** signed EIP-712 RFQ (a second fill path beside the book, with its own
typehash/nonce/cancellation surface), and sell-to-open.

**Out of scope:** maker bots, atomic hedging (`HedgedMaker`), vaults, `ShieldedLender`, the
pooled gap/binary market, passkey accounts, Pyth, corporate-action multipliers. The SwapVM
`WeekendGap` opcode stays deployed but unused (§12.9).

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

### OPEN HAZARD — `close` pro-rata is extractable (inherited from the source)

`close` pays pro-rata of **both** pool legs on the **pre-decrement** `totalWritten`. Spec §10
mandates that verbatim: *"a closer takes a slice of whatever mix is left, not their original
collateral."* On a CALL series that has taken exercises, the pool holds
`(W-X)` underlying **plus** `X*K` cash — so a writer who enters *after* those exercises buys
into cash banked at the strike.

Attacker writes `A` underlying, then immediately closes `A`:

```
outU = (W - X + A) * A / (W + A)
outC = X * K * A   / (W + A)
```

`W=10, X=4, K=205, A=10` gives `outU = 8`, `outC = 410` against a cost of `10*S`:

| spot | attacker | existing writers |
|---|---|---|
| 195 | **+20** | −20 |
| 201 | **+8** | −8 |
| 205 (= K) | 0 | 0 |
| 210 | −10 | +10 |

Profitable at **every spot below the strike**, and exactly zero-sum — the loss falls on
existing writers, never on holders. Reachable through any write path (`buyOption`, a desk
self-write, a third Aqua strategy), so **it cannot be avoided by choosing a different one.**

**Not yet decided.** Both candidate fixes diverge from the source protocol, which is why this
is recorded rather than patched:

1. **Pay a closer in the leg they contributed**, not pro-rata of the mix. Closes the
   extraction, but has its own asymmetry: a writer whose cover *was* exercised then gets back
   less than they put in.
2. **Bar `close` once the opposite leg is non-empty** (`poolCash != 0` on a CALL,
   `poolUnderlying != 0` on a PUT). Sound and tiny, but disables early unwind after the first
   exercise in the series.

A fix that is exactly fair needs each writer's entry state recorded, which is real complexity.

**DECIDED: option 2.** Bar `close` once the opposite leg is non-empty — `poolCash != 0` on a
CALL, `poolUnderlying != 0` on a PUT. Reasons, in order:

- It is the only candidate with no residual unfairness. Option 1 just points the asymmetry the
  other way: a writer whose cover genuinely was exercised gets back less than they put in.
- The cost is bounded and small *for this product*. It disables early unwind after the first
  exercise in a series, and these series live hours, not months. A writer who wants out before
  any exercise still can.
- It is a few lines, and it fails closed. Option 1 is arithmetic that has to be right.

This diverges from the source protocol, deliberately and in one place. Recorded here rather
than silently: the source is extractable, and porting a known-extractable path verbatim is not
fidelity, it is copying a bug.

**The guard is permanent once tripped, by design.** On a CALL only `exercise` credits
`poolCash`, `close` is the only pre-expiry decrement, and `settle` deliberately never touches
the pools — so one exercise shuts the extraction path for the life of the series and it cannot
be reopened. Same shape on the PUT side.

**ACCEPTED COST: this trades a value hole for a bounded liveness one.** Early unwind for every
writer in a series is now contingent on no holder having exercised. So a holder of a single
option can exercise a dust amount — `fullMulDivUp` rounds the strike on dust to 1 unit of quote
— and permanently freeze `close` for every writer in that series, for roughly 1e-6 USDC plus
whatever they paid to hold the option.

Accepted knowingly, because no value is extracted, writers are still made whole at settle, and
these series live hours. **This is a new denial path that did not exist before the fix**, and it
is recorded here so that whoever finds it later reads a decision rather than an oversight.

A third variant was considered and rejected: allow `close` but cap the payout at what the
closer contributed, in their own leg only. It closes the extraction and has no liveness hole,
but it silently haircuts a writer whose cover was exercised — a worse surprise than a blocked
`close`, because it costs money quietly instead of failing loudly.

Until it lands in `close`, treat the path as live. The desk tolerates a reverting or partial
`close` and keeps the options as inventory instead of failing the fill (§12.6).

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


---

# PART II — THE TRADING LAYER

## 12. SwapVM + Extruction

### 12.1 Shape

```
WeekendOptions.sol   series, pools, collateral, exercise, settle, redeem, claim   (Part I)
WeekendPricer.sol    Extruction target (opcode 0x04) — Black-Scholes + direction gate
WeekendDesk.sol      the maker — implements IMakerHooks, writes just-in-time
AquaSwapVMRouter     the venue — ALREADY DEPLOYED, not modified
```

**No fork edit. No new opcode. No router redeploy.**

### 12.2 Why Extruction and not an opcode

`AquaOpcodes` ships no WAD transcendental math (only OpenZeppelin `Math`) — which is why the
in-tree `WeekendGap` opcode prices a linearised Bachelier approximation instead of
Black-Scholes. A new opcode hits the identical wall. `Extruction` (`0x04`) is already wired
into `AquaOpcodes` for exactly this purpose, so full A&S pricing lives in our own contract.

`Extruction.exec` assigns the **entire** `SwapRegisters` struct plus the program counter, and
the VM validates **only** `chopped.length == choppedLength`. Nothing else about the returned
registers is checked. Treat that as the threat model.

### 12.3 What AquaOpcodes does NOT have — the load-bearing constraint

Present: `Deadline`, `Salt`, `DynamicBalances`, `RequireMinRate`, `Extruction`, `WeekendGap`,
`JumpIfDirection`, token validators, `XYCSwap`, `PeggedSwap`, `FeeFlatIn`, `FeeProtocol`, `Decay`.

**Absent: `StaticBalances`, `LimitSwap`, `InvalidateTokenIn`, `InvalidateTokenOut`, `Stop`,
`Revert`, whitelists, `ValidateSeriesEpoch`, `OraclePriceAdjuster`.**

`Extruction`'s own NatSpec prescribes `StaticBalances` + `InvalidateTokenIn/Out` to bound an
amount-limited strategy. **All three are missing from the Aqua router.** An option-writing
order is exactly an amount-limited strategy, so this is the gap the design must close by other
means:

| bound | mechanism |
|---|---|
| **cumulative notional** | the Aqua ledger. `Aqua.pull` does `prevBalance - amount` on a checked `uint248` — underflow reverts. Cumulative across every fill of that order hash. **This is the only hard cap.** |
| **price floor** | `RequireMinRate`, placed *before* `Extruction` in the program (it wraps the remainder via `ctx.runLoop()`). |
| **taker protection** | the taker's own `minOut` threshold, enforced by SwapVM after the program runs. |

The Aqua ledger must cover `amountOut + feeOut` — the protocol fee is a **second, separate**
pull.

### 12.4 Aqua strategies are immutable — design around it

`Aqua.ship` enforces `StrategiesMustBeImmutable`. You cannot re-ship the same strategy hash to
restock. The shipped `amounts[]` is a permanent cumulative cap on everything that order can
ever sell. Topping up requires `push()`, which moves real tokens in.

**Therefore: ship each series' ask strategy with the option-token balance set to exactly the
series cap.** The ledger underflow becomes the written-notional cap. Re-offering after
exhaustion needs a new `salt`.

### 12.5 Two sides, two ships, two gates

```
ASK  ship [optionToken @ cap, quote @ 0]   gate quote → option   maker writes
BID  ship [quote @ budget, optionToken @ 0] gate option → quote   maker buys back
```

Both legs of a pair must be shipped: `AQUA.safeBalances` reverts unless both tokens are in an
active strategy. The zero leg is there to satisfy that, never as a budget.

**The direction gate is a security control, not a sanity check.** `AquaOpcodes` has no
`LimitSwap`, so nothing validates direction for free. An ask order accrues quote in the maker's
Aqua counter; without the gate that counter is a standing allowance for anyone to fill the
reverse direction at the maker's own ask price. `WeekendPricer` refuses any fill whose
direction does not match the side the maker shipped.

Spread is expressed as vol: a two-sided maker ships a **higher `volWad` on the ask than on the
bid**. No separate spread parameter exists. Nothing else prevents a two-sided maker being
arbitraged flat.

### 12.6 Maker hooks

Verified present and orthogonal to the Aqua branch in `SwapVM.swap()` — the hook call sites sit
*outside* the `useAquaInsteadOfSignature` block. The only Aqua/traits incompatibilities are
`unwrapWeth`, custom `receiver` and Permit2; hooks are not among them.

```
preTransferOut   ASK → mint just-in-time against collateral, enforce per-series short cap
                 BID → ensure quote on hand
postTransferIn   ASK → premium becomes collateral
                 BID → close(id, min(amountIn, written)) — burn, unlock collateral
```

`AQUA.pull` is a real `transferFrom` out of the maker's wallet, so tokens minted in
`preTransferOut` are pullable one call later — **provided the desk has approved Aqua for that
token**. Minting does NOT credit the Aqua ledger (§12.3).

**`active` must be checked in BOTH hooks.** The reference desk checks it only in
`preTransferOut`, which is safe there solely because ERC-1271 rejects first. On a
no-signature Aqua path that gap goes live.

### 12.7 Transfer ordering is the TAKER's choice

`IS_FIRST_TRANSFER_FROM_TAKER` (`0x0020`) lives in **taker** traits. The maker cannot force it.
Unset (the common case) means `_transferOut` runs before `_transferIn` — the desk mints and
ships option tokens **before** the premium arrives. Atomic, so a reverting in-leg unwinds it.

**The hooks must be correct under both orderings.** Do not write logic that assumes the premium
has landed. This is a test, not a comment.

### 12.8 Zero prior coverage — we are first

No test anywhere in the fork exercises maker hooks together with an Aqua order.
`test/solidity/helpers/TraitsHelper.sol` hardcodes all four hook flags to `false`, so no Aqua
test routed through it can have hooks. `MakerHooks.t.sol` is entirely non-Aqua.

**The combined path must be proven by our own integration test against the real router before
anything is deployed.** Build traits via `MakerTraitsLib.build` directly, as `MakerHooks.t.sol`
does, not via `TraitsHelper`.

### 12.9 `WeekendGap` opcode

Left in place, unused. It sits in the live `AquaOpcodes` dispatcher ahead of `Extruction`, so
every options fill pays one extra comparison — trivial, but it is not inert.

**Open risk:** whether slot `0x52` was free upstream is unproven from this repo (the fork landed
in one commit with `WeekendGap` already at `0x52`, and `OpcodeEnumCheck.t.sol` pins neither
`0x52` nor `0x53`). If upstream had `LimitSwap` at `0x52`, every previously-shipped strategy's
bytes decode differently. **Diff against upstream `1inch/swap-vm` before deploying.**

### 12.10 Order program

```
Deadline  +  Salt  +  RequireMinRate  +  Extruction(WeekendPricer, args)
```

`args = abi.encode(uint256 seriesId, uint256 volWad, uint16 minPremiumBps, uint8 side)` —
128 bytes, instruction header `0x0494` — carried in the program bytes
and therefore covered by the order hash. A maker cannot repoint pricing after shipping: a
different target changes `order.data`, changes the hash, and the Aqua ledger key no longer
exists — `safeBalances` reverts before any opcode runs.

## 13. Testing standard

**Real contracts, real transactions, every case.** Integration tests deploy the actual
`AquaSwapVMRouter`, the actual `Aqua`, the real `WeekendOptions`, real ERC-20s, and drive real
`router.swap(...)` calls. Mocks are permitted only for the v4 `StateView` lens and the price
oracle. No mock router, no mock Aqua, no simulated fills.
