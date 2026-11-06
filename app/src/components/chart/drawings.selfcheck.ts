/* Run: node --experimental-strip-types src/components/chart/drawings.selfcheck.ts */
import assert from 'node:assert/strict'
import {
  anchorsNeeded,
  distToRay,
  distToSegment,
  hitTest,
  measure,
  plotSize,
  snapToBar,
} from './drawings.ts'

const S = plotSize(800, 400)

// -- anchors ---------------------------------------------------------------
assert.equal(anchorsNeeded('hline'), 1)
assert.equal(anchorsNeeded('trend'), 2)
assert.equal(anchorsNeeded('brush'), Infinity)

// -- segment vs ray --------------------------------------------------------
const a = { x: 0, y: 0 }
const b = { x: 10, y: 0 }
assert.equal(distToSegment({ x: 5, y: 3 }, a, b), 3)
// Past the end, a segment measures to the endpoint...
assert.equal(distToSegment({ x: 20, y: 0 }, a, b), 10)
// ...while a ray keeps going, so the distance stays 0.
assert.equal(distToRay({ x: 20, y: 0 }, a, b), 0)
// Behind the origin both clamp to the origin.
assert.equal(distToRay({ x: -5, y: 0 }, a, b), 5)
// Degenerate (both anchors identical) must not divide by zero.
assert.equal(distToSegment({ x: 3, y: 4 }, a, a), 5)
assert.equal(distToRay({ x: 3, y: 4 }, a, a), 5)

// -- magnet ----------------------------------------------------------------
const bar = { open: 10, high: 12, low: 9, close: 11 }
assert.equal(snapToBar(11.4, bar), 11)
assert.equal(snapToBar(11.9, bar), 12)
assert.equal(snapToBar(9.1, bar), 9)
// No bar under the pointer leaves the price alone.
assert.equal(snapToBar(11.4, undefined), 11.4)

// -- hit testing -----------------------------------------------------------
const h = [{ x: 0, y: 100 }]
assert.equal(hitTest('hline', h, { x: 500, y: 103 }, S), true)
assert.equal(hitTest('hline', h, { x: 500, y: 140 }, S), false)

const box = [
  { x: 100, y: 100 },
  { x: 300, y: 200 },
]
// On an edge: hit. Dead centre: miss, so a big rectangle does not eat clicks.
assert.equal(hitTest('rect', box, { x: 100, y: 150 }, S), true)
assert.equal(hitTest('rect', box, { x: 200, y: 150 }, S), false)
assert.equal(hitTest('rect', box, { x: 400, y: 150 }, S), false)

// Fib: the 0.5 level sits halfway between the anchors.
assert.equal(hitTest('fib', box, { x: 200, y: 150 }, S), true)
// y=170 falls between the 0.618 (161.8) and 0.786 (178.6) levels, clear of both.
assert.equal(hitTest('fib', box, { x: 200, y: 170 }, S), false)
// Outside the anchors' x-range, nothing is hit.
assert.equal(hitTest('fib', box, { x: 500, y: 150 }, S), false)

// A tool with too few anchors must never throw.
assert.equal(hitTest('trend', [{ x: 1, y: 1 }], { x: 1, y: 1 }, S), false)
assert.equal(hitTest('trend', [], { x: 1, y: 1 }, S), false)

const stroke = [
  { x: 0, y: 0 },
  { x: 10, y: 0 },
  { x: 10, y: 10 },
]
assert.equal(hitTest('brush', stroke, { x: 10, y: 5 }, S), true)
assert.equal(hitTest('brush', stroke, { x: 40, y: 5 }, S), false)

// -- measure ---------------------------------------------------------------
const m = measure({ logical: 0, price: 100 }, { logical: 4, price: 110 }, 900)
assert.equal(m.abs, 10)
assert.equal(m.pct, 10)
assert.equal(m.bars, 4)
assert.equal(m.seconds, 3600)
// Backwards in time still reports a positive bar count.
assert.equal(measure({ logical: 4, price: 100 }, { logical: 0, price: 90 }, 60).bars, 4)
// A zero reference price must not produce Infinity or NaN.
assert.equal(measure({ logical: 0, price: 0 }, { logical: 1, price: 5 }, 60).pct, 0)

console.log('drawings ok')
