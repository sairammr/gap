<div align="center">

# GAP — overnight gap options on 1inch Aqua

### The option is the order.

Fully collateralised options on tokenized stocks, traded as SwapVM orders backed by Aqua.
**Live on Base Sepolia · 172 tests green · the full lifecycle proven on chain.**

</div>

---

Tokenized stocks trade 24/7. Wall Street trades 32.5 hours of it. While the market is closed, stock tokens wick on thin liquidity, perps get liquidated, and stock-backed loans get wiped out by the Monday gap. GAP sells the gap — pay a known premium, cap your downside, and never get liquidated.

The option mechanics already existed — GAP ports them from the Weekend Options protocol, which is why the contracts are still named `WeekendOptions`, `WeekendDesk` and `WeekendPricer`. What did not exist was a way to trade them **without building an exchange first**. That is the whole of this project: the option stops being a product on a venue and becomes an order on one that is already there.

---

> **Example:** It's Friday. You hold $10,000 of tokenized Tesla (TSLAx). Over the weekend, bad earnings break and Monday the stock gaps down 12%. On a 10x perp you'd be liquidated — wiped out. But on Friday you bought a put for a small premium. Monday you exercise at your strike. You lost the premium, nothing else. No liquidation.

---

## The Problem

When US markets reopen after a weekend or overnight, prices **gap** — jumping sharply the moment trading resumes. On DeFi this cascades into failure:

- **Perps get liquidated.** High leverage makes them attractive, but a normal 5–10% weekend gap crosses the liquidation threshold instantly. The trader can't react — the market is closed.
- **Stock-backed loans get wiped.** Collateral value drops below the health factor before the borrower can repay.
- **xStocks wick on thin liquidity.** Over the weekend there are no buyers, so price overshoots.

This is structural. It isn't fixed by better liquidation engines — only by **capping downside before the gap happens**. That's what options do, and what DeFi was missing.

## Why it was missing

An option needs a venue before it needs a payoff. Every onchain options attempt starts by building an exchange: an order book, quoting makers, collateral custody, a matching path, settlement. The payoff math is the easy part — the venue is the project, and the collateral has to live inside your contract the entire time it is quoted.

## The Solution — make the option an order

**1inch Aqua is already the venue.** It holds a ledger of maker commitments; SwapVM carries the quote as bytecode; `AquaSwapVMRouter` is the matching path. So the option is not listed on an exchange we built. It *is* a SwapVM order, and filling it writes the option.

Everything the standalone version shipped as "what we built", this version **deleted**:

| Standalone options protocol | GAP on Aqua |
|---|---|
| Own order book, off-chain maker bots | No book. A SwapVM order is the quote; Aqua's ledger is the depth |
| Collateral deposited into the protocol | Collateral stays in the maker's wallet until a fill pulls it |
| Custom matching and settlement path | The real `AquaSwapVMRouter` — 1inch code, our deployment |
| Signed quotes, an RFQ server, a relayer | No signature is ever read. Shipping on chain is the authorisation |
| Options minted, listed, then sold | Minted just-in-time inside the fill. Nothing exists until a taker pays |

**No new opcode, no fork edit, no router patch.**

## What makes it special

- **The collateral never moves until a buyer turns up.** `ship` does not transfer a token — it writes an entry on Aqua's books against the maker's own balance. The ERC-20 moves at `pull` time, inside the taker's transaction, at the instant the option is written.
- **Just-in-time writing.** A maker can quote a hundred series while holding the collateral for one. The Aqua ledger is the hard cap and it binds **cumulatively** — the fill that would over-write the maker reverts on `Aqua::pull`, mid-transaction.
- **Exercise reads no oracle at all.** Holders exercise physically: a call holder pays the strike and takes the stock, a put holder hands over the stock and takes the strike. The oracle is touched once, after expiry, and only for whatever nobody exercised.
- **No liquidations, ever.** A quote can't exist without collateral behind it. Calls are covered, puts are cash-secured. No margin, nothing to liquidate.
- **Real Black-Scholes, on-path.** `AquaOpcodes` ships no WAD transcendental math, so full Abramowitz–Stegun pricing lives in our own contract behind `Extruction` — which is already wired into that opcode set for exactly this.
- **Two-sided.** Buy from the ask, sell back into the maker's bid before expiry. Same router, same program shape, opposite direction.
- **Tamper-evident orders.** On the Aqua path `hash(order) == keccak256(abi.encode(order)) == Aqua's strategyHash`, so repointing the pricer invalidates the order before a single opcode runs.

## How it works

