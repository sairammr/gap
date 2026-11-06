# Trading Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Weekend Options tradeable in both directions through the already-deployed `AquaSwapVMRouter`, with no fork edit, no new opcode and no router redeploy.

**Architecture:** A SwapVM order *is* a resting quote. `WeekendPricer` (an `Extruction` target, already built) prices it and gates direction; `WeekendDesk` is the maker, implementing `IMakerHooks` to write options just-in-time on an ask and close them on a bid. Aqua backs both sides with no signature in the fill path.

**Tech Stack:** Foundry (solc 0.8.30), the vendored `swap-vm-fork` compiled under a dedicated `[profile.swapvm]`, 1inch Aqua, OpenZeppelin, Solady.

**Spec:** `docs/superpowers/specs/2026-11-07-weekend-options-on-aqua.md` — **PART II (§12, §13)**. Every verifier finding is already encoded there; do not re-derive.

---

## Global Constraints

- **File ownership.** A concurrent agent owns `contracts/src/WeekendOptions.sol`, `contracts/src/WeekendTaker.sol`, `contracts/src/OptionToken.sol`, `contracts/src/oracle/**` and the core test files. **No task here may modify them.** Read their interfaces only.
- **Two builds, two commands.** Foundry default: `~/.foundry/bin/forge test` (forge is NOT on PATH; `via_ir = false`, so watch stack depth). SwapVM integration: `FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path <path>`. The hardhat fork build (`node node_modules/hardhat/dist/src/cli.js test solidity --build-profile fast`) is **not used by this plan** — nothing here edits the fork.
- **`[profile.swapvm]` already exists** in `contracts/foundry.toml`: `via_ir = true`, `evm_version = "prague"`, `optimizer_runs = 1`, `allow_paths = ["../swap-vm-fork"]`, remapping `swapvm/=../swap-vm-fork/contracts/`. **SwapVM does not compile under the default profile** (stack too deep) and does not compile under `cancun`. Verified working.
- **Integration tests use real contracts only** (§13): real `AquaSwapVMRouter`, real `Aqua`, real `WeekendOptions`, real ERC-20s, real `router.swap(...)`. Mocks permitted only for the v4 `StateView` lens and the price oracle.
- **Order traits are built with `MakerTraitsLib.build(Args)`**, never `TraitsHelper` (it hardcodes all four hook flags to `false`).
- Units: option amounts 18 dp; `strike`, premiums and oracle prices are quote-token units (6 dp) per 1e18.
- Spread is vol: a two-sided maker ships a higher `volWad` on the ask than the bid. No spread parameter exists.

## Already done — do not re-plan

| | |
|---|---|
| `contracts/src/interfaces/IExtruction.sol` | `SwapQuery`, `SwapRegisters`, `IStaticExtruction` mirrored |
| `contracts/src/desk/WeekendPricer.sol` | Black-Scholes premium, direction gate, ask/bid × exact-in/exact-out arithmetic |
| `contracts/test/Pricer.t.sol` | 13 tests passing |
| `contracts/foundry.toml` | `[profile.swapvm]` |

`WeekendPricer` produces, for reuse: `premiumPerOption(uint256 seriesId, uint256 volWad) public view returns (uint256)`, `SIDE_ASK() → 0`, `SIDE_BID() → 1`, `extruction(bool,uint256,SwapQuery,SwapRegisters,bytes,bytes) external view returns (uint256,uint256,SwapRegisters memory)`, errors `UnknownSide(uint8)`, `WrongSwapDirection(address,address)`, `SeriesExpired(uint64)`, `ZeroPremium()`, `ZeroAmount()`.

---

## ⚠ Blocked on core — one open design question

The desk must write options against its own collateral inside `preTransferOut`. The core's only write entry point is:

```solidity
buyOption(Strategy calldata s, uint256 seriesId, uint256 amount, uint256 maxPremium, address to, bytes calldata takerData) external returns (uint256 premium)
```

which pulls collateral from `s.maker` **via Aqua** and requires an `IGapOptionCallback` to push the premium. There is no zero-price self-write path (the reference desk used a zero-price RFQ; our core has no RFQ).

**Workaround requiring no core change, and what Task 3 implements:** the desk is a maker in the core protocol *as well as* the SwapVM maker. It ships a **third** Aqua strategy holding its collateral, then calls `buyOption(ownStrategy, seriesId, amount, type(uint256).max, address(this), abi.encode(address(this), ownStrategyHash))` with itself as both maker and taker — the premium is pushed desk→desk and nets to zero movement of value.

