/* Run: node --experimental-strip-types src/components/chart/indicators.selfcheck.ts */
import assert from 'node:assert/strict'
import { bollinger, ema, macd, resample, rsi, sma, trueRange, type Bar } from './indicators.ts'

const close = (xs: number[]) => xs

// -- sma -------------------------------------------------------------------
assert.deepEqual(sma(close([1, 2, 3, 4]), 2), [null, 1.5, 2.5, 3.5])
assert.deepEqual(sma(close([5, 5, 5]), 3), [null, null, 5])
// Not enough history is all nulls, never NaN.
assert.deepEqual(sma(close([1, 2]), 5), [null, null])

// -- ema -------------------------------------------------------------------
const e = ema(close([1, 2, 3, 4, 5]), 3)
assert.equal(e[0], null)
assert.equal(e[1], null)
assert.equal(e[2], 2) // seeded with sma(1,2,3)
assert.equal(e[3], 3) // 4*0.5 + 2*0.5
assert.equal(e[4], 4)

// -- bollinger -------------------------------------------------------------
const b = bollinger(close([2, 4, 6]), 3, 2)
assert.equal(b.middle[2], 4)
// population sd of 2,4,6 is sqrt(8/3)
const sd = Math.sqrt(8 / 3)
assert.ok(Math.abs(b.upper[2]! - (4 + 2 * sd)) < 1e-12)
assert.ok(Math.abs(b.lower[2]! - (4 - 2 * sd)) < 1e-12)

// -- rsi -------------------------------------------------------------------
// A strictly rising series has no losses, so RSI pins at 100.
const up = Array.from({ length: 30 }, (_, i) => i + 1)
assert.equal(rsi(up, 14)[20], 100)
// Flat series: no gain and no loss -> the loss===0 guard keeps it at 100, not NaN.
assert.equal(Number.isNaN(rsi(new Array(30).fill(7), 14)[20] as number), false)
// Bounded.
const noisy = Array.from({ length: 60 }, (_, i) => 100 + Math.sin(i) * 5)
for (const v of rsi(noisy, 14)) if (v != null) assert.ok(v >= 0 && v <= 100, `rsi out of range: ${v}`)

// -- macd ------------------------------------------------------------------
const m = macd(noisy)
assert.equal(m.line.length, noisy.length)
assert.equal(m.signal.length, noisy.length)
assert.equal(m.hist.length, noisy.length)
// The signal must not start before the macd line does.
const lineStart = m.line.findIndex((v) => v != null)
const sigStart = m.signal.findIndex((v) => v != null)
assert.ok(sigStart >= lineStart)

// -- trueRange -------------------------------------------------------------
const bars: Bar[] = [
  { time: 0, open: 10, high: 12, low: 9, close: 11 },
  { time: 60, open: 11, high: 15, low: 10, close: 14 },
]
assert.deepEqual(trueRange(bars), [3, 5])

// -- resample --------------------------------------------------------------
const fine: Bar[] = [
  { time: 0, open: 1, high: 3, low: 1, close: 2 },
  { time: 30, open: 2, high: 4, low: 0, close: 3 },
  { time: 60, open: 3, high: 3, low: 2, close: 2 },
]
const coarse = resample(fine, 60)
assert.equal(coarse.length, 2)
// The bucket keeps the first open, the extremes, and the last close.
assert.deepEqual(coarse[0], { time: 0, open: 1, high: 4, low: 0, close: 3 })
assert.deepEqual(coarse[1], { time: 60, open: 3, high: 3, low: 2, close: 2 })
// Resampling must not mutate the input.
assert.equal(fine[0].high, 3)

console.log('indicators ok')
