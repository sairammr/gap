# Gap — overnight-gap options on Aqua (NVDAx/USDC)

**Status:** draft for approval
**Date:** 2026-11-06
**Bounty:** ETHGlobal "Build an Aqua App" ($5,000)
**Source-grounded by:** `docs/aqua-app-build-spec.md` and `docs/SPEC-VERIFICATION.md`
(both `[VERIFIED]` against `1inch/aqua@main`, `1inch/swap-vm@main`, and live `eth_getCode` on Base 8453 / Base Sepolia 84532).

> **Scope note (2026-11-06):** the spot-swap product was cut at the user's request — Gap is **overnight-gap options only**. That is the key part. The Aqua settlement core, mock NVDAx, v4 pool, and frontend all serve options; references to a swap tab/entrypoint are removed below.

---

## 1. Intent and the why

Build **Gap**: a TradeFi web app where a user buys **overnight-gap options** on a tokenized stock (**NVDAx**), priced in **USDC**, settled through 1inch **Aqua**.

- **Overnight-gap options** — buy a capped call or put on NVDAx, priced by Black-Scholes off the live Uniswap v4 spot (`GapPricing.sol`, already written), premium paid in USDC, settled through the Aqua `pull → callback → check` window.

**Why this shape.** The bounty rewards a "sophisticated DeFi position" and scores SwapVM usage higher. Capped options on a tokenized stock are the sophisticated position. The headline differentiator (from the spec): the maker's collateral earns Uniswap v4 spot fees as an LP position until the instant an option needs it, then is unwound **just-in-time** inside the Aqua reentrancy window.

**Why mock tokens.** There is **no tokenized NVDA on any testnet** — xStocks/Backed NVDAx is mainnet-only and not on Base at all (verified against xstocks.com / docs.xstocks.fi, 2026-11-06). The user confirmed: use mock tokens. We deploy a mock `NVDAx` ERC-20 faithful to the real asset (18 decimals, name "NVIDIA xStock", symbol "NVDAx") and use **Circle USDC** (`0x036CbD53842c5426634e7929541eC2318f3dCF7e`, real on Base Sepolia) for the premium/payout leg; a mock USDC (6dp) is used only in local Foundry tests.

## 2. Goals / non-goals / anti-goals

**Goals**
- One Aqua settlement core serving the buy-option entrypoint, NVDAx/USDC.
- Real on-chain transfers in the demo: `Shipped` / `Pulled` / `Pushed` events + ERC-1155 (option position) mint and USDC movement, on **Base Sepolia live**.
- Uniswap v4 spot as the single price oracle, read via the deployed `StateView` lens (not a `StateLibrary` import).
- A full wired frontend (Vite + React + wagmi/viem) using **`lightweight-charts@^5.2.1`** for candles, driving real option-buy and settle transactions.
- Custom SwapVM **`WeekendGap`** opcode, added **after** the app is end-to-end, for the scoring bump (slot `_52` in the Swap-curves bank per the verification doc).
- Incremental git commits from the first slice.

**On the Aqua codehash (settled call, 2026-11-06):** deploying byte-identical-to-mainnet Aqua from Foundry is almost certainly unachievable — 1inch builds Aqua with **Hardhat 3** (verification doc item 6), and a Foundry `[profile.aqua]` build will differ in metadata/bytecode layout. So matching the Base mainnet runtime codehash is **best-effort, not a goal**. We deploy Aqua from the **unmodified `@1inch/aqua` source**; if the codehash matches we note it, and if it doesn't we document it as a known Foundry-vs-Hardhat build-metadata difference. Functionality is identical and the bounty only requires official contracts be *used*. (Fallback if a reviewer insists on an exact match: build Aqua via Hardhat from the official repo — out of scope unless asked.)

**Non-goals**
- Selling/writing options from the UI (maker-side ship happens via script/SDK; UI is taker-side buy + settle).
- Spot swapping (cut from scope 2026-11-06 — options only).
- American exercise, multi-leg strategies, a full order book.
- Mainnet deployment. Aqua is not on any testnet, so we **deploy official Aqua bytecode ourselves**; matching the Base mainnet runtime codehash is best-effort (see §2 note), not required.
- On-chain TWAP from the pool (v4 core has no oracle; settlement uses a sampled observation window in the app, as the verification doc notes).

