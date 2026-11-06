import { useEffect, useRef, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { stateViewAbi } from '../lib/abi'
import { spotFromSqrtPriceX96 } from '../lib/spot'
import { QUOTE_DECIMALS, UNDERLYING_DECIMALS } from '../lib/strategy'
import type { Deployment } from '../lib/deployment'
import type { Candle } from '../components/PriceChart'

const SAMPLE_MS = 15_000 // poll StateView every 15s
const SYNTH_ANCHOR = 100 // NVDAx seeded near 100 USDC in the deploy script

// Build a synthetic rolling candle series (random walk around an anchor). Used when
// there is no live deployment, or while the real series is still thin. The chart
// badges this clearly as "synthetic".
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
  synthetic: boolean
  lastSpot: number | null
}

/**
 * Returns a candle series + the latest spot.
 * - Deployed: polls StateView.getSlot0(poolId) and accretes a rolling candle series
 *   from the sampled sqrtPriceX96 (v4 spot is a single point, so we bucket samples).
 * - Not deployed: returns a synthetic random-walk series (badged synthetic).
 */
export function useSpotSeries(deployment: Deployment | null, deployed: boolean): SpotState {
  const client = usePublicClient()
  const [state, setState] = useState<SpotState>(() => ({
    candles: makeSyntheticSeries(SYNTH_ANCHOR),
    synthetic: true,
    lastSpot: SYNTH_ANCHOR,
  }))
  const liveCandles = useRef<Candle[]>([])

  useEffect(() => {
    if (!deployed || !deployment || !client) {
      // No deployment — keep a synthetic series, refreshed occasionally for life.
      setState({ candles: makeSyntheticSeries(SYNTH_ANCHOR), synthetic: true, lastSpot: SYNTH_ANCHOR })
      const id = setInterval(() => {
        setState({ candles: makeSyntheticSeries(SYNTH_ANCHOR), synthetic: true, lastSpot: SYNTH_ANCHOR })
      }, SAMPLE_MS * 4)
      return () => clearInterval(id)
    }

    let cancelled = false
    liveCandles.current = []

    async function sample() {
      try {
        const res = (await client!.readContract({
          address: deployment!.stateView as `0x${string}`,
          abi: stateViewAbi,
          functionName: 'getSlot0',
          args: [deployment!.poolId as `0x${string}`],
        })) as readonly [bigint, number, number, number]
        const sqrtPriceX96 = res[0]
        const spot = spotFromSqrtPriceX96(
          sqrtPriceX96,
          UNDERLYING_DECIMALS,
          QUOTE_DECIMALS,
          deployment!.underlyingIsCurrency0,
        )
        if (cancelled || spot <= 0) return
        const t = Math.floor(Date.now() / 1000)
        const prev = liveCandles.current[liveCandles.current.length - 1]
        // One candle per sample point (synthetic OHLC from the single spot read).
        const candle: Candle = {
          time: t,
          open: prev ? prev.close : spot,
          high: Math.max(prev ? prev.close : spot, spot),
          low: Math.min(prev ? prev.close : spot, spot),
          close: spot,
        }
        // Ensure strictly increasing time (lightweight-charts requires it).
        if (prev && candle.time <= prev.time) candle.time = prev.time + 1
        liveCandles.current = [...liveCandles.current, candle].slice(-120)
        // Thin history -> still mark synthetic until we have a few real points.
        const thin = liveCandles.current.length < 3
        setState({
          candles: thin ? makeSyntheticSeries(spot) : liveCandles.current,
          synthetic: thin,
          lastSpot: spot,
        })
      } catch {
        // RPC/pool read failed (e.g. pool not initialized) — fall back to synthetic.
        if (!cancelled) {
          setState({ candles: makeSyntheticSeries(SYNTH_ANCHOR), synthetic: true, lastSpot: null })
        }
      }
    }

    sample()
    const id = setInterval(sample, SAMPLE_MS)
    return () => {
      cancelled = true
      clearInterval(id)
    }
  }, [client, deployment, deployed])

  return state
}