**If the core agent later adds a `writeFor(uint256 seriesId, uint256 amount, address to)` that takes collateral straight from the caller's wallet, Task 3 should use it instead and drop the third ship.** Flag this to the core owner; do not add it yourself.

---

## Review Focus

Five failure modes the spec implies that no single task's happy path exercises. Each is assigned to an owning task.

1. **Cumulative cap, not per-fill cap.** The Aqua ledger is the only hard bound and it accrues across *every* fill of one order hash. A series can be oversold across many small fills if anything assumes a per-fill check. → Task 8.
2. **The ledger must cover `amountOut + feeOut`.** The protocol fee is a second, separate `AQUA.pull`. A strategy shipped at exactly the series cap underflows on the fee. → Task 8.
3. **Transfer ordering is the taker's choice.** `IS_FIRST_TRANSFER_FROM_TAKER` (`0x0020`) is in *taker* traits; hooks must be correct with it both set and unset. → Task 9.
4. **`active` is checked in only one hook.** The reference desk gets away with this because ERC-1271 rejects first; on a no-signature Aqua path the gap is live. → Task 7.
5. **Minting does not credit the Aqua ledger.** JIT-minted tokens are pullable only because `pull` is a real `transferFrom`; the ledger still decrements from the shipped amount. Approval to Aqua is required or every ask fill reverts. → Task 6.

---

## Execution order

```
           ┌─ T1 OrderLib.sol ────────┐
           ├─ T2 sdk/orders.ts ───────┤
  (start) ─┼─ T3 WeekendDesk.sol ─────┼─→ T5 DeskFixture.sol ─┬─→ T6 DeskBuy.t.sol
           ├─ T4 Ship scripts ────────┤                       ├─→ T7 DeskGuards.t.sol
           └──────────────────────────┘                       ├─→ T8 DeskCaps.t.sol
                                                              ├─→ T9 DeskOrdering.t.sol
                                                              └─→ T10 DeskSell.t.sol
                                                                      │
                                                              T11 DeployDesk.s.sol
```

| Wave | Tasks | Why they are safe together |
|---|---|---|
| **1** | **T1, T2, T3, T4** | Four different files, zero shared symbols. T1/T2 depend only on the frozen `WeekendPricer` + `MakerTraitsLib` signatures below. |
| **2** | **T5** | Sole serialization point. Owns the shared fixture every integration test inherits. |
| **3** | **T6, T7, T8, T9, T10** | **Five agents, five separate test files**, all inheriting T5's fixture read-only. This is where the parallelism pays. |
| **4** | **T11** | Needs T3's constructor to be final. |

Deliberately split by **file**, not by feature: `WeekendDesk.sol` has one owner (T3) and the integration suite is five files instead of one so wave 3 fans out. Nothing in waves 1 or 3 shares a file with anything else in its wave.

---

### Task 1: Order-building library (Solidity) `[PARALLEL-SAFE]`

**Files:**
- Create: `contracts/test/helpers/OrderLib.sol`
- Test: `contracts/test/OrderLib.t.sol`

**Interfaces:**
- Consumes: `MakerTraitsLib.build(Args)` from `swapvm/libs/MakerTraits.sol` (returns a full `ISwapVM.Order`); `Deadline.build(uint40)`, `Salt.build(bytes32)` from `swapvm/instructions/Controls.sol`; `RequireMinRate.build(uint64,uint64)` from `swapvm/instructions/MinRate.sol`; `Extruction.build(address,bytes)` from `swapvm/instructions/Extruction.sol`.
- Produces:
  - `library OrderLib`
  - `struct Params { address desk; address pricer; address quote; address optionToken; uint256 seriesId; uint256 volWad; uint8 side; uint40 deadline; bytes32 salt; uint64 minRateA; uint64 minRateB; }`
  - `program(Params memory p) internal pure returns (bytes memory)` — `Deadline + Salt + RequireMinRate + Extruction(pricer, abi.encode(seriesId, volWad, side))`, in that order
  - `order(Params memory p) internal pure returns (ISwapVM.Order memory)` — `MakerTraitsLib.build` with `useAquaInsteadOfSignature: true`, `hasPreTransferOutHook: true`, `hasPostTransferInHook: true`, the other two false, all four hook targets `address(0)` (defaults to maker), hook data `""`, `receiver: address(0)`, `tokenA`/`tokenB` **sorted ascending** (`build` requires `tokenA < tokenB`)

