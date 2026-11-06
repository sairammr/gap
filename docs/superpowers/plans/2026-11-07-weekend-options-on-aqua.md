# Weekend Options on 1inch Aqua Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the capped-spread `GapOptionsApp` with Weekend Options' exact option mechanism — fungible series, pooled collateral, CALL/PUT, American physical exercise, oracle read only after expiry, pro-rata redeem/claim — using 1inch Aqua as the collateral layer.

**Architecture:** One Aqua app (`WeekendOptions`) owns a global series registry; each series mints its own ERC-20 `OptionToken`. Writers `AQUA.ship` collateral that stays in their wallet until a buy calls `AQUA.pull` into the series pool. Premium is parametric — the maker commits one `volWad`, the chain prices vanilla Black-Scholes off a v4 spot oracle at fill time. Exercise is physical and oracle-free; the oracle is read exactly once per series, at settle.

**Tech Stack:** Foundry (solc 0.8.30, `via_ir = false`), `@1inch/aqua`, OpenZeppelin ERC-20, solady `FixedPointMathLib`, Uniswap v4 `StateView`.

**Spec:** `docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md`

## Global Constraints

- Solc **0.8.30**, `evm_version = cancun`, `optimizer_runs = 1000`, **`via_ir = false`**. Stack-too-deep is a real failure mode: pack call arguments into a memory struct and split functions rather than enabling via_ir.
- Forge is **not on PATH**. Every command is `~/.foundry/bin/forge …`, run from `contracts/`.
- **Units.** Option and underlying amounts are 18 dp. `strike`, `settlePrice` and every oracle price are **quote-token units (6 dp USDC) per 1e18 of underlying**. `volWad` is WAD. `GapPricing` is WAD-native, so `quotePremium` converts 6 dp → WAD (`×1e12` for 6 dp) before pricing and WAD → 6 dp after.
- **Rounding.** `collateralFor` is the only `Ceil` — it rounds the writer's obligation against the writer. Every post-expiry formula **floors** (`F.fullMulDiv`, never `fullMulDivUp`).
- The underlying is assumed **18 dp**, as in the source protocol: `collateralFor` returns `amount` unscaled for a CALL.
- Reuse `test/helpers/MockStateView.sol` and `test/helpers/TakerStub.sol`. Do not write new doubles for these.
- Test spot prices are pinned by `MockStateView.setSqrtPriceX96`. Derive each constant from the 18 dp / 6 dp, `underlyingIsCurrency0 = true` base `spot = 100e18 → 792281625142643375935439`, scaling by `sqrt(P/100)`: `SQRT_PRICE_205 = 1134374654051415993876480`, `SQRT_PRICE_212 = 1153579458859239867416576`, `SQRT_PRICE_201 = 1123253065347574722985984`, `SQRT_PRICE_185 = 1077619515899065348915200`, `SQRT_PRICE_300 = 1372272028650298020986880`. Assert quote-unit prices with `assertApproxEqAbs(..., 1e3)` — the sqrt round-trip is not wei-exact.
- Keep `lib/UniV4Spot.sol`, `lib/GapPricing.sol` (minus `premium`), `interfaces/IStateView.sol`, `interfaces/IGapOptionCallback.sol`, `mocks/MockERC20.sol` unchanged in behaviour.
- Commit after every task. Conventional Commits.

## Review Focus

1. **`settlePrice == 0` pays PUT holders nothing.** `if (p > 0)` gates both payoff branches, so a *genuine* price of zero — where a PUT's intrinsic is the full strike — pays holders zero and hands writers the whole pool. Ported verbatim as a known quirk. → test in **Task 7**.
2. **`supplyAtSettle == 0` divides by zero.** A series settled with every option already exercised has zero supply; `redeem` must not panic. → test in **Task 8**.
3. **Maker committed on Aqua's books but wallet drained.** `ship` moves no tokens, so `rawBalances` can read full while `balanceOf(maker)` is zero; the pull then reverts deep inside Aqua with an opaque `ERC20InsufficientBalance`. Solvency must be `min(committed, wallet)` with a legible revert. → test in **Task 4**.
4. **Partial exercise then settle.** Exercise swaps value between legs, so a CALL series at settle holds *both* `poolUnderlying` and `poolCash`. Settlement must pay the holder from the underlying leg and still return the accumulated cash to writers. → test in **Task 7**.
5. **Exercise and buy after expiry.** Both must revert; settlement must not be reachable before expiry. An off-by-one on `<` vs `<=` here silently lets a holder exercise a worthless option. → test in **Task 5**.

## Execution order

```
Task 1  ─┬─ Task 2 ─┬─ Task 4 ─┬─ Task 5 ─┬─ Task 7 ── Task 8 ── Task 10 ─┬─ Task 11
         └─ Task 3 ─┘          ├─ Task 6 ─┘                               └─ Task 12
                               └─ Task 9 ───────────────────────────────┘
```

