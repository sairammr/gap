# Gap — Overnight-Gap Options on Aqua: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy (Base Sepolia live) an Aqua app that sells capped overnight-gap options on a mock tokenized NVDA (NVDAx) priced in USDC, with Black-Scholes pricing off a Uniswap v4 spot, JIT-liquidity collateral, permissionless settlement, a full React frontend (lightweight-charts), and a custom SwapVM `WeekendGap` opcode for the scoring bonus.

**Architecture:** A `GapOptionsApp` extends the unmodified `@1inch/aqua` `AquaApp`. `buyOption` runs inside `nonReentrantStrategy`: price the premium from the v4 spot (`GapPricing` + `UniV4Spot`), `AQUA.pull` the capped collateral from the maker's wallet to the app as backing, mint an ERC-1155 long to the taker, and in the taker callback collect the USDC premium verified by `_safeCheckAquaPush`. A later permissionless `settle` samples the v4 spot at expiry, pays the holder from the maker's JIT-unwound collateral, and burns the position. Aqua + SwapVM are not on Base Sepolia, so we deploy them ourselves from official source.

**Tech Stack:** Solidity 0.8.30, Foundry (forge/anvil at `~/.foundry/bin`), `@1inch/aqua@1.0.2-rc.2` (npm), `@uniswap/v4-core@1.0.2` / `v4-periphery@1.0.3`, `solady`, `@openzeppelin/contracts@5.6.1`; `1inch/swap-vm` from git (unpublished); frontend Vite + React + TS + wagmi + viem + `lightweight-charts@^5.2.1`.

**Spec:** `docs/superpowers/specs/2026-11-06-gap-tradefi-platform-design.md` (and its source `docs/aqua-app-build-spec.md`, verified by `docs/SPEC-VERIFICATION.md`).

## Global Constraints

- Solidity `0.8.30`; `foundry.toml` `[profile.default]` evm `cancun`, optimizer runs `1000`. App contracts compile here.
- Import `@1inch/aqua` **unmodified**. Never vendor or edit `Aqua.sol` / `AquaApp.sol`.
- `strategyHash = keccak256(strategy)` over the **raw `bytes`** passed to `ship` (verified: `Aqua.ship` line 61). The `strategy` bytes MUST encode the app address; `GapOptionsApp` reverts `InvalidAquaStrategy` if `decoded.app != address(this)`.
- Aqua's `pull` gate is `_balances[maker][msg.sender]` — the app *is* `msg.sender`. Collateral lives in the **maker's wallet**; maker must `approve(AQUA, ...)`. Ordering: **unwind → pull → (mint/callback) → check**, never pull→unwind.
- `pull` has no solvency require (uint248 underflow on over-pull). App adds a legible `require` pre-check before every `pull`.
- Settlement price has **no native v4 TWAP** — sample `StateView.getSlot0` N times and average. Document as a testnet-demo limitation.
- Premium, prices, vol are WAD (1e18). USDC is 6dp; NVDAx is 18dp. All decimal conversions explicit.
- Aqua address (all chains) `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a`; **not deployed on Base Sepolia** — we deploy it. Codehash match to mainnet is best-effort only; do not revert on mismatch.
- Base Sepolia (84532): PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`, PositionManager `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80`, StateView `0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4`, Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`, WETH `0x4200000000000000000000000000000000000006`, Circle USDC `0x036CbD53842c5426634e7929541eC2318f3dCF7e`.
- SwapVM opcode slot = `_52` (Swap-curves bank), not `_05`.
- Incremental commits — one per task minimum.
- `forge` is invoked as `~/.foundry/bin/forge` (not on PATH).

## Review Focus

