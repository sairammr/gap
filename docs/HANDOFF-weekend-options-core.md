# Weekend Options core — handoff

Scope: the options **core** contracts (`WeekendOptions`, `OptionToken`, `WeekendTaker`,
`V4SpotOracle`, `IPriceOracle`) and their test suites. The SwapVM trading layer
(`src/desk/**`), the frontend and the deploy/keeper scripts are owned elsewhere.

Branch `weekend-options-on-aqua`, from `61e2b31` to `69575cf` plus a final fix wave.
Spec: `docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md` (§9 golden vectors,
§10 post-expiry arithmetic and §11 are binding).

## What shipped

| Area | File |
|---|---|
| Series registry, pooled collateral, the whole lifecycle | `contracts/src/WeekendOptions.sol` |
| Per-series ERC-20 + factory | `contracts/src/OptionToken.sol` |
| EOA entry point (the app callbacks `msg.sender`, so an EOA cannot call `buyOption` directly) | `contracts/src/WeekendTaker.sol` |
| Settlement oracle behind `IPriceOracle` | `contracts/src/oracle/V4SpotOracle.sol` |

Lifecycle: `createSeries` → maker `AQUA.ship`s cover (moves **no tokens**) → `buyOption`
pulls the cover at fill time and mints option tokens → `exercise` (American, physical,
**reads no oracle**) or `close` (writer unwind) → `settle` (one oracle read) →
`redeem` / `claim`, both with permissionless `…For` keeper variants.

Tests: **123/123, nothing skipped**, plus 43 integration tests against the real router owned
by the trading layer. `WeekendOptions` runtime 17,061 B against the 24,576 B ceiling.

The full lifecycle has been run on chain by the trading-layer session — buy, sell-back,
exercise, a real expiry wait, settle, redeem, claim — and the protocol drained to 0 USDC and
0 NVDAx after `claimFor`, verified by live reads.

## Open security items

### 1. `spot()` is manipulable — ACCEPTED RISK, not fixed

`V4SpotOracle.recordSettlement` is permissionless, unbounded in time after expiry, reads an
instantaneous `slot0`, and is irrevocable. **The user reviewed and accepted this.** It is
documented by two deliberately-named tests in `Settle.t.sol`, not hidden:

- `test_settle_KNOWN_EXPOSURE_manipulatedSettlementPriceZeroesHolders`
- `test_settle_KNOWN_EXPOSURE_atomicGracePathManipulationLetsHoldersTakeTheWriterPool`

The exposure is wider than the obvious reading, and the scope matters if it is ever revisited:

- **Every `spot()` read reachable from `_settle` is manipulable**, including the one *inside*
  `settle` — and `settle` is permissionless and lazily invoked by `redeem`/`claim`. Past
  `expiry + SETTLEMENT_GRACE` the attack is atomic in **one transaction**: flash-loan → move
  `slot0` → `redeem` → unwind. No record step, no `AlreadyRecorded` race.
- **It is bidirectional.** On a CALL, pumping the spot drives `hU → supply`, so *holders* take
  the writers' entire pool. On a PUT, depressing it gives holders `poolCash`.
- **It also prices entry.** `quotePremium` feeds `spot()` straight into Black-Scholes, so a
  manipulated spot collapses the premium on a fill, not just the payout at settlement.

**Known fix, already written:** the source protocol ships
`contracts/src/oracle/PythSettlementOracle.sol` (113 lines) implementing the *same*
`IPriceOracle`. Signed Pyth updates, so there is no AMM to manipulate; permissionless
sampling with `publishTime` constrained to `[expiry, expiry + window]`; returns the mean;
and `ok = false` until the window closes, so no single observation can be locked in early —
exactly what `V4SpotOracle`'s one-shot `recordSettlement` lacks.

Two traps if that port is taken:

1. **Spec §7 currently forbids it** — it lists `Pyth` and `corporate-action multipliers` as
   out of scope, and `PythSettlementOracle` is both. Supersede §7 explicitly.
2. **`window` must be strictly less than `SETTLEMENT_GRACE` (7 days).** Otherwise `ok` never
   flips before the grace path opens, every settle falls through to step 3's instantaneous
   `spot()` read, and the median is bypassed — silently, with no revert. `setWindow` is
   owner-settable, so this is one admin call away. The oracle should reject a window ≥ the
   consuming protocol's grace rather than trust the deployer.