- **Task 1 is strictly first** — the tree does not build until the capped product is gone.
- **Tasks 2 and 3 run in parallel** (no shared files).
- **Tasks 5, 6 and 9 run in parallel** once Task 4 lands (all three only read Task 4's interfaces).
- **Task 7 waits for 5 and 6** — its pool-mix test needs both `exercise` and `close`.
- **Tasks 11 and 12 run in parallel** after Task 10.

---

### Task 1: Remove the capped-spread product

**Files:**
- Delete: `contracts/src/GapOptionsApp.sol`, `contracts/src/GapTaker.sol`
- Delete: `contracts/test/BuyOptionFixed.t.sol`, `BuyOptionPriced.t.sol`, `Settle.t.sol`, `GapStrategy.t.sol`, `GapTaker.t.sol`, `MultiMaker.t.sol`
- Delete: `contracts/script/Demo.s.sol`, `Ship.s.sol`, `ShipMany.s.sol`, `E2E.s.sol`, `e2e.sh`, `settle-keeper.sh`
- Delete: `app/src/components/GapCurve.tsx`, `app/src/components/Counterfactual.tsx`
- Modify: `contracts/src/lib/GapPricing.sol` — remove `premium()` (lines 26–55) and `error UnknownOptionKind` (line 24); rewrite the file's doc header so it no longer describes capped spreads
- Modify: `contracts/test/GapPricing.t.sol` — delete the two `GapPricing.premium` cases (lines 10–24); keep the `call`/`put`/parity/`normalCdf` cases
- Modify: `contracts/src/lib/UniV4Spot.sol:12` — doc comment names `GapOptionsApp`; retarget it
- Modify: `contracts/script/DeployGap.s.sol` — strip the `GapOptionsApp`/`GapTaker` deploy + JSON serialisation (lines 19–21, 30, 76–77, 110–113, 224–225); keep Aqua, token and pool seeding
- Modify: `contracts/script/redeploy-base-sepolia.sh` — drop the deleted ship-step invocations
- Keep untouched: `test/helpers/MockStateView.sol`, `test/helpers/TakerStub.sol`, `test/UniV4Spot.t.sol`, `test/PoolFork.t.sol`, `test/MockERC20.t.sol`, `script/DeployAqua.s.sol`, `script/lib/PoolSetup.sol`, `script/SyncSpot.s.sol`

**Interfaces:**
- Consumes: nothing.
- Produces: a tree where `GapPricing.call(spot, strike, secondsToExpiry, volWad)`, `GapPricing.put(…)` and `GapPricing.normalCdf(int256)` survive as the only pricing entry points; `GapPricing.CALL == 0` and `GapPricing.PUT == 1` remain.

- [ ] **Step 1: Delete the files listed above**

- [ ] **Step 2: Trim `GapPricing.sol` and `GapPricing.t.sol`**

- [ ] **Step 3: Retarget the two stale doc comments and strip `DeployGap.s.sol`**

- [ ] **Step 4: Verify the tree builds and the surviving suite passes**

Run: `~/.foundry/bin/forge test`
Expected: PASS, with zero references to `GapOptionsApp` remaining (`grep -r GapOptionsApp contracts/src contracts/test contracts/script` returns nothing).

- [ ] **Step 5: Commit**

```bash
git add -A contracts app
git commit -m "refactor: remove capped-spread options product"
```

---

### Task 2: Series registry and OptionToken

**Files:**
- Create: `contracts/src/OptionToken.sol`
- Create: `contracts/src/WeekendOptions.sol`
- Test: `contracts/test/Series.t.sol`

**Interfaces:**
- Consumes: `GapPricing.CALL`, `GapPricing.PUT` (Task 1).
- Produces:
  - `contract OptionToken is ERC20` with `address public immutable protocol`, `uint256 public immutable seriesId`, `mint(address,uint256)` and `burn(address,uint256)` both reverting `OnlyProtocol()` unless `msg.sender == protocol`.
  - `contract OptionTokenFactory` with `address public protocol`, `bind(address)` (one-time), `deploy(string,string,uint256) returns (OptionToken)`.
  - In `WeekendOptions`: `enum Kind { CALL, PUT }`; `struct Series { address underlying; uint64 expiry; Kind kind; uint256 strike; OptionToken token; uint256 totalWritten; uint256 poolUnderlying; uint256 poolCash; bool settled; uint256 settlePrice; uint256 supplyAtSettle; uint256 holderUnderlying; uint256 holderCash; uint256 writerUnderlying; uint256 writerCash; uint256 writtenAtSettle; }`
  - `createSeries(address underlying, uint64 expiry, Kind kind, uint256 strike) external returns (uint256 id)`
  - `seriesCount() external view returns (uint256)`
  - `getSeries(uint256 id) external view returns (Series memory)`
  - `collateralFor(uint256 id, uint256 amount) public view returns (address token, uint256 need)`
  - `mapping(uint256 => mapping(address => uint256)) public written`
  - `uint256 public constant SETTLEMENT_GRACE = 7 days`
  - errors `BadSeries()`, `Expired()`, `NotExpired()`, `AlreadySettled()`, `BadAmount()`
  - `event SeriesCreated(uint256 indexed seriesId, address indexed underlying, uint64 expiry, Kind kind, uint256 strike, address token)`

- [ ] **Step 1: Write the failing tests**

```solidity
function test_createSeries_dedupesOnKey() public {
    uint256 a = app.createSeries(address(nvdax), expiry, Kind.CALL, 205e6);
    uint256 b = app.createSeries(address(nvdax), expiry, Kind.CALL, 205e6);
    assertEq(a, b);
    assertEq(app.seriesCount(), 1);
}

function test_createSeries_rejectsPastExpiryAndZeroStrike() public {
    vm.expectRevert(WeekendOptions.BadSeries.selector);
    app.createSeries(address(nvdax), uint64(block.timestamp), Kind.CALL, 205e6);
    vm.expectRevert(WeekendOptions.BadSeries.selector);
    app.createSeries(address(nvdax), expiry, Kind.CALL, 0);
}

function test_collateralFor_callLocksUnderlyingPutLocksCashRoundedUp() public {
    uint256 c = app.createSeries(address(nvdax), expiry, Kind.CALL, 205e6);
    (address tc, uint256 nc) = app.collateralFor(c, 10e18);
    assertEq(tc, address(nvdax));
    assertEq(nc, 10e18);

    uint256 p = app.createSeries(address(nvdax), expiry, Kind.PUT, 205e6);
    (address tp, uint256 np) = app.collateralFor(p, 10e18);
    assertEq(tp, address(usdc));
    assertEq(np, 2050e6);
    // 1 wei of options still costs 1 unit of cash: Ceil, never free
    (, uint256 dust) = app.collateralFor(p, 1);
    assertEq(dust, 1);
}

function test_optionToken_onlyProtocolMintsAndBurns() public {
    uint256 id = app.createSeries(address(nvdax), expiry, Kind.CALL, 205e6);
    OptionToken t = app.getSeries(id).token;
    vm.expectRevert(OptionToken.OnlyProtocol.selector);
    t.mint(address(this), 1e18);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/Series.t.sol`
Expected: FAIL — `WeekendOptions` and `OptionToken` do not exist.

- [ ] **Step 3: Implement `OptionToken.sol`**

Port `core/OptionToken.sol` from the source protocol. The factory exists only to keep `WeekendOptions` under the 24KB limit — same reason as theirs.

- [ ] **Step 4: Implement the registry half of `WeekendOptions.sol`**

`createSeries` dedupes on `keccak256(abi.encode(underlying, expiry, kind, strike))` via `mapping(bytes32 => uint256) seriesIdOf` storing `id + 1`; returns the existing id rather than reverting. Rejects `expiry <= block.timestamp`, `expiry > block.timestamp + 400 days`, `strike == 0`. `collateralFor` returns `(underlying, amount)` for CALL and `(quote, F.fullMulDivUp(amount, strike, 1e18))` for PUT.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/Series.t.sol`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add contracts/src/OptionToken.sol contracts/src/WeekendOptions.sol contracts/test/Series.t.sol
git commit -m "feat: series registry and per-series option token"
```

---

### Task 3: v4 spot oracle behind `IPriceOracle`

**Files:**
- Create: `contracts/src/interfaces/IPriceOracle.sol`
- Create: `contracts/src/oracle/V4SpotOracle.sol`
- Test: `contracts/test/V4SpotOracle.t.sol`

**Interfaces:**
- Consumes: `IStateView`, `UniV4Spot.spotWad` (both unchanged from Task 1).
- Produces:
  - `interface IPriceOracle { function spot(address asset) external view returns (uint256 price, uint256 updatedAt); function settlementPrice(address asset, uint64 expiry) external view returns (uint256 price, bool ok); }` — copied verbatim from the source protocol.
  - `contract V4SpotOracle is IPriceOracle` with:
    - `constructor(IStateView stateView, uint8 quoteDecimals)`
    - `setPool(address asset, bytes32 poolId, uint8 assetDecimals, bool assetIsCurrency0) external` (owner-only)
    - `recordSettlement(address asset, uint64 expiry) external` — permissionless, callable only at or after `expiry`, writes once
    - `mapping(address => mapping(uint64 => uint256)) public settlement`
    - errors `NotConfigured()`, `TooEarly()`, `AlreadyRecorded()`

- [ ] **Step 1: Write the failing tests**

```solidity
function test_spot_returnsQuoteUnitsAndNow() public {
    stateView.setSqrtPriceX96(SQRT_PRICE_205);
    (uint256 p, uint256 at) = oracle.spot(address(nvdax));
    assertApproxEqAbs(p, 205e6, 1e3);
    assertEq(at, block.timestamp);
}

function test_spot_returnsZeroZeroWhenPoolUninitialised() public {
    stateView.setSqrtPriceX96(0);
    (uint256 p, uint256 at) = oracle.spot(address(nvdax));
    assertEq(p, 0);
    assertEq(at, 0);
}

function test_settlementPrice_notOkUntilRecorded() public {
    (, bool ok) = oracle.settlementPrice(address(nvdax), expiry);
    assertFalse(ok);
    vm.warp(expiry);
    oracle.recordSettlement(address(nvdax), expiry);
    (uint256 p, bool ok2) = oracle.settlementPrice(address(nvdax), expiry);
    assertTrue(ok2);
    assertApproxEqAbs(p, 205e6, 1e3);
}

function test_recordSettlement_rejectsEarlyAndDouble() public {
    vm.expectRevert(V4SpotOracle.TooEarly.selector);
    oracle.recordSettlement(address(nvdax), expiry);
    vm.warp(expiry);
    oracle.recordSettlement(address(nvdax), expiry);
    vm.expectRevert(V4SpotOracle.AlreadyRecorded.selector);
    oracle.recordSettlement(address(nvdax), expiry);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/V4SpotOracle.t.sol`
Expected: FAIL — contract does not exist.

- [ ] **Step 3: Implement `V4SpotOracle.sol`**

`spot` reads `getSlot0`, and **returns `(0, 0)` rather than reverting when `sqrtPriceX96 == 0`** — Task 7's grace-period fallback depends on an unconfigured/uninitialised pool yielding a zero price instead of bubbling a revert out of `settle`. Otherwise convert `UniV4Spot.spotWad` (WAD) to quote units by `F.mulDiv(spotWad, 10 ** quoteDecimals, 1e18)` and return `block.timestamp` as `updatedAt`. `settlementPrice` returns `(settlement[asset][expiry], settlement[asset][expiry] != 0)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/V4SpotOracle.t.sol`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add contracts/src/interfaces/IPriceOracle.sol contracts/src/oracle contracts/test/V4SpotOracle.t.sol
git commit -m "feat: v4 spot oracle with recorded settlement prices"
```

---

### Task 4: Aqua write path

**Files:**
- Modify: `contracts/src/WeekendOptions.sol`
- Create: `contracts/src/WeekendTaker.sol`
- Test: `contracts/test/Write.t.sol`

**Interfaces:**
- Consumes: Task 2's `Series`/`collateralFor`/`written`; Task 3's `IPriceOracle`; `IGapOptionCallback`; `AquaApp`'s `AQUA`, `nonReentrantStrategy(maker, hash)` and `_safeCheckAquaPush(maker, hash, token, expected)`.
- Produces:
  - `struct Strategy { address app; address maker; address underlying; address quote; uint256 volWad; bytes32 salt; }`
  - `hashStrategy(Strategy calldata s) public pure returns (bytes32)` — `keccak256(abi.encode(s))`, which must equal the hash Aqua derives from the same bytes in `ship`
  - `quotePremium(Strategy calldata s, uint256 seriesId, uint256 amount) public view returns (uint256)` — quote-token units
  - `buyOption(Strategy calldata s, uint256 seriesId, uint256 amount, uint256 maxPremium, address to, bytes calldata takerData) external returns (uint256 premium)`
  - `makerCapacity(Strategy calldata s, address token) public view returns (uint256 committed, uint256 wallet, uint256 backable)`
  - errors `NotThisApp()`, `PremiumTooHigh()`, `InsufficientMakerCollateral()`, `StrategyMismatch()`
  - `event OptionWritten(uint256 indexed seriesId, address indexed to, address indexed maker, uint256 amount, uint256 premium)`
  - `contract WeekendTaker` with `buy(WeekendOptions app, WeekendOptions.Strategy calldata s, uint256 seriesId, uint256 amount, uint256 maxPremium, address to, bytes calldata takerData) external` holding the payer in `address transient payer`, and `gapOptionCallback(...)` that `transferFrom`s the premium from the payer and `AQUA.push`es it to the maker. `takerData = abi.encode(maker, strategyHash)`.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_buy_pullsCoverIntoPoolAndPushesPremiumToMakerWallet() public {
    uint256 id = _callSeries();
    _ship(maker, address(nvdax), 10e18);
    uint256 makerUsdc0 = usdc.balanceOf(maker);

    uint256 prem = _buy(id, 10e18, buyer);

    assertEq(nvdax.balanceOf(maker), 0);                    // cover left the wallet
    assertEq(nvdax.balanceOf(address(app)), 10e18);         // ...into the pool
    assertEq(app.getSeries(id).poolUnderlying, 10e18);
    assertEq(app.getSeries(id).totalWritten, 10e18);
    assertEq(app.written(id, maker), 10e18);
    assertEq(app.getSeries(id).token.balanceOf(buyer), 10e18);
    assertEq(usdc.balanceOf(maker) - makerUsdc0, prem);     // premium to the wallet
}

function test_ship_movesNoTokens() public {
    _ship(maker, address(nvdax), 10e18);
    assertEq(nvdax.balanceOf(maker), 10e18);
}

// Review Focus 3
function test_buy_revertsLegiblyWhenMakerWalletDrainedDespiteAquaBooks() public {
    uint256 id = _callSeries();
    _ship(maker, address(nvdax), 10e18);
    vm.prank(maker);
    nvdax.transfer(address(0xDEAD), 10e18);
    (,, uint256 backable) = app.makerCapacity(_strategy(), address(nvdax));
    assertEq(backable, 0);
    vm.expectRevert(WeekendOptions.InsufficientMakerCollateral.selector);
    _buy(id, 10e18, buyer);
}

function test_buy_revertsOverMaxPremiumAndAfterExpiry() public { /* PremiumTooHigh, then Expired */ }

// Spec §6.2 — the product's headline claim: a violent move changes nothing
function test_adversePriceMove_leavesThePositionUntouched() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    WeekendOptions.Series memory before = app.getSeries(id);

    stateView.setSqrtPriceX96(SQRT_PRICE_300);   // +46% overnight gap against the writer

    WeekendOptions.Series memory afterMove = app.getSeries(id);
    assertEq(afterMove.poolUnderlying, before.poolUnderlying);
    assertEq(afterMove.totalWritten, before.totalWritten);
    assertEq(app.written(id, maker), 10e18);
    assertEq(nvdax.balanceOf(address(app)), 10e18);
    // there is no liquidate() to call, and no price-triggered path into the contract
}

function test_quotePremium_callIsWorthMoreThanIntrinsic() public {
    // ATM 205 strike, spot 205, 7d to expiry, 50% IV -> strictly positive, well under spot
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/Write.t.sol`
Expected: FAIL — `buyOption` not defined.

- [ ] **Step 3: Implement `quotePremium` and `makerCapacity`**

`quotePremium` converts the series strike and the oracle spot from quote units to WAD (`×10**(18 - quoteDecimals)`), calls `GapPricing.call`/`GapPricing.put` with `secondsToExpiry = expiry > block.timestamp ? expiry - block.timestamp : 0`, applies `amount` via `F.mulWad`, then converts WAD → quote units. `makerCapacity` returns `min(AQUA.rawBalances(...), IERC20(token).balanceOf(s.maker))` as `backable`.

- [ ] **Step 4: Implement `buyOption`**

Guard `s.app == address(this)`, `s.underlying`/`s.quote` match the series, `block.timestamp < expiry`, `amount > 0`. Check `backable >= need` **before** pulling so the revert is `InsufficientMakerCollateral` rather than Aqua's `ERC20InsufficientBalance`. Then `AQUA.pull` the cover to `address(this)`, add it to the correct pool leg, `written[id][s.maker] += amount`, `totalWritten += amount`, mint option tokens to `to`, and collect the premium: snapshot `rawBalances`, call `IGapOptionCallback(msg.sender).gapOptionCallback(...)`, then `_safeCheckAquaPush`. Carry the arguments in a memory struct — this function is stack-deep and the build has no via_ir.

- [ ] **Step 5: Implement `WeekendTaker.sol`**

Port the deleted `GapTaker` shape: transient `payer`, `transferFrom` the premium in, `approve(AQUA)`, `AQUA.push` to the maker.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/Write.t.sol`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add contracts/src/WeekendOptions.sol contracts/src/WeekendTaker.sol contracts/test/Write.t.sol
git commit -m "feat: write options against shipped Aqua collateral"
```

---

### Task 5: Physical exercise

**Files:**
- Modify: `contracts/src/WeekendOptions.sol`
- Test: `contracts/test/Exercise.t.sol`

**Interfaces:**
- Consumes: Task 4's write path.
- Produces: `exercise(uint256 id, uint256 amount) external`; error `NotExercisable()`; `event Exercised(uint256 indexed seriesId, address indexed holder, uint256 amount)`.

- [ ] **Step 1: Write the failing tests**

```solidity
// Golden vector, spec §9
function test_exerciseCall_paysStrikeReceivesStock() public {
    uint256 id = _callSeries();            // strike 205e6
    _shipAndBuy(id, 10e18, buyer);
    uint256 u0 = usdc.balanceOf(buyer);
    vm.prank(buyer);
    app.exercise(id, 10e18);
    assertEq(nvdax.balanceOf(buyer), 10e18);
    assertEq(u0 - usdc.balanceOf(buyer), 2050e6);
    assertEq(app.getSeries(id).poolUnderlying, 0);
    assertEq(app.getSeries(id).poolCash, 2050e6);
}

// Review Focus 5 — the oracle must never be touched
function test_exercise_readsNoOracle() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    stateView.setSqrtPriceX96(0);          // any oracle read would now price at zero
    vm.prank(buyer);
    app.exercise(id, 10e18);               // must still succeed
    assertEq(nvdax.balanceOf(buyer), 10e18);
}

function test_exercisePut_deliversStockReceivesCash() public {
    uint256 id = _putSeries();
    _shipAndBuy(id, 10e18, buyer);
    deal(address(nvdax), buyer, 10e18);
    vm.startPrank(buyer);
    nvdax.approve(address(app), 10e18);
    app.exercise(id, 10e18);
    vm.stopPrank();
    assertEq(usdc.balanceOf(buyer), 2050e6 + /* premium change */ 0);
    assertEq(app.getSeries(id).poolUnderlying, 10e18);
}

function test_exercise_partialLeavesRemainder() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    vm.prank(buyer);
    app.exercise(id, 4e18);
    assertEq(app.getSeries(id).token.balanceOf(buyer), 6e18);
    assertEq(app.getSeries(id).poolUnderlying, 6e18);
    assertEq(app.getSeries(id).poolCash, 820e6);
}

// Review Focus 5
function test_exercise_revertsAtAndAfterExpiry() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    vm.warp(expiry);
    vm.prank(buyer);
    vm.expectRevert(WeekendOptions.Expired.selector);
    app.exercise(id, 10e18);
}

function test_exercise_revertsOnZeroAmount() public { /* BadAmount */ }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/Exercise.t.sol`
Expected: FAIL — `exercise` not defined.

- [ ] **Step 3: Implement `exercise`**

Require `block.timestamp < expiry` (strict — expiry itself is too late), `amount > 0`. Burn `amount` from `msg.sender`. CALL: pull `F.fullMulDivUp(amount, strike, 1e18)` quote in, `poolCash +=` it, `poolUnderlying -= amount`, transfer `amount` underlying out. PUT: pull `amount` underlying in, `poolUnderlying +=` it, `poolCash -=` `F.fullMulDiv(amount, strike, 1e18)`, transfer that cash out. Effects before transfers.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/Exercise.t.sol`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add contracts/src/WeekendOptions.sol contracts/test/Exercise.t.sol
git commit -m "feat: American physical exercise with no oracle read"
```

---

### Task 6: Writer unwind via `close`

**Files:**
- Modify: `contracts/src/WeekendOptions.sol`
- Test: `contracts/test/Close.t.sol`

**Interfaces:**
- Consumes: Task 4's write path.
- Produces: `close(uint256 id, uint256 amount) external`; `event Closed(uint256 indexed seriesId, address indexed writer, uint256 amount)`.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_close_returnsProRataOfBothPools() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);       // maker wrote 10
    vm.prank(buyer);
    app.exercise(id, 4e18);              // pool is now 6e18 stock + 820e6 cash
    // writer buys their options back and closes half the written position
    vm.prank(buyer);
    app.getSeries(id).token.transfer(maker, 5e18);      // buyer holds 6e18 after exercising 4e18
    uint256 makerUsdc0 = usdc.balanceOf(maker);         // already holds the premium
    vm.prank(maker);
    app.close(id, 5e18);
    // pro-rata on PRE-decrement totalWritten = 10e18
    assertEq(nvdax.balanceOf(maker), 3e18);              // 6e18 * 5/10
    assertEq(usdc.balanceOf(maker) - makerUsdc0, 410e6); // 820e6 * 5/10, snapshot before close
    assertEq(app.getSeries(id).totalWritten, 5e18);
    assertEq(app.getSeries(id).poolUnderlying, 3e18);
    assertEq(app.getSeries(id).poolCash, 410e6);
    assertEq(app.written(id, maker), 5e18);
}

