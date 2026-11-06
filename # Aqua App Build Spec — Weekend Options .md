# Aqua App Build Spec — Weekend Options (ETHGlobal "Build an Aqua App" bounty)

Target: **💧 Build an Aqua App — $5,000** ($2,500 / $1,500 / $1,000).
This doc is the source-grounded build plan. All interface facts below are `[VERIFIED]` from
canonical public repos (`1inch/aqua`, `1inch/swap-vm`) read at the `.sol` level, unless tagged otherwise.

---

## 0. How the bounty reframes everything

| Bounty line | Consequence |
|---|---|
| "Create a custom Aqua app that implements a sophisticated DeFi position" | **Options on tokenized stocks = the sophisticated position.** Clear fit. |
| "If you use SwapVM, you may modify opcodes… Projects that utilize SwapVM scored higher" | SwapVM is an **optional bonus**, not required. A plain `AquaApp` (Solidity) qualifies; a custom SwapVM opcode scores higher. **Do both: ship the app, add one custom opcode for the scoring bump.** |
| "Official Aqua/SwapVM contracts must be used (redeploys of modified SwapVM allowed)" | Use `1inch/aqua` as a dep; fork+redeploy SwapVM only for the custom opcode. |
| "Onchain token transfers presented in demo (local forks ok)" | **Kills the permissioned-taker blocker.** Demo on a Base fork. |
| "Proper Git commit history (no single-commit final day)" | Commit incrementally from day one. |

---

## 1. What an "Aqua App" actually is `[VERIFIED from 1inch/aqua]`

An Aqua App is a plain Solidity contract extending abstract **`AquaApp`**. **No VM required.**

- `aqua` repo (Solidity 0.8.30, **Foundry**, license **Degensoft Aqua-Source-1.1** — source-available, note for submission):
  ```
  contracts/Aqua.sol             core protocol (ship/pull/push/safeBalances/dock)
  contracts/AquaApp.sol          abstract base you extend
  contracts/interfaces/IAqua.sol
  examples/apps/XYCSwap.sol      ← full CPMM app = our skeleton
  examples/apps/interfaces/IXYCSwapCallback.sol
  test/*.t.sol                   Foundry tests
  ```

### Core `IAqua` surface `[VERIFIED]`
- `ship(app, strategy, tokens[], amounts[]) → strategyHash` — commits **virtual balances** (no token movement). Strategies **immutable** (re-ship same hash reverts).
- `pull(maker, strategyHash, token, amount, to)` — maker→`to`. Gated: **only the app the maker shipped to can pull**.
- `push(maker, app, strategyHash, token, amount)` — `safeTransferFrom(msg.sender→maker)`, credits balance.
- `safeBalances(maker, app, strategyHash, t0, t1)` — reverts if token not in active strategy.
- `dock(app, strategyHash, tokens[])` — deactivate.
- **`Aqua` has no `swap()`** — the *app* implements swap.

### `AquaApp` base gives you `[VERIFIED]`
- `AQUA` immutable (ctor takes `IAqua`).
- `nonReentrantStrategy(maker, strategyHash)` modifier (TransientLock → atomic).
- `_safeCheckAquaPush(maker, strategyHash, token, expectedBalance)`.

### Taker gate `[VERIFIED — NONE]`
`Aqua.sol` has **no KYB / Resolver / allowlist / Controls**. Only auth = "msg.sender is the shipped app."
The permissioned-taker restriction we worried about is **off-chain product policy, absent from these contracts**. A fork demo is fully permissionless.

---

## 2. The settlement pattern (the whole mechanism) `[VERIFIED from XYCSwap.swapExactIn]`

```solidity
nonReentrantStrategy(maker, strategyHash) {
    amountOut = quote(...);
    AQUA.pull(maker, strategyHash, tokenOut, amountOut, to);     // 1. give taker output FIRST
    IXYCSwapCallback(msg.sender).xycSwapCallback(...);           // 2. taker pushes input in callback
    _safeCheckAquaPush(maker, strategyHash, tokenIn, balIn + amountIn); // 3. verify or revert
}
```
Output pulled **before** input arrives; taker callback supplies input; balance check reverts if underpaid.
**This pull→callback→check window is where all custom logic lives — including JIT Uniswap work.**

---

## 3. Our app: `WeekendOptionsAquaApp`

Copy `XYCSwap` skeleton; replace CPMM math with option logic. Two entrypoints:

### 3a. Buy an option (`buyOption`)
- `quote()` = Black-Scholes premium from the Uniswap v4 spot (read pool via StateLibrary).
- `AQUA.pull` mints/sends the option position (ERC-1155 long) to taker.
- taker pushes premium (USDC) in callback.
- `_safeCheckAquaPush` confirms premium received.
- Fully collateralized: the maker's shipped balance *is* the collateral; `pull` only succeeds if backed.

### 3b. The JIT-liquidity differentiator (the "sophisticated position")
During the week, the maker's collateral sits as a **Uniswap v4 LP position** earning spot fees.
When a buy arrives, inside the `nonReentrantStrategy` window the app:
1. calls Uniswap v4 `modifyLiquidity` to **unwind exactly enough LP** to materialize collateral,
2. `AQUA.pull`s it to back the option,
3. balance check seals it.
`[VERIFIED feasible]`: settlement/push happens after the app body, and the reentrancy lock makes it
atomic — so unwinding mid-call is sound. This is the headline: **"collateral earns Uniswap spot fees
until the instant an option needs it, then is pulled just-in-time."**

