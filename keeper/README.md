# keeper — Weekend Options settlement

Nothing in this protocol settles itself. Every payout entry point is
**permissionless**, so this process needs no privileged key — only gas.

| call | what it does | re-running it |
|---|---|---|
| `oracle.recordSettlement(asset, expiry)` | records the settlement price | reverts `AlreadyRecorded` — one-shot, irrevocable |
| `weekendOptions.settle(seriesId)` | snapshots the six payout fields | reverts `AlreadySettled` |
| `weekendOptions.redeemFor(seriesId, holder)` | pays a holder | returns `(0,0)` if they hold nothing |
| `weekendOptions.claimFor(seriesId, writer)` | pays a writer | one-shot: `written` is zeroed first, so a second call is a no-op, not a double-pay |

```bash
node index.js --once          # one dry-run pass (no key needed)
node index.js                 # dry-run loop, every INTERVAL_MS
node index.js --broadcast     # actually send
npm test                      # 6 asserts on the pure encode/decode/pro-rata bits
```

**Dry run is the default.** Broadcasting takes an explicit `--broadcast`.

## Config

| env | default | |
|---|---|---|
| `RPC_URL` | `https://base-sepolia-rpc.publicnode.com` | publicnode serves the whole log range in one call |
| `INTERVAL_MS` | `60000` | |
| `KEEPER_PRIVATE_KEY` | — | only for `--broadcast`; **its own key, not the deployer's** |
| `ETH_KEYSTORE` / `ETH_PASSWORD` | — | preferred over `KEEPER_PRIVATE_KEY` (see Keys) |
| `DEPLOYMENT_FILE` | `../contracts/deployments/base-sepolia.json` | |
| `FROM_BLOCK` | `55393920` | the current stack's deploy block |
| `LOG_CHUNK_BLOCKS` | `0` (= try the whole range) | |
| `CAST_BIN` | `cast` | e.g. `~/.foundry/bin/cast` |

Addresses are read from the deployment JSON **at runtime**, never hardcoded — a
redeploy has already moved them once.

## Keys

The keeper account needs **gas and nothing else**. It is never a counterparty: every
payout goes to the holder's or writer's own wallet, never the caller's. A fresh
throwaway key with a little Base Sepolia ETH is the right thing to run this with.

`contracts/.env` exists but holds the **deployer's** key — do not point the keeper at it.

Signing needs keccak256 + secp256k1 recovery, which node's crypto does not have
(`sha3-256` is a different padding), so `--broadcast` shells out to foundry's `cast`
rather than hand-rolling crypto on a payout path. Prefer `ETH_KEYSTORE` +
`ETH_PASSWORD`: `cast` picks those up from the environment, so the key never reaches
argv. A raw `KEEPER_PRIVATE_KEY` goes through `--private-key`, where it is visible in
`ps` to anyone on the box. Neither is ever logged — `cast`'s stderr is suppressed on
failure because it can echo back the arguments it was given.

Reads need no key at all, so a dry run works with an RPC URL and nothing else.

## How it finds things

There is no indexer, so everything is derived from chain:

- **Series** — `seriesCount()` then `getSeries(i)`. The count is small; walking it beats
  replaying `SeriesCreated`.
- **Holders** — `OptionWritten` (the `to` topic) plus the series' own option-token
  `Transfer` logs, which catch anyone who bought on the secondary.
- **Writers** — the `maker` topic of `OptionWritten`, then `written[seriesId][addr]` to
  see what is actually still owed.

`eth_getLogs` on the public Base Sepolia RPC is capped at a 200-block range. The keeper
tries the whole span in one call and latches to 200-block chunks the first time a
provider refuses — one request on publicnode, ~40 on `sepolia.base.org`, same answer
either way.

## Skip, don't crash

Every action is simulated with `eth_call` before it is sent, and a revert is matched
against a table of expected states rather than thrown:

- `NotExpired` — before expiry.
- `OracleNotReady` — settled inside the 7-day grace window with no recorded price yet.
- `AlreadySettled` / `AlreadyRecorded` — someone else got there first.
- `NotConfigured` — the oracle has no pool for that asset.

All are normal. They are logged as notes and the pass continues. A failed pass does not
kill the loop either.

Two deliberate non-actions:

- A **zero payout is not sent.** A worthless-at-settle holder balance would still be
  *burned* by `redeemFor`, so the keeper leaves it alone; a writer owed nothing is left
  with their `written` entry intact.
- When `recordSettlement` has not landed yet, `settle` is left to the **next tick**
  rather than chained inside this one. The loop is idempotent, so a tick of latency
  costs nothing and a mid-pass reorg costs nothing either.

## Verified against the live deployment

`node index.js --once`, Base Sepolia, block 55403132:

```
weekend-options keeper — https://base-sepolia-rpc.publicnode.com
weekendOptions 0x7031B0eD0Cf2Dc85eC157696B91f3985bD7BCe4f  oracle 0x9587C0301FeA237B2f6045e2D50C8f9E6d1bf7B1
dry run (default). pass --broadcast to actually send.

[2026-11-06T22:01:35.326Z] block 55403132 — dry run
  · 2 series, chain time 2026-11-06T22:01:35.000Z
  · series 0 (CALL 0x11dd00… strike 99999999): not expired, expires 2026-11-13T21:30:35.000Z
  · series 1 (CALL 0x11dd00… strike 94999999): settled at 99999999, 3 holder(s) / 1 writer(s) scanned — all paid out
  nothing to do
```

Series 1 ran the full lifecycle on chain and is drained (`totalSupply == 0`,
`written[1][desk] == 0`); the keeper identifies it as finished rather than trying to
re-settle it. Series 0 expires 2026-11-13 and is correctly left alone.
