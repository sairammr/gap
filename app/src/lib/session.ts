// US equity session, client-side. Gap is named after the overnight gap, so the
// vol a maker quotes should not be the same number at 3pm on a Tuesday as it is
// at 9pm on a Saturday — the whole move happens while the market is shut.
//
// Regular hours are 09:30–16:00 America/New_York. We use the UTC window
// 13:30–20:00 Mon–Fri, which is correct during EDT and off by an hour during
// EST, and we ignore market holidays.
// ponytail: fixed UTC window, no DST and no holiday calendar. Swap for an
// exchange-calendar feed if the hint ever needs to be authoritative — it is a
// suggestion the maker can overrule, not an input to pricing.

const OPEN_MIN = 13 * 60 + 30
const CLOSE_MIN = 20 * 60

/** True when the US equity market is shut — weekend, or outside 13:30–20:00 UTC. */
export function marketClosed(now: Date = new Date()): boolean {
  const day = now.getUTCDay()
  if (day === 0 || day === 6) return true
  const minutes = now.getUTCHours() * 60 + now.getUTCMinutes()
  return minutes < OPEN_MIN || minutes >= CLOSE_MIN
}

/** Vol multiplier suggested while the market is closed (Weekend Options uses 1.3). */
export const CLOSED_VOL_MULTIPLIER = 1.3

/** The vol we suggest to a maker right now, given their baseline. */
export function suggestedVol(base: number, now: Date = new Date()): number {
  return marketClosed(now) ? base * CLOSED_VOL_MULTIPLIER : base
}