function test_close_revertsWithoutWrittenPositionOrTokens() public {
    // written[id][caller] < amount -> BadAmount
    // holds no option tokens -> ERC20 burn reverts
}

function test_close_revertsAfterExpiry() public { /* Expired */ }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/Close.t.sol`
Expected: FAIL — `close` not defined.

- [ ] **Step 3: Implement `close`**

Require `block.timestamp < expiry`, `amount > 0`, `written[id][msg.sender] >= amount`. Burn `amount` option tokens from `msg.sender`. Compute `outU`/`outC` by `F.fullMulDiv(pool*, amount, totalWritten)` using the **pre-decrement** `totalWritten`, then decrement `written`, `totalWritten`, `poolUnderlying`, `poolCash` and transfer both legs to `msg.sender`'s wallet (spec §11 — no `freeBalance` under Aqua).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/Close.t.sol`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add contracts/src/WeekendOptions.sol contracts/test/Close.t.sol
git commit -m "feat: pre-expiry writer unwind via close"
```

---

### Task 7: Settlement

**Files:**
- Modify: `contracts/src/WeekendOptions.sol`
- Test: `contracts/test/Settle.t.sol`

**Interfaces:**
- Consumes: Tasks 4, 5, 6; Task 3's `IPriceOracle`.
- Produces: `settle(uint256 id) external`, internal `_settle(uint256 id)` (so Task 8 can lazy-settle); error `OracleNotReady()`; `event Settled(uint256 indexed seriesId, uint256 price, uint256 holderUnderlying, uint256 holderCash)`.

- [ ] **Step 1: Write the failing tests**

```solidity
// Golden vector, spec §9 — ITM call settles in stock
function test_settle_itmCall_snapshotsHolderAndWriterShares() public {
    uint256 id = _callSeries();                     // strike 205e6
    _shipAndBuy(id, 10e18, buyer);
    _recordSettlementAt(212e6);                     // warp past expiry, record 212
    app.settle(id);
    WeekendOptions.Series memory s = app.getSeries(id);
    assertEq(s.settlePrice, 212e6);
    assertEq(s.supplyAtSettle, 10e18);
    assertApproxEqAbs(s.holderUnderlying, 330188679245283018, 10);
    assertApproxEqAbs(s.writerUnderlying, 9669811320754716982, 10);
    assertEq(s.holderUnderlying + s.writerUnderlying, 10e18);  // exact subtraction
    assertEq(s.writtenAtSettle, 10e18);
    assertEq(s.poolUnderlying, 10e18);              // pools are NOT decremented
}

