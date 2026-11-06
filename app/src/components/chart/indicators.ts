/* Indicator maths. Pure functions over a close/OHLC series so they can be
   checked without a chart (see indicators.selfcheck.ts).

   Every one returns an array the same length as the input, with `null` for
   bars before the indicator has enough history. The chart layer drops the
   nulls — lightweight-charts wants gaps omitted, not nullish. */

export interface Bar {
  time: number
  open: number
  high: number
  low: number
  close: number
}

export type Maybe = (number | null)[]

/** Simple moving average. */
export function sma(values: number[], period: number): Maybe {
  if (period < 1) throw new Error('sma: period must be >= 1')
  const out: Maybe = new Array(values.length).fill(null)
  let sum = 0
  for (let i = 0; i < values.length; i++) {
    sum += values[i]
    if (i >= period) sum -= values[i - period]
    if (i >= period - 1) out[i] = sum / period
  }
  return out
}

/** Exponential moving average, seeded with the SMA of the first `period` bars. */
export function ema(values: number[], period: number): Maybe {
  if (period < 1) throw new Error('ema: period must be >= 1')
  const out: Maybe = new Array(values.length).fill(null)
  if (values.length < period) return out
  const k = 2 / (period + 1)
  let prev = 0
  for (let i = 0; i < period; i++) prev += values[i]
  prev /= period
  out[period - 1] = prev
  for (let i = period; i < values.length; i++) {
    prev = values[i] * k + prev * (1 - k)
    out[i] = prev
  }
  return out
}

export interface Bands {
  upper: Maybe
  middle: Maybe
  lower: Maybe
}

/** Bollinger bands: SMA +/- `mult` population standard deviations. */
export function bollinger(values: number[], period = 20, mult = 2): Bands {
  const middle = sma(values, period)
  const upper: Maybe = new Array(values.length).fill(null)
  const lower: Maybe = new Array(values.length).fill(null)
  for (let i = period - 1; i < values.length; i++) {
    const mean = middle[i]
    if (mean == null) continue
    let acc = 0
    for (let j = i - period + 1; j <= i; j++) acc += (values[j] - mean) ** 2
    const sd = Math.sqrt(acc / period)
    upper[i] = mean + mult * sd
    lower[i] = mean - mult * sd
  }
  return { upper, middle, lower }
}

/** Wilder's RSI. Returns 0..100. */
export function rsi(values: number[], period = 14): Maybe {
  const out: Maybe = new Array(values.length).fill(null)
  if (values.length <= period) return out
  let gain = 0
  let loss = 0
  for (let i = 1; i <= period; i++) {
    const d = values[i] - values[i - 1]
    if (d >= 0) gain += d
    else loss -= d
  }
  gain /= period
  loss /= period
  out[period] = loss === 0 ? 100 : 100 - 100 / (1 + gain / loss)
  for (let i = period + 1; i < values.length; i++) {
    const d = values[i] - values[i - 1]
    // Wilder smoothing: the running average is carried, not recomputed.
    gain = (gain * (period - 1) + Math.max(d, 0)) / period
    loss = (loss * (period - 1) + Math.max(-d, 0)) / period
    out[i] = loss === 0 ? 100 : 100 - 100 / (1 + gain / loss)
  }
  return out
}

/** MACD line, signal line and histogram. */
export function macd(values: number[], fast = 12, slow = 26, signal = 9) {
  const f = ema(values, fast)
  const s = ema(values, slow)
  const line: Maybe = values.map((_, i) => (f[i] != null && s[i] != null ? f[i]! - s[i]! : null))
  const defined = line.filter((v): v is number => v != null)
  const sig = ema(defined, signal)
  // Re-align the signal with the original indices.
  const offset = line.findIndex((v) => v != null)
  const signalOut: Maybe = new Array(values.length).fill(null)
  if (offset >= 0) sig.forEach((v, i) => (signalOut[offset + i] = v))
  const hist: Maybe = line.map((v, i) => (v != null && signalOut[i] != null ? v - signalOut[i]! : null))
  return { line, signal: signalOut, hist }
}

/**
 * The volume we can honestly show. v4 spot is sampled, not traded through us,
 * so there is no real per-bar volume — this is the bar's range, which at least
 * tracks activity. Labelled as such in the UI; never called "volume".
 */
export function trueRange(bars: Bar[]): number[] {
  return bars.map((b, i) => {
    if (i === 0) return b.high - b.low
    const pc = bars[i - 1].close
    return Math.max(b.high - b.low, Math.abs(b.high - pc), Math.abs(b.low - pc))
  })
}

/** Resample a bar series into buckets of `seconds`. Used by the interval picker. */
export function resample(bars: Bar[], seconds: number): Bar[] {
  if (seconds <= 0 || !bars.length) return bars
  const out: Bar[] = []
  for (const b of bars) {
    const bucket = Math.floor(b.time / seconds) * seconds
    const last = out[out.length - 1]
    if (last && last.time === bucket) {
      last.high = Math.max(last.high, b.high)
      last.low = Math.min(last.low, b.low)
      last.close = b.close
    } else {
      out.push({ time: bucket, open: b.open, high: b.high, low: b.low, close: b.close })
    }
  }
  return out
}
