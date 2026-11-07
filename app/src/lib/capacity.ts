/* ============================================================================
   How much a resting quote can actually fill.

   This is the number the ticket needs, and it is NOT one contract read. Three
   independent ceilings bind an ask, and the smallest wins:

     1. THE AQUA LEDGER on the shipped order. `Aqua.ship` is immutable, so the
        option-token leg of `(desk, router, strategyHash)` is a PERMANENT cumulative
        cap on everything that order can ever sell. Minting does not credit it —
        `AQUA.pull` is a real transferFrom, so the ledger only ever counts down.
     2. THE DESK'S SHORT CAP. `maxShort[seriesId]` is checked against the cumulative
        `written[seriesId][desk]` AFTER each write, so the headroom is the difference.
     3. THE COVER ITSELF. The desk can only write what its own core-protocol strategy
        can back: `min(rawBalances(desk, weekendOptions, ownStrategyHash, coverToken),
        coverToken.balanceOf(desk))` — Aqua's books and the real wallet, whichever is
        smaller, because `pull` is a transferFrom out of that wallet.

   Inventory sits in front of (2) and (3): `_mintShortfall` spends option tokens the
   desk already holds before it mints anything, so those cost no cover and no short.

   WHY NOT `makerCapacity`. The core exposes `makerCapacity(Strategy, token)`, which
   is exactly ceiling (3) — but it takes the TUPLE and hashes it to key the ledger.
   The deployment JSON does not carry the own strategy's fields (volWad = VOL_SELF,
   minPremiumBps = 0, maxSecondsToExpiry = uint64 max, salt = 0), only the finished
   `ownStrategyHash`. Any tuple rebuilt from the ask's parameters hashes to something
   that was never shipped, and the read comes back 0 against a desk holding thousands
   of NVDAx. Reading the ledger by its real hash cannot drift that way.
   ========================================================================= */

import { aquaAbi, deskAbi, erc20Abi, optionTokenAbi, weekendOptionsAbi } from './abi'
import type { Deployment, MakerQuote } from './deployment'
import { KIND, type OptionKind } from './pricing'

/** Minimal structural type for the viem/wagmi public client reads used here. */
export interface Reader {
  readContract: (args: {
    address: `0x${string}`
    abi: readonly unknown[]
    functionName: string
    args?: readonly unknown[]
  }) => Promise<unknown>
}

export interface AskCapacity {
  side: 'ask'
  /** Options this quote can still sell, 18dp. The min of all three ceilings. */
  options: bigint
  /** Ceiling 1 — what is left on the shipped order's Aqua ledger. */
  ledgerOptions: bigint
  /** Ceiling 2 — `maxShort - written`, in options. */
  shortHeadroom: bigint
  /** Ceiling 3 — cover the desk can really back, expressed in options. */
  coverOptions: bigint
  /** Option tokens already in the desk's wallet; spent before anything is minted. */
  inventory: bigint
  /** The cover token and what the desk has of it (for display). */
  coverToken: `0x${string}`
  coverCommitted: bigint
  coverWallet: bigint
}

export interface BidCapacity {
  side: 'bid'
  /** USDC the desk can still spend buying options back, 6dp. */
  usdc: bigint
  ledgerUsdc: bigint
  walletUsdc: bigint
}

export type Capacity = AskCapacity | BidCapacity

const min = (...xs: bigint[]) => xs.reduce((a, b) => (a < b ? a : b))

/**
 * Cover -> options.
 *
 * CALL cover is the underlying 1:1 (`collateralFor` returns `amount`), so an 18dp
 * cover balance IS an option count. PUT cover is `ceil(amount * strike / 1e18)` in
 * 6dp quote, so invert it — flooring, because a partial option cannot be written.
 */
function coverToOptions(kind: OptionKind, cover: bigint, strikeRaw: bigint): bigint {
  if (kind === KIND.CALL) return cover
  if (strikeRaw === 0n) return 0n
  return (cover * 10n ** 18n) / strikeRaw
}

/**
 * Read every ceiling on one resting quote.
 *
 * `strikeRaw` and `kind` come from `getSeries` (6dp strike, never the float the UI
 * displays) so the PUT conversion stays exact.
 */
export async function readCapacity(
  client: Reader,
  d: Deployment,
  q: MakerQuote,
  kind: OptionKind,
  strikeRaw: bigint,
): Promise<Capacity> {
  const aqua = d.aqua as `0x${string}`
  const desk = d.desk as `0x${string}`
  const router = d.swapVmRouter as `0x${string}`
  const app = d.weekendOptions as `0x${string}`
  const usdc = d.usdc as `0x${string}`
  const hash = q.strategyHash as `0x${string}`

  if (q.side === 'bid') {
    const [ledger, wallet] = await Promise.all([
      client.readContract({
        address: aqua,
        abi: aquaAbi,
        functionName: 'rawBalances',
        args: [desk, router, hash, usdc],
      }) as Promise<readonly [bigint, number]>,
      client.readContract({
        address: usdc,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [desk],
      }) as Promise<bigint>,
    ])
    const ledgerUsdc = ledger[0]
    return { side: 'bid', usdc: min(ledgerUsdc, wallet), ledgerUsdc, walletUsdc: wallet }
  }

  const coverToken = (kind === KIND.CALL ? d.nvdax : usdc) as `0x${string}`
  const optionToken = q.optionToken as `0x${string}`
  const ownHash = d.ownStrategyHash as `0x${string}`

  const [ledger, cover, coverWallet, inventory, maxShort, written] = await Promise.all([
    client.readContract({
      address: aqua,
      abi: aquaAbi,
      functionName: 'rawBalances',
      args: [desk, router, hash, optionToken],
    }) as Promise<readonly [bigint, number]>,
    client.readContract({
      address: aqua,
      abi: aquaAbi,
      functionName: 'rawBalances',
      args: [desk, app, ownHash, coverToken],
    }) as Promise<readonly [bigint, number]>,
    client.readContract({
      address: coverToken,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [desk],
    }) as Promise<bigint>,
    client.readContract({
      address: optionToken,
      abi: optionTokenAbi,
      functionName: 'balanceOf',
      args: [desk],
    }) as Promise<bigint>,
    client.readContract({
      address: desk,
      abi: deskAbi,
      functionName: 'maxShort',
      args: [BigInt(q.seriesId)],
    }) as Promise<bigint>,
    client.readContract({
      address: app,
      abi: weekendOptionsAbi,
      functionName: 'written',
      args: [BigInt(q.seriesId), desk],
    }) as Promise<bigint>,
  ])

  const ledgerOptions = ledger[0]
  const coverCommitted = cover[0]
  // `pull` is a transferFrom out of the desk wallet, so the books never beat reality.
  const coverBackable = min(coverCommitted, coverWallet)
  const coverOptions = coverToOptions(kind, coverBackable, strikeRaw)
  const shortHeadroom = maxShort > written ? maxShort - written : 0n

  // Inventory is spent before minting, so it is additive to what can still be minted,
  // then the whole lot is still capped by the immutable shipped ledger.
  const mintable = min(coverOptions, shortHeadroom)
  const options = min(ledgerOptions, inventory + mintable)

  return {
    side: 'ask',
    options,
    ledgerOptions,
    shortHeadroom,
    coverOptions,
    inventory,
    coverToken,
    coverCommitted,
    coverWallet,
  }
}
