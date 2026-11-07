# Weekend Options on 1inch Aqua

## Short description (< 100 chars)

Fully-collateralised stock options traded as 1inch Aqua / SwapVM orders — exercise needs no oracle.

## Full description

### What it is

Weekend Options is a fully-collateralised options venue for tokenised stocks (NVDAx),
priced and settled in one quote token (USDC), running live on Base Sepolia (chain 84532).
It exists to trade the overnight and weekend *gap* — the move that happens while the
equity market is shut — on-chain, without a single liquidatable position.

Two instruments, nothing else:

- **CALL** (`Kind.CALL = 0`, token symbol `UP-<id>`) — a covered call. The writer locks
  the **underlying** (NVDAx).
- **PUT** (`Kind.PUT = 1`, token symbol `FLOOR-<id>`) — a cash-secured put. The writer
  locks **USDC** (`size × strike`).

Both sides are fully collateralised *before the option exists*. There is no margin, no
health factor, and nothing to liquidate — by construction, not by policy.

### The two properties that define it

1. **Exercise reads no oracle.** A holder exercises physically and American-style, any
   time before expiry: on a CALL they pay the strike and take the stock; on a PUT they
   deliver the stock and take the strike. No published price is consulted. This is the
   headline — the holder *names* the price by paying the strike, so the route stays open
   even when the underlying market (and therefore the oracle) is closed, which is exactly
   when a gap product needs it.

2. **The oracle is touched once.** The Uniswap-v4 spot oracle (`V4SpotOracle`) is read a
   single time, at settlement, and only for whatever nobody exercised. Entry pricing
   (Black-Scholes) reads spot too, but the payout path does not depend on a live feed.

An option is a plain **ERC-20** — one token contract per series. It transfers and trades
anywhere; the protocol does not care how a holder acquired it.

### How a trade flows

```
Maker ships cover to Aqua  ──►  no tokens move (just a commitment)
Taker buys via the router  ──►  app pulls the cover JIT and mints the option ERC-20
Holder exercises           ──►  physical, pre-expiry, no oracle
            or
After expiry: settle (one oracle read) ──► redeem (holder) / claim (writer)
```

A maker ships collateral into **1inch Aqua** and posts a **SwapVM** order. Crucially,
`ship` moves **no tokens** — it writes an allowance-like commitment against the maker's
own wallet. The collateral only leaves the wallet at `pull` time, when a buyer actually
turns up, inside a maker hook. A taker buys through the real `AquaSwapVMRouter`; the desk
mints the option just-in-time against that collateral.

### How it's made

**Contracts (Solidity 0.8.30):**

| Contract | Role |
|---|---|
| `WeekendOptions.sol` | Series registry, pooled collateral, the whole lifecycle: `createSeries`, `buyOption`, `exercise`, `close`, `settle`, `redeem`/`redeemFor`, `claim`/`claimFor`. Extends `AquaApp`. |
| `OptionToken.sol` | One ERC-20 per series, minted on buy, burned on exercise/redeem. |
| `WeekendTaker.sol` | Stateless EOA router. `buyOption` calls back into `msg.sender` to collect the premium, so an EOA cannot call it directly — this helper is that `msg.sender` and holds no funds between transactions. |
| `desk/WeekendDesk.sol` | The SwapVM maker — implements `IMakerHooks`, writes options just-in-time against shipped cover. |
| `desk/WeekendPricer.sol` | `Extruction` (opcode `0x04`) target — Abramowitz-Stegun Black-Scholes plus the ask/bid direction gate. |
| `oracle/V4SpotOracle.sol` | Settlement price behind `IPriceOracle`, read from Uniswap v4 `StateView.getSlot0`. |

**The Aqua / SwapVM integration is real, not mocked.** No new opcode, no fork edit, no
router patch. The order program is `Deadline + Salt + RequireMinRate + Extruction(pricer, args)`,
and on the Aqua path `hash(order) == keccak256(abi.encode(order)) == Aqua's strategyHash` —
**no signature is ever read**; shipping on-chain is the authorisation. Spread is expressed
as implied vol: a two-sided maker ships a higher `volWad` on the ask than on the bid.

**Units (6dp quote, 18dp everything else):** option amounts and the underlying are 18
decimals; `strike`, oracle prices and premiums are quote units (6dp USDC) *per 1e18 of
underlying*; `volWad` is WAD (`1e18` = 100% annualised IV).

**Frontend (Vite + React 19 + wagmi/viem):** a Kuru-style trading desk — resting orders
listed by side on the left, the price chart and position tabs in the centre, and the order
ticket on the right. Spot comes from the v4 pool via `StateView`; premiums preview
client-side (a TS mirror of the on-chain Black-Scholes) and bind against the on-chain
`quotePremium`. There is no indexer and no backend — every bit of state is a chain read or
a log scan, with Aqua's `Shipped` logs acting as the maker registry.

**Tests:** 172 green — 119 default, 43 integration against the real router + real Aqua, 10
TypeScript SDK. The full lifecycle (buy, sell-back, exercise, settle, redeem, claim) has
been proven on chain with exact conservation: the protocol holds 0 USDC and 0 NVDAx after
the final `claimFor`.

### Accepted trade-offs (documented, not hidden)

- **The settlement oracle is manipulable** — `V4SpotOracle.recordSettlement` reads an
  instantaneous `slot0`. Accepted for this deployment; the fix (a Pyth-backed oracle behind
  the same `IPriceOracle`) is written and ready if this ever moves to a pool we don't
  control. The oracle-free exercise route is why this is tolerable.
- `close` is barred once the opposite pool leg is non-empty — closes a real value-extraction
  path at the cost of a bounded liveness hole.
- No allowlist, no pause, no guardian, no protocol fee — all deliberate, so the contract's
  claim that nothing can be seized holds with no admin key.