function test_settle_otmCall_writerTakesEverything() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    _recordSettlementAt(201e6);
    app.settle(id);
    assertEq(app.getSeries(id).holderUnderlying, 0);
    assertEq(app.getSeries(id).writerUnderlying, 10e18);
}

function test_settle_itmPut_paysHolderCash() public {
    uint256 id = _putSeries();                      // strike 205e6, 10 options -> 2050e6 cash
    _shipAndBuy(id, 10e18, buyer);
    _recordSettlementAt(185e6);
    app.settle(id);
    assertEq(app.getSeries(id).holderCash, 200e6);  // 10e18 * 20e6 / 1e18
    assertEq(app.getSeries(id).writerCash, 1850e6);
}

// Review Focus 4 — a CALL series holds BOTH legs after a partial exercise
function test_settle_afterPartialExercise_paysFromStockAndReturnsAccruedCash() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    vm.prank(buyer);
    app.exercise(id, 4e18);                         // pool: 6e18 stock + 820e6 cash
    _recordSettlementAt(212e6);
    app.settle(id);
    WeekendOptions.Series memory s = app.getSeries(id);
    assertEq(s.supplyAtSettle, 6e18);
    assertApproxEqAbs(s.holderUnderlying, 198113207547169811, 10); // 6e18*7/212
    assertEq(s.writerUnderlying, 6e18 - s.holderUnderlying);
    assertEq(s.holderCash, 0);                      // a CALL never pays holders cash
    assertEq(s.writerCash, 820e6);                  // exercise proceeds go to writers
}

