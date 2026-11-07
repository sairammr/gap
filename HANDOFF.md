# GAP on 1inch Aqua — Handoff

**Branch:** `weekend-options-on-aqua` · **Live on Base Sepolia (84532)** · **207 tests green · full lifecycle proven on chain**

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

### Proven on chain — the full lifecycle, series 1

Every step broadcast on the CURRENT deployment and confirmed `status 0x1`. Conservation is
exact: after `claimFor` the protocol holds **0 USDC and 0 NVDAx**, verified by live reads.

| step | tx |
|---|---|
| buy (`router.swap`) | `0xfa495ee82fe2f8f05c77307b77d8b3211d2c128909972cc6945cf7d950b63de8` |
| sell-back | `0xd60e6314c8882aa5aecaa26c3f3290c478f35d100c83f56c5b081bc9e3f2cd29` |
| exercise — **no oracle read** | `0x04e67cab227d414e9af85f226a00c6f9110e2a3cd9a8917921d67839d3220977` |
| `recordSettlement` | `0x84e735a767a84639492e983f1cdd02eb8291ee421d52317d727bc94490e00bf3` |
| `settle` | `0x5e1b6850354cb9ed3dc605d57389936e99a75b9e947d23cba6ac0c71b3a9950c` |
| `redeemFor` | `0xa41024c2cc2405df469d451fe0be5e54822493fbc85a06ebd690a65e759ff851` |
| `claimFor` | `0x7bf7fa8096f004f99b9ad12b700201ce180b3763fb565b2a46d252c17415c4ee` |

**Series 0 is untouched** — `totalWritten == 0`, expires 2026-11-13. Only series 1 ran the
lifecycle. An earlier demo ran buy and exercise against a *previous* stack whose addresses no
longer appear here.

Replay it in ~40s without waiting: `forge script script/FullCycle.s.sol --sig 'cycle()'
--fork-url <rpc>`. It asserts every leg, including `balanceOf(app) == 0`. Note it exits 1 on a
forge quirk documented in the file — read the printed values, not the exit code.

---

## 3. Architecture

```
WeekendOptions.sol   series, pooled collateral, exercise, close, settle, redeem, claim
WeekendPricer.sol    Extruction (0x04) target — Black-Scholes + the direction gate
WeekendDesk.sol      the maker — IMakerHooks, writes just-in-time
AquaSwapVMRouter     the venue — real 1inch code, our deployment

V4SpotOracle.sol         IPriceOracle — what the live stack points at. Manipulable; see §5
PythSettlementOracle.sol IPriceOracle — the fix, in tree, unwired; see §5
```

**No new opcode, no fork edit, no router patch.** `AquaOpcodes` ships no WAD transcendental
math — which is why the in-tree `WeekendGap` opcode prices a linearised approximation — so full
Abramowitz-Stegun Black-Scholes lives in our own contract behind `Extruction`, which is already
wired into that opcode set for exactly this.

Order program: `Deadline + Salt + RequireMinRate + Extruction(pricer, args)`.
On the Aqua path `hash(order) == keccak256(abi.encode(order)) == Aqua's strategyHash`, and
**no signature is ever read** — shipping on-chain is the authorisation.

---

## 4. Tests — 207

| | |
|---|---|
| Default profile | **138** |
| Integration, real router + real Aqua | **53** |
| SDK (TypeScript) | **10** |
| Keeper (Node) | **6** |

```bash
~/.foundry/bin/forge test                                              # 138
FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/*'   # 53
cd sdk && npm test                                                     # 10
cd keeper && npm test                                                  # 6
```

forge is **not** on PATH. The swapvm profile exists because SwapVM needs `viaIR` + `prague`;
it must re-state its own `skip`, since a profile inherits the default's.

**Mocks are used for exactly two things: the v4 `StateView` lens and Pyth's signature check.**
Everything else — Aqua, the router, the options protocol, the ERC-20s — is real in every test.

### What the integration suite proves

- **The first maker-hooks-plus-Aqua fill ever run.** Nothing in the fork pairs them;
  `TraitsHelper` hardcodes all four hook flags off.
- Both transfer orderings produce **identical end state**, with a guard test reading real
  `Transfer` logs to prove the orderings actually differ.
- The **Aqua ledger is the only hard cap** and it binds cumulatively — the 11th fill reaches
  `written = 11e18` mid-transaction before `Aqua::pull` underflows.
- Repointing the pricer invalidates the order **before any opcode runs**.
- The bid side keeps working after the close guard trips permanently.
- **Both KINDS trade, not just both sides.** `DeskPut.t.sol` runs the cash-secured PUT through
  the same router, where the quote token is cover and premium at once — the collision that
  `_collectPremium`'s post-pull snapshot and `gapOptionCallback`'s approve-to-max both exist
  for. One desk serves a CALL and a PUT on the same underlying without crossing collateral.