- [ ] **Step 1: Write the failing test**

```solidity
function test_program_ordersInstructionsDeadlineSaltMinRateExtruction() public pure {
    // RequireMinRate wraps the remainder via ctx.runLoop(), so it MUST precede Extruction.
    bytes memory p = OrderLib.program(_goldenParams());
    assertEq(uint8(p[0]), 0x20, "Deadline first");   // opcode 0x20
    // Salt, RequireMinRate, Extruction follow; assert Extruction's 0x04 is the last header.
    assertEq(_lastOpcode(p), 0x04, "Extruction last");
    // Same golden vector Task 2 pins, so the two encoders are checked independently
    // against one spec rather than against each other.
    assertEq(p, GOLDEN_PROGRAM);
}

function test_order_setsAquaFlagAndExactlyTwoHookBits() public view {
    ISwapVM.Order memory o = OrderLib.order(_params());
    uint256 t = MakerTraits.unwrap(o.traits);
    assertTrue(t & (1 << 254) != 0, "aqua flag");
    assertTrue(t & (1 << 250) != 0, "preTransferOut");
    assertTrue(t & (1 << 251) != 0, "postTransferIn");
    assertTrue(t & (1 << 252) == 0, "preTransferIn must stay off");
    assertTrue(t & (1 << 249) == 0, "postTransferOut must stay off");
}

function test_order_sortsTokensAscending() public view {
    // MakerTraitsLib.build reverts unless tokenA < tokenB; the caller must not have to care.
    ISwapVM.Order memory a = OrderLib.order(_paramsWithQuoteBelowOption());
    ISwapVM.Order memory b = OrderLib.order(_paramsWithQuoteAboveOption());
    assertTrue(MakerTraits.unwrap(a.traits) != 0 && MakerTraits.unwrap(b.traits) != 0);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path test/OrderLib.t.sol`
Expected: FAIL — `OrderLib` does not exist.

- [ ] **Step 3: Implement `OrderLib`**

Concatenate the four instruction `build(...)` outputs in order. Sort `tokenA`/`tokenB` inside `order(...)` so callers pass quote/option in any order.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit** — `git commit -m "feat: SwapVM order builder for option quotes"`

---

### Task 2: Order-building SDK (TypeScript) `[PARALLEL-SAFE]`

**Files:**
- Create: `sdk/orders.ts`, `sdk/package.json`
- Test: `sdk/orders.test.ts`

> The frontend is off-limits. This lands in `sdk/`, never `app/src/lib/`.

**Interfaces:**
- Produces:
  - `export const OP = { deadline: 0x20, salt: 0x02, requireMinRate: 0xb0, extruction: 0x04 }`
  - `export const SIDE = { ASK: 0, BID: 1 }`
  - `export function program(p: OrderParams): string`
  - `export function order(p: OrderParams): { maker: string; traits: bigint; data: string }`
  - `export interface OrderParams { desk, pricer, quote, optionToken, seriesId, volWad, side, deadline, salt, minRateA, minRateB }`
  - `export const USE_AQUA = 1n << 254n`, `PRE_TRANSFER_OUT_HOOK = 1n << 250n`, `POST_TRANSFER_IN_HOOK = 1n << 251n`

- [ ] **Step 1: Write the failing test**

Assert against the **golden vector** below — the same constant Task 1 asserts against, so the two
tasks never have to run in sequence. Both encoders are independently checked against one spec,
and byte-equality between them follows.

```
GOLDEN_PARAMS = {
  pricer:      0x1111111111111111111111111111111111111111
  seriesId:    1
  volWad:      600000000000000000        // 0.6e18
  side:        0                         // ASK
  deadline:    0x0000000064          // uint40
  salt:        0x00..01                  // bytes32(uint256(1))
  minRateA:    1, minRateB: 1
}
GOLDEN_PROGRAM = "0x2005" + "0000000064"
               + "0220"  + <salt 32 bytes>
               + "b010"  + <rateA 8 bytes><rateB 8 bytes>
               + "0474"  + <pricer 20 bytes> + <abi.encode(seriesId, volWad, side) 96 bytes>
```

