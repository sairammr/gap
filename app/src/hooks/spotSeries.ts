/* Pure candle-series helpers for useSpotSeries: no React, no wagmi, so they can be
   checked without a chart or a chain (see spotSeries.selfcheck.ts). */
import type { Candle } from '../components/PriceChart'

/** Hard cap on series length so a long-running demo cannot grow unbounded. */
export const MAX_CANDLES = 720

/**
 * Sanitises the raw `candles` array of public/nvda-history.json into something
 * lightweight-charts will accept: finite positive OHLC, strictly increasing time.
 * Anything that fails is dropped rather than thrown — a malformed file degrades the
 * chart, it does not crash the desk.
 */
export function normalizeCandles(raw: unknown): Candle[] {
  if (!Array.isArray(raw)) return []
  const out: Candle[] = []
  for (const row of raw) {
    const c = row as Partial<Candle>
    const time = Math.floor(Number(c?.time))
    const open = Number(c?.open)
    const high = Number(c?.high)
    const low = Number(c?.low)
    const close = Number(c?.close)
    if (![time, open, high, low, close].every((n) => Number.isFinite(n) && n > 0)) continue
    const prev = out[out.length - 1]
    if (prev && time <= prev.time) continue
    out.push({ time, open, high, low, close })
  }
  return out
}

/**
 * Folds one live spot read into the series.
 *
 * The sample is snapped to the SAME bucket grid as the historical candles: inside the
 * current bucket it updates that candle's high/low/close in place, and the first sample
 * of a new bucket opens a fresh one at the previous close. That is what lets a 15s poll
 * sit on top of 5-minute history — without it, every poll would append a hairline candle
 * next to 5-minute bars and (worse) could emit a timestamp <= the previous one, which
 * lightweight-charts rejects outright.
 *
 * Never mutates `series`.
 */
export function foldSpot(
  series: Candle[],
  spot: number,
  step: number,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): Candle[] {
  const size = step > 0 ? Math.floor(step) : 1
  const bucket = Math.floor(nowSeconds / size) * size
  const last = series[series.length - 1]
  if (!last) return [{ time: bucket, open: spot, high: spot, low: spot, close: spot }]
  if (bucket > last.time) {
    const open = last.close
    const next: Candle = {
      time: bucket,
      open,
      high: Math.max(open, spot),
      low: Math.min(open, spot),
      close: spot,
    }
    return [...series, next].slice(-MAX_CANDLES)
  }
  // Still inside the newest bucket (or clock skew put us behind it) — update it in place
  // so the right-hand edge tracks the pool without ever moving time backwards.
  const merged: Candle = {
    ...last,
    high: Math.max(last.high, spot),
    low: Math.min(last.low, spot),
    close: spot,
  }
  return [...series.slice(0, -1), merged]
}
