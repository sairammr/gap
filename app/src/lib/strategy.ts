import type { Deployment, MakerEntry } from './deployment'
import { parseUnits } from 'viem'

// Strategy constants mirror contracts/script/Ship.s.sol + Demo.s.sol so the UI's
// Strategy tuple hashes to the maker's shipped strategy. The maker is the party
// that SHIPPED the collateral, recorded in the deployment JSON — never the
// connected wallet, which is the taker. volWad default 0.5e18 (50% annualised IV)
// matches the scripts.
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
 * Build the on-chain Strategy tuple from the deployment.
 *
 * `maker` overrides the maker identity + their pricing axis (volWad, salt). Pass
 * `deployment.makers?.[0]` to quote a listed maker, or — in the Earn view only,
 * where the connected wallet IS the maker — the wallet's own entry. Omitted, it
 * falls back to the deployment's single `maker` at the default 50% IV.
 */
export function buildStrategy(d: Deployment, maker?: MakerEntry): StrategyTuple {
  return {
    app: d.gapOptionsApp as `0x${string}`,
    maker: (maker?.address ?? d.maker) as `0x${string}`,
    underlying: d.nvdax as `0x${string}`,
    quote: d.usdc as `0x${string}`,
    poolId: d.poolId as `0x${string}`,
    underlyingIsCurrency0: d.underlyingIsCurrency0,
    underlyingDecimals: UNDERLYING_DECIMALS,
    quoteDecimals: QUOTE_DECIMALS,
    volWad: maker ? BigInt(maker.volWad) : DEFAULT_VOL_WAD,
    salt: (maker?.salt ?? DEFAULT_SALT) as `0x${string}`,
  }
}

/** WAD vol -> the plain number the client-side preview wants. */
export const volFromWad = (wad: bigint): number => Number(wad) / 1e18

/** Default annualised vol as a plain number, for the client-side preview. */
export const DEFAULT_VOL = 0.5