Each instruction is `uint8 opcode || uint8 argsLength || args`. Derive the exact hex once, pin it
in both test files, and assert `order().traits` has exactly bits 254, 251 and 250 set.

> If the two encoders disagree, the golden vector says which one is wrong — that is the point of
> pinning it rather than cross-comparing two implementations that could both drift.

- [ ] **Step 2: Run to verify it fails** — `cd sdk && npm test`

- [ ] **Step 3: Implement** using `ethers.concat`; instruction encoding is `uint8 opcode || uint8 argsLength || args`.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit** — `git commit -m "feat: TypeScript order builder for option quotes"`

---

### Task 3: `WeekendDesk` `[PARALLEL-SAFE]`

**Files:**
- Create: `contracts/src/desk/WeekendDesk.sol`
- Create: `contracts/src/interfaces/IMakerHooks.sol` (mirror of `swapvm/interfaces/IMakerHooks.sol`, so the desk compiles under the default profile too)
- Test: `contracts/test/Desk.t.sol` (unit-level only; integration lives in waves 2–3)

**Interfaces:**
- Consumes (read-only, core-owned): `WeekendOptions.getSeries(uint256) → Series memory`, `collateralFor(uint256,uint256) → (address,uint256)`, `buyOption(Strategy,uint256,uint256,uint256,address,bytes) → uint256`, `close(uint256,uint256)`, `written(uint256,address) → uint256`, `hashStrategy(Strategy) → bytes32`; `IGapOptionCallback.gapOptionCallback(address,address,uint256,bytes)`.
- Produces:
  - `contract WeekendDesk is IMakerHooks, IGapOptionCallback, Ownable2Step`
  - `constructor(WeekendOptions app_, IAqua aqua_, address router_, address quote_)`
  - `function setActive(bool) external onlyOwner`
  - `function listSeries(uint256[] calldata ids, uint256[] calldata maxShort_) external onlyOwner` — also fills `seriesOfToken[token] = id + 1`
  - `function setOwnStrategy(WeekendOptions.Strategy calldata s) external onlyOwner` — the desk's own core-protocol collateral strategy (see **Blocked on core**)
  - `function approveAqua(address token, uint256 amount) external onlyOwner` — **required**; without it every ask fill reverts at `AQUA.pull`
  - `mapping(address => uint256) public seriesOfToken`, `mapping(uint256 => uint256) public maxShort`, `bool public active`
  - `preTransferOut(address,address,address,address,uint256,uint256,bytes32,bytes,bytes) external`
  - `postTransferIn(address,address,address,address,uint256,uint256,uint256,bytes32,bytes,bytes) external`
  - errors `NotRouter()`, `NotMaker()`, `Inactive()`, `UnknownToken(address)`, `ShortLimit(uint256,uint256,uint256)`, `BadPair()`
  - events `Sold(uint256 indexed seriesId, address indexed taker, uint256 amountOut, uint256 amountIn, uint256 minted)`, `BoughtBack(uint256 indexed seriesId, address indexed taker, uint256 amountIn, uint256 amountOut, uint256 closed)`

- [ ] **Step 1: Write the failing tests**