Note also that step 3's `spot()` is a permanent fallback: a deployment that keeps
`V4SpotOracle` answering `spot()` while Pyth answers `settlementPrice()` hands the pool read
back to anyone willing to wait out the grace period. It must be **one** oracle, not a pair
split by method.

### 2. A maker cannot decline a series — PARTIALLY MITIGATED

`Strategy` binds no series, strike or expiry, `buyOption` accepts any `seriesId`, and
`createSeries` is permissionless. So a maker who ships cover is exposed to **every** series on
that `(underlying, quote)` pair, including ones an attacker creates afterwards.

Mitigated by two maker-set bounds now in `Strategy`, both enforced in `_buyOption`:

- `minPremiumBps` — a floor as bps of the strike notional in quote units. Closes a Critical
  where `GapPricing.normalCdf` returns exactly 0 past 8σ, so the premium floored to zero and
  anyone could seize a maker's entire shipped cover for free at any strike ≥ ~1.76× spot.
- `maxSecondsToExpiry` — rejects a series longer-dated than the maker's vol was calibrated for.

**Residual:** a maker still quotes one flat `volWad` across every strike and tenor, so an
attacker picks the point where that flat vol is most wrong. This is ordinary adverse selection
once the oracle is honest, answered by a wider `volWad` or not shipping. `maxMoneynessBps` was
deliberately **not** added: it would be evaluated against the same manipulated spot it guards
against — depressing the spot moves a deep-ITM series *inside* the bound, not outside — and it
would make fills spot-dependent at fill time, an intermittent invisible revert for honest takers.

## Deliberate divergences from the source protocol

1. **`close` reverts `CloseAfterExercise` when the opposite pool leg is non-empty.** The source
   is extractable without this: `close` pays pro-rata across both legs on the pre-decrement
   `totalWritten`, so a writer entering a CALL series *after* holders have exercised buys into a
   pool holding cash banked at the strike. With `W` written, `X` exercised, strike `K`, writing
   then closing `A` takes `outU = (W−X+A)·A/(W+A)` and `outC = X·K·A/(W+A)` — profitable at
   every spot below the strike, zero-sum against existing writers.

   **This buys a liveness hole with the value hole, knowingly.** A holder of one option can
   exercise a dust amount (the strike on dust rounds up to one quote unit, ~1e-6 USDC) and
   freeze `close` for every writer in that series. No value is extracted and writers are made
   whole at settle, so the trade is right — but it is cheap and it is new.

   A third option was considered and rejected: cap the closer's payout at what they contributed,
   in their own leg only. It closes both holes but silently haircuts a writer whose cover
   genuinely was exercised. Failing loudly beats costing someone money quietly.

   The error name is **load-bearing across contracts** — the desk catches it by selector.

2. **`claim` and `close` transfer directly to the writer's wallet**, never `AQUA.push`. `push`
   reverts `PushToNonActiveStrategyPrevented` on a docked strategy, which would strand a
   writer's claim behind their own revocation (spec §11).

3. **Dropped deliberately, recorded so they read as decisions not omissions:** the
   `allowedUnderlying` owner allowlist (it would introduce the first admin key into a contract
   whose claim is that nothing can be seized; `underlying == quote` is rejected instead),
   `pause`/`guardian` (a pause key on a non-upgradeable contract holding others' collateral is a
   larger liability than the incidents it prevents, and hours-long series leave no window to
   act), `feeBps`/`treasury`, and any dust sweep.

## Behaviours that look like bugs and are not

Each is documented in natspec at its site; listed here so a future reader does not "fix" one.

- `_settle` does **not** zero or decrement the pools. They go stale; every payout runs off the
  six snapshot fields.
- The `if (p > 0)` gate means a *genuine* settlement price of exactly `0` pays PUT holders
  nothing even though intrinsic is then the full strike. Zero is overloaded as "no price".
- The two `min` caps apply at settle, not at payout, and truncate silently.
- `close`'s pro-rata uses the **pre-decrement** `totalWritten`.
- `_claim` caches `w` **before** zeroing `written[id][writer]`. Inverting that pays every writer
  zero — and would still pass a test that only checks the second call returns `(0,0)`.