---

## 4. SwapVM custom opcode (bonus scoring) `[VERIFIED from 1inch/swap-vm]`

Optional, but "scored higher." The seam is tiny (fork+redeploy is bounty-sanctioned):

1. Claim a pre-named free enum slot in `contracts/libs/OpcodeList.sol` (e.g. `_05` → `WeekendGap`).
2. Write `contracts/instructions/WeekendGap.sol` as a library — copy `XYCSwap.sol` instruction shape:
   `Opcode constant opcode`, `sizeOf()`, `build(...)` (encode via `InstructionBuilder`), `exec(Context, args)`
   reading/writing `ctx.swap` (`SwapRegisters{balanceIn,balanceOut,amountIn,amountOut,surcharge}`).
3. Add **one line** to the dispatcher `AquaOpcodes._runOpcode`:
   `else if (opcode == WeekendGap.opcode.asU8()) WeekendGap.exec(ctx, args);`
   (dispatch is a hand-written if-else chain — no registry; one line is the whole wiring).
4. Redeploy router (ctor: `aqua, weth, owner, name, version`).

Interpreter: `ContextLib.runLoop` in `libs/VM.sol`, bytecode `[1b opcode][1b argsLen][args]`, dispatch via
stored function pointer → router `_runOpcode`. `[VERIFIED]`

**Extruction** (`instructions/Extruction.sol`): `IExtruction(target).extruction(isStatic,nextPC,query,swap,args,takerData)`
— general external call that can mutate registers + side-effect external protocols **before settlement**.
An alternative JIT path if going the SwapVM route. Guard with `RequireMinRate` before it.

**Build tooling:** Hardhat; Sol 0.8.27 libs / 0.8.30 `SwapVM.sol`; `InstructionBuilder` + `Strategies.sol` program builders.

---

## 5. Aqua SDK (`1inch/sdks/typescript/aqua`) `[VERIFIED]`

- viem-based `AquaProtocolContract`: encodes **`ship` / `dock`** txs, parses `Shipped/Pushed/Pulled/Docked`, `calculateStrategyHash`, `AQUA_CONTRACT_ADDRESSES` for 10+ chains.
- **No ProgramBuilder / bytecode composer** — `push`/`pull` are app-level, not SDK-encoded.
- Use it for the UI/script ship+event flow; encode any SwapVM program yourself.

---

## 6. Qualification checklist (map to requirements)

- [ ] **Official contracts used** — `1inch/aqua` as dependency; SwapVM forked+redeployed only for the custom opcode. ✅ permitted.
- [ ] **Onchain token transfers in demo** — Foundry/Hardhat script OR the web UI driving `buyOption` on a **Base mainnet fork**, showing real `Pulled`/`Pushed` events + ERC-1155 mint + USDC transfer.
- [ ] **Git history** — incremental commits from day 1; no single final-day dump.
- [ ] **SwapVM utilized** — custom `WeekendGap` opcode for the scoring bump.
- [ ] **Sophisticated position demonstrated** — options buy + JIT-liquidity unwind, via tests + UI.

---

## 7. Build order (first slice first)

1. **Fork harness:** Foundry project pulling `1inch/aqua`; Base mainnet fork; deploy a mock xStock ERC-20 + USDC (or use real Base tokens on the fork) + a Uniswap v4 pool. `[verify v4 PoolManager on Base]`
2. **`WeekendOptionsAquaApp` v0:** copy XYCSwap; `buyOption` with a fixed premium (no BS yet); ship collateral; taker buys; assert `Pulled`/`Pushed` + ERC-1155 mint. **This is the end-to-end on-chain-transfer demo the bounty requires.**
3. **Uniswap pricing:** replace fixed premium with BS off the v4 pool spot.
4. **JIT unwind:** collateral as a v4 LP position; unwind-on-buy inside the strategy window.
5. **SwapVM custom opcode:** add `WeekendGap` for scoring; wire a strategy that uses it.
6. **UI/script + settlement:** TWAP settlement, payout; web demo driving it.

---

## 8. Open items `[still to verify]`
- [ ] Uniswap v4 `PoolManager` / `PositionManager` addresses on Base (mainnet for fork; the demo runs on a fork so mainnet addresses are fine).
- [ ] Exact `IXYCSwapCallback` analogue we define for our taker-push callback.
- [ ] `StateLibrary` read call for v4 spot (standard, unconfirmed exact signature).
- [ ] Confirm `1inch/aqua` Aqua address on Base (earlier on-chain check: `0x1111113ccf1426a8E30E2bF5e005D929bf6a90A` has code on Base).
- [ ] Degensoft Aqua-Source-1.1 license — check it permits hackathon redistribution of a derived app.

---

## 9. Sources (canonical, read at .sol level)
- `github.com/1inch/aqua` — `Aqua.sol`, `AquaApp.sol`, `IAqua.sol`, `examples/apps/XYCSwap.sol`
- `github.com/1inch/swap-vm` — `libs/VM.sol`, `libs/OpcodeList.sol`, `opcodes/AquaOpcodes.sol`, `instructions/{XYCSwap,Extruction}.sol`
- `github.com/1inch/sdks/tree/master/typescript/aqua`
- On-chain (Base): Aqua `0x1111113ccf1426a8E30E2bF5e005D929bf6a90A`, AquaSwapVMRouter `0x111111338c5091E8440b67B168bAe16a668AC0De`