```solidity
function test_hooksRejectAnyCallerButTheRouter() public {
    vm.expectRevert(WeekendDesk.NotRouter.selector);
    desk.preTransferOut(address(desk), TAKER, quote, optionToken, 1, 1, bytes32(0), "", "");
}

function test_hooksRejectAForeignMaker() public {
    vm.prank(router);
    vm.expectRevert(WeekendDesk.NotMaker.selector);
    desk.preTransferOut(address(0xDEAD), TAKER, quote, optionToken, 1, 1, bytes32(0), "", "");
}

function test_bothHooksRefuseWhenInactive() public {
    // Review Focus #4: the reference desk checks `active` only in preTransferOut, which is safe
    // there only because ERC-1271 rejects first. On the no-signature Aqua path that gap is live.
    desk.setActive(false);
    vm.startPrank(router);
    vm.expectRevert(WeekendDesk.Inactive.selector);
    desk.preTransferOut(address(desk), TAKER, quote, optionToken, 1, 1, bytes32(0), "", "");
    vm.expectRevert(WeekendDesk.Inactive.selector);
    desk.postTransferIn(address(desk), TAKER, quote, optionToken, 1, 1, 0, bytes32(0), "", "");
    vm.stopPrank();
}

function test_rejectsATokenPairThatIsNotQuoteAndAListedOption() public {
    vm.prank(router);
    vm.expectRevert(WeekendDesk.BadPair.selector);
    desk.preTransferOut(address(desk), TAKER, quote, address(stray), 1, 1, bytes32(0), "", "");
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `~/.foundry/bin/forge test --match-path test/Desk.t.sol`

- [ ] **Step 3: Implement `WeekendDesk`**

`modifier fromRouter(address maker)` — `msg.sender == router` and `maker == address(this)`.

`preTransferOut`: require `active`; resolve the series from the token pair (`seriesOfToken[opt] - 1`, `0` means unlisted). Branch on `tokenOut`:
- `tokenOut != quote` (ask): `held = IERC20(tokenOut).balanceOf(address(this))`; if `held < amountOut`, write the shortfall via `buyOption(ownStrategy, id, amountOut - held, type(uint256).max, address(this), abi.encode(address(this), ownStrategyHash))`, then require `written(id, address(this)) <= maxShort[id]` (cumulative, checked after).
- `tokenOut == quote` (bid): no-op beyond the guards — the quote is already in the wallet or the pull reverts.

`postTransferIn`: require `active`; `tokenIn == quote` → nothing to do, the premium is already in the wallet and backs the next write. Otherwise `close(id, min(amountIn, written(id, address(this))))`, guarded for zero.

`gapOptionCallback`: the self-write path — approve `AQUA` and `push` the premium back to itself.

**Do not** assume the premium has arrived (Review Focus #3).

- [ ] **Step 4: Run to verify they pass**

- [ ] **Step 5: Commit** — `git commit -m "feat: WeekendDesk maker hooks for SwapVM option fills"`

---

### Task 4: Ship scripts `[PARALLEL-SAFE]`

**Files:**
- Create: `contracts/script/ShipAsk.s.sol`, `contracts/script/ShipBid.s.sol`

**Interfaces:**
- Produces: `ShipAsk.run()` and `ShipBid.run()`, each returning `bytes32 strategyHash`.

- [ ] **Step 1: Implement `ShipAsk`**

Ships `[optionToken, quote]` at `[seriesCap, 0]`. Per spec §12.4 the shipped amount is a **permanent** cumulative cap — `Aqua.ship` enforces `StrategiesMustBeImmutable`, so re-offering after exhaustion needs a new `salt`. Both legs must be present or `AQUA.safeBalances` reverts.

Asserts `IAqua.ship(...)` returns a hash equal to `router.hash(order)` for the order `OrderLib.order(...)` produces with the same parameters — the two are the same value by design, and this is the cheapest place to catch a drift.

- [ ] **Step 2: Implement `ShipBid`**

Ships `[quote, optionToken]` at `[budget, 0]`, side `BID`, with a lower `volWad` than the ask.

- [ ] **Step 3: Verify both compile**

Run: `FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge build`

- [ ] **Step 4: Commit** — `git commit -m "feat: ask and bid ship scripts"`

---

### Task 5: Shared integration fixture `[SERIAL: depends on 1, 3, 4]`

**Files:**
- Create: `contracts/test/helpers/DeskFixture.sol`

> **This is the only serialization point.** Every wave-3 task inherits it read-only. Get the surface right and five agents proceed without touching one another.

**Interfaces:**
- Produces: `abstract contract DeskFixture is Test` exposing, after `setUp()`:
  - `AquaSwapVMRouter router; Aqua aqua; WeekendOptions app; WeekendDesk desk; WeekendPricer pricer; MockERC20 quote; MockERC20 underlying; MockOracle oracle;`
  - `uint256 callId; address optionToken; uint64 expiry; address TAKER;`
  - `uint256 constant VOL_ASK = 0.6e18; uint256 constant VOL_BID = 0.4e18; uint256 constant SERIES_CAP = 100e18;`
  - `function shipAsk(uint256 cap) internal returns (bytes32 hash, ISwapVM.Order memory o)`
  - `function shipBid(uint256 budget) internal returns (bytes32 hash, ISwapVM.Order memory o)`
  - `function takerTraits(bool exactIn, bool takerFirst, uint256 threshold) internal pure returns (bytes memory)`
  - `function fill(ISwapVM.Order memory o, uint256 amount, bytes memory tt) internal returns (uint256 amountIn, uint256 amountOut)`

- [ ] **Step 1: Implement the fixture**

Deploys the **real** `AquaSwapVMRouter` and **real** `Aqua` (§13). Mocks only the oracle and the v4 `StateView` lens. The desk is funded, listed via `listSeries`, and `approveAqua`'d for both tokens (Review Focus #5). Orders are built with `OrderLib` / `MakerTraitsLib.build`, never `TraitsHelper`.

- [ ] **Step 2: Prove the fixture itself works**

Add one smoke test asserting `aqua.ship(...)` returns exactly `router.hash(order)`.

Run: `FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path test/helpers/DeskFixture.sol`

- [ ] **Step 3: Commit** — `git commit -m "test: real-contract fixture for SwapVM desk integration"`

---

### Task 6: Buy path — the first hooks + Aqua fill ever `[PARALLEL-SAFE: after 5]`

**Files:**
- Create: `contracts/test/integration/DeskBuy.t.sol`

> §12.8: no test anywhere in the fork exercises maker hooks together with an Aqua order. **This is that test.** If it does not pass, nothing else in this plan is deployable.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_exactIn_takerPaysQuoteAndReceivesOptionsMintedJustInTime() public {
    (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
    uint256 before = app.written(callId, address(desk));
    (uint256 amountIn, uint256 amountOut) = fill(o, 100e6, takerTraits(true, false, 0));
    assertEq(amountIn, 100e6);
    assertEq(IERC20(optionToken).balanceOf(TAKER), amountOut);
    assertEq(app.written(callId, address(desk)), before + amountOut, "desk is the writer of record");
}

function test_exactOut_takerNamesTheOptionCountAndPaysTheCeiling() public { /* … */ }

function test_premiumLandsAtTheDeskAndBacksTheNextWrite() public { /* … */ }

function test_inventoryIsSpentBeforeMinting() public {
    // A desk holding options it bought back must sell those first, not mint fresh ones.
}

function test_partialFillsAccumulateAgainstOneOrderHash() public { /* … */ }
```

