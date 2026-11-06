# Spec verification — `Aqua App Build Spec — Weekend Options`

Verified 2026-11-06 against `1inch/aqua@main` and `1inch/swap-vm@main` read at the `.sol` level,
plus live `eth_getCode` on Base (8453) and Base Sepolia (84532).

## Confirmed correct

| Spec claim | Status |
|---|---|
| Aqua App = plain Solidity contract extending `abstract AquaApp`, no VM needed | ✅ `contracts/AquaApp.sol` |
| `IAqua` surface: `ship / dock / pull / push / rawBalances / safeBalances` | ✅ exact |
| `ship` commits virtual balances, no token movement; strategies immutable | ✅ `require(balance.tokensCount == 0, StrategiesMustBeImmutable(...))` |
| `pull` gate = "only the app the maker shipped to" | ✅ `_balances[maker][msg.sender][strategyHash][token]` — `msg.sender` *is* the app key |
| `Aqua` has no `swap()`; the app implements swap | ✅ |
| `AquaApp` gives `AQUA` immutable, `nonReentrantStrategy`, `_safeCheckAquaPush` | ✅ exact |
| **No KYB / resolver / allowlist / taker gate anywhere in `Aqua.sol`** | ✅ confirmed — only auth is the app-key. Permissionless. |
| Settlement pattern = `pull(out) → taker callback → _safeCheckAquaPush(in)` | ✅ `XYCSwap.swapExactIn` |
| SwapVM: bytecode `[1b opcode][1b argsLen][args]`, `ContextLib.runLoop`, dispatch via stored fn pointer | ✅ `libs/VM.sol` |
| SwapVM opcode wiring = **one** `else if` line in `AquaOpcodes._runOpcode` (hand-written if-else chain, no registry) | ✅ |
| Instruction shape = library with `Opcode constant opcode`, `sizeOf()`, `build(...)`, `exec(Context, args)` | ✅ `instructions/XYCSwap.sol`, `instructions/MinRate.sol` |
| `AquaSwapVMRouter` ctor = `(aqua, weth, owner, name, version)` | ✅ |
| `Extruction` = general external call that can mutate registers pre-settlement | ✅ `instructions/Extruction.sol` + `IExtruction` |
| License = `LicenseRef-Degensoft-Aqua-Source-1.1` (source-available) | ✅ |

## Corrections to the spec

1. **`strategyHash = keccak256(strategy)` over the raw `bytes`, not `keccak256(abi.encode(struct))`.**
   `Aqua.ship` hashes the opaque `bytes calldata strategy`. `XYCSwap` happens to use
   `keccak256(abi.encode(strategy))` *because* the maker ships `abi.encode(Strategy)` — the two agree
   only if the off-chain encoder matches byte-for-byte. Our app pins this with an explicit
   `hashStrategy()` view used by both the SDK path and the tests.

2. **Collateral lives in the maker's wallet, not in Aqua.** `pull` is
   `IERC20(token).safeTransferFrom(maker, to, amount)` — the maker must hold an **ERC-20 allowance to
   the Aqua contract**. Aqua custodies nothing. Consequence for the JIT story: the app cannot "unwind
   an LP position held by Aqua"; it must make the maker's *wallet* balance materialize **before**
   calling `pull`, inside the same `nonReentrantStrategy` window. Ordering is
   `unwind → pull → callback → check`, not `pull → unwind`.

3. **`pull` has no solvency `require`.** It does `prevBalance - amount` on a `uint248`, so an
   over-pull reverts on arithmetic underflow, and the `safeTransferFrom` reverts if the maker's real
   wallet balance or allowance is short. Both are hard reverts, but the error is not a named one —
   worth a pre-check in the app for a legible revert.

4. **Aqua address in the spec is malformed** (39 hex chars). Canonical, identical on every chain:
   - Aqua: `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a`
   - SwapVM router: `0x111111338c5091e8440b67b168bae16a668ac0de`
   Base mainnet Aqua runtime codehash: `0x720bc02d220db318164dc3bade86eec1f3655bdc00fc1174de7d816a95c341f8`.

5. **Aqua is not deployed on any testnet.** `deployments.md` lists 19 chains — all mainnets
   (Ethereum, Base, OP, Polygon, Arbitrum, Avalanche, BNB, Linea, Sonic, Unichain, Gnosis, zkSync,
   Robinhood Chain, Cronos, Monad, HyperEVM, Arc). Live check: `eth_getCode` at the Aqua address on
   Base Sepolia returns `0x`. So "deploy to testnet" means **we deploy Aqua ourselves from the
   unmodified official source**, and prove it is official by matching the Base mainnet codehash.

6. **Build tooling is Hardhat 3, not Foundry.** `aqua` has `hardhat.config.ts` (solc 0.8.30, `viaIR`,
   optimizer runs 10_000_000, `evmVersion: prague`) and runs its `.t.sol` suite through
   `hardhat test solidity`. `swap-vm` is Hardhat 3.18 and depends on `@1inch/aqua` from npm. Only
   `@1inch/aqua` is on npm (`1.0.2-rc.2`); `@1inch/swap-vm` is **not published** — the fork must come
   from git, which is what the custom-opcode plan needs anyway.

7. **Opcode slot: use the swap-curve bank, not `_05`.** `OpcodeList.sol` is banked by instruction
   family and documents "for new instructions take the next free `_Ix` slots of their family bank".
   `_05` is in `0x00-0x0f | Core control flow`. A pricing curve belongs in `0x50-0x6f | Swap curves`
   → first free slot is **`_52`**. (`OpcodeEnumCheck.t.sol` asserts the enum layout, so renaming a
   free slot in place is the only safe edit.)

8. **Uniswap v4 spot is read via the `StateView` periphery contract**, not a `StateLibrary` import —
   `StateView.getSlot0(PoolId)` is the deployed read path. v4 core has **no built-in TWAP oracle**
   (that needs a hook), so "TWAP settlement" cannot come from the pool for free.

## Base Sepolia (84532) — live-verified addresses

| Contract | Address | code |
|---|---|---|
| Uniswap v4 PoolManager | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | ✅ |
| Uniswap v4 PositionManager | `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80` | ✅ |
| Uniswap v4 StateView | `0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4` | ✅ |
| Uniswap v4 Quoter | `0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa` | ✅ |
| Uniswap UniversalRouter | `0x492E6456D9528771018DeB9E87ef7750EF184104` | ✅ |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | ✅ |
| WETH | `0x4200000000000000000000000000000000000006` | ✅ |
| Circle USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | ✅ |
| Aqua | `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a` | ❌ **not deployed** |
| SwapVM router | `0x111111338c5091e8440b67b168bae16a668ac0de` | ❌ **not deployed** |

## Open items from the spec, now closed

- v4 addresses on Base — resolved above (Base **Sepolia**, since we deploy to testnet).
- Taker-push callback analogue — we define `IGapOptionCallback`, same shape as `IXYCSwapCallback`.
- `StateLibrary` read for v4 spot — it is `StateView.getSlot0(PoolId) → (sqrtPriceX96, tick, …)`.
- Aqua address on Base — corrected above.
- License: `Aqua-Source-1.1` is source-available; our app is a derived work that *imports* the
  official contracts rather than vendoring them, and we deploy official bytecode unmodified.
