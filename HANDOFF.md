# Gap — Overnight-Gap Options Platform — Handoff

**Branch:** `worktree-gap-options` · **Head:** `01a5f9d` · **Built for:** ETHGlobal "Build an Aqua App" ($5,000 bounty)
**Status:** All 10 planned tasks complete, each per-task reviewed clean + one whole-branch review. **Live deploy is gated on a `.env` you add (see §7).** Nothing has been broadcast on-chain.

---

## 1. What Gap is

Gap is an overnight-gap **options** platform. A maker writes **capped** call/put options on a mock
NVDAx token, priced in mock USDC. The premium is a **capped Black-Scholes (r = 0)** price computed
on-chain off **Uniswap v4** spot. Collateral and premium flow through **1inch Aqua** (`ship` / `pull`
/ `push`). Each option is an **ERC-1155** position, **cash-settled in USDC** after expiry. A React
desk wires the whole thing; a custom **SwapVM opcode** (`WeekendGap`) is a scoring bonus.

Capped means the payoff is a bounded vertical spread — `min(max(0, ±(S−K)), cap) · size` — so the
writer fully collateralizes it with exactly `cap · size` USDC. No liquidation, no margin calls.

> Scope note: an earlier spot-swap idea was explicitly **cut** — the product is options only.

---

## 2. Repository layout

```
contracts/          Foundry project (forge 1.8.1, solc 0.8.30)
  src/
    GapOptionsApp.sol        the Aqua app: ERC-1155 + buyOption/settle/quotePremium/hashStrategy
    lib/GapPricing.sol       capped Black-Scholes (r=0), A&S 26.2.17 normal CDF, WAD math
    lib/UniV4Spot.sol        v4 StateView.getSlot0 → spot (sqrtPriceX96 → WAD)
    interfaces/              IStateView, IGapOptionCallback
  script/
    DeployAqua.s.sol         deploy fresh Aqua, log codehash vs mainnet (log-only)
    DeployGap.s.sol          deploy mock USDC+NVDAx + Aqua + app, init+seed v4 pool, write JSON
    PoolSetup.sol (lib)      v4 initPool + seed (Permit2 two-step)
    Ship.s.sol               maker approves+ships USDC collateral into Aqua
    Demo.s.sol               self-contained DemoTaker + one buyOption + settle (compile-only)
    redeploy-base-sepolia.sh gated wrapper to redeploy the SwapVM router (Task 10)
  test/                      29 passing Foundry tests
  deployments/base-sepolia.json   written by DeployGap at deploy time (empty until you deploy)
app/                Vite + React 19 + TS frontend (wagmi/viem/@tanstack/react-query)
  src/
    App.tsx                  the desk
    lib/pricing.ts           client-side mirror of GapPricing (premium preview)
    lib/abi.ts, lib/deployment.ts, components/, hooks/
swap-vm-fork/       vendored 1inch/swap-vm fork (Task 10) — WeekendGap opcode at slot 0x52
docs/superpowers/   spec + plan
basic-template-design.tsx    the visual-language reference the desk reproduces
```

---

## 3. The money path (end to end)

1. **Maker ships collateral** — `Ship.s.sol`: `approve(AQUA, USDC)` then
   `aqua.ship(app, abi.encode(strategy), [usdc], [collateralUSDC])`. The collateral token is **USDC**
   (the quote), not NVDAx — NVDAx is pricing-only. Collateral stays in the maker's wallet under Aqua.
2. **Taker buys** — `buyOption(strategy, kind, strike, cap, expiry, size, maxPremium, to, takerData)`.
   The app pulls `capBacking` USDC from the maker via `AQUA.pull`, and the taker's callback
   (`IGapOptionCallback.gapOptionCallback`) pushes the premium into the maker's Aqua balance via
   `aqua.push`. An **ERC-1155** position is minted to `to`.
   - **An EOA cannot call `buyOption`** — `msg.sender` must be a contract implementing the callback.
     The frontend routes through a small `GapTaker` helper (mirrors `DemoTaker` in `Demo.s.sol`); that
     helper must be deployed and its address added to the deployment JSON before live buys work.
3. **Settle (permissionless, after expiry)** — `settle(strategy, positionId, holder)`: pays the holder
   `min(max(0, ±(S−K)), cap)·size` in USDC **from the app-held backing**, returns the remainder to the
   maker, burns the position. No second Aqua pull.

**Units (consistent across the whole path):** `strike`/`cap`/`size`/`spot`/`volWad` are **WAD (1e18)**;
`premium`/`payout`/`capBacking` are **6-dp USDC**. `capBacking = cap·size/1e18` scaled WAD→6dp. By
construction `payout ≤ capBacking` always, so settle can never under-pay (fuzzed + asserted).

---

## 4. Pricing

`GapPricing.premium` (on-chain, authoritative): capped call = `call(K) − call(K+cap)`, capped put =
`put(K) − put(K−cap)`, vanilla BS with r = 0, Abramowitz-Stegun 26.2.17 normal CDF (|err| < 7.5e-8).
Rates omitted on purpose — these options live hours, `r·T` is noise.

`app/src/lib/pricing.ts` mirrors it in JS doubles for the instant preview; the **binding** number the UI
shows is the on-chain `quotePremium` read.

---

## 5. Frontend

Vite + React 19 + wagmi/viem, `lightweight-charts@^5.2.1` (pinned, v5 `addSeries(CandlestickSeries,…)`
API). Reproduces `basic-template-design.tsx`'s dark "GAP // PROTOCOL" look. Candlestick fed from periodic
`StateView.getSlot0` reads; 3-step CALL/PUT ticket with live premium preview + on-chain `quotePremium`;
positions panel with settle. **Handles an empty/unpopulated deployment gracefully** — amber "preview" banner,
synthetic chart, no fake addresses, no crash. Verified: `npm install` + `npm run build` (0 type errors) +
`npm run dev` renders. On-chain buy/settle is **deferred to the live deploy** (needs the gated `.env`).