- [ ] **Step 2: Run to verify they fail**

Run: `FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path test/integration/DeskBuy.t.sol`

- [ ] **Step 3: Fix whatever the real router rejects**

Expected friction: hook flag bits, slice indexes, the desk's Aqua approval, and `tokenA < tokenB` sorting. Fix in `OrderLib`/`WeekendDesk`, not by weakening the test.

- [ ] **Step 4: Run to verify they pass**

- [ ] **Step 5: Commit** — `git commit -m "test: first maker-hooks-plus-Aqua fill against the real router"`

---

### Task 7: Guards `[PARALLEL-SAFE: after 5]`

**Files:**
- Create: `contracts/test/integration/DeskGuards.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
function test_anAskOrderCannotBeFilledInReverse() public {
    // The security property, end to end: without the gate, the quote accruing in the maker's
    // Aqua counter is a standing allowance to sell options back at the maker's own ask price.
    (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
    vm.expectRevert();
    fill(o, 1e18, takerTraits(true, false, 0)); // option → quote against an ASK order
}

function test_shortCapTripsOnTheFillThatCrossesIt() public { /* ShortLimit */ }
function test_inactiveDeskRefusesBothDirections() public { /* Review Focus #4 */ }
function test_expiredSeriesCannotBeFilled() public { /* SeriesExpired */ }
function test_anUnlistedOptionTokenIsRejected() public { /* UnknownToken / BadPair */ }
function test_repointingThePricerInvalidatesTheOrder() public {
    // A different Extruction target changes order.data, changes the hash, and the Aqua ledger
    // key no longer exists — safeBalances reverts before a single opcode runs.
}
```

- [ ] **Step 2–4: Run, implement, run** — `FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path test/integration/DeskGuards.t.sol`

- [ ] **Step 5: Commit** — `git commit -m "test: direction gate, short cap and kill switch under the real router"`

---

### Task 8: Caps and fees `[PARALLEL-SAFE: after 5]`

**Files:**
- Create: `contracts/test/integration/DeskCaps.t.sol`

