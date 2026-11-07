// Runtime loader for the deployment addresses. The JSON lives in /public so a live
// deploy can overwrite app/public/deployments/base-sepolia.json WITHOUT a rebuild.
//
// This is the WeekendOptions product on Base Sepolia. The authoritative source is
// contracts/deployments/base-sepolia.json — copied here verbatim. The buy/sell path
// is the real AquaSwapVMRouter (WeekendTaker was never deployed), so the app routes
// fills through `swapVmRouter` using orders built from the shipped strategy params.
//
// Until a real deploy has filled these in, the core addresses (weekendOptions, nvdax,
// usdc, poolId) can be empty. The app detects this and degrades to read-only PREVIEW
// mode — it never crashes and never pretends fake addresses are real.

export const BASE_SEPOLIA_CHAIN_ID = 84532

export const UNDERLYING_DECIMALS = 18
export const QUOTE_DECIMALS = 6

/** ASK = taker buys options off the maker. BID = taker sells options into the maker. */
export type Side = 'ask' | 'bid'

/**
 * One shipped maker quote — a resting order. Each maps 1:1 to a strategy the desk
 * shipped into Aqua, identified by its on-chain strategyHash. The order bytes the
 * router fills are rebuilt from these fields (see lib/orders.ts), so they must match
 * what was shipped exactly or the fill reverts.
 */
export interface MakerQuote {
  /** Stable key for React lists. */
  key: string
  side: Side
  seriesId: number
  /** The desk (maker) that shipped the cover. */
  maker: string
  /** Per-series option ERC-20. */
  optionToken: string
  /** Annualised IV, WAD integer string, e.g. "600000000000000000" for 60%. */
  volWad: string
  minPremiumBps: number
  /** uint40 unix seconds — the order's SwapVM deadline. */
  deadline: number
  /** bytes32 order salt. */
  salt: string
  /** The strategyHash Aqua recorded at ship time — the fill gate checks against this. */
  strategyHash: string
}

export interface Deployment {
  aqua: string
  weekendOptions: string
  /** The SwapVM router that fills orders. The buy/sell path. */
  swapVmRouter: string
  /** The maker: WeekendDesk (ships cover, implements IMakerHooks). */
  desk: string
  /** Extruction pricing target: WeekendPricer. */
  pricer: string
  /** V4SpotOracle behind IPriceOracle. */
  oracle: string
  optionTokenFactory: string
  nvdax: string
  usdc: string
  circleUsdc: string
  poolManager: string
  positionManager: string
  stateView: string
  poolId: string
  underlyingIsCurrency0: boolean
  /** The top-level maker EOA that funds the desk (used for the Earn/ship view). */
  maker: string
  /** Block the contracts were deployed at — the history log scan starts here. */
  deployBlock?: number
  /**
   * The desk's OWN core-protocol strategy hash — `hashStrategy` of the tuple the
   * desk ships to `weekendOptions` (not to the router) and buys from itself with.
   *
   * This is NOT derivable from the fields below. The own strategy carries
   * `volWad = VOL_SELF`, `minPremiumBps = 0`, `maxSecondsToExpiry = type(uint64).max`
   * and `salt = 0` (DeployDemo.s.sol `_ownStrategy`), none of which are written to
   * this JSON — only the finished hash is. Reconstructing a tuple from the ASK
   * parameters instead produces a hash nothing was ever shipped under, and every
   * capacity read against it returns 0. Use this hash.
   */
  ownStrategyHash: string

  /**
   * Every resting quote the book should show. Written by `contracts/script/SeedBook.s.sol`
   * and verified against Aqua by `scripts/seed-quotes.ts`. When present it REPLACES the
   * three legacy per-key quotes below, which could only ever describe the deploy's own
   * three ships and cannot grow with the book.
   */
  quotes?: MakerQuote[]