// Review Focus 1 — ported quirk: a genuine zero price pays PUT holders nothing
function test_settle_zeroPrice_paysPutHoldersNothing() public {
    uint256 id = _putSeries();
    _shipAndBuy(id, 10e18, buyer);
    vm.warp(expiry + app.SETTLEMENT_GRACE());
    stateView.setSqrtPriceX96(0);                   // spot() -> (0, 0)
    app.settle(id);
    assertEq(app.getSeries(id).settlePrice, 0);
    assertEq(app.getSeries(id).holderCash, 0);      // intrinsic would be the full strike
    assertEq(app.getSeries(id).writerCash, 2050e6);
}

function test_settle_revertsBeforeExpiryAndInsideGraceWithoutPrice() public {
    // NotExpired before expiry; OracleNotReady at expiry with nothing recorded
}

function test_settle_revertsOnSecondCall() public { /* AlreadySettled */ }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/Settle.t.sol`
Expected: FAIL — `settle` not defined.

- [ ] **Step 3: Implement `_settle`**

Follow spec §10 exactly. Oracle sequence: `settlementPrice` → if `!ok` and inside grace revert `OracleNotReady` → past grace, read `spot` and take `updatedAt >= expiry ? sp : 0`. Then the `if (p > 0)` block, the two `min` caps, and the six snapshot writes. `writerUnderlying`/`writerCash` are exact subtractions, not a second `mulDiv`. **Do not** decrement the pools.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/Settle.t.sol`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add contracts/src/WeekendOptions.sol contracts/test/Settle.t.sol
git commit -m "feat: post-expiry settlement with grace-period fallback"
```

---

### Task 8: Redeem and claim

**Files:**
- Modify: `contracts/src/WeekendOptions.sol`
- Test: `contracts/test/Payout.t.sol`

**Interfaces:**
- Consumes: Task 7's `_settle` and the six snapshot fields.
- Produces:
  - `redeem(uint256 id, uint256 amount) external returns (uint256 outU, uint256 outC)`
  - `redeemFor(uint256 id, address holder) external returns (uint256, uint256)`
  - `claim(uint256 id) external returns (uint256 outU, uint256 outC)`
  - `claimFor(uint256 id, address writer) external returns (uint256, uint256)`
  - events `Redeemed(uint256 indexed seriesId, address indexed holder, uint256 amount, uint256 outU, uint256 outC)`, `WriterClaimed(uint256 indexed seriesId, address indexed writer, uint256 outU, uint256 outC)`

- [ ] **Step 1: Write the failing tests**

```solidity
// Golden vector, spec §9
function test_redeemAndClaim_itmCall_matchTheSourceProtocolToTheWei() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    _recordSettlementAt(212e6);
    vm.prank(buyer);
    app.redeem(id, 10e18);
    assertApproxEqAbs(nvdax.balanceOf(buyer), 330188679245283018, 10);
    app.claimFor(id, maker);
    assertApproxEqAbs(nvdax.balanceOf(maker), 9669811320754716982, 10);
}

