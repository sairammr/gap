/* Pure position decoding for usePositions: no React, no wagmi, so the raw
   `positions(id)` tuple -> UI row mapping can be checked against real chain
   values without a browser (see positions.selfcheck.ts). The panel showing
   "No positions yet" for a position that exists on chain is exactly the class
   of bug this file exists to make checkable. */

import { formatUnits } from 'viem'
import { KIND, type OptionKind } from '../lib/pricing.ts'

/** Strike, cap and size are WAD (1e18) on chain; premium is in quote units. */
export const PRICE_DECIMALS = 18
export const PREMIUM_DECIMALS = 6

export interface Position {
  /** Hex position id for real positions, `preview-xxxx` for local previews. */
  positionId: string
  /** False only for the local, not-on-chain preview rows. */
  onchain: boolean
  kind: OptionKind
  strike: number
  cap: number
  size: number
  /** Unix seconds. */
  expiry: number
  /** Premium actually paid, in quote units (USDC). */
  premium: number
  settled: boolean
  /** ERC-1155 balance still held. 0 => settled or transferred away. */
  balance: bigint
  /** The strategy this position hashes to — needed to rebuild `settle`'s tuple. */
  strategyHash?: `0x${string}`
}

/** The `positions(uint256)` return tuple, in Solidity order. */
export type PositionRecord = readonly [
  `0x${string}`, // strategyHash
  `0x${string}`, // maker
  `0x${string}`, // underlying
  `0x${string}`, // quote
  number, // kind (0 = CALL, 1 = PUT)
  bigint, // strike, WAD
  bigint, // cap, WAD
  bigint, // expiry, unix seconds
  bigint, // size, WAD
  boolean, // settled
  bigint, // capBacking, quote units
]

const num = (v: bigint, decimals: number) => Number(formatUnits(v, decimals))

/** `positions(id)` + `balanceOf` + the log's premium -> one table row. */
export function toPosition(
  id: bigint,
  rec: PositionRecord,
  balance: bigint,
  premium: bigint,
): Position {
  return {
    positionId: `0x${id.toString(16).padStart(64, '0')}`,
    onchain: true,
    kind: (rec[4] === 1 ? KIND.PUT : KIND.CALL) as OptionKind,
    strike: num(rec[5], PRICE_DECIMALS),
    cap: num(rec[6], PRICE_DECIMALS),
    size: num(rec[8], PRICE_DECIMALS),
    expiry: Number(rec[7]),
    premium: num(premium, PREMIUM_DECIMALS),
    settled: rec[9],
    balance,
    strategyHash: rec[0],
  }
}

/** A position with no balance left is settled or transferred away — not the
 *  holder's any more. Soonest expiry first, so the actionable row is on top. */
export function liveRows(rows: Position[]): Position[] {
  return rows.filter((p) => p.balance > 0n).sort((a, b) => a.expiry - b.expiry)
}
