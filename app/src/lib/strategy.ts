import type { Deployment, MakerQuote } from './deployment'

// The on-chain Strategy tuple. Field order is LOAD-BEARING: WeekendOptions.hashStrategy
// is keccak256(abi.encode(s)) and must equal the hash Aqua derived from the identical
// bytes the maker shipped. See WeekendOptions.sol:42 (struct Strategy) — there is
// deliberately no poolId/decimals; vol is the only competitive axis.
export const UNDERLYING_DECIMALS = 18
export const QUOTE_DECIMALS = 6

/** `type(uint64).max` — what `DeployDemo._ownStrategy` ships. */
export const MAX_SECONDS_TO_EXPIRY = (2n ** 64n - 1n) as bigint

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
 * A tuple for the `quotePremium` READ, and nothing else.
 *
 * `WeekendOptions.quotePremium(s, seriesId, amount)` reads exactly ONE field off
 * `s` — `volWad` — and derives everything else from the series. So this carries the
 * quote's vol, which is the number the taker is actually being priced at, and fills
 * the rest to match the desk's own shipped strategy so the tuple is at least a
 * coherent object rather than a fiction.
 *
 * It is deliberately NOT used for anything that hashes the tuple. `makerCapacity`
 * does (`hashStrategy(s)` keys the Aqua ledger), and no tuple reconstructable from
 * this JSON hashes to something that was shipped — see `Deployment.ownStrategyHash`
 * and `lib/capacity.ts`, which reads the ledger by its real hash instead.
 */
export function pricingStrategy(d: Deployment, q: MakerQuote): StrategyTuple {
  return {
    app: d.weekendOptions as `0x${string}`,
    maker: q.maker as `0x${string}`,
    underlying: d.nvdax as `0x${string}`,
    quote: d.usdc as `0x${string}`,
    volWad: BigInt(q.volWad),
    minPremiumBps: q.minPremiumBps,
    maxSecondsToExpiry: MAX_SECONDS_TO_EXPIRY,
    salt: q.salt as `0x${string}`,
  }
}

/** WAD vol -> the plain number the client-side preview wants. */
export const volFromWad = (wad: bigint): number => Number(wad) / 1e18

/** WAD vol -> percent string for display, e.g. 600000000000000000n -> "60". */
export const volPct = (wad: bigint | string | number): string =>
  (Number(BigInt(wad)) / 1e16).toFixed(0)