function test_redeem_lazySettlesOnFirstTouch() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    _recordSettlementAt(212e6);
    assertFalse(app.getSeries(id).settled);
    vm.prank(buyer);
    app.redeem(id, 10e18);                       // no explicit settle() call
    assertTrue(app.getSeries(id).settled);
}

function test_redeem_partialUsesSnapshotDenominator() public {
    // two halves redeemed separately sum to the same total as one full redeem
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    _recordSettlementAt(212e6);
    vm.startPrank(buyer);
    (uint256 a,) = app.redeem(id, 5e18);
    (uint256 b,) = app.redeem(id, 5e18);
    vm.stopPrank();
    assertApproxEqAbs(a + b, 330188679245283018, 10);
}

function test_claim_isOneShot() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    _recordSettlementAt(201e6);
    app.claimFor(id, maker);
    (uint256 u, uint256 c) = app.claimFor(id, maker);
    assertEq(u, 0);
    assertEq(c, 0);
    assertEq(app.written(id, maker), 0);
}

// Review Focus 11 (spec §6) — keeper pays everyone, permissionlessly
function test_redeemForAndClaimFor_payTheTargetNotTheCaller() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    _recordSettlementAt(212e6);
    vm.prank(keeper);
    app.redeemFor(id, buyer);
    vm.prank(keeper);
    app.claimFor(id, maker);
    assertEq(nvdax.balanceOf(keeper), 0);
    assertGt(nvdax.balanceOf(buyer), 0);
    assertGt(nvdax.balanceOf(maker), 0);
}

