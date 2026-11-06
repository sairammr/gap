// Runtime loader for the deployment addresses. The JSON lives in /public so a live
// deploy can overwrite app/public/deployments/base-sepolia.json WITHOUT a rebuild.
//
// Until a live deploy runs (gated on the user's contracts/.env), the core addresses
// (gapOptionsApp, nvdax, usdc, poolId) are empty strings / the zero poolId. The app
// detects this and degrades to read-only PREVIEW mode — it never crashes and never
// pretends fake addresses are real.

export const BASE_SEPOLIA_CHAIN_ID = 84532

export interface Deployment {
  aqua: string
  gapOptionsApp: string
  nvdax: string
  usdc: string
  circleUsdc: string
  poolManager: string
  positionManager: string
  stateView: string
  poolId: string
  underlyingIsCurrency0: boolean
  // Optional: the GapTaker helper the UI routes buys through. Not written by the
  // current deploy script; absent until a taker helper is deployed.
  gapTaker?: string
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
