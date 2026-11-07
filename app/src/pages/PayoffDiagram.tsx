/* ============================================================================
   The two products, as payoff shapes.

   This is the one slide the argument cannot survive without: everything else
   claims the downside is capped, and this is the picture that shows it. Both
   charts are drawn to the same axis so they read as a pair.

     UPSIDE (call) — P&L. Flat at minus-the-premium until the strike, then it
       turns and climbs with the stock. The flat part IS the pitch: a position
       whose worst case is a rectangle you chose the height of on Friday.

     FLOOR (put) — the value of stock you already hold, with a floor under it.
       The dashed line is the same stock held bare, which keeps falling. Where
       the two separate is the gap you did not eat.
   ========================================================================= */

const W = 460
const H = 250
/** Left/right of the plot, the zero line, and where the strike sits. */
const X0 = 46
const X1 = 436
const STRIKE_X = 236
const ZERO_Y = 150
const FLOOR_Y = 176 // zero minus the premium
const TOP_Y = 44

export function UpsidePayoff() {
  return (
    <svg
      className="pf"
      viewBox={`0 0 ${W} ${H}`}
      role="img"
      aria-label="Call option profit and loss against the stock price. Below the strike the loss is flat at the premium paid. Above the strike the profit climbs one-for-one with the stock, with no cap."
    >
      {/* The capped-loss rectangle — the whole point of the product. */}
      <rect className="pf-loss" x={X0} y={ZERO_Y} width={STRIKE_X - X0} height={FLOOR_Y - ZERO_Y} />

      <line className="pf-axis" x1={X0} y1={ZERO_Y} x2={X1} y2={ZERO_Y} />
      <line className="pf-axis" x1={X0} y1={TOP_Y - 12} x2={X0} y2={FLOOR_Y + 22} />
      <line className="pf-strike" x1={STRIKE_X} y1={TOP_Y - 6} x2={STRIKE_X} y2={FLOOR_Y + 22} />

      {/* Flat at -premium to the strike, then 45 degrees up and uncapped. */}
      <polyline className="pf-line pf-line--up" points={`${X0},${FLOOR_Y} ${STRIKE_X},${FLOOR_Y} ${X1 - 8},${TOP_Y}`} />

      <text className="pf-ax" x={X0} y={TOP_Y - 20}>
        your P&amp;L
      </text>
      <text className="pf-ax pf-ax--end" x={X1} y={ZERO_Y - 10}>
        price →
      </text>
      <text className="pf-k" x={STRIKE_X} y={FLOOR_Y + 38} textAnchor="middle">
        STRIKE
      </text>
      <text className="pf-note pf-note--down" x={X0 + 10} y={FLOOR_Y + 18}>
        lose only the premium
      </text>
      <text className="pf-note pf-note--up pf-ax--end" x={X1 - 8} y={TOP_Y - 12}>
        gain the move, no cap
      </text>
    </svg>
  )
}

export function FloorPayoff() {
  // The bare stock: one straight line through the strike, falling to the left.
  const BARE_LEFT_Y = 214
  return (
    <svg
      className="pf"
      viewBox={`0 0 ${W} ${H}`}
      role="img"
      aria-label="The value of tokenized stock you hold, with a put floor under it. Below the strike the floor holds the value flat while the bare stock keeps falling. Above the strike the floor expires and the stock is kept."
    >
      {/* Everything between the floor and the bare stock is the loss you skipped. */}
      <polygon
        className="pf-saved"
        points={`${X0},${FLOOR_Y} ${STRIKE_X},${FLOOR_Y} ${STRIKE_X},${FLOOR_Y} ${X0},${BARE_LEFT_Y}`}
      />

      <line className="pf-axis" x1={X0} y1={FLOOR_Y + 24} x2={X1} y2={FLOOR_Y + 24} />
      <line className="pf-axis" x1={X0} y1={TOP_Y - 12} x2={X0} y2={FLOOR_Y + 24} />
      <line className="pf-strike" x1={STRIKE_X} y1={TOP_Y - 6} x2={STRIKE_X} y2={FLOOR_Y + 24} />

      {/* Bare stock — keeps going down, which is the thing being avoided. */}
      <polyline
        className="pf-line pf-line--bare"
        points={`${X0},${BARE_LEFT_Y} ${STRIKE_X},${FLOOR_Y} ${X1 - 8},${TOP_Y}`}
      />
      {/* Protected: flat to the strike, then it simply is the stock again. */}
      <polyline
        className="pf-line pf-line--floor"
        points={`${X0},${FLOOR_Y} ${STRIKE_X},${FLOOR_Y} ${X1 - 8},${TOP_Y}`}
      />

      <text className="pf-ax" x={X0} y={TOP_Y - 20}>
        your value
      </text>
      <text className="pf-ax pf-ax--end" x={X1} y={FLOOR_Y + 42}>
        price →
      </text>
      <text className="pf-k" x={STRIKE_X} y={FLOOR_Y + 42} textAnchor="middle">
        STRIKE
      </text>
      <text className="pf-note pf-note--floor" x={X0 + 10} y={FLOOR_Y - 12}>
        floor holds
      </text>
      <text className="pf-note pf-note--down" x={X0 + 10} y={BARE_LEFT_Y + 18}>
        bare stock keeps falling
      </text>
    </svg>
  )
}