---

## 5. Known and accepted

**The oracle is manipulable — accepted by the user, and the deployed stack still is.**
`V4SpotOracle.recordSettlement` is permissionless, reads an instantaneous `slot0`, and is
one-shot. One atomic transaction can move the pool, record, and unwind; forcing a CALL's price
`<= strike` pays ITM holders nothing. `spot()` also feeds Black-Scholes on every fill, so entry
pricing shares the root cause. Spec §4.
`test_settle_KNOWN_EXPOSURE_manipulatedSettlementPriceZeroesHolders` documents it.

**The fix is now in-tree but UNWIRED.** `src/oracle/PythSettlementOracle.sol` implements the
same `IPriceOracle` (15 tests). It takes the attacker's power down from *set any price* to
*select among prices Pyth's publishers actually signed inside the window*, then dilutes that:
settlement is the MEAN of every sample recorded between expiry and `expiry + WINDOW`, anyone
can push an honest sample, and `ok` stays false until the window closes so nobody settles on a
cherry-picked one. `WINDOW` is immutable and the constructor refuses `>= SETTLEMENT_GRACE`,
which would otherwise let `_settle`'s grace fallback beat the average to a single `spot()` read.

Nothing points at it yet. `WeekendOptions.oracle` is **immutable**, so adopting it is a full
redeploy, not a setter — fold it into the redeploy already pending below. Two deployment
decisions it needs first:

- **Base Sepolia Pyth is `0xA2aa501b19aff244D90cc15a4Cf739D2725B5729`; NVDA/USD is
  `0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593`.** Both exist, so this
  is deployable today, not theoretical.
- **`maxStaleness` has to clear the weekend.** A market-hours equity feed stops publishing on
  Friday; `spot() == 0` makes `buyOption` revert `NoPrice`, which would shut the ask side for
  exactly the two days this protocol is named after. Either widen `maxStaleness` past the
  close or point `priceId` at Pyth's 24/7 index feed. Exercise is unaffected — it reads no
  oracle at all, which is the whole design.

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
| **Redeploy** | live runtime is 16829 bytes, HEAD builds 17061 — the live stack predates `1e45cb7`'s `ShortPull` guard on PUT `exercise`. CALL path identical. Correct in the same pass: `PythSettlementOracle` (§5) if adopted, since `oracle` is immutable |
| ~~Keeper~~ | **built** — `keeper/`, zero deps, dry-run by default, verified against the live chain |
| ~~PUT through Aqua~~ | **proven** — `test/integration/DeskPut.t.sol`, 10 tests |
| ~~`PythSettlementOracle`~~ | **ported** — `src/oracle/PythSettlementOracle.sol`, 15 tests. Unwired; see §5 |
| **Frontend** | a generation behind, not merely stale — see below |
| **Rotate the Alchemy key** | an RPC URL with an embedded key was echoed in a console transcript |

**The frontend cannot reach this stack, and re-pointing the JSON will not fix it.**
`app/public/deployments/base-sepolia.json` names a dead deployment (`gapOptionsApp
0x45bBb79E…`, router `0xcB57df03…`, different usdc/nvdax); the key is `gapOptionsApp` where the
contracts write `weekendOptions`; and `app/src/lib/strategy.ts:37` builds a **10-field**
Strategy (`poolId`, `underlyingIsCurrency0`, decimals) against the current **8-field** one
(`app, maker, underlying, quote, volWad, minPremiumBps, maxSecondsToExpiry, salt`). The tuple
hashes to nothing the desk ever shipped. `sdk/orders.ts` is current and unaffected — it builds
the SwapVM *order*, which is a different object.

**Corrected from an earlier draft of this file:** the redeploy is *not* needed because
`hashStrategy` moved with `maxSecondsToExpiry`. The live contract already has the 8-field
struct — `hashStrategy` on chain returns
`0x81bea4227148a32f276ce340d806a06acc4f747d7a06f82b30295f256b39f90f`, byte-identical to local
`keccak(abi.encode(…))`. The real reason is the `ShortPull` guard above.

The desk needs **no** claim forwarder: `claimFor` is permissionless and pays the writer's
wallet directly (spec §11), so anyone can call it and `sweep` collects.

---

## 7. Docs

- `docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md` — the spec. Part I is the
  option mechanics, Part II the trading layer. Every decision and accepted risk is recorded
  there with its reasoning.
- `docs/FRONTEND-INTERFACE.md` — standalone UI handoff.
- `docs/superpowers/plans/` — the two implementation plans.
