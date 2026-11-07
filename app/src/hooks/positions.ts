/* Pure position decoding for usePositions: no React, no wagmi, so the raw
   Series tuple + balanceOf + written -> UI row mapping can be checked against real
   chain values without a browser (see positions.selfcheck.ts).

   WeekendOptions model: one ERC-20 per series. A user can be a HOLDER (balanceOf > 0)
   and/or a WRITER (written[series][user] > 0) of the same series. A single row carries
   both legs so the Positions tab shows a wallet's full exposure to a series. */

import { formatUnits } from 'viem'
import { KIND, type OptionKind } from '../lib/pricing.ts'

/** Option amounts + underlying are 18dp; strike + premiums are 6dp quote units. */
export const AMOUNT_DECIMALS = 18
export const QUOTE_DECIMALS = 6

export interface Position {
  seriesId: number
  kind: OptionKind
  /** Strike in quote units (USD), e.g. 99.999999. */
  strike: number
  /** Unix seconds. */
  expiry: number
  /** The per-series option ERC-20. */
  token: `0x${string}`
  settled: boolean
  /** Holder balance, 18dp bigint — options the wallet can exercise/redeem/sell. */
  balance: bigint
  /** Writer position, 18dp bigint — options the wallet wrote and can close/claim. */
  written: bigint
  /** Live total supply of the series token, 18dp. */
  totalSupply: bigint
  /** Settlement price in quote units, valid only when `settled`. */
  settlePrice: number
}

/** The getSeries(id) return tuple, in Solidity order (WeekendOptions.sol:58). */
export type SeriesRecord = {
  underlying: `0x${string}`
  expiry: bigint
  kind: number
  strike: bigint
  token: `0x${string}`
  totalWritten: bigint
  poolUnderlying: bigint
  poolCash: bigint
  settled: boolean
  settlePrice: bigint
  supplyAtSettle: bigint
  holderUnderlying: bigint
  holderCash: bigint
  writerUnderlying: bigint
  writerCash: bigint
  writtenAtSettle: bigint
}

const num = (v: bigint, decimals: number) => Number(formatUnits(v, decimals))

/** getSeries(id) + holder balanceOf + written + totalSupply -> one table row. */
export function toPosition(
  seriesId: number,
  ser: SeriesRecord,
  balance: bigint,
  written: bigint,
  totalSupply: bigint,
): Position {
  return {
    seriesId,
    kind: (ser.kind === 1 ? KIND.PUT : KIND.CALL) as OptionKind,
    strike: num(ser.strike, QUOTE_DECIMALS),
    expiry: Number(ser.expiry),
    token: ser.token,
    settled: ser.settled,
    balance,
    written,
    totalSupply,
    settlePrice: num(ser.settlePrice, QUOTE_DECIMALS),
  }
}

/** A row with neither a holder balance nor a written leg is not the wallet's
 *  concern. Soonest expiry first, so the actionable row is on top. */
export function liveRows(rows: Position[]): Position[] {
  return rows.filter((p) => p.balance > 0n || p.written > 0n).sort((a, b) => a.expiry - b.expiry)
}