function test_redeemFor_returnsZeroForEmptyHolder() public { /* (0,0), no revert */ }

// Review Focus 2
function test_redeem_doesNotPanicWhenSupplyAtSettleIsZero() public {
    uint256 id = _callSeries();
    _shipAndBuy(id, 10e18, buyer);
    vm.prank(buyer);
    app.exercise(id, 10e18);                     // supply is now 0
    _recordSettlementAt(212e6);
    app.settle(id);
    assertEq(app.getSeries(id).supplyAtSettle, 0);
    (uint256 u, uint256 c) = app.redeemFor(id, buyer);
    assertEq(u, 0);
    assertEq(c, 0);
    app.claimFor(id, maker);                     // writer still gets the whole pool
    assertEq(usdc.balanceOf(maker) >= 2050e6, true);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/Payout.t.sol`
Expected: FAIL — `redeem` not defined.

- [ ] **Step 3: Implement `_redeem` and `_claim`**

Both lazy-settle when `!settled`. `_redeem` burns from `holder`, divides by the snapshot `supplyAtSettle` (return `(0,0)` early when it is zero rather than dividing), and transfers directly. `_claim` caches `w = written[id][writer]`, returns `(0,0)` when zero, **zeroes `written` before paying**, divides by `writtenAtSettle`, and transfers directly to the writer's wallet. `redeemFor` reads the holder's full balance and returns `(0,0)` when it is zero.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/Payout.t.sol`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add contracts/src/WeekendOptions.sol contracts/test/Payout.t.sol
git commit -m "feat: pro-rata redeem and claim with keeper entry points"
```

---

### Task 9: Multi-maker quoting

**Files:**
- Modify: `contracts/src/WeekendOptions.sol`
- Test: `contracts/test/QuoteBest.t.sol`

**Interfaces:**
- Consumes: Task 4's `quotePremium`, `makerCapacity`, `Strategy`.
- Produces: `quoteBest(Strategy[] calldata ss, uint256 seriesId, uint256 amount) external view returns (uint256 bestIndex, uint256 bestPremium, address bestMaker)` — `bestIndex == type(uint256).max` when nobody qualifies, and never reverts on an empty array.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_quoteBest_picksCheapestVol() public {
    // three makers at 45%, 50%, 60% IV, all solvent -> index of the 45% maker
}

function test_quoteBest_skipsInsolventAndForeignApp() public {
    // maker committed on Aqua but wallet drained -> skipped
    // s.app != address(this) -> skipped
}

function test_quoteBest_emptyAndAllInsolventReturnSentinel() public {
    (uint256 i,, address m) = app.quoteBest(new WeekendOptions.Strategy[](0), id, 10e18);
    assertEq(i, type(uint256).max);
    assertEq(m, address(0));
}

function test_quoteBest_winnerIsActuallyFillable() public {
    // buy from the returned maker at the returned premium -> succeeds
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/QuoteBest.t.sol`
Expected: FAIL — `quoteBest` not defined.

- [ ] **Step 3: Implement `quoteBest`**

Skip a candidate when `s.app != address(this)` or when `makerCapacity(...).backable < collateralFor(seriesId, amount).need` — the same threshold `buyOption` pulls at, so a returned quote is always fillable. Extract the per-candidate filter into an internal helper to keep the loop's stack shallow.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/.foundry/bin/forge test --match-path test/QuoteBest.t.sol`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add contracts/src/WeekendOptions.sol contracts/test/QuoteBest.t.sol
git commit -m "feat: cheapest-solvent-maker quoting over shipped strategies"
```

---

### Task 10: Deploy and ship scripts

**Files:**
- Modify: `contracts/script/DeployGap.s.sol`
- Create: `contracts/script/ShipWeekend.s.sol`
- Modify: `contracts/script/redeploy-base-sepolia.sh`
- Modify: `app/public/deployments/base-sepolia.json`, `contracts/deployments/base-sepolia.json`

**Interfaces:**
- Consumes: every contract from Tasks 2–9.
- Produces: a deployment JSON carrying `weekendOptions`, `weekendTaker`, `optionTokenFactory`, `oracle`, plus the existing `aqua`/`usdc`/`nvdax`/`poolId`/`stateView`/`makers` keys.

- [ ] **Step 1: Extend `DeployGap.s.sol`**

Deploy `OptionTokenFactory`, `V4SpotOracle`, `WeekendOptions`, `WeekendTaker`; `bind` the factory; `setPool` the oracle for NVDAx; create one CALL and one PUT series at a near-term expiry; serialise the new keys. Keep the existing Aqua, mock-token and v4 pool seeding untouched.

- [ ] **Step 2: Write `ShipWeekend.s.sol`**

Ships a maker's collateral: `[underlying]` for a CALL-writing strategy, `[quote]` for a PUT-writing strategy, `approve` then `AQUA.ship`. Assert the Aqua-returned hash equals `app.hashStrategy(strategy)` — the same guard the deleted `Ship.s.sol` carried, and the thing that catches a struct drifting from what the UI builds.

- [ ] **Step 3: Verify against a fork without broadcasting**

Run: `~/.foundry/bin/forge script script/DeployGap.s.sol --fork-url $BASE_SEPOLIA_RPC_URL -vvv`
Expected: completes, logs the new addresses, no revert.

- [ ] **Step 4: Commit**

```bash
git add contracts/script contracts/deployments app/public/deployments
git commit -m "feat: deploy and ship scripts for the weekend options app"
```

---

### Task 11: Frontend swap

**Files:**
- Modify: `app/src/lib/abi.ts`, `app/src/lib/deployment.ts`, `app/src/lib/strategy.ts`, `app/src/lib/pricing.ts`
- Modify: `app/src/hooks/positions.ts`, `app/src/hooks/positions.selfcheck.ts`, `app/src/hooks/usePositions.ts`
- Modify: `app/src/App.tsx`, `app/src/pages/Earn.tsx`

**Interfaces:**
- Consumes: Task 10's deployment JSON keys; the ABIs of `WeekendOptions` and `WeekendTaker`.
- Produces: a ticket with no `cap` anywhere, an **Exercise** control on open positions, and a positions panel sourced from `OptionWritten` logs.

- [ ] **Step 1: Strip the capped surface**

`pricing.ts`: delete `cappedPremiumPerUnit`, `previewPremium`, `cappedPayoffPerUnit` (lines 78–121); keep `normalCdf`, `sigmaRootT`, `bsCall`, `bsPut`, `KIND`. `abi.ts`: replace the capped `quotePremium`/`buyOption`/`positions`/`OptionBought` entries with the new signatures. `App.tsx`: remove the cap state, slider, "Max payout" card, cap column and the `GapCurve` mount at the lines named in the removal inventory.

- [ ] **Step 2: Rewire the ticket and positions**

Ticket collects kind, strike, expiry and amount, previews with `bsCall`/`bsPut`, and shows the on-chain `quotePremium` as the binding number. Buy routes through `WeekendTaker.buy` after an `approve`. Positions hydrate from `OptionWritten` logs plus `getSeries` and the option token's `balanceOf`.

- [ ] **Step 3: Add the Exercise control**

An **Exercise** button on any unexpired position, calling `exercise(id, amount)` after approving the underlying for a PUT. Label it as the oracle-free route — it is the capability no other DeFi options UI offers, and burying it wastes the whole design.

- [ ] **Step 4: Verify the build and the self-checks**

Run: `cd app && npm run build`
Expected: 0 type errors.

- [ ] **Step 5: Commit**

```bash
git add app/src
git commit -m "feat: weekend options desk with physical exercise"
```

---

### Task 12: Settlement keeper

**Files:**
- Create: `contracts/script/weekend-keeper.sh`

**Interfaces:**
- Consumes: Task 8's `redeemFor`/`claimFor`; Task 3's `recordSettlement`.
- Produces: a cron-able script that settles and pays out every expired series.

- [ ] **Step 1: Write the keeper**

Scan `SeriesCreated` logs, filter to expired and unsettled series, then per series: `recordSettlement` on the oracle, `settle`, then `redeemFor` each holder and `claimFor` each writer discovered from `OptionWritten` logs. Skip cleanly when `.env` is absent, matching `redeploy-base-sepolia.sh`'s existing gating.

- [ ] **Step 2: Verify it is a no-op against a chain with nothing expired**

Run: `bash contracts/script/weekend-keeper.sh`
Expected: exits 0, reports zero series settled.

- [ ] **Step 3: Commit**

```bash
git add contracts/script/weekend-keeper.sh
git commit -m "feat: keeper that settles and pays out expired series"
```
