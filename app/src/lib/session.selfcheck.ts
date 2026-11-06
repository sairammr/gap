/* Self-check for the session window. Run:
   node --experimental-strip-types src/lib/session.selfcheck.ts */
import assert from 'node:assert/strict'
import { marketClosed, suggestedVol } from './session.ts'

const at = (iso: string) => new Date(iso)

// Wednesday 2026-11-04.
assert.equal(marketClosed(at('2026-11-04T13:29:59Z')), true) // one second before the open
assert.equal(marketClosed(at('2026-11-04T13:30:00Z')), false) // the open itself
assert.equal(marketClosed(at('2026-11-04T17:00:00Z')), false) // midday
assert.equal(marketClosed(at('2026-11-04T19:59:59Z')), false) // last second of the session
assert.equal(marketClosed(at('2026-11-04T20:00:00Z')), true) // the close is closed
assert.equal(marketClosed(at('2026-11-04T02:00:00Z')), true) // overnight

// Weekends are shut at every hour, including one inside the weekday window.
assert.equal(marketClosed(at('2026-11-07T17:00:00Z')), true) // Saturday
assert.equal(marketClosed(at('2026-11-08T17:00:00Z')), true) // Sunday

assert.equal(suggestedVol(0.5, at('2026-11-04T17:00:00Z')), 0.5)
assert.equal(suggestedVol(0.5, at('2026-11-07T17:00:00Z')), 0.65)

console.log('session window ok')
