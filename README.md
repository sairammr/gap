<div align="center">

# GAP

**Fully collateralised options on tokenized stocks, traded as 1inch SwapVM orders.**

Live on Base Sepolia · 207 tests · full lifecycle proven on chain

[Live app](https://gap-aqua.vercel.app) · [Pitch deck](https://gap-aqua.vercel.app/#pitch) · [Submission](#submission)

</div>

---

Tokenized stocks trade 24/7. Wall Street trades 32.5 hours of it. While the market is shut, stock tokens drift on thin liquidity — then the equity market reopens and reprices in a handful of candles, straight through the level where leveraged positions die. Nobody on the wrong side can do anything about it, because the market that sets the real price was closed the whole time.

GAP sells that gap. Pay a known premium, cap your downside, and there is nothing to liquidate — because every option is fully collateralised on both sides before it exists.

> **The one-line version:** the option *is* a 1inch order. There is no exchange in this repo.

---

## Contents

- [What makes it different](#what-makes-it-different)
- [Architecture](#architecture)
- [How a fill works](#how-a-fill-works)
- [Repository layout](#repository-layout)
- [Quick start](#quick-start)
- [Live deployment](#live-deployment)
- [Proven on chain](#proven-on-chain)
- [Tests](#tests)
- [Known and accepted](#known-and-accepted)
- [Submission](#submission)

---

## What makes it different

An option needs a venue before it needs a payoff. Every onchain options attempt starts by building an exchange: an order book, quoting makers, collateral custody, a matching path, settlement. The payoff math is the easy part — the venue is the project, and the collateral has to live inside your contract the entire time it is quoted.

**1inch Aqua is already that venue.** It holds a ledger of maker commitments, SwapVM carries the quote as bytecode, and `AquaSwapVMRouter` is the matching path. So a resting option quote is not listed on an exchange we built — it *is* a SwapVM order, and filling it writes the option.

| What a standalone options protocol ships | What GAP does instead |
|---|---|
| Own order book, off-chain maker bots | A SwapVM order is the quote; Aqua's ledger is the depth |
| Collateral deposited into the protocol | It stays in the maker's wallet until a fill pulls it |
| Custom matching and settlement | The real `AquaSwapVMRouter` — 1inch code, our deployment |
| Signed quotes, an RFQ server, a relayer | No signature is ever read. Shipping on chain is the authorisation |
| Mint, list, then sell | Minted just-in-time inside the fill. Nothing exists until a taker pays |

Properties that fall out of this, and that the protocol actively relies on:

- **Collateral moves exactly once.** `Aqua.ship` transfers no tokens — it writes an entry against the maker's own balance. The ERC-20 moves at `pull` time, inside the taker's transaction, at the instant the option is written. A maker can quote a hundred series while holding collateral for one.
- **The Aqua ledger is the only hard risk cap**, and it binds cumulatively. The fill that would over-write the maker reverts inside `Aqua::pull`, mid-transaction. No liquidation engine required.
- **Exercise reads no oracle at all.** Holders exercise physically — a call holder pays the strike and takes the stock, a put holder hands over the stock and takes the strike. The oracle is touched once, after expiry, and only for whatever nobody exercised.
- **Tamper-evident quotes.** On the Aqua path `hash(order) == keccak256(abi.encode(order)) == Aqua's strategyHash`, so repointing the pricer invalidates a resting order *before a single opcode runs*.

---

## Architecture

Two views. The first is **who does what**; the second is **when**.

### The actors and the lane between them

```
┌──────────────────────┐                                        ┌──────────────────────┐
│ MAKER                │                                        │ TAKER                │
│ owns the collateral  │                                        │ wants the option     │
└──────────┬───────────┘                                        └───────────┬──────────┘
           │ ship()                                                         │ swap()
           ▼                                                                │
  ╔═════════════════════════════════════════════════════════════╗           │
  ║ 1  Aqua                       ledger entry · no tokens move ║           │
  ╚══════════════════════════════╤══════════════════════════════╝           │
                                 ▼                                          │
  ╔═════════════════════════════════════════════════════════════╗ ◀─────────┘
  ║ 2  AquaSwapVMRouter           runs the order as bytecode    ║
  ╚══════════════════════════════╤══════════════════════════════╝
                                 ▼  Extruction (0x04)
  ┌─────────────────────────────────────────────────────────────┐
  │ 3  WeekendPricer              Black-Scholes, on-path        │
  └──────────────────────────────┬──────────────────────────────┘
                                 ▼  IMakerHooks.preTransferOut
  ┌─────────────────────────────────────────────────────────────┐
  │ 4  WeekendDesk                writes the option just-in-time│
  └──────────────────────────────┬──────────────────────────────┘
                                 ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ 5  WeekendOptions             mints OptionToken to the taker│
  └─────────────────────────────────────────────────────────────┘

  ╔═══╗  1inch, as deployed — no new opcode, no fork edit, no router patch
  ┌───┐  ours
```

Collateral leaves the maker's wallet through `Aqua.pull` and the premium arrives through `Aqua.push`, **both inside that one transaction**. The option is written, paid for and delivered before it ends.

### The three moments

```
 1 · SHIP — not one token moves
     maker ──ship()──▶ Aqua              collateral stays in the maker's wallet
     order = Deadline + Salt + RequireMinRate + Extruction(pricer, args)
     hash(order) == Aqua.strategyHash

 2 · FILL — one transaction, atomic
     taker ──router.swap()──▶ AquaSwapVMRouter
            │  [Deadline][Salt][RequireMinRate][Extruction]
            │                      └──▶ WeekendPricer ──reads──▶ Uniswap v4 StateView
            └──maker hook──▶ WeekendDesk ──writes JIT──▶ WeekendOptions ──mints──▶ taker

     Aqua.pull   collateral, maker → protocol     (the first time a token moves)
     Aqua.push   premium, taker → maker
     then a balance check, or the whole transaction reverts

 3 · AFTER
     exercise, any time     physical — reads no oracle at all
     at expiry              V4SpotOracle, one price, only for what nobody exercised
     redeemFor / claimFor   permissionless · everyone gets paid
```

### Why pricing runs through `Extruction`

`AquaOpcodes` ships no WAD transcendental math, so a Black-Scholes premium cannot be computed by the stock opcode set. `Extruction` (`0x04`) is the general external call already wired into that set for exactly this — it can read and write the swap registers and touch external protocols *before* settlement. So `WeekendPricer` computes full Abramowitz–Stegun Black-Scholes off a Uniswap v4 spot, mid-fill, inside the VM's execution, and the pricing args ride inside the program where the order hash covers them.

### Collateral by option kind

| | CALL | PUT |
|---|---|---|
| Writer locks | the underlying (covered) | `size × strike` in quote (cash-secured) |
| Holder exercises by | paying the strike, taking the stock | handing over the stock, taking the strike |
| Oracle involved | none | none |

---

## How a fill works

```solidity
// the maker's resting ask, as a SwapVM program
Deadline + Salt + RequireMinRate + Extruction(pricer, args)

// args = abi.encode(uint256 seriesId, uint256 volWad, uint16 minPremiumBps, uint8 side)
// and on the Aqua path:
hash(order) == keccak256(abi.encode(order)) == Aqua.strategyHash
```

1. The maker ships collateral: `Aqua.ship(router, abi.encode(order), tokens, amounts)`. Both legs of the pair are always shipped — `safeBalances` reverts unless both tokens sit in an active strategy, so the zero leg is a lookup, never a budget.
2. A taker calls `router.swap(order, amount, takerTraits)`.
3. SwapVM runs the program. `Extruction` calls `WeekendPricer`, which prices the fill against Uniswap v4 spot and enforces the direction gate and the premium floor.
4. The router calls the desk's `preTransferOut` maker hook. `WeekendDesk._mintShortfall` writes exactly the shortfall into `WeekendOptions`, against the desk's own shipped cover, bounded by `maxShort`.
5. `Aqua.pull` moves the collateral and `Aqua.push` moves the premium. A balance check seals it, or everything reverts.

To our knowledge this is the **first pairing of SwapVM maker hooks with Aqua** — the fork's own `TraitsHelper` hardcodes all four hook flags off, and the integration suite covers it.

---

## Repository layout

```
contracts/      Foundry — protocol, desk, pricer, oracles, deploy + lifecycle scripts, tests
  src/          the contracts (table below)
  script/       Deploy, Ship, SeedBook, Lifecycle, FullCycle, SyncSpot
  test/         unit suites; test/integration/ runs against real Aqua + real router
  deployments/  written by the deploy script — addresses per network
sdk/            TypeScript SwapVM order encoder, byte-reconciled against OrderLib.sol
app/            Vite + React desk — Trade, Earn, Positions, and the pitch deck at #pitch
keeper/         zero-dependency settlement keeper, dry-run by default
swap-vm-fork/   1inch SwapVM, plus our in-tree WeekendGap opcode (note below)
docs/           spec, build spec, interface handoffs, implementation plans
```

### Contracts

| Path | |
|---|---|
| `src/WeekendOptions.sol` | Series, pooled collateral, exercise, close, settle, redeem, claim |
| `src/OptionToken.sol` | ERC-20 per series, protocol mint/burn only |
| `src/desk/WeekendDesk.sol` | The maker. `IMakerHooks` — writes the option just-in-time on fill |
| `src/desk/WeekendPricer.sol` | The `Extruction` target — Black-Scholes and the direction gate |
| `src/oracle/V4SpotOracle.sol` | Uniswap v4 spot and the one-shot settlement record |
| `src/oracle/PythSettlementOracle.sol` | Permissionless Pyth samples, multiplier-aware per-token prices |
| `src/lib/GapPricing.sol` | Abramowitz–Stegun normal CDF and the premium math |
| `src/lib/UniV4Spot.sol` | `sqrtPriceX96` → USDC price, via the `StateView` lens |

> **On `swap-vm-fork/`.** It carries a custom `WeekendGap` opcode and its test, written to explore the SwapVM scoring path. **The live deployment does not use it** — `AquaOpcodes` has no WAD transcendental math, so that opcode can only price a linearised approximation, and full Black-Scholes lives in `WeekendPricer` behind `Extruction` instead. The deployed router is stock 1inch code. The fork is kept because the opcode is real, reviewable work; it is not load-bearing.

---

## Quick start

```bash
# contracts
cd contracts
forge test                                                           # 138
FOUNDRY_PROFILE=swapvm forge test --match-path 'test/integration/*'  # 53

# SDK and keeper
cd sdk    && npm test                                                # 10
cd keeper && npm test                                                # 6

# the desk UI
cd app && npm install && npm run dev                                 # http://localhost:5173
```

`forge` may not be on PATH — use `~/.foundry/bin/forge`. The `swapvm` profile exists because SwapVM needs `viaIR` + `prague`, and it must re-state its own `skip`, since a profile does not inherit the default's.

### Moving the demo pool to a real price

The Base Sepolia NVDAx/USDC v4 pool is seeded, not traded, so it sits wherever it was last put. To make the demo price off something that moves:

```bash
cd contracts
bash script/sync-spot.sh              # one sync against the live NVDA quote
bash script/sync-spot.sh --loop 60    # keep it tracking
```

### Seeding a book

```bash
cd contracts
FOUNDRY_PROFILE=swapvm forge script script/SeedBook.s.sol --sig 'seed()' \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Ships a strike ladder as resting quotes. Must be run by the desk's **owner**: Aqua keys balances by `msg.sender` and the maker is the desk, so `WeekendDesk.ship` (owner-only) forwards the call. `ShipAsk.s.sol` / `ShipBid.s.sol` only print calldata for the same reason.

---

## Live deployment

Base Sepolia (chain `84532`). **Read addresses from `contracts/deployments/base-sepolia.json` at runtime** — never hardcode them.

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

---

## Proven on chain

Every step broadcast on the current deployment and confirmed `status 0x1`. Conservation is exact: after `claimFor` the protocol holds **0 USDC and 0 NVDAx**, verified by live reads rather than by a test's own accounting.

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
cd contracts
forge script script/FullCycle.s.sol --sig 'cycle()' --fork-url <rpc>
```

It asserts every leg, including `balanceOf(app) == 0`. **It exits 1** on a forge quirk documented in the file — it re-runs the broadcast legs against un-warped state, where `NotExpired()` is correct. Read the printed values, not the exit code.

---

## Tests

**207 passing.**

| Suite | Count | Command |
|---|---|---|
| Protocol | **138** | `forge test` |
| Integration — real router, real Aqua | **53** | `FOUNDRY_PROFILE=swapvm forge test --match-path 'test/integration/*'` |
| SDK | **10** | `cd sdk && npm test` |
| Keeper | **6** | `cd keeper && npm test` |

**Mocks are used for exactly one thing: the Uniswap v4 `StateView` lens.** Aqua, the router, the options protocol and the ERC-20s are real in every test.

What the integration suite proves:

- The **first maker-hooks-plus-Aqua fill** we are aware of. Nothing in the fork pairs them; `TraitsHelper` hardcodes all four hook flags off.
- Both transfer orderings produce **identical end state**, with a guard test reading real `Transfer` logs to prove the orderings actually differ.
- The **Aqua ledger is the only hard cap** and it binds cumulatively — the 11th fill reaches `written = 11e18` mid-transaction before `Aqua::pull` underflows.
- Repointing the pricer invalidates the order **before any opcode runs**.
- The bid side keeps working after the close guard trips permanently.

Two harnesses in `app/scripts/` are worth knowing about:

- **`wallet-flow.ts`** replays the UI's exact `handleBuy` / `handleSell` / `exercise` argument lists as real transactions on an anvil fork. It caught a bug no unit test would have — the UI was the only caller of that path.
- **`seed-quotes.ts`** rebuilds every seeded quote with the *browser's* encoder and checks Aqua carries a balance on the resulting hash, pinning `app/src/lib/orders.ts` against the Solidity `OrderLib` without a golden vector.

---

## Known and accepted

**The settlement oracle is manipulable.** `V4SpotOracle.recordSettlement` is permissionless, reads an instantaneous `slot0`, and is one-shot. One atomic transaction can move the pool, record, and unwind — forcing a call's settlement price `≤` strike pays ITM holders nothing. `spot()` also feeds Black-Scholes on every fill, so entry pricing shares the root cause.

Scope: **only what nobody exercised.** Physical exercise is untouched, because it reads no oracle. The fix is a 113-line swap behind the same `IPriceOracle` — `PythSettlementOracle` is already in the tree. Accepted for a testnet pool we control; revisit before mainnet or any pool we do not. Documented by name in `test_settle_KNOWN_EXPOSURE_manipulatedSettlementPriceZeroesHolders`.

Other recorded decisions, each with its reasoning in the spec:

- `close` is barred once the opposite pool leg is non-empty. Stops a real extraction, costs a bounded liveness hole — a dust exercise can freeze a series.
- `Strategy` carries `maxSecondsToExpiry`, because a maker cannot otherwise decline a series.
- **An ask order must not carry a token-out `FeeProtocol`** — the desk would mint net and be pulled net+fee.
- No allowlist, no pause, no guardian, no fee. All deliberate.
- PUT asks are bounded by the USDC cover in the desk's own shipped strategy, which is currently small — puts fill in fractions where calls fill in tens.

---

## Submission

**Bounty:** 1inch — *Build an Aqua App*.

| Requirement | How this meets it |
|---|---|
| A sophisticated DeFi position | Fully collateralised options on tokenized stocks, written just-in-time, two-sided, physically exercisable |
| Official Aqua / SwapVM contracts used | Real `Aqua`, a stock `AquaSwapVMRouter`. No opcode fork, no router patch on the deployed path |
| SwapVM utilised | The order *is* a SwapVM program; pricing runs on-path through `Extruction` |
| Onchain token transfers in the demo | Seven live Base Sepolia transactions, full lifecycle, exact conservation |
| Proper git history | Incremental commits from day one, no single-commit final day |

| | |
|---|---|
| Protocol write-up | [`docs/submission-1inch.md`](docs/submission-1inch.md) |
| Long-form submission | [`docs/submission.md`](docs/submission.md) |
| Demo script | [`docs/pitch-script.md`](docs/pitch-script.md) |
| Deck | [gap-aqua.vercel.app/#pitch](https://gap-aqua.vercel.app/#pitch) |

### Lineage

GAP ports its option mechanics from the **Weekend Options** protocol, which is why the contracts are named `WeekendOptions`, `WeekendDesk` and `WeekendPricer`. The option mechanics are theirs; the trading layer — everything that turns a quote into a SwapVM order — is new here.

---

## Documentation

| | |
|---|---|
| [`docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md`](docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md) | The spec. Part I the option mechanics, Part II the trading layer. Every decision and accepted risk, with reasoning |
| [`docs/aqua-app-build-spec.md`](docs/aqua-app-build-spec.md) | The source-grounded build plan, written against the canonical 1inch repos |
| [`docs/FRONTEND-INTERFACE.md`](docs/FRONTEND-INTERFACE.md) | Standalone UI integration handoff |
| [`HANDOFF.md`](HANDOFF.md) | Current state, what is left, how to replay the lifecycle |

## License

See [LICENSE](LICENSE). `swap-vm-fork/` carries its own upstream licensing — see `swap-vm-fork/LICENSE` and `THIRD_PARTY_NOTICES`.
