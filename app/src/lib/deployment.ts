// Runtime loader for the deployment addresses. The JSON lives in /public so a live
// deploy can overwrite app/public/deployments/base-sepolia.json WITHOUT a rebuild.
//
// Until a live deploy runs (gated on the user's contracts/.env), the core addresses
// (gapOptionsApp, nvdax, usdc, poolId) are empty strings / the zero poolId. The app
// detects this and degrades to read-only PREVIEW mode — it never crashes and never
// pretends fake addresses are real.

export const BASE_SEPOLIA_CHAIN_ID = 84532

/**
 * A maker who has shipped collateral into Aqua. Optional: the deploy script only
 * started writing this array recently, so every read must degrade to the single
 * top-level `maker` + default vol when it is absent.
 */
export interface MakerEntry {
  address: string
  /** Annualised IV as a WAD integer, e.g. "500000000000000000" for 50%. */
  volWad: string | number
  salt?: string
}

export interface Deployment {
  aqua: string
  gapOptionsApp: string
  /** The party that shipped the collateral. The Strategy tuple hashes against it. */
  maker: string
  nvdax: string
  usdc: string
  circleUsdc: string
  poolManager: string
  positionManager: string
  stateView: string
  poolId: string
  underlyingIsCurrency0: boolean
  // The GapTaker helper the UI routes buys through.
  gapTaker?: string
  /** Written by the deploy once makers ship. Absent on older deployment JSON. */
  makers?: MakerEntry[]
  /** Block the app was deployed in — where the OptionBought log scan starts.
   *  Absent on older JSON; usePositions falls back to a build-time constant. */
  deployBlock?: number | string
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
    isNonEmptyAddr(d.gapOptionsApp) &&
    isNonEmptyAddr(d.stateView) &&
    isNonEmptyAddr(d.usdc) &&
    isNonEmptyAddr(d.nvdax) &&
    typeof d.poolId === 'string' &&
    d.poolId.length === 66 &&
    d.poolId !== ZERO_POOL_ID
  )
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
