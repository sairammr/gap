/* ============================================================================
   The wallet's WeekendOptions positions, read from the chain.

   WeekendOptions is one ERC-20 per series, so there is no ERC-1155 positions(id)
   anymore. A wallet's exposure to a series has two legs: a HOLDER balance
   (OptionToken.balanceOf, the options it can exercise/redeem/sell) and a WRITER
   amount (written[series][wallet], the cover it posted and can close/claim).

   Discovery is a direct walk, not a log scan: seriesCount() -> getSeries(i), then
   per series read balanceOf(holder) + written(i, holder) + totalSupply. Series
   are few and dense (ids 0..count-1), so this is a handful of reads and always
   on-chain truth — a reload can't lose a position the chain still holds.

   Logs are used only for the History tab (OptionWritten / Exercised), which still
   needs the wide-range endpoint below.
   ========================================================================= */

import { useCallback, useEffect, useState } from 'react'
import { createPublicClient, http } from 'viem'
import { baseSepolia } from 'viem/chains'
import { usePublicClient } from 'wagmi'
import { deskAbi, optionTokenAbi, oracleAbi, weekendOptionsAbi } from '../lib/abi'
import { liveRows, toPosition, type Position, type SeriesRecord } from './positions'
import type { Deployment } from '../lib/deployment'

/**
 * eth_getLogs needs its OWN endpoint. The app's transport (sepolia.base.org)
 * rejects any range wider than 200 blocks ("eth_getLogs is limited to a 200
 * range") and Alchemy's free tier caps it at 10 — neither can reach back to the
 * deploy block. publicnode is the widest free one and sends
 * `access-control-allow-origin: *`, so the browser can hit it directly. Reads and
 * writes still go through the wagmi client; only the history log scan uses this.
 */
const LOGS_RPC_URL =
  import.meta.env.VITE_LOGS_RPC_URL || 'https://base-sepolia-rpc.publicnode.com'

/**
 * publicnode's own ceiling, and it is NOT unlimited — a wider request comes back
 * `-32701: exceed maximum block range: 50000` and the whole History tab silently
 * rendered empty, because one rejected request failed all four scans at once.
 * Every scan below is therefore chunked.
 */
const MAX_LOG_RANGE = 45_000n

/** How far back to look. ~10 windows is several weeks of Base blocks — far more
 *  than a testnet deployment's life, and bounded so a cold load cannot hang. */
const MAX_WINDOWS = 10

/** Scanning from 0 is rejected by every provider, so start at the deploy block.
 *  Overridable per-deployment (`deployBlock`) and per-environment. */
const DEFAULT_FROM_BLOCK = BigInt(import.meta.env.VITE_GAP_FROM_BLOCK || 55_300_000)

const logsClient = createPublicClient({ chain: baseSepolia, transport: http(LOGS_RPC_URL) })

/** The shape every scanned log is read back as — only the fields History uses. */
interface RawLog {
  args: Record<string, bigint | undefined>
  blockNumber: bigint | null
  transactionHash: string | null
}

/** One `getContractEvents` call, split into windows the endpoint will accept.
 *  Newest window first, so the rows that matter land even if an older one fails. */
async function scanChunked(
  address: `0x${string}`,
  abi: readonly unknown[],
  eventName: string,
  args: Record<string, unknown>,
  fromBlock: bigint,
  latest: bigint,
): Promise<RawLog[]> {
  const out: RawLog[] = []
  let hi = latest
  for (let i = 0; i < MAX_WINDOWS && hi >= fromBlock; i++) {
    const span = hi - MAX_LOG_RANGE + 1n
    const lo = span > fromBlock ? span : fromBlock
    try {
      const logs = await logsClient.getContractEvents({
        address,
        abi,
        eventName,
        args,
        fromBlock: lo,
        toBlock: hi,
      } as never)
      out.push(...(logs as unknown as RawLog[]))
    } catch {
      // A window the endpoint refuses is skipped, never fatal: a partial history
      // beats the empty table a single thrown request used to produce.
    }
    if (lo === fromBlock) break
    hi = lo - 1n
  }
  return out
}

export type { Position }

/** One historical event, flattened for the History tab. */
export interface HistoryRow {
  kind: 'bought' | 'sold' | 'exercised' | 'redeemed'
  seriesId: number
  /** Options, 18dp. */
  amount: bigint
  /** USDC moved, 6dp: premium paid (bought), proceeds (sold), payout (redeemed). */
  quoteAmount: bigint
  blockNumber: bigint
  txHash: `0x${string}`
}

export interface PositionsState {
  positions: Position[]
  history: HistoryRow[]
  loading: boolean
  error: string | null
  /** Re-read series + balances. Call after a trade/exercise/settle receipt lands. */
  refetch: () => void
}