**Anti-goals (these make it a failure even if it "works")**
- Vendoring/modifying the official `Aqua.sol` — we import `@1inch/aqua` unmodified; only SwapVM is forked+redeployed, which the bounty explicitly permits.
- A single final-day commit dump.
- Faking transfers / a mocked demo that doesn't emit real Aqua events.
- Pretending a mock token is the real xStocks NVDAx anywhere user-visible without labeling it a testnet mock.

## 3. Constraints (all [VERIFIED] in the verification doc unless noted)

- `strategyHash = keccak256(raw strategy bytes)`; app pins an explicit `hashStrategy()` view used by both SDK path and tests.
- Collateral lives in the **maker's wallet**, not in Aqua; maker must grant an ERC-20 allowance to Aqua. JIT ordering is **unwind → pull → callback → check**, never pull→unwind.
- `pull` has no solvency `require` (underflows on over-pull); app adds a legible pre-check.
- Aqua/ SwapVM addresses are identical on every chain: Aqua `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a`, router `0x111111338c5091e8440b67b168bae16a668ac0de` — **but not deployed on Base Sepolia**, so we deploy them.
- Build tooling: `@1inch/aqua` is on npm (`1.0.2-rc.2`, already in `contracts/package.json`); `@1inch/swap-vm` is **not** published — fork from git for the opcode.
- Foundry is our harness (`foundry.toml` has a `[profile.aqua]` mirroring 1inch's solc 0.8.30 / prague / viaIR / runs=10_000_000 to get as close as possible to the official build; an exact codehash match is **not** expected — see §2).
- Base Sepolia v4 addresses (live-verified): PoolManager `0x05E7…3408`, PositionManager `0x4B2C…ca80`, StateView `0x5712…B9B4`, Quoter `0x4A65…1cBa`, Permit2 `0x0000…8BA3`, WETH `0x4200…0006`, USDC `0x036C…CF7e`.

## 4. Architecture — the parts decided, as decided

### 4.1 Contracts (`contracts/`, Foundry)
Existing (prior session, keep): `src/lib/GapPricing.sol` (capped BS, r=0), `src/lib/UniV4Spot.sol` (sqrtPriceX96→WAD), `src/interfaces/IStateView.sol`.

New:
- `src/GapCore.sol` — abstract Aqua app extending `@1inch/aqua` `AquaApp`; owns the `nonReentrantStrategy` settlement window, strategy struct + `hashStrategy()`, the maker pre-check, and the v4 JIT-unwind helper (`modifyLiquidity` on PositionManager to materialize collateral before `pull`).
- `src/GapOptionsApp.sol` — `buyOption(kind, strike, cap, expiry, size, maxPremium, to, takerData)`: `premium = GapPricing.premium(...)` off v4 spot; `pull` mints an **ERC-1155** long position to taker; taker pushes USDC premium in callback; `_safeCheckAquaPush`. Settlement is defined below. `volWad` (implied vol) is a strategy parameter set by the maker at ship time (not derived on-chain — v4 has no vol oracle); the UI shows it per asset as in the template.

**Option settlement (settled calls, 2026-11-06):**
- **Collateral custody = JIT-pull at settle.** Between buy and expiry the maker's capped collateral stays in the maker's wallet as the Uniswap v4 LP position (earning spot fees — the headline differentiator). It is **not** escrowed at buy. At `settle`, the app unwinds exactly the owed payout from the LP and `pull`s it via Aqua to the holder, inside the strategy window (unwind → pull → check). Risk: if the maker's wallet/LP can't cover at expiry, settle reverts with a legible error — acceptable for a testnet demo, documented as the known trade-off of the JIT model vs. escrow.
- **Trigger = permissionless.** Anyone may call `settle(positionId)` once `block.timestamp >= expiry`. It reads the expiry price, computes `payout = min(max(0, ±(S−K)), cap) * size`, pays the ERC-1155 holder, and **burns** the position. Idempotent: a settled/zero position can't be re-settled.
- **Expiry price = sampled v4 spot.** At/after expiry, sample `StateView.getSlot0` spot over a short fixed window and average (v4 core has no native TWAP). Manipulable in principle; documented as a testnet-demo limitation. Sampling defaults (count/spacing) are the builder's call (§6).
- `src/mocks/MockERC20.sol` — `NVDAx` (18dp, "NVIDIA xStock"/"NVDAx") and a local mock USDC (6dp) for Foundry tests.
- `src/interfaces/IGapOptionCallback.sol` — taker-push callback, same shape as `IXYCSwapCallback`.

### 4.2 Aqua + pool bring-up (`contracts/script/`)
- `script/DeployAqua.s.sol` — deploy official Aqua from the unmodified `@1inch/aqua` source; **log** the runtime codehash and compare to the Base mainnet codehash (best-effort, per §2 — do not revert on mismatch).
- `script/DeployGap.s.sol` — deploy NVDAx mock, GapCore/Options, mint NVDAx, create + initialize a Uniswap v4 **NVDAx/USDC** pool via PoolManager, seed liquidity via PositionManager, write all addresses to `deployments/base-sepolia.json`.
- `script/Ship.s.sol` — maker ships NVDAx + USDC virtual balances to the app and sets Aqua allowances (uses `@1inch/aqua` SDK semantics; hash pinned by `hashStrategy()`).

### 4.3 SwapVM opcode (`swap-vm-fork/`, added after app is live)
Fork `1inch/swap-vm` from git. Rename free slot **`_52`** → `WeekendGap` in `OpcodeList.sol`; add `instructions/WeekendGap.sol` (library: `opcode`, `sizeOf`, `build`, `exec` reading/writing `ctx.swap`); add one `else if` to `AquaOpcodes._runOpcode`; redeploy router `(aqua, weth, owner, name, version)`. Wire one strategy that prices a gap option through the opcode to demonstrate it.

### 4.4 Frontend (`app/`, Vite + React + TS)
- wagmi + viem, Base Sepolia; wallet connect.
- `lightweight-charts@^5.2.1` candlestick chart fed from Uniswap v4 spot history (indexed from `Swap`/slot0 reads; synthetic overnight series as in the template where real history is thin).
- **Options desk** (single-product UI): asset = NVDAx/USDC, strike/cap/expiry pickers, live premium from `GapPricing` (mirrored client-side for preview, authoritative on-chain), buy → ERC-1155 position, positions list, permissionless settle.
- Visual language from `basic-template-design.tsx` (the overnight-gap desk), rebuilt as a real wired app — not shipped as the raw template.
- Reads/writes `deployments/base-sepolia.json` for addresses.

## 5. Build order (first slice first — matches spec §7)
1. `forge install` deps; compile existing libs; add mock NVDAx + mock USDC; unit-test `GapPricing` and `UniV4Spot`.
2. `GapCore` + `GapOptionsApp` `buyOption` with a **fixed premium** (no BS yet); Foundry test proving `Shipped`/`Pulled`/`Pushed` + ERC-1155 mint + USDC movement on a Base fork — **the end-to-end on-chain-transfer slice**.
3. Replace fixed premium with BS off v4 spot (`GapPricing` + `UniV4Spot`).
4. JIT v4 LP unwind + permissionless `settle` with sampled expiry spot (unwind→pull→check).
5. Deploy Aqua + Gap + pool to **Base Sepolia live**; run `Ship` + a live buy + a settle; capture real tx hashes.
6. Frontend wired to the live deployment (options desk + charts).
7. SwapVM `WeekendGap` opcode + redeploy router + demo strategy (scoring bonus).

## 6. Left to the builder
- Exact option settlement sampling (observation count/spacing for the expiry TWAP-substitute) — pick sane defaults, document them.
- Precise v4 pool fee tier / tick spacing and initial price for the seeded NVDAx/USDC pool.
- Client-side premium mirror precision vs. on-chain authority (preview only; chain is source of truth).
- ERC-1155 metadata shape for option positions.
- Default `volWad` values seeded per asset for the demo (maker-set; template shows ~34–96% overnight IV).

## 7. Open item requiring the user
- **Deploy creds.** User will add `contracts/.env` (`PRIVATE_KEY`, `BASE_SEPOLIA_RPC_URL`, `ETHERSCAN_API_KEY`). Build proceeds against a local Base fork until creds land; live deploy (step 5) runs when they do.
