# Weekend Options on 1inch Aqua — Handoff

**Branch:** `weekend-options-on-aqua` · **Live on Base Sepolia (84532)** · **172 tests green · full lifecycle proven on chain**

Fully collateralised options on tokenized stocks, traded as 1inch SwapVM orders backed by
Aqua. Ported from the Weekend Options protocol; the option mechanics are theirs, the trading
layer is new.

---

## 1. What it does

A maker ships collateral to Aqua and posts a SwapVM order. **The collateral never leaves their
wallet until a fill pulls it.** A taker buys through the real `AquaSwapVMRouter`; the desk
mints the option just-in-time against that collateral inside a maker hook.

Holders **exercise physically** — pay the strike, take the stock — which **reads no oracle at
all**. The oracle is touched once, after expiry, and only for whatever nobody exercised.

Both directions work: buy, and sell back to the maker's bid.

| | |
|---|---|
| CALL | writer locks the underlying (covered) |
| PUT | writer locks `size × strike` in quote (cash-secured) |

Fully collateralised both sides before a position exists. **No margin, nothing to liquidate.**

---

## 2. Live deployment

| contract | address |
|---|---|
| `weekendOptions` | `0x7031B0eD0Cf2Dc85eC157696B91f3985bD7BCe4f` |
| `desk` | `0xc05D7b0069DCAF627a94d77e535c3f7b802A1B0C` |
| `pricer` | `0xE4C03419fc2C4A1BDf283e260d1Cb0B224ce19C9` |
| `oracle` | `0x9587C0301FeA237B2f6045e2D50C8f9E6d1bf7B1` |
| `optionTokenFactory` | `0x59D9A317Bf527C3df8B946FFB9e0cF61164f7E32` |
| `optionToken` | `0x971e9B9738A5cbaAB198a36e2fcc1D165Ef2A30e` |
| `usdc` | `0x7b7900fd08aA2b70f9595B3CCE0621baaad54463` |
| `nvdax` | `0x11Dd00c731F27793Bd9426B8ef22d7971AA2052b` |
| `swapVmRouter` | `0x09235bE12Ab393C8B4343Db8d329F5B29B5F3B72` |
| `aqua` | `0x1E522b17600Aa9eE58C7633C528cCC19fdcFcd1f` |

Series 0: ATM CALL, strike `100000000` (100 USDC), `poolId` and `askStrategyHash` in
`contracts/deployments/base-sepolia.json` — **read addresses from that file at runtime.**

### Proven on chain

A real buy and a real exercise, both broadcast:

- `0x5b11a058…595acd` — 50.000000 USDC bought **15.096244597808870674 options** at 3.3122 each
  (Black-Scholes reference ≈3.316, so the on-chain pricer is honest)
- `0x2af3d9a1…a78cc6` — `exercise(0, …)` with **no oracle read**: options burned,
  1,509.624460 USDC paid at strike, 15.0962446 NVDAx delivered

---

## 3. Architecture

```
WeekendOptions.sol   series, pooled collateral, exercise, close, settle, redeem, claim
WeekendPricer.sol    Extruction (0x04) target — Black-Scholes + the direction gate
WeekendDesk.sol      the maker — IMakerHooks, writes just-in-time
AquaSwapVMRouter     the venue — real 1inch code, our deployment
```

**No new opcode, no fork edit, no router patch.** `AquaOpcodes` ships no WAD transcendental
math — which is why the in-tree `WeekendGap` opcode prices a linearised approximation — so full
Abramowitz-Stegun Black-Scholes lives in our own contract behind `Extruction`, which is already
wired into that opcode set for exactly this.

Order program: `Deadline + Salt + RequireMinRate + Extruction(pricer, args)`.
On the Aqua path `hash(order) == keccak256(abi.encode(order)) == Aqua's strategyHash`, and
**no signature is ever read** — shipping on-chain is the authorisation.

---

## 4. Tests — 172

| | |
|---|---|
| Default profile | **119** |
| Integration, real router + real Aqua | **43** |
| SDK (TypeScript) | **10** |

```bash
~/.foundry/bin/forge test                                              # 119
FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/*'   # 43
cd sdk && npm test                                                     # 10
```

forge is **not** on PATH. The swapvm profile exists because SwapVM needs `viaIR` + `prague`;
it must re-state its own `skip`, since a profile inherits the default's.

**Mocks are used for exactly one thing: the v4 `StateView` lens.** Everything else — Aqua, the
router, the options protocol, the ERC-20s — is real in every test.

### What the integration suite proves

- **The first maker-hooks-plus-Aqua fill ever run.** Nothing in the fork pairs them;
  `TraitsHelper` hardcodes all four hook flags off.
- Both transfer orderings produce **identical end state**, with a guard test reading real
  `Transfer` logs to prove the orderings actually differ.
- The **Aqua ledger is the only hard cap** and it binds cumulatively — the 11th fill reaches
  `written = 11e18` mid-transaction before `Aqua::pull` underflows.
- Repointing the pricer invalidates the order **before any opcode runs**.
- The bid side keeps working after the close guard trips permanently.

---

## 5. Known and accepted

**The oracle is manipulable — accepted by the user.** `V4SpotOracle.recordSettlement` is
permissionless, reads an instantaneous `slot0`, and is one-shot. One atomic transaction can
move the pool, record, and unwind; forcing a CALL's price `<= strike` pays ITM holders nothing.
`spot()` also feeds Black-Scholes on every fill, so entry pricing shares the root cause.

The fix is a 113-line swap behind the same `IPriceOracle` (`PythSettlementOracle` exists in the
source protocol). **Revisit if this moves to mainnet or a pool we do not control.** Spec §4.
`test_settle_KNOWN_EXPOSURE_manipulatedSettlementPriceZeroesHolders` documents it.

**Other recorded decisions** (spec §7b, §10, §12.6b):
- `close` barred once the opposite pool leg is non-empty — stops a real extraction, costs a
  bounded liveness hole, a dust exercise can freeze a series.
- `Strategy` carries `maxSecondsToExpiry`, because a maker cannot otherwise decline a series.
- **An ask order must not carry a token-out `FeeProtocol`** — the desk would mint net and be
  pulled net+fee.
- No allowlist, no pause, no guardian, no fee. All deliberate; reasoning in the spec.

---

## 6. What is left

| | |
|---|---|
| **Redeploy** | `hashStrategy` moved with `maxSecondsToExpiry`; the live stack predates it |
| **Keeper** | nobody calls `settle` / `redeemFor` / `claimFor` — all permissionless, so a cron suffices |
| **Frontend** | `docs/FRONTEND-INTERFACE.md`, addresses current |
| **`app/public/deployments/base-sepolia.json`** | still stale |
| **Rotate the Alchemy key** | an RPC URL with an embedded key was echoed in a console transcript |

The desk needs **no** claim forwarder: `claimFor` is permissionless and pays the writer's
wallet directly (spec §11), so anyone can call it and `sweep` collects.

---

## 7. Docs

- `docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md` — the spec. Part I is the
  option mechanics, Part II the trading layer. Every decision and accepted risk is recorded
  there with its reasoning.
- `docs/FRONTEND-INTERFACE.md` — standalone UI handoff.
- `docs/superpowers/plans/` — the two implementation plans.