export function usePositions(
  deployment: Deployment | null,
  deployed: boolean,
  holder: `0x${string}` | undefined,
): PositionsState {
  const client = usePublicClient()
  const [positions, setPositions] = useState<Position[]>([])
  const [history, setHistory] = useState<HistoryRow[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [nonce, setNonce] = useState(0)
  const refetch = useCallback(() => setNonce((n) => n + 1), [])

  // Positions: walk every series, read both legs for this holder.
  useEffect(() => {
    if (!deployed || !deployment || !client || !holder) {
      setPositions([])
      setError(null)
      return
    }
    let cancelled = false
    setLoading(true)
    const app = deployment.weekendOptions as `0x${string}`
    void (async () => {
      try {
        const count = (await client.readContract({
          address: app,
          abi: weekendOptionsAbi,
          functionName: 'seriesCount',
        })) as bigint

        const ids = Array.from({ length: Number(count) }, (_, i) => i)
        const rows = await Promise.all(
          ids.map(async (id) => {
            const ser = (await client.readContract({
              address: app,
              abi: weekendOptionsAbi,
              functionName: 'getSeries',
              args: [BigInt(id)],
            })) as unknown as SeriesRecord
            const [balance, written, totalSupply, priceRecorded] = await Promise.all([
              client.readContract({
                address: ser.token,
                abi: optionTokenAbi,
                functionName: 'balanceOf',
                args: [holder],
              }) as Promise<bigint>,
              client.readContract({
                address: app,
                abi: weekendOptionsAbi,
                functionName: 'written',
                args: [BigInt(id), holder],
              }) as Promise<bigint>,
              client.readContract({
                address: ser.token,
                abi: optionTokenAbi,
                functionName: 'totalSupply',
              }) as Promise<bigint>,
              // `settle` is gated on this, so the row needs it to know which button
              // to offer. Already-settled series never ask again.
              ser.settled
                ? Promise.resolve(true)
                : (client.readContract({
                    address: deployment.oracle as `0x${string}`,
                    abi: oracleAbi,
                    functionName: 'recorded',
                    args: [ser.underlying, ser.expiry],
                  }) as Promise<boolean>),
            ])
            return toPosition(id, ser, balance, written, totalSupply, priceRecorded)
          }),
        )
        if (cancelled) return
        setPositions(liveRows(rows))
        setError(null)
      } catch (e) {
        if (cancelled) return
        setPositions([])
        setError(e instanceof Error ? e.message.split('\n')[0] : 'position scan failed')
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [client, deployment, deployed, holder, nonce])

  /* History.
   *
   * NOT `OptionWritten`. On the Aqua path the taker never appears in it: the desk
   * mints to ITSELF inside `preTransferOut` (`buyOption(..., to = address(this))`)
   * and `AQUA.pull` then moves the fresh tokens out, so `OptionWritten.to` is always
   * the desk. Filtering it by the connected wallet returns an empty list for someone
   * who has definitely just bought — which is exactly what it did.
   *
   * The events that name a taker are the desk's own `Sold` / `BoughtBack`, both with
   * `taker` indexed. Exercise and redemption stay on the core, keyed by `holder`.
   */
  useEffect(() => {
    if (!deployed || !deployment || !holder) {
      setHistory([])
      return
    }
    let cancelled = false
    const app = deployment.weekendOptions as `0x${string}`
    const desk = deployment.desk as `0x${string}`
    const fromBlock = deployment.deployBlock ? BigInt(deployment.deployBlock) : DEFAULT_FROM_BLOCK
    void (async () => {
      try {
        const latest = await logsClient.getBlockNumber()
        const [bought, sold, exercised, redeemed] = await Promise.all([
          scanChunked(desk, deskAbi, 'Sold', { taker: holder }, fromBlock, latest),
          scanChunked(desk, deskAbi, 'BoughtBack', { taker: holder }, fromBlock, latest),
          scanChunked(app, weekendOptionsAbi, 'Exercised', { holder }, fromBlock, latest),
          scanChunked(app, weekendOptionsAbi, 'Redeemed', { holder }, fromBlock, latest),
        ])
        if (cancelled) return
        const at = (l: { blockNumber: bigint | null; transactionHash: string | null }) => ({
          blockNumber: l.blockNumber ?? 0n,
          txHash: (l.transactionHash ?? '0x') as `0x${string}`,
        })
        const rows: HistoryRow[] = [
          // Desk `Sold`: amountOut is the options the taker received, amountIn the USDC paid.
          ...bought.map((l) => ({
            kind: 'bought' as const,
            seriesId: Number(l.args.seriesId ?? 0n),
            amount: l.args.amountOut ?? 0n,
            quoteAmount: l.args.amountIn ?? 0n,
            ...at(l),
          })),
          // Desk `BoughtBack`: amountIn is the options delivered, amountOut the USDC received.
          ...sold.map((l) => ({
            kind: 'sold' as const,
            seriesId: Number(l.args.seriesId ?? 0n),
            amount: l.args.amountIn ?? 0n,
            quoteAmount: l.args.amountOut ?? 0n,
            ...at(l),
          })),
          ...exercised.map((l) => ({
            kind: 'exercised' as const,
            seriesId: Number(l.args.seriesId ?? 0n),
            amount: l.args.amount ?? 0n,
            quoteAmount: 0n,
            ...at(l),
          })),
          ...redeemed.map((l) => ({
            kind: 'redeemed' as const,
            seriesId: Number(l.args.seriesId ?? 0n),
            amount: l.args.amount ?? 0n,
            quoteAmount: l.args.outC ?? 0n,
            ...at(l),
          })),
        ].sort((a, b) => Number(b.blockNumber - a.blockNumber))
        setHistory(rows)
      } catch {
        if (!cancelled) setHistory([])
      }
    })()
    return () => {
      cancelled = true
    }
  }, [deployment, deployed, holder, nonce])

  return { positions, history, loading, error, refetch }
}
