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
import { optionTokenAbi, weekendOptionsAbi } from '../lib/abi'
import { liveRows, toPosition, type Position, type SeriesRecord } from './positions'
import type { Deployment } from '../lib/deployment'

/**
 * eth_getLogs needs its OWN endpoint. The app's transport (sepolia.base.org)
 * rejects any range wider than 200 blocks ("eth_getLogs is limited to a 200
 * range") and Alchemy's free tier caps it at 10 — neither can reach back to the
 * deploy block. publicnode serves the whole range in one call and sends
 * `access-control-allow-origin: *`, so the browser can hit it directly. This is
 * exactly what contracts/script/settle-keeper.sh does. Reads and writes still go
 * through the wagmi client; only the history log scan uses this.
 */
const LOGS_RPC_URL =
  import.meta.env.VITE_LOGS_RPC_URL || 'https://base-sepolia-rpc.publicnode.com'

/** Scanning from 0 is rejected by every provider, so start at the deploy block.
 *  Overridable per-deployment (`deployBlock`) and per-environment. */
const DEFAULT_FROM_BLOCK = BigInt(import.meta.env.VITE_GAP_FROM_BLOCK || 55_300_000)

const logsClient = createPublicClient({ chain: baseSepolia, transport: http(LOGS_RPC_URL) })

export type { Position }

/** One historical event, flattened for the History tab. */
export interface HistoryRow {
  kind: 'written' | 'exercised'
  seriesId: number
  amount: bigint
  /** OptionWritten only: premium paid, 6dp quote units. */
  premium: bigint
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
            const [balance, written, totalSupply] = await Promise.all([
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
            ])
            return toPosition(id, ser, balance, written, totalSupply)
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

  // History: OptionWritten(to=holder) + Exercised(holder) over the full range.
  useEffect(() => {
    if (!deployed || !deployment || !holder) {
      setHistory([])
      return
    }
    let cancelled = false
    const app = deployment.weekendOptions as `0x${string}`
    const fromBlock = deployment.deployBlock ? BigInt(deployment.deployBlock) : DEFAULT_FROM_BLOCK
    void (async () => {
      try {
        const [written, exercised] = await Promise.all([
          logsClient.getContractEvents({
            address: app,
            abi: weekendOptionsAbi,
            eventName: 'OptionWritten',
            args: { to: holder },
            fromBlock,
            toBlock: 'latest',
          }),
          logsClient.getContractEvents({
            address: app,
            abi: weekendOptionsAbi,
            eventName: 'Exercised',
            args: { holder },
            fromBlock,
            toBlock: 'latest',
          }),
        ])
        if (cancelled) return
        const rows: HistoryRow[] = [
          ...written.map((l) => ({
            kind: 'written' as const,
            seriesId: Number(l.args.seriesId ?? 0n),
            amount: l.args.amount ?? 0n,
            premium: l.args.premium ?? 0n,
            blockNumber: l.blockNumber ?? 0n,
            txHash: l.transactionHash as `0x${string}`,
          })),
          ...exercised.map((l) => ({
            kind: 'exercised' as const,
            seriesId: Number(l.args.seriesId ?? 0n),
            amount: l.args.amount ?? 0n,
            premium: 0n,
            blockNumber: l.blockNumber ?? 0n,
            txHash: l.transactionHash as `0x${string}`,
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