```
maker ships collateral ──▶ Aqua ledger (tokens still in the maker's wallet)
       │
       └─ posts a SwapVM order:  Deadline + Salt + RequireMinRate + Extruction(pricer, args)

taker calls router.swap
  └─ SwapVM runs the order, Extruction prices it (Black-Scholes off Uniswap v4 spot)
      └─ maker hook: the desk WRITES the option just-in-time
          └─ Aqua.pull   maker → protocol   (collateral, the first time it moves)
          └─ Aqua.push   taker → maker      (premium)
      └─ balance check, or the whole transaction reverts

exercise any time before expiry — physical, no oracle involved
after expiry — one settlement price covers only what nobody exercised
redeemFor / claimFor are permissionless, so everyone gets paid without trusting a keeper
```

| | CALL | PUT |
|---|---|---|
| Writer locks | the underlying (covered) | `size × strike` in quote (cash-secured) |
| Holder exercises by | paying the strike, taking the stock | handing over the stock, taking the strike |

## Proven on chain

Base Sepolia (84532), series 1. Every step broadcast on the **current** deployment and confirmed `status 0x1`. Conservation is exact: after `claimFor` the protocol holds **0 USDC and 0 NVDAx**, verified by live reads rather than by a test's own accounting.

| step | tx |
|---|---|
| buy (`router.swap`) | [`0xfa495ee8…`](https://sepolia.basescan.org/tx/0xfa495ee82fe2f8f05c77307b77d8b3211d2c128909972cc6945cf7d950b63de8) |
| sell back into the bid | [`0xd60e6314…`](https://sepolia.basescan.org/tx/0xd60e6314c8882aa5aecaa26c3f3290c478f35d100c83f56c5b081bc9e3f2cd29) |
| exercise — **no oracle read** | [`0x04e67cab…`](https://sepolia.basescan.org/tx/0x04e67cab227d414e9af85f226a00c6f9110e2a3cd9a8917921d67839d3220977) |
| `recordSettlement` | [`0x84e735a7…`](https://sepolia.basescan.org/tx/0x84e735a767a84639492e983f1cdd02eb8291ee421d52317d727bc94490e00bf3) |
| `settle` | [`0x5e1b6850…`](https://sepolia.basescan.org/tx/0x5e1b6850354cb9ed3dc605d57389936e99a75b9e947d23cba6ac0c71b3a9950c) |
| `redeemFor` (holder paid) | [`0xa41024c2…`](https://sepolia.basescan.org/tx/0xa41024c2cc2405df469d451fe0be5e54822493fbc85a06ebd690a65e759ff851) |
| `claimFor` (writer paid) | [`0x7bf7fa80…`](https://sepolia.basescan.org/tx/0x7bf7fa8096f004f99b9ad12b700201ce180b3763fb565b2a46d252c17415c4ee) |

Replay the whole thing in ~40s without waiting on a real expiry:

```bash
forge script script/FullCycle.s.sol --sig 'cycle()' --fork-url <rpc>
```

It asserts every leg, including `balanceOf(app) == 0`. It exits 1 on a forge quirk documented in the file — read the printed values, not the exit code.

### Live deployment

| contract | address |
|---|---|
| `weekendOptions` | `0x7031B0eD0Cf2Dc85eC157696B91f3985bD7BCe4f` |
| `desk` | `0xc05D7b0069DCAF627a94d77e535c3f7b802A1B0C` |
| `pricer` | `0xE4C03419fc2C4A1BDf283e260d1Cb0B224ce19C9` |
| `oracle` | `0x9587C0301FeA237B2f6045e2D50C8f9E6d1bf7B1` |
| `optionTokenFactory` | `0x59D9A317Bf527C3df8B946FFB9e0cF61164f7E32` |
| `swapVmRouter` | `0x09235bE12Ab393C8B4343Db8d329F5B29B5F3B72` |
| `aqua` | `0x1E522b17600Aa9eE58C7633C528cCC19fdcFcd1f` |
| `usdc` | `0x7b7900fd08aA2b70f9595B3CCE0621baaad54463` |
| `nvdax` | `0x11Dd00c731F27793Bd9426B8ef22d7971AA2052b` |

**Read addresses from `contracts/deployments/base-sepolia.json` at runtime** — never hardcode them. Series 0 is an untouched ATM CALL at strike `100000000` (100 USDC); only series 1 ran the lifecycle above.

## Quick start

```bash
# contracts
cd contracts
forge test                                                        # 119
FOUNDRY_PROFILE=swapvm forge test --match-path 'test/integration/*'   # 43

# the TypeScript SDK
cd sdk && npm test                                                # 10

# the desk UI
cd app && npm install && npm run dev                              # http://localhost:5173
```

`forge` is not on PATH in this environment — use `~/.foundry/bin/forge`. The `swapvm` profile exists because SwapVM needs `viaIR` + `prague`, and it must re-state its own `skip`, since a profile does not inherit the default's.

## Tests — 172

| | |
|---|---|
| Protocol (default profile) | **119** |
| Integration, real router + real Aqua | **43** |
| SDK (TypeScript) | **10** |

**Mocks are used for exactly one thing: the Uniswap v4 `StateView` lens.** Aqua, the router, the options protocol and the ERC-20s are real in every test.

What the integration suite proves:

- **The first maker-hooks-plus-Aqua fill ever run.** Nothing in the fork pairs them; `TraitsHelper` hardcodes all four hook flags off.
- Both transfer orderings produce **identical end state**, with a guard test reading real `Transfer` logs to prove the orderings actually differ.
- The **Aqua ledger is the only hard cap** and it binds cumulatively — the 11th fill reaches `written = 11e18` mid-transaction before `Aqua::pull` underflows.
- Repointing the pricer invalidates the order **before any opcode runs**.
- The bid side keeps working after the close guard trips permanently.

## Repository layout

```
contracts/   Foundry: protocol, desk, pricer, oracles, deploy + lifecycle scripts, tests
contracts/deployments/   written by the deploy script — addresses per network
sdk/         TypeScript: order building and the Aqua ship/dock flow
app/         Vite + React desk UI — Trade, Earn, Protect, Positions, and the pitch deck at #pitch
keeper/      zero-dependency settlement keeper, dry-run by default
docs/        the spec, the frontend interface handoff, the implementation plans
```

### Contracts (`contracts/src`)

| Path | |
|---|---|
| `WeekendOptions.sol` | Series, pooled collateral, exercise, close, settle, redeem, claim |
| `OptionToken.sol` | ERC-20 per series, protocol mint/burn only |
| `desk/WeekendDesk.sol` | The maker. `IMakerHooks` — writes the option just-in-time on fill |
| `desk/WeekendPricer.sol` | The `Extruction` (`0x04`) target — Black-Scholes and the direction gate |
| `oracle/V4SpotOracle.sol` | Uniswap v4 spot and the one-shot settlement record |
| `oracle/PythSettlementOracle.sol` | Permissionless Pyth samples, multiplier-aware per-token prices |
| `lib/GapPricing.sol` | Abramowitz–Stegun normal CDF and the premium math |
| `lib/UniV4Spot.sol` | `sqrtPriceX96` → USDC price, via the `StateView` lens |

The order program is `Deadline + Salt + RequireMinRate + Extruction(pricer, args)`, run by the stock `AquaSwapVMRouter`.

## The pitch deck

The deck lives in the app, not beside it: **`#pitch`** (`app/src/pages/Pitch.tsx`). Arrow keys or the dot rail page through it; every claim on it links back to something in this repo or to a transaction on Basescan.

## Known and accepted

**The settlement oracle is manipulable.** `V4SpotOracle.recordSettlement` is permissionless, reads an instantaneous `slot0`, and is one-shot. One atomic transaction can move the pool, record, and unwind — forcing a call's settlement price `≤` strike pays ITM holders nothing. `spot()` also feeds Black-Scholes on every fill, so entry pricing shares the root cause.

Scope: **only what nobody exercised.** Physical exercise is untouched, because it reads no oracle. The fix is a 113-line swap behind the same `IPriceOracle` — `PythSettlementOracle` is already in the tree. Accepted for a testnet pool we control; revisit before mainnet or any pool we do not. Documented by name in `test_settle_KNOWN_EXPOSURE_manipulatedSettlementPriceZeroesHolders`.

Other recorded decisions, each with its reasoning in the spec:

- `close` is barred once the opposite pool leg is non-empty. Stops a real extraction, costs a bounded liveness hole — a dust exercise can freeze a series.
- `Strategy` carries `maxSecondsToExpiry`, because a maker cannot otherwise decline a series.
- **An ask order must not carry a token-out `FeeProtocol`** — the desk would mint net and be pulled net+fee.
- No allowlist, no pause, no guardian, no fee. All deliberate.

## Against the bounty brief — *Build an Aqua App*

| Requirement | How this meets it |
|---|---|
| A sophisticated DeFi position | Fully collateralised options on tokenized stocks, written just-in-time, two-sided, physically exercisable |
| Official Aqua / SwapVM contracts used | Real `Aqua`, a stock `AquaSwapVMRouter`. No opcode fork, no router patch |
| SwapVM utilised | The order *is* a SwapVM program; pricing runs on-path through `Extruction` |
| Onchain token transfers in the demo | Seven live Base Sepolia transactions, the full lifecycle, exact conservation |
| Proper git history | Incremental commits from day one, no single-commit final day |

## Documentation

- **[docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md](docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md)** — the spec. Part I is the option mechanics, Part II the trading layer. Every decision and accepted risk is recorded with its reasoning.
- **[HANDOFF.md](HANDOFF.md)** — current state, what is left, how to replay the lifecycle.
- **[docs/FRONTEND-INTERFACE.md](docs/FRONTEND-INTERFACE.md)** — standalone UI handoff.
