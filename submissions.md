# GAP on 1inch Aqua

## Short description (< 100 chars)

Trade the weekend gap on tokenised stocks. Fully collateralised options — nothing to liquidate.

## Full description

### The problem, briefly

Tokenised stocks trade 24/7; the companies behind them do not. From Friday's close to
Monday's open the price drifts on thin liquidity rather than information, then the equity
market reopens and reprices it in a handful of candles — straight through the level where
leveraged positions get closed out. Nobody on the wrong side can react, because the market
that sets the real price was shut the whole time the position was at risk.

The only thing that fixes that is capping the downside *before* the weekend. GAP is that,
built as an options venue on 1inch Aqua.

### What it is

Fully-collateralised options on tokenised stocks (NVDAx), priced and settled in USDC, live
on **Base Sepolia (84532)**. Two instruments:

| | writer locks | token |
|---|---|---|
| **UPSIDE** · `Kind.CALL` | the underlying — covered | `UP-<id>` |
| **FLOOR** · `Kind.PUT` | `size × strike` in USDC — cash-secured | `FLOOR-<id>` |

Collateral is posted in full before a position exists, so there is no margin, no health
factor and nothing to liquidate. Each series is a plain ERC-20.

---

## The implementation

### The central idea: the option *is* a SwapVM order

There is no separate exchange. A maker's resting quote is a SwapVM order; filling that
order is what writes the option. Everything a standalone options protocol would have to
build — book, custody, matching, settlement, authorisation — is something Aqua already
does, so it was deleted rather than written.

**The order program**

```
Deadline + Salt + RequireMinRate + Extruction(pricer, args)

args   = abi.encode(uint256 seriesId, uint256 volWad, uint16 minPremiumBps, uint8 side)
data   = tokenA || tokenB || program          (tokens sorted ascending)
traits = USE_AQUA (1<<254) | PRE_TRANSFER_OUT_HOOK (1<<250) | POST_TRANSFER_IN_HOOK (1<<251)
```

On the Aqua path `hash(order) == keccak256(abi.encode(order)) == Aqua's strategyHash`, and
because `USE_AQUA` replaces signature verification, **no signature is ever read**. Shipping
the order on chain *is* the authorisation. Every parameter — series, vol, floor, side,
deadline — is inside `order.data`, so it is covered by that hash and cannot be changed
after shipping.

**Three Aqua strategies, not one**

| shipped to | legs | purpose |
|---|---|---|
| router | `[optionToken @ cap, quote @ 0]` | the ask — a permanent cumulative cap on everything that order can sell |
| router | `[quote @ budget, optionToken @ 0]` | the bid — the budget the desk can spend buying options back |
| app | `[underlying @ cover, quote @ cash]` | the desk's own collateral, for the just-in-time write |

Both legs of every pair must be shipped: `Aqua.safeBalances` reverts unless both tokens
belong to an active strategy. `Aqua.ship` is immutable, so a shipped amount is a permanent
cap and re-offering after exhaustion needs a new salt, which hashes to a new strategy.

### Pricing runs inside the fill

`AquaOpcodes` carries no WAD transcendental math, so full Abramowitz-Stegun Black-Scholes
lives in `WeekendPricer`, reached through the `Extruction` interface the opcode set already
exposes for maker-chosen logic. It is implemented `view`, so quote mode and swap mode cannot
diverge, and every dependency is `immutable` — the target address is baked into the order
bytes, so a maker cannot repoint pricing after shipping.

Inside one call the pricer does three things:

1. **Gates direction.** `AquaOpcodes` has no `LimitSwap`, so nothing validates swap
   direction for free. An ask accumulates quote balance in the maker's Aqua counter, and
   without this gate that growing counter would be a standing allowance for anyone to fill
   the *reverse* direction — selling options back at the maker's own ask price. Each order
   declares its side and any mismatched fill is refused.
2. **Fills the missing amount register** — whichever leg the taker did not name — rounding
   so it always favours the maker.
3. **Enforces the premium floor**, ask side only. `normalCdf` returns exactly 0 beyond
   −8 sigma, so a far-enough strike prices at exactly 0 and a no-op taker would take the
   maker's whole shipped cover for gas.

### The fill, step by step

```
taker ── router.swap ──▶ AquaSwapVMRouter
                           ├─ runs the program; Extruction calls WeekendPricer
                           │    └─ WeekendPricer reads Uniswap v4 spot (StateView.getSlot0)
                           ├─ preTransferOut ─▶ WeekendDesk
                           │    └─ mints the shortfall via WeekendOptions.buyOption
                           │         ├─ Aqua.pull  collateral : maker  → protocol
                           │         └─ Aqua.push  premium    : taker  → maker
                           └─ postTransferIn ─▶ WeekendDesk (bid side: close the short)
```

**Just-in-time writing.** The desk carries no option inventory at rest. `preTransferOut`
spends whatever it does happen to hold (picked up on the bid side) and mints only the
shortfall against shipped cover, and `AQUA.pull` then moves tokens that did not exist one
call earlier — possible only because `pull` is a real `transferFrom`. Minting never credits
the Aqua ledger, so the shipped option leg stays the cumulative cap.

**The desk buys from itself.** The core has no `writeFor`: the only write path is
`buyOption`, which pulls collateral through Aqua and demands an `IGapOptionCallback` premium
push. So the desk ships that third strategy and is both maker and taker of its own write —
the premium leg is a desk→desk transfer that nets to zero.

**Two bounds, both cumulative.** The Aqua ledger caps what an order can ever sell;
`maxShort[seriesId]` caps the desk's position and is checked *after* each write against
cumulative `written[id][desk]`, so many small fills cannot walk past it.