- `_redeem` divides by the snapshot `supplyAtSettle`, never live `totalSupply()`. That is what
  makes partial redemption pro-rata-stable.
- Exactly **two** rounding-up sites exist repo-wide — `collateralFor` and `exercise`'s CALL
  `pay`. Both round against the party who owes. Everything else floors.

## Golden vectors

Spec §9's two numbers for the ITM-CALL case sum to `9999999999999999999`, one wei short of
`1e19`, so they cannot both be right. §10 mandates `writerUnderlying = poolUnderlying − hU` as
an **exact subtraction**, and the source does the same — §9's `…981` came from its JS assertion
under tolerance. The correct writer share is **`9669811320754716982`**, and the tests assert it
wei-exact. Tolerances are used in exactly one place: the single integration test that settles
through the real `V4SpotOracle`, where the sqrt round-trip genuinely is approximate (±1e3 in
quote units, which moves `holderUnderlying` by ~4.6e13 wei — hence Ruling 2's `MockPriceOracle`
for every arithmetic test).

## Known breakage and loose ends

- **The final fix wave has no clean commit.** Peer sessions ran broad `git add` mid-edit and
  swept it into `1e45cb7` and `b47a83c` under unrelated messages. The changes are present and
  verified per-file; rewriting already-synced shared history was declined. To see them as a
  unit, diff `69575cf..HEAD` restricted to the core paths.
- **`WeekendOptions.sol:395`** still carries a stale "collateralFor's only-Ceil" comment next to
  the second `fullMulDivUp`. Cosmetic; the three other instances were corrected.
- **Not built:** `quoteBest` (cancelled — spec §2.2 no longer argues for parametric multi-maker
  quoting), and the deploy scripts, frontend and keeper (held pending the trading layer).
- **Deferred minors**, none merge-blocking: an unreachable `NotExercisable()` branch; an unused
  import in `Settle.t.sol`; a bare `vm.expectRevert()` where a selector was available;
  out-of-range `id` panicking instead of reverting `BadSeries` in six entry points; no events on
  `setPool`/`recordSettlement` (worth adding — `recordSettlement` is the irrevocable one);
  `createSeries` emitting nothing on its dedup return path; and the partial `Gap`→`Weekend`
  rename (`IGapOptionCallback`, `gapOptionCallback`, `GapPricing` survive — `gapOptionCallback`
  is in the integration surface external takers implement, so renaming later is breaking).

## Two economic limits found on a live run

Neither is a code bug. Both are the pricing model meeting a tenor it was not calibrated for,
and both constrain how the core's parameters can actually be set. Written up in spec §12.6c by
the trading-layer session; repeated here because they are properties of `quotePremium` and
`_premiumFloor`, which live in this file.

1. **A constant `minPremiumBps` is unusable on short tenors.** 25 bps of strike notional
   exceeds a 15-minute option's entire time value, so a maker's own quote reverts against their
   own floor. The live run had to ship at **1 bp**. The floor is flat while time value is not,
   so the two cross somewhere — and for weekend-length series that crossing point is inside the
   product's normal operating range. If `minPremiumBps` ever grows a tenor term, this is the
   case for it.

2. **The vol-only spread collapses to zero on ITM short-dated series.** Ask vol `0.6` and bid
   vol `0.4` both priced a live series at exactly `5000000`, making the buy→sell round trip
   free. Deep enough ITM, the premium is intrinsic and intrinsic has no vol sensitivity, so
   `volWad` — the maker's only economic lever — stops being a lever at all. This is the same
   root as the `maxMoneynessBps` discussion above, seen from the maker's side rather than the
   attacker's.

`GapPricing.put` is `call + strike − spot` and `call()` is an Abramowitz–Stegun approximation,
so a deep-ITM call returning slightly less than intrinsic would underflow and brick
`quotePremium`/`buyOption` for far-OTM puts. The pricing functions were reimplemented
bit-for-bit offline and swept over S/K ∈ [1.05, 1000], vol ∈ [0.1%, 300%], tenor ∈ [1s, 400d]:
zero underflows, minimum exactly 0. The `t1 > t2 ? t1 − t2 : 0` floor and the `upperTail` clamp
keep it safe. Recorded so it is not rediscovered.