- **Over-pull of collateral when maker wallet/allowance is short** — `buyOption`/`settle` must revert with a legible app error, not a raw arithmetic underflow. Test owns: Task 4 + Task 7.
- **Premium quoted stale/zero when the v4 pool is uninitialized** — `UniV4Spot.spotWad` reverts `PoolNotInitialized`; `buyOption` must surface that, not sell a zero-premium option. Test owns: Task 5.
- **Double-settle / settle-before-expiry** — `settle` must revert before `expiry` and be idempotent after (burned position can't pay twice). Test owns: Task 7.
- **Strategy bound to the wrong app** — a `strategy` whose encoded `app` isn't this contract must revert `InvalidAquaStrategy`, or a maker's balance under another app could be referenced. Test owns: Task 3.
- **Decimal mismatch USDC(6) vs premium WAD(18)** — premium owed in USDC must be scaled from WAD to 6dp; an unscaled transfer is 10^12× wrong. Test owns: Task 5.

---

## Task 1: Toolchain, deps, existing libs compile + unit tests

**Files:**
- Modify: `contracts/foundry.toml` (confirm remappings resolve)
- Test: `contracts/test/GapPricing.t.sol`, `contracts/test/UniV4Spot.t.sol`

**Interfaces:**
- Consumes: existing `src/lib/GapPricing.sol` (`GapPricing.premium(kind,spot,strike,cap,secondsToExpiry,volWad)→uint256`, `.call`, `.put`, `.normalCdf`), `src/lib/UniV4Spot.sol` (`spotWad(IStateView,bytes32,uint8,uint8,bool)→uint256`, `fromSqrtPriceX96(...)`), `src/interfaces/IStateView.sol`.
- Produces: a compiling Foundry project with deps installed (`node_modules/@1inch/aqua`, uniswap, solady, OZ already present).

- [ ] **Step 1: Verify deps + forge present.** Run `~/.foundry/bin/forge --version` and `ls contracts/node_modules/@1inch/aqua/contracts/Aqua.sol`. Expected: forge 1.8.x; file exists. (npm install already done.)

- [ ] **Step 2: Write `test/UniV4Spot.t.sol`** — pure-function tests of `fromSqrtPriceX96`. Assert a known `sqrtPriceX96` for a 1:1 pool (both 18dp, underlyingIsCurrency0=true) yields `1e18`; assert the inverted branch (underlyingIsCurrency0=false) with 18/6 decimals yields the expected WAD; assert `sqrtPriceX96 == 0` reverts `PoolNotInitialized`.

- [ ] **Step 3: Write `test/GapPricing.t.sol`** — assert `premium(CALL, spot=100e18, strike=100e18, cap=5e18, 1 days, 0.6e18)` is in a sane band `(0, cap]`; assert `sigmaRootT==0` (zero vol) returns intrinsic; assert put-call via `put()`; assert `normalCdf(0)==0.5e18 ± 1e14`.

- [ ] **Step 4: Run both tests.** Run `cd contracts && ~/.foundry/bin/forge test --match-path 'test/GapPricing.t.sol' --match-path 'test/UniV4Spot.t.sol' -vv`. Expected: PASS. (If a remapping is missing, fix `foundry.toml` remappings, not the libs.)

- [ ] **Step 5: Commit** — `git add contracts/test/GapPricing.t.sol contracts/test/UniV4Spot.t.sol contracts/foundry.toml && git commit -m "test: unit-test GapPricing and UniV4Spot libs"`

---

## Task 2: Mock tokens

**Files:**
- Create: `contracts/src/mocks/MockERC20.sol`
- Test: `contracts/test/MockERC20.t.sol`

**Interfaces:**
- Produces: `contract MockERC20 is ERC20` with constructor `(string name, string symbol, uint8 decimals_)` and `function mint(address to, uint256 amount) external`; `decimals()` returns the ctor value. Used to instantiate NVDAx (`"NVIDIA xStock","NVDAx",18`) and test USDC (`"USD Coin","USDC",6`).

- [ ] **Step 1: Write `test/MockERC20.t.sol`** — deploy `MockERC20("NVIDIA xStock","NVDAx",18)`; assert `decimals()==18`, `symbol()=="NVDAx"`; `mint(alice,1e18)` then `balanceOf(alice)==1e18`. Deploy a 6dp one; assert `decimals()==6`.

- [ ] **Step 2: Run test.** `~/.foundry/bin/forge test --match-path 'test/MockERC20.t.sol' -vv`. Expected: FAIL (MockERC20 not defined).

- [ ] **Step 3: Implement `src/mocks/MockERC20.sol`** extending OpenZeppelin `ERC20` with an overridable `decimals()` backed by an immutable, and a public `mint`.

- [ ] **Step 4: Run test.** Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: add MockERC20 for NVDAx and test USDC"`

---

## Task 3: `GapOptionsApp` skeleton — strategy, hashStrategy, app binding

**Files:**
- Create: `contracts/src/GapOptionsApp.sol`, `contracts/src/interfaces/IGapOptionCallback.sol`
- Test: `contracts/test/GapStrategy.t.sol`

**Interfaces:**
- Consumes: `@1inch/aqua` `AquaApp` (`AQUA`, `nonReentrantStrategy(maker,hash)`, `_safeCheckAquaPush(maker,hash,token,bal)`), `IAqua` (`ship/pull/push/rawBalances`). `IStateView`.
- Produces:
  - `struct Strategy { address app; address maker; address underlying; address quote; bytes32 poolId; bool underlyingIsCurrency0; uint8 underlyingDecimals; uint8 quoteDecimals; uint256 volWad; bytes32 salt; }`
  - `function hashStrategy(Strategy calldata s) public pure returns (bytes32)` == `keccak256(abi.encode(s))` — the exact bytes a maker passes to `AQUA.ship`.
  - `error InvalidAquaStrategy(...)` reused from AquaApp semantics; `error NotThisApp()`.
  - constructor `(IAqua aqua, IStateView stateView)`.
  - `IGapOptionCallback.gapOptionCallback(address taker, address quoteToken, uint256 premiumOwed, bytes calldata takerData)`.

- [ ] **Step 1: Write `test/GapStrategy.t.sol`** — build a `Strategy` with `app=address(gapApp)`; assert `hashStrategy(s) == keccak256(abi.encode(s))`; assert a helper `_validateStrategy(s)` passes when `s.app==address(gapApp)` and reverts `NotThisApp` when `s.app` is a random address.

- [ ] **Step 2: Run test.** Expected: FAIL (GapOptionsApp not defined).

- [ ] **Step 3: Implement the skeleton** — `contract GapOptionsApp is AquaApp, ERC1155` with the `Strategy` struct, `hashStrategy`, an internal `_validateStrategy(Strategy calldata)` that reverts `NotThisApp` unless `s.app == address(this)`, the constructor, and the `IGapOptionCallback` interface file. No `buyOption` body yet.

- [ ] **Step 4: Run test.** Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: GapOptionsApp skeleton with strategy hashing and app binding"`

---

## Task 4: `buyOption` with a FIXED premium — the end-to-end Aqua slice

**Files:**
- Modify: `contracts/src/GapOptionsApp.sol`
- Create: `contracts/test/BuyOptionFixed.t.sol`, a test taker `contracts/test/helpers/TakerStub.sol`
- Test deploys the real `@1inch/aqua` `Aqua` locally.

**Interfaces:**
- Consumes: Task 3 types; `Aqua` deployed in-test; `MockERC20` (Task 2).
- Produces:
  - `function buyOption(Strategy calldata s, uint8 kind, uint256 strike, uint256 cap, uint64 expiry, uint256 size, uint256 maxPremium, address to, bytes calldata takerData) external nonReentrantStrategy(s.maker, hashStrategy(s)) returns (uint256 positionId)`.
  - In this task premium is a fixed constant (e.g. `cap/10` scaled to quote dp) — NO pricing yet.
  - Emits an app `OptionBought(positionId, to, kind, strike, cap, expiry, size, premium)`.
  - `positionId = uint256(keccak256(abi.encode(hashStrategy(s), kind, strike, cap, expiry, to, optionNonce++)))`; ERC-1155 `_mint(to, positionId, size, "")`.
  - Position record `mapping(uint256 => Position)` with `Position{ bytes32 strategyHash; address maker; address underlying; address quote; uint8 kind; uint256 strike; uint256 cap; uint64 expiry; uint256 size; bool settled; }`.

- [ ] **Step 1: Write `TakerStub.sol`** — implements `IGapOptionCallback`; in `gapOptionCallback` it `IERC20(quoteToken).approve` + calls `AQUA.push(maker, app, strategyHash, quoteToken, premiumOwed)` using stored handles. (Stub mimics a real taker funding the premium.)

- [ ] **Step 2: Write `test/BuyOptionFixed.t.sol`** — deploy `Aqua`, `GapOptionsApp`, NVDAx(18), USDC(6); maker mints NVDAx collateral, `approve(aqua)`, `ship(app, abi.encode(strategy), [NVDAx], [collateral])`; taker funded with USDC. Call `buyOption(...)`. Assert: `Pulled` event (NVDAx, backing), ERC-1155 `balanceOf(to,positionId)==size`, `Pushed` event (USDC premium), taker USDC decreased by the fixed premium, and the maker's Aqua USDC balance increased. Assert over-cap/short-allowance path reverts with a legible error (Review Focus).

- [ ] **Step 3: Run test.** Expected: FAIL.

- [ ] **Step 4: Implement `buyOption`** — validate strategy; compute `collateral = cap * size / 1e18` (WAD) → NVDAx dp; `require` maker Aqua balance ≥ collateral (legible pre-check); `AQUA.pull(s.maker, hash, s.underlying, collateral, address(this))`; mint ERC-1155; set a transient `premiumOwed` (fixed); call `IGapOptionCallback(msg.sender).gapOptionCallback(to, s.quote, premiumOwed, takerData)`; `_safeCheckAquaPush(s.maker, hash, s.quote, prevQuoteBal + premiumOwed)`; `require(premium <= maxPremium)`.

- [ ] **Step 5: Run test.** Expected: PASS — real `Shipped/Pulled/Pushed` + ERC-1155 mint on a local Aqua. **This is the bounty's on-chain-transfer slice.**

- [ ] **Step 6: Commit** — `git commit -m "feat: buyOption end-to-end with fixed premium (Aqua pull/push + ERC-1155 mint)"`

---

## Task 5: Black-Scholes premium off the v4 spot

**Files:**
- Modify: `contracts/src/GapOptionsApp.sol`
- Create: `contracts/test/BuyOptionPriced.t.sol`, `contracts/test/helpers/MockStateView.sol`

**Interfaces:**
- Consumes: `GapPricing.premium`, `UniV4Spot.spotWad`, `IStateView` (Task 1 libs); Task 4 `buyOption`.
- Produces: `function quotePremium(Strategy calldata s, uint8 kind, uint256 strike, uint256 cap, uint64 expiry, uint256 size) public view returns (uint256 premiumQuoteUnits)` — spot from `UniV4Spot.spotWad(STATE_VIEW, s.poolId, s.underlyingDecimals, s.quoteDecimals, s.underlyingIsCurrency0)`, WAD premium from `GapPricing.premium(kind, spot, strike, cap, expiry-block.timestamp, s.volWad)`, `* size / 1e18`, then WAD→`quoteDecimals`. `buyOption` uses this instead of the fixed constant.

- [ ] **Step 1: Write `MockStateView.sol`** — implements `IStateView.getSlot0` returning a settable `sqrtPriceX96` (so tests pin spot without a real pool) and `getLiquidity`.

- [ ] **Step 2: Write `test/BuyOptionPriced.t.sol`** — set MockStateView to a sqrtPriceX96 ≈ spot 100 USDC/NVDAx; assert `quotePremium` for an ATM 1-day call is within a BS band and denominated in 6dp USDC (Review Focus: decimal scaling). Assert `getSlot0` returning `sqrtPriceX96==0` makes `buyOption` revert `PoolNotInitialized` (Review Focus). Re-run the Task-4 flow with the priced premium; assert push matches `quotePremium`.

- [ ] **Step 3: Run test.** Expected: FAIL.

- [ ] **Step 4: Implement `quotePremium`** and swap it into `buyOption`; store `STATE_VIEW` immutable from ctor. Scale WAD→quoteDecimals via `mulDiv(premiumWad, 10**quoteDecimals, 1e18)`.

- [ ] **Step 5: Run test.** Expected: PASS.

- [ ] **Step 6: Commit** — `git commit -m "feat: price option premium via Black-Scholes off v4 spot"`

---

## Task 6: Real Uniswap v4 NVDAx/USDC pool on a Base fork

**Files:**
- Create: `contracts/test/PoolFork.t.sol`, `contracts/script/lib/PoolSetup.sol` (shared pool create/seed helper)

**Interfaces:**
- Produces: `library PoolSetup` with `initPool(IPoolManager, Currency c0, Currency c1, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96) → PoolKey` and `seed(IPositionManager, PoolKey, int24 lower, int24 upper, uint256 liq, address recipient)`. `poolId = keccak256(abi.encode(poolKey))`.

- [ ] **Step 1: Write `test/PoolFork.t.sol`** — `vm.createSelectFork(BASE_SEPOLIA_RPC)`; deploy NVDAx; use real USDC; `PoolSetup.initPool` on the real PoolManager; read spot back through the real `StateView` (`0x5712…B9B4`) and assert it equals the initialized price. Fork test is skipped automatically when `BASE_SEPOLIA_RPC_URL` is unset (`vm.envOr`).

- [ ] **Step 2: Run test.** `~/.foundry/bin/forge test --match-path 'test/PoolFork.t.sol' -vvv` (needs `BASE_SEPOLIA_RPC_URL`). Expected: FAIL then, after impl, PASS. Document the skip-without-RPC behavior.

- [ ] **Step 3: Implement `PoolSetup.sol`** using v4-core `IPoolManager.initialize` and v4-periphery `PositionManager` mint (via `Actions`/`Planner` or direct `modifyLiquidities`). Sort currencies by address to set `underlyingIsCurrency0`.

- [ ] **Step 4: Run test (with RPC).** Expected: PASS — spot read from the real StateView matches.

- [ ] **Step 5: Commit** — `git commit -m "feat: v4 NVDAx/USDC pool setup + fork test reading real StateView spot"`

---

## Task 7: Permissionless `settle` + JIT collateral unwind

**Files:**
- Modify: `contracts/src/GapOptionsApp.sol`
- Create: `contracts/test/Settle.t.sol`

**Interfaces:**
- Consumes: Task 4 Position record, Task 5 pricing, `IStateView`.
- Produces:
  - `function settle(uint256 positionId) external` — requires `block.timestamp >= p.expiry`, `!p.settled`; samples spot (`_sampleSpot`), computes `payout = min(max(0, signed(S-K)), cap) * size / 1e18` → quote dp; pulls payout collateral from maker (`AQUA.pull`), transfers to the ERC-1155 holder, `_burn`, `p.settled = true`. Legible revert if maker can't cover.
  - `function _sampleSpot(Strategy memory) internal view returns (uint256 spotWad)` — averages `SAMPLES` reads of `UniV4Spot.spotWad` (constant `SAMPLES`, documented; single read acceptable in-block on testnet since no intra-tx time passes — average across the settle window is the UI's job; document).
  - `uint256 constant SAMPLES`.

- [ ] **Step 1: Write `test/Settle.t.sol`** — after a buy (Task 4/5 flow on MockStateView): assert `settle` before expiry reverts; warp past expiry; set spot above strike so a call pays `min(S-K,cap)*size`; assert holder USDC increases by payout, position burned (`balanceOf==0`), `p.settled`; assert a second `settle` reverts (idempotent, Review Focus); assert maker-short reverts legibly (Review Focus).

- [ ] **Step 2: Run test.** Expected: FAIL.

- [ ] **Step 3: Implement `settle` + `_sampleSpot`** per the signatures. Payout uses `GapPricing`-free arithmetic (intrinsic capped payoff, not BS). Burn before external transfer (CEI).

- [ ] **Step 4: Run test.** Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: permissionless settle with capped payout and JIT collateral pull"`

---

## Task 8: Deploy scripts — Aqua, Gap, pool, ship

**Files:**
- Create: `contracts/script/DeployAqua.s.sol`, `contracts/script/DeployGap.s.sol`, `contracts/script/Ship.s.sol`
- Create: `contracts/src-aqua/` symlink/copy note for the `[profile.aqua]` Aqua build
- Writes: `contracts/deployments/base-sepolia.json`

**Interfaces:**
- Consumes: all contracts above; `PoolSetup` (Task 6); env `PRIVATE_KEY`, `BASE_SEPOLIA_RPC_URL`.
- Produces: a JSON of `{aqua, gapOptionsApp, nvdax, usdc, poolManager, positionManager, stateView, poolId, poolKey}`.

- [ ] **Step 1: `DeployAqua.s.sol`** — deploy `Aqua` from `@1inch/aqua` source; `console2.log` the runtime codehash and compare to `0x720bc02d220db318164dc3bade86eec1f3655bdc00fc1174de7d816a95c341f8` (log match/mismatch, do NOT revert).

- [ ] **Step 2: `DeployGap.s.sol`** — deploy NVDAx mock + `GapOptionsApp(aqua, stateView)`; create+init the v4 NVDAx/USDC pool via `PoolSetup`; mint + seed; write `deployments/base-sepolia.json`.

- [ ] **Step 3: `Ship.s.sol`** — maker `approve(aqua, collateral)` on NVDAx; `aqua.ship(app, abi.encode(strategy), [nvdax], [collateral])`; log `strategyHash` and assert it equals `gapApp.hashStrategy(strategy)`.

- [ ] **Step 4: Dry-run against a fork.** `~/.foundry/bin/forge script script/DeployGap.s.sol --fork-url $BASE_SEPOLIA_RPC_URL -vvv` (no broadcast). Expected: completes, JSON written.

- [ ] **Step 5: Commit** — `git commit -m "feat: deploy + ship scripts for Base Sepolia"`

- [ ] **Step 6 (gated on user `.env`): Live deploy.** With `contracts/.env` present: `forge script ... --broadcast --verify`. Run `DeployAqua`, `DeployGap`, `Ship`, then one live `buyOption` + `settle` via a `script/Demo.s.sol`; record tx hashes in `deployments/base-sepolia.json`. **Do not run until the user confirms creds are in place.**

---

## Task 9: Frontend — wired options desk with lightweight-charts

**Files:**
- Create: `app/` (Vite React TS): `app/package.json`, `app/src/main.tsx`, `app/src/App.tsx`, `app/src/wagmi.ts`, `app/src/abi/` (generated), `app/src/components/{Chart,OptionTicket,Positions}.tsx`, `app/src/lib/pricing.ts`
- Consumes: `contracts/deployments/base-sepolia.json`, contract ABIs.

**Interfaces:**
- Produces: a running app (`npm run dev` in `app/`) with wallet connect (Base Sepolia), a `lightweight-charts@^5.2.1` candlestick fed from v4 spot reads, an option ticket (kind/strike/cap/expiry/size) showing a client-side premium preview (`lib/pricing.ts` mirroring `GapPricing`) and sending `buyOption`, and a positions list with a `settle` button.

- [ ] **Step 1: Scaffold** `npm create vite@latest app -- --template react-ts`; add `wagmi viem @tanstack/react-query lightweight-charts@^5.2.1 lucide-react`. Pin `lightweight-charts` to `^5.2.1`.

- [ ] **Step 2: `wagmi.ts`** — Base Sepolia chain, injected connector, transport from a public RPC. Load addresses from `deployments/base-sepolia.json`.

- [ ] **Step 3: Chart** — `createChart` + `addCandlestickSeries`; feed candles built from periodic `StateView.getSlot0` reads via viem (synthetic overnight series placeholder when history thin, per template). Verify it renders in a browser.

- [ ] **Step 4: OptionTicket + Positions** — ticket computes preview premium in `lib/pricing.ts`, calls `buyOption` (writeContract) with a viem-side taker-push path; Positions reads ERC-1155 balances + the app's position records and wires `settle`. Reuse the visual language of `basic-template-design.tsx`.

- [ ] **Step 5: Manual browser verification** — `npm run dev`, connect wallet on Base Sepolia, buy an option against the live deployment, see the ERC-1155 position + the on-chain premium transfer, settle after expiry. (UI correctness is manual — state so explicitly; no automated e2e in this plan.)

- [ ] **Step 6: Commit** — `git commit -m "feat: wired options desk frontend with lightweight-charts"`

---

## Task 10: SwapVM `WeekendGap` custom opcode (scoring bonus)

**Files:**
- Create: `swap-vm-fork/` (git clone of `1inch/swap-vm`), `swap-vm-fork/contracts/instructions/WeekendGap.sol`
- Modify: `swap-vm-fork/contracts/libs/OpcodeList.sol` (rename free slot `_52`→`WeekendGap`), `swap-vm-fork/contracts/opcodes/AquaOpcodes.sol` (one `else if`)

**Interfaces:**
- Consumes: swap-vm `Context`, `SwapRegisters`, `InstructionBuilder`.
- Produces: `library WeekendGap { Opcode constant opcode; function sizeOf(...) ; function build(...) ; function exec(Context ctx, bytes args); }` writing a gap-option premium into `ctx.swap`. Redeployed `AquaSwapVMRouter(aqua, weth, owner, name, version)`.

- [ ] **Step 1: Clone fork** — `git clone https://github.com/1inch/swap-vm swap-vm-fork` (unpublished on npm; git is the only source). Build it per its Hardhat setup; run its existing test suite green first.

- [ ] **Step 2: Rename slot** — in `OpcodeList.sol` rename the first free `_5x` slot in the Swap-curves bank (`_52`) to `WeekendGap`. Run `OpcodeEnumCheck.t.sol`; expected PASS (rename-in-place only).

- [ ] **Step 3: Write `WeekendGap.sol`** — instruction library shaped like `instructions/XYCSwap.sol`, pricing a capped gap premium into registers. Add one `else if (opcode == WeekendGap.opcode.asU8()) WeekendGap.exec(ctx, args);` to `AquaOpcodes._runOpcode`.

- [ ] **Step 4: Test the opcode** — a swap-vm test that builds a strategy using `WeekendGap` and asserts the computed premium/registers. Expected: PASS.

- [ ] **Step 5: Redeploy router + demo** — deploy the modified `AquaSwapVMRouter` to Base Sepolia; a script runs one strategy through the opcode. Record address in `deployments/base-sepolia.json`.

- [ ] **Step 6: Commit** — `git commit -m "feat: WeekendGap SwapVM opcode (slot _52) + redeployed router"`

---

## Notes for the executor
- Tasks 1–5 and 7 run fully local (no RPC). Task 6, Task 8 step 6, and Task 10 step 5 need `BASE_SEPOLIA_RPC_URL` / `PRIVATE_KEY` from `contracts/.env` — **pause for the user** at those points.
- The frontend (Task 9) depends on a live deployment (Task 8 step 6) for its manual verification, but can be built and run against a local anvil fork earlier if desired.
- Keep `@1inch/aqua` untouched; only `swap-vm-fork` is modified, per the bounty.
