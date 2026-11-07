import type { Deployment, MakerQuote } from './deployment'

// The on-chain Strategy tuple. Field order is LOAD-BEARING: WeekendOptions.hashStrategy
// is keccak256(abi.encode(s)) and must equal the hash Aqua derived from the identical
// bytes the maker shipped. See WeekendOptions.sol:42 (struct Strategy) — there is
// deliberately no poolId/decimals; vol is the only competitive axis.
export const UNDERLYING_DECIMALS = 18
export const QUOTE_DECIMALS = 6

export interface StrategyTuple {
  app: `0x${string}`
  maker: `0x${string}`
  underlying: `0x${string}`
  quote: `0x${string}`
  volWad: bigint
  minPremiumBps: number
  maxSecondsToExpiry: bigint
  salt: `0x${string}`
}

/**
 * Build the on-chain Strategy tuple for a shipped maker quote.
 *
 * `maxSecondsToExpiry` is derived from the quote's series deadline: the shipped order
 * was calibrated for that tenor, and `_buyOption` reverts `TenorTooLong` if a series'
 * remaining life exceeds it. We use a generous bound (the order deadline) so a fill
 * near expiry still clears; the maker's real protection is the vol they shipped.
 */
export function buildStrategy(d: Deployment, q: MakerQuote): StrategyTuple {
  return {
    app: d.weekendOptions as `0x${string}`,
    maker: q.maker as `0x${string}`,
    underlying: d.nvdax as `0x${string}`,
    quote: d.usdc as `0x${string}`,
    volWad: BigInt(q.volWad),
    minPremiumBps: q.minPremiumBps,
    maxSecondsToExpiry: BigInt(q.deadline),
    salt: q.salt as `0x${string}`,
  }
}

/** WAD vol -> the plain number the client-side preview wants. */
export const volFromWad = (wad: bigint): number => Number(wad) / 1e18

/** WAD vol -> percent string for display, e.g. 600000000000000000n -> "60". */
export const volPct = (wad: bigint | string | number): string =>
  (Number(BigInt(wad)) / 1e16).toFixed(0)