**Transfer ordering is the taker's choice.** `IS_FIRST_TRANSFER_FROM_TAKER` is a taker
trait, so `preTransferOut` may run before or after `postTransferIn` for the same fill. No
hook reads a balance that only exists once the counter-leg has landed; both orderings are
tested to produce identical end state.

### Settlement

**Exercise reads no oracle.** Physical and American: pay the strike and take the stock, or
deliver the stock and take the strike. The holder names the price by paying it, so the route
stays open when the underlying market — and therefore every price feed — is shut. That is
precisely when a gap product needs it.

**The oracle is touched once**, after expiry, only for whatever nobody exercised. `settle`
snapshots the whole payout split — price, supply, total written, and the holder/writer share
of each pool leg — and every payout afterwards is pro-rata against those snapshots, never
the live pools, which go stale the instant `settled` flips. `redeemFor` and
`claimFor` are permissionless, so a keeper can pay everyone out and nobody has to click
anything.

### Contracts

| | |
|---|---|
| `WeekendOptions.sol` | series registry, pooled collateral, `buyOption` / `exercise` / `close` / `settle` / `redeem` / `claim`. Extends `AquaApp`. |
| `OptionToken.sol` | one ERC-20 per series, minted on buy, burned on exercise or redeem |
| `desk/WeekendDesk.sol` | the maker — `IMakerHooks`, just-in-time writing, short caps, ship/dock |
| `desk/WeekendPricer.sol` | `Extruction` target — Black-Scholes, direction gate, premium floor |
| `oracle/V4SpotOracle.sol` | `IPriceOracle` off Uniswap v4 `StateView.getSlot0` |
| `oracle/PythSettlementOracle.sol` | drop-in `IPriceOracle`: settlement is the **mean** of every Pyth-signed sample in a window after expiry, so no single sample decides it |
| `WeekendTaker.sol` | stateless helper so an EOA can hit `buyOption` directly (it needs an `IGapOptionCallback` caller) |

Solidity 0.8.30. SwapVM needs `viaIR` + `prague`, so the integration tests get their own
Foundry profile.

### Frontend

Vite + React 19 + wagmi/viem. **No backend and no indexer** — every value is a chain read or
a log scan.

- The SwapVM order encoder is reimplemented in TypeScript, byte-reconciled against
  `OrderLib.sol`, and **every fill is gated**: the rebuilt order must satisfy
  `router.hash(order) == the shipped strategyHash` or the trade is refused before sending.
- **Buys are exact-out.** The pricer derives whichever leg the taker did not name, so an
  exact-in buy of "premium + slack" silently returns extra options; naming the option count
  makes the number on the ticket the number that lands.
- **Depth is the real ceiling**, computed from all three bounds — the Aqua ledger, the short
  cap, and the cover the desk can actually back — not from any single contract view.
- **Every write previews itself** before a wallet opens: what you pay, what you receive,
  what you hold, how many prompts to expect, and the action blocked outright if the balance
  cannot cover it.


What the integration suite pins down: the first maker-hooks-plus-Aqua fill  both transfer
orderings producing identical state, with a guard test reading real `Transfer` logs to prove
the orderings actually differ; the Aqua ledger binding cumulatively mid-transaction; a
repointed pricer invalidating the order before any opcode runs; and the cash-secured PUT
running the same router path, where the quote token is collateral and premium at once.

The full lifecycle — buy, sell-back, exercise, settle, redeem, claim — is proven on chain
with exact conservation.


---

## How it's made

**Stack.** Solidity 0.8.30 + Foundry; **1inch Aqua** and a SwapVM router as the venue;
**Uniswap v4** for spot; React 19 + wagmi/viem + Privy; a Node settlement keeper. Base
Sepolia.

**The option is a SwapVM order.** A maker ships collateral into Aqua — which records a
commitment against their wallet and moves no tokens — and posts a program:
`Deadline + Salt + RequireMinRate + Extruction(pricer, args)`, where
`args = abi.encode(seriesId, volWad, minPremiumBps, side)`. On the Aqua path
`hash(order) == keccak256(abi.encode(order)) == Aqua's strategyHash`, and `USE_AQUA`
replaces signature verification, so shipping on chain is the authorisation. Aqua's ledger
is the depth, the maker's wallet the custody, the router the matching engine.

**Pricing runs inside the fill.** Abramowitz-Stegun Black-Scholes lives in `WeekendPricer`,
reached through `Extruction` against live Uniswap v4 spot. It is `view`, and its address is
covered by the order hash. It gates swap direction and enforces the maker's premium floor.

**Writing is just-in-time.** `preTransferOut` calls `WeekendDesk`, which mints exactly the
shortfall through `WeekendOptions.buyOption`; `Aqua.pull` draws collateral, `Aqua.push`
returns the premium. Nothing exists until a taker pays. The shipped ledger leg and a
per-series `maxShort` are both cumulative caps.

**Settlement.** Exercise is physical and reads no oracle — pay the strike, take the stock —
so it works while the underlying market is shut. The oracle is touched once after expiry,
only for what nobody exercised; `redeemFor` and `claimFor` are permissionless. A Pyth oracle
behind the same interface averages signed samples across a window.

**Front end.** The order encoder is reimplemented in TypeScript, byte-reconciled against
`OrderLib.sol`, and every fill is gated on `router.hash(order)` matching the shipped hash.
Buys are exact-out. No backend or indexer — every value is a chain read.

**207 tests green**, 53 against the real router and real Aqua. Full lifecycle proven on
chain with exact conservation: 0 USDC and 0 NVDAx held after the final `claimFor`.
