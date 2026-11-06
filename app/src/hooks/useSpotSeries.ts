import { useEffect, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { stateViewAbi } from '../lib/abi'
import { spotFromSqrtPriceX96 } from '../lib/spot'
import { QUOTE_DECIMALS, UNDERLYING_DECIMALS } from '../lib/strategy'
import type { Deployment } from '../lib/deployment'
import type { Candle } from '../components/PriceChart'
import { foldSpot, normalizeCandles } from './spotSeries'

const SAMPLE_MS = 15_000 // poll StateView every 15s
const SYNTH_ANCHOR = 100 // NVDAx seeded near 100 USDC in the deploy script
const LIVE_STEP = 15 // bucket size (s) used when there is no history to match

/** Real NVDA OHLC written by contracts/script/fetch-history.sh. */
interface History {
  candles: Candle[]
  /** Bucket size of those candles, in seconds — live samples snap onto the same grid. */
  intervalSeconds: number
}

/**
 * Loads app/public/nvda-history.json (real Yahoo OHLC, refreshed by the keeper).
 * Same runtime-fetch pattern as loadDeployment(): a static file in /public, so the
 * keeper can overwrite it without a rebuild and the browser never has to talk to
 * Yahoo (which sends no CORS headers). Returns null on anything unusable.
 */
async function loadHistory(): Promise<History | null> {
  try {
    const base = import.meta.env.BASE_URL || '/'
    const res = await fetch(`${base}nvda-history.json`, { cache: 'no-store' })
    if (!res.ok) return null
    const doc = (await res.json()) as unknown
    const d = doc as { candles?: unknown; intervalSeconds?: unknown }
    const candles = normalizeCandles(d.candles)
    const step = Number(d.intervalSeconds)
    if (candles.length < 2) return null
    return { candles, intervalSeconds: step > 0 ? Math.floor(step) : 300 }
  } catch {
    return null
  }
}

// Build a synthetic rolling candle series (random walk around an anchor). Only used
// when nvda-history.json is missing/malformed AND the chain read has not landed yet.
// The chart badges this clearly as "synthetic".
function makeSyntheticSeries(anchor: number, count = 48): Candle[] {
  const now = Math.floor(Date.now() / 1000)
  const step = 60 * 15 // 15-minute buckets
  const candles: Candle[] = []
  let price = anchor
  // Walk backwards from now so the latest candle sits at `now`.
  const start = now - step * (count - 1)
  for (let i = 0; i < count; i++) {
    const drift = (Math.sin(i / 5) + (Math.random() - 0.5)) * anchor * 0.004
    const open = price
    const close = Math.max(0.01, open + drift)
    const high = Math.max(open, close) * (1 + Math.random() * 0.002)
    const low = Math.min(open, close) * (1 - Math.random() * 0.002)
    candles.push({ time: start + i * step, open, high, low, close })
    price = close
  }
  return candles
}

export interface SpotState {
  candles: Candle[]
  /** True only when the series is a fabricated random walk (no history file, no chain read). */
  synthetic: boolean
  /** The last REAL v4 read. Null until a chain read lands, so callers can tell
   *  "we have a live price" from "we are only showing history". */
  lastSpot: number | null
}

/**
 * Returns a candle series + the latest spot.
 * - Seeds the series with REAL NVDA candles from /nvda-history.json (written by
 *   contracts/script/fetch-history.sh off Yahoo Finance).
 * - Then polls StateView.getSlot0(poolId) and folds each live v4 spot into the newest
 *   bucket, so the right-hand edge of the chart is the actual pool price.
 * - If the history file is missing/malformed it degrades to the old behaviour: a
 *   synthetic random walk until a few real chain reads have accreted.
 */
export function useSpotSeries(deployment: Deployment | null, deployed: boolean): SpotState {
  const client = usePublicClient()
  const [state, setState] = useState<SpotState>(() => ({
    candles: makeSyntheticSeries(SYNTH_ANCHOR),
    synthetic: true,
    lastSpot: null,
  }))

  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setInterval> | undefined

    void (async () => {
      const history = await loadHistory()
      if (cancelled) return

      const step = history ? history.intervalSeconds : LIVE_STEP
      let series: Candle[] = history ? history.candles.slice() : []

      const publish = (lastSpot: number | null) => {
        // Honest: synthetic only while we have neither real history nor real reads.
        const synthetic = !history && series.length < 3
        setState({
          candles: synthetic ? makeSyntheticSeries(lastSpot ?? SYNTH_ANCHOR) : series,
          synthetic,
          lastSpot,
        })
      }

      publish(null)

      if (!deployed || !deployment || !client) {
        // No deployment. With history we just show it; without, keep the walk alive.
        if (!history) timer = setInterval(() => publish(null), SAMPLE_MS * 4)
        if (cancelled && timer) clearInterval(timer)
        return
      }

      const sample = async () => {
        try {
          const res = (await client.readContract({
            address: deployment.stateView as `0x${string}`,
            abi: stateViewAbi,
            functionName: 'getSlot0',
            args: [deployment.poolId as `0x${string}`],
          })) as readonly [bigint, number, number, number]
          const spot = spotFromSqrtPriceX96(
            res[0],
            UNDERLYING_DECIMALS,
            QUOTE_DECIMALS,
            deployment.underlyingIsCurrency0,
          )
          if (cancelled || spot <= 0) return
          series = foldSpot(series, spot, step)
          publish(spot)
        } catch {
          // RPC/pool read failed (e.g. pool not initialized). Keep the real history if
          // we have it; otherwise fall back to synthetic. lastSpot goes back to null.
          if (cancelled) return
          if (!history) series = []
          publish(null)
        }
      }

      await sample()
      timer = setInterval(sample, SAMPLE_MS)
      if (cancelled) clearInterval(timer)
    })()

    return () => {
      cancelled = true
      if (timer) clearInterval(timer)
    }
  }, [client, deployment, deployed])

  return state
}