> Owns Review Focus #1 and #2 — the Aqua ledger is the *only* hard bound and it is cumulative.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_manySmallFillsCannotExceedTheShippedCap() public {
    // Review Focus #1. Per-fill checks would pass; the ledger is what actually stops this.
    (, ISwapVM.Order memory o) = shipAsk(10e18);
    for (uint256 i; i < 10; ++i) fill(o, 1e18, takerTraits(false, false, 0));
    vm.expectRevert(); // 11th underflows Aqua's uint248
    fill(o, 1e18, takerTraits(false, false, 0));
}

function test_theLedgerMustCoverAmountOutPlusTheProtocolFee() public {
    // Review Focus #2: the fee is a SECOND, separate AQUA.pull. A strategy shipped at exactly
    // the cap underflows on the fee, not on the principal.
}

function test_anExhaustedStrategyCannotBeRestockedWithoutANewSalt() public {
    // Aqua.ship enforces StrategiesMustBeImmutable.
    vm.expectRevert();
    shipAsk(SERIES_CAP); // same salt, same hash
}
```

- [ ] **Step 2–4: Run, implement, run**

- [ ] **Step 5: Commit** — `git commit -m "test: cumulative Aqua ledger cap, fee accounting and ship immutability"`

---

### Task 9: Transfer ordering `[PARALLEL-SAFE: after 5]`

**Files:**
- Create: `contracts/test/integration/DeskOrdering.t.sol`

> Owns Review Focus #3. `IS_FIRST_TRANSFER_FROM_TAKER` (`0x0020`) is a **taker** trait; the maker cannot force it, so the hooks must be correct both ways.

- [ ] **Step 1: Write the failing tests**

```solidity
function test_buyWorksWithTheTakerPayingFirst() public {
    (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
    fill(o, 100e6, takerTraits(true, true, 0)); // takerFirst = true
}

function test_buyWorksWithTheDeskShippingFirst() public {
    (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
    fill(o, 100e6, takerTraits(true, false, 0)); // the default, desk ships before it is paid
}

function test_bothOrderingsProduceIdenticalBalances() public {
    // The one that matters: no hook may depend on the premium having already landed.
}
```

- [ ] **Step 2–4: Run, implement, run**

- [ ] **Step 5: Commit** — `git commit -m "test: hooks are correct under both transfer orderings"`

---

### Task 10: Sell-back path `[PARALLEL-SAFE: after 5]`

**Files:**
- Create: `contracts/test/integration/DeskSell.t.sol`

- [ ] **Step 1: Write the failing tests**

```solidity
function test_holderSellsOptionsBackAndReceivesQuote() public { /* … */ }

function test_sellBackClosesTheDeskSWrittenPositionAndUnlocksCollateral() public {
    // close(id, min(amountIn, written)) — the collateral comes back before expiry.
}

function test_sellBackBeyondWhatTheDeskWroteIsHeldAsInventoryNotClosed() public {
    // close() can only burn against the caller's own `written`; the excess stays as inventory
    // and is spent by the next ask fill.
}

function test_aBidOrderCannotBeFilledInReverse() public { /* … */ }

function test_bidPaysLessThanTheAskCharges() public {
    // The spread is the vol gap and nothing else enforces one.
}
```

- [ ] **Step 2–4: Run, implement, run**

- [ ] **Step 5: Commit** — `git commit -m "test: sell-back closes the desk position and unlocks collateral"`

---

### Task 11: Deploy script `[SERIAL: depends on 3]`

**Files:**
- Create: `contracts/script/DeployDesk.s.sol`

- [ ] **Step 1: Implement**

Deploys `WeekendPricer` then `WeekendDesk`, calls `listSeries` and `approveAqua` for both tokens, and writes `weekendPricer` / `weekendDesk` into `deployments/base-sepolia.json`. Reads the existing router address from that file; **does not deploy a router**.

- [ ] **Step 2: Dry-run against a fork**

Run: `FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge script script/DeployDesk.s.sol --fork-url $BASE_SEPOLIA_RPC_URL -vvv`

- [ ] **Step 3: Commit** — `git commit -m "feat: pricer and desk deploy script"`

---

## Pre-deploy gate

Before anything is broadcast, per §12.9: **diff `swap-vm-fork/contracts/libs/OpcodeList.sol` against upstream `1inch/swap-vm`.** If upstream has `LimitSwap` at `0x52` rather than `WeekendGap`, every previously-shipped strategy's bytes decode differently. `OpcodeEnumCheck.t.sol` pins neither `0x52` nor `0x53`, so the suite will not catch it.