  // --- series 0 (weekend, long-dated ask) ---
  seriesId: number
  strike: number
  expiry: number
  optionToken: string
  askVolWad: string | number
  askMinPremiumBps: number
  askSalt: string
  askDeadline: number
  askStrategyHash: string

  // --- series 1 (short-dated, two-sided ask + bid) ---
  shortSeriesId: number
  shortStrike: number
  shortExpiry: number
  shortOptionToken: string
  shortAskVolWad: string | number
  shortAskSalt: string
  shortAskStrategyHash: string
  shortBidVolWad: string | number
  shortBidSalt: string
  shortBidStrategyHash: string
  shortMinPremiumBps: number
}

const ZERO_POOL_ID = '0x0000000000000000000000000000000000000000000000000000000000000000'

function isNonEmptyAddr(v: string | undefined): boolean {
  return (
    typeof v === 'string' &&
    /^0x[0-9a-fA-F]{40}$/.test(v) &&
    v.toLowerCase() !== '0x0000000000000000000000000000000000000000'
  )
}

/** True when the deployment has the addresses needed to read on-chain (app + pool). */
export function isDeployed(d: Deployment | null): d is Deployment {
  return (
    !!d &&
    isNonEmptyAddr(d.weekendOptions) &&
    isNonEmptyAddr(d.stateView) &&
    isNonEmptyAddr(d.usdc) &&
    isNonEmptyAddr(d.nvdax) &&
    typeof d.poolId === 'string' &&
    d.poolId.length === 66 &&
    d.poolId !== ZERO_POOL_ID
  )
}

/** True when a fill can be routed — the router must also be present. */
export function canTrade(d: Deployment | null): d is Deployment {
  return isDeployed(d) && isNonEmptyAddr(d.swapVmRouter) && isNonEmptyAddr(d.desk)
}

/**
 * The shipped maker quotes, derived from the flat deployment fields so the orders
 * panel has rows on first paint without a log scan. Aqua `Shipped` logs refine this
 * later (new makers), but these three are the ones the deploy shipped.
 */
export function makerQuotes(d: Deployment): MakerQuote[] {
  // The seeded ladder is authoritative when it is there.
  if (Array.isArray(d.quotes) && d.quotes.length > 0) {
    return d.quotes.filter((q) => isNonEmptyAddr(q.optionToken))
  }

  const quotes: MakerQuote[] = [
    {
      key: `ask-${d.seriesId}`,
      side: 'ask',
      seriesId: d.seriesId,
      maker: d.desk,
      optionToken: d.optionToken,
      volWad: String(d.askVolWad),
      minPremiumBps: d.askMinPremiumBps,
      deadline: d.askDeadline,
      salt: d.askSalt,
      strategyHash: d.askStrategyHash,
    },
    {
      key: `ask-${d.shortSeriesId}`,
      side: 'ask',
      seriesId: d.shortSeriesId,
      maker: d.desk,
      optionToken: d.shortOptionToken,
      volWad: String(d.shortAskVolWad),
      minPremiumBps: d.shortMinPremiumBps,
      deadline: d.askDeadline,
      salt: d.shortAskSalt,
      strategyHash: d.shortAskStrategyHash,
    },
    {
      key: `bid-${d.shortSeriesId}`,
      side: 'bid',
      seriesId: d.shortSeriesId,
      maker: d.desk,
      optionToken: d.shortOptionToken,
      volWad: String(d.shortBidVolWad),
      minPremiumBps: d.shortMinPremiumBps,
      deadline: d.askDeadline,
      salt: d.shortBidSalt,
      strategyHash: d.shortBidStrategyHash,
    },
  ]
  return quotes.filter((q) => isNonEmptyAddr(q.optionToken))
}

export async function loadDeployment(): Promise<Deployment | null> {
  try {
    const base = import.meta.env.BASE_URL || '/'
    const res = await fetch(`${base}deployments/base-sepolia.json`, { cache: 'no-store' })
    if (!res.ok) return null
    return (await res.json()) as Deployment
  } catch {
    return null
  }
}
