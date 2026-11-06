/* Self-check for the slider math. Run: node --experimental-strip-types src/ui/math.selfcheck.ts */
import assert from 'node:assert/strict'
import { clamp, fracOf, quantize } from './math.ts'

assert.equal(clamp(5, 0, 10), 5)
assert.equal(clamp(-1, 0, 10), 0)
assert.equal(clamp(99, 0, 10), 10)

// Snaps to the grid anchored at min, not at zero.
assert.equal(quantize(7.4, 0, 10, 1), 7)
assert.equal(quantize(7.6, 0, 10, 1), 8)
assert.equal(quantize(1.26, 1, 2, 0.1), 1.3)
// Float dust would otherwise give 1.2000000000000002.
assert.equal(quantize(1.21, 1, 2, 0.1), 1.2)
// Off-grid min: 0.5-steps from 0.5 land on 0.5, 1.0, 1.5...
assert.equal(quantize(1.3, 0.5, 20, 0.5), 1.5)
// Clamped, and the clamp wins over the grid.
assert.equal(quantize(-5, 0, 10, 3), 0)
assert.equal(quantize(50, 0, 10, 3), 10)
// step 0 means "no grid", still clamped.
assert.equal(quantize(3.7, 0, 10, 0), 3.7)

assert.equal(fracOf(5, 0, 10), 0.5)
assert.equal(fracOf(-3, 0, 10), 0)
assert.equal(fracOf(30, 0, 10), 1)
// Degenerate domain must not divide by zero.
assert.equal(fracOf(5, 5, 5), 0)

console.log('slider math ok')
