/* Run: node --experimental-strip-types src/hooks/spotSeries.selfcheck.ts */
import assert from 'node:assert/strict'
import { foldSpot, normalizeCandles, MAX_CANDLES } from './spotSeries.ts'

const c = (time: number, close: number) => ({ time, open: close, high: close, low: close, close })

// -- normalizeCandles ------------------------------------------------------
assert.deepEqual(normalizeCandles(null), [])
assert.deepEqual(normalizeCandles('nope'), [])
// Yahoo nulls out buckets with no trades; they must not reach the chart.
assert.deepEqual(
  normalizeCandles([
    { time: 100, open: 1, high: 2, low: 0.5, close: 1.5 },
    { time: 200, open: null, high: null, low: null, close: null },
    { time: 300, open: 2, high: 2, low: 2, close: 2 },
  ]).map((x) => x.time),
  [100, 300],
)
// Strictly increasing time is enforced (lightweight-charts throws otherwise).
assert.deepEqual(
  normalizeCandles([c(100, 1), c(100, 2), c(90, 3), c(110, 4)]).map((x) => x.time),
  [100, 110],
)

// -- foldSpot --------------------------------------------------------------
const hist = [c(1000, 10), c(1300, 11)] // two 5-minute buckets
const step = 300

// Empty series: the sample opens the first candle.
assert.deepEqual(foldSpot([], 7, step, 1500), [{ time: 1500, open: 7, high: 7, low: 7, close: 7 }])

// Same bucket as the newest candle -> update in place, no new timestamp.
const same = foldSpot(hist, 12, step, 1450)
assert.equal(same.length, 2)
assert.deepEqual(same[1], { time: 1300, open: 11, high: 12, low: 11, close: 12 })
// A second sample in that bucket keeps the running high/low.
const same2 = foldSpot(same, 9, step, 1499)
assert.deepEqual(same2[1], { time: 1300, open: 11, high: 12, low: 9, close: 9 })

// New bucket -> append, opening at the previous close.
const next = foldSpot(hist, 13, step, 1700)
assert.equal(next.length, 3)
assert.deepEqual(next[2], { time: 1500, open: 11, high: 13, low: 11, close: 13 })

// The input series is never mutated.
assert.deepEqual(hist[1], c(1300, 11))

// Clock skew behind the newest candle must NOT move time backwards.
assert.deepEqual(foldSpot(hist, 5, step, 100).map((x) => x.time), [1000, 1300])

// Whatever the inputs, time stays strictly increasing and the series stays capped.
let s = normalizeCandles(Array.from({ length: 400 }, (_, i) => c(i * step, 100 + i)))
for (let i = 0; i < 500; i++) {
  s = foldSpot(s, 100 + Math.sin(i) * 5, step, 400 * step + i * 15 - (i % 7) * 30)
  assert.ok(s.length <= MAX_CANDLES)
  for (let k = 1; k < s.length; k++) assert.ok(s[k].time > s[k - 1].time, 'time went backwards')
}

console.log('spotSeries selfcheck OK')
