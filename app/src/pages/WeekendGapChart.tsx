/* ============================================================================
   The problem, as it actually happened.

   Redrawn from a QQQx/USDC hourly chart: the price drifts sideways all weekend
   on almost no volume, then the equity market reopens and it reprices in a
   handful of candles — straight through the level where leveraged positions
   die. Nobody on the wrong side of that could do anything about it, because
   the market that sets the real price was shut the whole time.

   Drawn rather than screenshotted so it carries the deck's own type and colour
   and stays legible at projector size. The numbers are the real ones.
   ========================================================================= */

const W = 960
const H = 360
const PLOT_TOP = 40
const PLOT_BOT = 300
const HI = 730
const LO = 680

const y = (price: number) => PLOT_BOT - ((price - LO) / (HI - LO)) * (PLOT_BOT - PLOT_TOP)

/** [x, open, close] — hourly candles, weekend drift then the reopen. */
const WEEKEND: [number, number, number][] = [
  [70, 724, 723], [104, 723, 724.5], [138, 724.5, 723], [172, 723, 722],
  [206, 722, 723], [240, 723, 721.5], [274, 721.5, 722], [308, 722, 720],
  [342, 720, 721], [376, 721, 719], [410, 719, 720], [444, 720, 718],
  [478, 718, 717], [512, 717, 716.5],
]

const MONDAY: [number, number, number][] = [
  [560, 716, 707], [594, 707, 704], [628, 704, 699], [662, 699, 694],
  [696, 694, 690], [730, 690, 686], [764, 686, 688], [798, 688, 687],
  [832, 687, 689], [866, 689, 687.21],
]

const REOPEN_X = 540
const LIQ = 708

export function WeekendGapChart() {
  return (
    <svg
      className="wg"
      viewBox={`0 0 ${W} ${H}`}
      role="img"
      aria-label="A QQQx hourly chart. Through the weekend the price drifts sideways from 724 to 716 on very thin volume. The moment the equity market reopens it gaps straight down through the 708 liquidation level and keeps going to 687 — a 4 percent repricing in a few hours that nobody could hedge, because the underlying market was closed."
    >
      {/* The weekend, shaded: the whole window in which nothing can be done. */}
      <rect className="wg-dead" x={54} y={PLOT_TOP} width={REOPEN_X - 54} height={PLOT_BOT - PLOT_TOP} />
      <text className="wg-zone" x={(54 + REOPEN_X) / 2} y={PLOT_TOP + 22} textAnchor="middle">
        MARKET CLOSED · 61 HOURS
      </text>

      {/* The level where leverage dies. */}
      <line className="wg-liq" x1={54} y1={y(LIQ)} x2={W - 24} y2={y(LIQ)} />
      {/* Anchored inside the right edge and lifted off the rule, or it clips. */}
      <text className="wg-liq-l" x={W - 28} y={y(LIQ) - 8} textAnchor="end">
        LIQUIDATION · {LIQ}
      </text>

      {WEEKEND.map(([x, o, c]) => (
        <rect
          key={x}
          className="wg-c wg-c--flat"
          x={x}
          y={Math.min(y(o), y(c)) - 1}
          width={10}
          height={Math.abs(y(o) - y(c)) + 2}
        />
      ))}
      {MONDAY.map(([x, o, c]) => (
        <rect
          key={x}
          className={`wg-c ${c < o ? 'wg-c--down' : 'wg-c--up'}`}
          x={x}
          y={Math.min(y(o), y(c)) - 1}
          width={10}
          height={Math.abs(y(o) - y(c)) + 2}
        />
      ))}

      {/* The reopen itself. */}
      <line className="wg-open" x1={REOPEN_X} y1={PLOT_TOP - 8} x2={REOPEN_X} y2={PLOT_BOT + 10} />
      <text className="wg-open-l" x={REOPEN_X + 8} y={PLOT_TOP + 2}>
        MARKET REOPENS
      </text>

      <text className="wg-px" x={54} y={y(724) - 10}>
        724
      </text>
      <text className="wg-px" x={W - 120} y={y(687.21) + 22}>
        687.21
      </text>

      <text className="wg-sub" x={54} y={H - 18}>
        QQQx / USDC · 1h · weekend drift on $315K of volume, then −4.0% in a morning
      </text>
    </svg>
  )
}
