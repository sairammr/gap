import type { Deployment } from './deployment'
import { parseUnits } from 'viem'

// Strategy constants mirror contracts/script/Ship.s.sol + Demo.s.sol so the UI's
// Strategy tuple hashes to the maker's shipped strategy. The maker address is set
// at ship time; here it comes from the deployment (or the connected wallet for a
// self-maker demo). volWad default 0.5e18 (50% annualised IV) matches the scripts.
export const UNDERLYING_DECIMALS = 18
export const QUOTE_DECIMALS = 6
export const DEFAULT_VOL_WAD = parseUnits('0.5', 18) // 0.5e18
export const DEFAULT_SALT = ('0x' + '00'.repeat(31) + '01') as `0x${string}` // bytes32(uint256(1))

export interface StrategyTuple {
  app: `0x${string}`
  maker: `0x${string}`
  underlying: `0x${string}`
  quote: `0x${string}`
  poolId: `0x${string}`
  underlyingIsCurrency0: boolean
  underlyingDecimals: number
  quoteDecimals: number
  volWad: bigint
  salt: `0x${string}`
}

/**
 * Build the on-chain Strategy tuple from the deployment + a maker address.
 * Returns null if the deployment is not populated enough to form one.
 */
export function buildStrategy(d: Deployment, maker: `0x${string}`): StrategyTuple {
  return {
    app: d.gapOptionsApp as `0x${string}`,
    maker,
    underlying: d.nvdax as `0x${string}`,
    quote: d.usdc as `0x${string}`,
    poolId: d.poolId as `0x${string}`,
    underlyingIsCurrency0: d.underlyingIsCurrency0,
    underlyingDecimals: UNDERLYING_DECIMALS,
    quoteDecimals: QUOTE_DECIMALS,
    volWad: DEFAULT_VOL_WAD,
    salt: DEFAULT_SALT,
  }
}

/** Default annualised vol as a plain number, for the client-side preview. */
export const DEFAULT_VOL = 0.5
