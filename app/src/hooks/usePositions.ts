/* ============================================================================
   The user's ERC-1155 option positions, read from the chain.

   Positions used to live in a React useState array that only the buy handler
   appended to — so a reload wiped them and the panel lied ("No positions yet")
   about positions that provably exist on chain. This hook is the fix: it
   discovers positions from `OptionBought` logs and hydrates each one from
   `positions(id)` + `balanceOf(holder, id)`, so the panel is on-chain truth.
   ========================================================================= */

import { useCallback, useEffect, useState } from 'react'
import { createPublicClient, http } from 'viem'
import { baseSepolia } from 'viem/chains'
import { usePublicClient } from 'wagmi'
import { gapOptionsAppAbi } from '../lib/abi'
import { buildStrategy, type StrategyTuple } from '../lib/strategy'
import { liveRows, toPosition, type Position, type PositionRecord } from './positions'
import type { Deployment, MakerEntry } from '../lib/deployment'

/**
 * eth_getLogs needs its OWN endpoint. The app's transport (sepolia.base.org)
 * rejects any range wider than 200 blocks ("eth_getLogs is limited to a 200
 * range") and Alchemy's free tier caps it at 10 — neither can reach back to the
 * deploy block, and chunking a ~12k-block history into 200-block pages would be
 * ~60 requests per refresh. publicnode serves the whole range in one call and
 * sends `access-control-allow-origin: *`, so the browser can hit it directly.
 * This is exactly what contracts/script/settle-keeper.sh does (GAP_LOGS_RPC_URL).
 * Reads and writes still go through the wagmi client.
 */
const LOGS_RPC_URL =
  import.meta.env.VITE_LOGS_RPC_URL || 'https://base-sepolia-rpc.publicnode.com'

/** Scanning from 0 is rejected by every provider, so start at the app's deploy
 *  block. Overridable per-deployment (`deployBlock` in the deployment JSON) and
 *  per-environment, so a redeploy does not silently hide older positions. */
const DEFAULT_FROM_BLOCK = BigInt(import.meta.env.VITE_GAP_FROM_BLOCK || 55_300_000)

const logsClient = createPublicClient({ chain: baseSepolia, transport: http(LOGS_RPC_URL) })

export type { Position }

export interface PositionsState {
  positions: Position[]
  loading: boolean
  error: string | null
  /** Re-read logs + records. Call after a buy or settle receipt lands. */
  refetch: () => void
  /** The Strategy tuple whose hash matches, or undefined if no shipped maker does. */
  strategyFor: (hash: `0x${string}`) => StrategyTuple | undefined
}

export function usePositions(
  deployment: Deployment | null,
  deployed: boolean,
  holder: `0x${string}` | undefined,
): PositionsState {
  const client = usePublicClient()
  const [positions, setPositions] = useState<Position[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [strategies, setStrategies] = useState<Map<string, StrategyTuple>>(new Map())
  const [nonce, setNonce] = useState(0)
  const refetch = useCallback(() => setNonce((n) => n + 1), [])

  // `settle` takes the full Strategy struct but the Position record stores only
  // its hash, so index every shipped maker's tuple by what the app hashes it to
  // — the same trick settle-keeper.sh uses. hashStrategy is a pure view.
  useEffect(() => {
    if (!deployed || !deployment || !client) return
    let cancelled = false
    const app = deployment.gapOptionsApp as `0x${string}`
    // Older deployment JSON has no `makers` array; buildStrategy(d, undefined)
    // falls back to the single top-level maker at the default IV.
    const makers: (MakerEntry | undefined)[] = deployment.makers?.length
      ? deployment.makers
      : [undefined]
    void Promise.all(
      makers.map(async (m) => {
        const s = buildStrategy(deployment, m)
        const h = (await client.readContract({
          address: app,
          abi: gapOptionsAppAbi,
          functionName: 'hashStrategy',
          args: [s],
        })) as `0x${string}`
        return [h.toLowerCase(), s] as const
      }),
    )
      .then((entries) => {
        if (!cancelled) setStrategies(new Map(entries))
      })
      .catch(() => {
        if (!cancelled) setStrategies(new Map())
      })
    return () => {
      cancelled = true
    }
  }, [client, deployment, deployed])

  useEffect(() => {
    if (!deployed || !deployment || !client || !holder) {
      setPositions([])
      setError(null)
      return
    }
    let cancelled = false
    setLoading(true)
    void (async () => {
      try {
        const app = deployment.gapOptionsApp as `0x${string}`
        const logs = await logsClient.getContractEvents({
          address: app,
          abi: gapOptionsAppAbi,
          eventName: 'OptionBought',
          args: { to: holder },
          fromBlock: deployment.deployBlock ? BigInt(deployment.deployBlock) : DEFAULT_FROM_BLOCK,
          toBlock: 'latest',
        })
        // premium is only in the log; the Position record does not keep it.
        const premiums = new Map<bigint, bigint>()
        for (const l of logs) {
          if (l.args.positionId != null) premiums.set(l.args.positionId, l.args.premium ?? 0n)
        }
        // ponytail: one pair of reads per position, no multicall — a user has a
        // handful of these. Batch them if someone ever holds hundreds.
        const rows = await Promise.all(
          [...premiums.keys()].map(async (id) => {
            const [rec, balance] = await Promise.all([
              client.readContract({
                address: app,
                abi: gapOptionsAppAbi,
                functionName: 'positions',
                args: [id],
              }),
              client.readContract({
                address: app,
                abi: gapOptionsAppAbi,
                functionName: 'balanceOf',
                args: [holder, id],
              }),
            ])
            return toPosition(id, rec as PositionRecord, balance as bigint, premiums.get(id) ?? 0n)
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

  const strategyFor = useCallback(
    (hash: `0x${string}`) => strategies.get(hash.toLowerCase()),
    [strategies],
  )

  return { positions, loading, error, refetch, strategyFor }
}