Run: `cd app && npm install && npm run dev` (→ http://localhost:5173).

---

## 6. SwapVM `WeekendGap` opcode (bonus)

`swap-vm-fork/` is a local fork of `1inch/swap-vm` (proprietary license — forked/modified locally for the
demo, **not** republished). Free slot `_52` renamed to `WeekendGap`; `WeekendGap.sol` prices a capped gap
premium into the swap registers (`amountOut`/`amountIn`), wired by one `else if` in `AquaOpcodes._runOpcode`.
Upstream baseline 811 tests → **817 passing** (+6, incl. a 1024-run fuzz proving `premium ≤ cap`).

**Deliberate simplification:** the opcode uses a **linearized** premium (capped intrinsic + a Bachelier ATM
time-value term), **not** full Black-Scholes — the fork ships no WAD `exp`/`ln`, and vendoring transcendental
math into third-party code was rejected. Full BS stays off-VM in `GapOptionsApp.quotePremium`. The
economically load-bearing property — premium ≤ cap ⇒ full collateralization — is preserved and fuzzed.

Fork toolchain: Hardhat 3.18.1 / solc 0.8.30 / viaIR. (`yarn install` didn't populate `node_modules/.bin`
in our env; tests were run via `node node_modules/hardhat/dist/src/cli.js test solidity`.)

---

## 7. Going live (what's left — all gated on YOUR `.env`)

> **Live-demo preconditions (read before enabling on-chain Buy).** The final whole-branch review found
> two cross-task gaps that are harmless while buy/settle stays gated, but **block a live frontend buy** the
> moment you enable it:
> 1. **Connect with the maker/deployer wallet.** `Ship.s.sol` ships collateral as `maker = msg.sender`
>    (the deployer). The frontend sets `maker` to the *connected* wallet (`strategy.ts:33`). If you connect
>    a different wallet, the Strategy hashes to an unshipped maker → `buyOption` reverts
>    `InsufficientMakerCollateral` (while `quotePremium` still shows a binding quote, since it ignores
>    maker). Either connect with the shipper wallet, **or** add a `maker` field to
>    `deployments/base-sepolia.json` and read it in `buildStrategy`.
> 2. **`GapTaker` is not deployed yet.** `abi.ts`/`App.tsx`/`deployment.ts` all reference a `GapTaker`
>    helper, but the only implementation is `DemoTaker` inside `Demo.s.sol` (a script, no reusable address).
>    Until you **extract `DemoTaker` into a deployable `GapTaker.sol`, deploy it, and write its address to
>    `deployments/base-sepolia.json` under `gapTaker`**, `canBuyOnChain` stays false and the Buy button
>    silently falls back to adding a *preview* position — it is inert on-chain.
> 3. **(Minor)** When `quotePremium` errors but a `gapTaker` is set, Buy derives `maxPremium` from the
>    client preview (`App.tsx:139`); if the preview underestimates chain premium by >2%, `buyOption` reverts
>    `PremiumTooHigh`. Consider disabling Buy when `deployed && !onchainPremium`.

Nothing has been broadcast. To deploy to Base Sepolia, create `contracts/.env` with:

```
PRIVATE_KEY=0x...            # funded Base Sepolia deployer
BASE_SEPOLIA_RPC_URL=https://...
ETHERSCAN_API_KEY=...        # for --verify (optional)
```

Then, from `contracts/` (forge at `~/.foundry/bin/forge`, not on PATH):

1. `forge script script/DeployGap.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify`
   — deploys mocks + Aqua + app, inits/seeds the v4 pool, writes `deployments/base-sepolia.json`.
2. `forge script script/Ship.s.sol --rpc-url ... --broadcast` — maker ships USDC collateral.
3. **Deploy a `GapTaker` helper** and add its address to `deployments/base-sepolia.json` under `gapTaker`
   so the frontend can route buys (the callback contract — pattern is `DemoTaker` in `Demo.s.sol`).
4. SwapVM router (bonus): `bash contracts/script/redeploy-base-sepolia.sh` (skips cleanly if `.env` absent).
5. Point the frontend at the populated JSON and exercise buy → settle live.

**A dry-run against a fork** (no broadcast) is available any time once you have an RPC:
`forge script script/DeployGap.s.sol --fork-url $BASE_SEPOLIA_RPC_URL -vvv`.

---

## 8. Known non-blocking items (none worth blocking the handoff)

- `lucide-react` resolved to `^1.70.0` in this registry (the usual line is 0.3xx–0.5xx); build passes here
  but a public-npm reinstall may need it re-pinned to a known-good 0.4xx.
- `GapOptionsApp` uses unchecked `IERC20.transfer` — fine for the mock/standard USDC; add SafeERC20 if an
  exotic quote token is ever introduced.
- `SAMPLES=3` in settle averages identical single-tx spot reads (a hook for a future multi-block window);
  real manipulation-resistant averaging is a keeper/UI concern, documented in NatSpec.
- The `WeekendGap` opcode's time-value term is ATM-flat (overprices wings vs true BS) — capped at `cap`,
  acceptable for a demo primitive.
- Deploy codehash vs mainnet Aqua will log MISMATCH under the default profile (byte-identical needs the
  `[profile.aqua]` prague/via_ir/10M build) — expected, log-only, never reverts.

---

## 9. Tests

- Contracts: `cd contracts && ~/.foundry/bin/forge test` → **29 passing**.
- SwapVM fork: **817 passing** (see §6 for the runner caveat).
- Frontend: `cd app && npm run build` → 0 type errors; `npm run dev` renders.
```
```
