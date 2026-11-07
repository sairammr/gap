/* ============================================================================
   One $10,000 position, three ways to hold it through the same 12% gap.

   The source deck drew two bars, perp and option. Three is the honest count:
   bare spot is the middle case, and leaving it out makes the floor look like
   it beats a move it does not actually beat — it caps the loss, it does not
   erase it.

   Bar heights are real: the baseline is $0, the dashed reference is $10,000,
   and 270 units of height is the whole position, so every bar is to scale.
   ========================================================================= */

/** Dollars → the y of a bar's top edge, against the $10,000 reference. */
const TOP = 60
const BASE = 330
const SCALE = (BASE - TOP) / 10000

const y = (usd: number) => BASE - usd * SCALE

export function GapOutcomeChart() {
  return (
    <svg
      className="go"
      viewBox="0 0 1080 400"
      role="img"
      aria-label="A $10,000 tokenized-stock position through the same 12% weekend gap down. On a 10x perp it is liquidated to zero. Held as bare spot it is worth $8,800. With a GAP floor bought on Friday it is worth about $9,700 — the strike, less the premium paid."
    >
      {/* the $10,000 reference, and the floor everything is measured from */}
      <line className="go-base" x1={90} y1={BASE} x2={990} y2={BASE} />
      <line className="go-ref" x1={90} y1={TOP} x2={990} y2={TOP} />
      <text className="go-ref-l" x={96} y={TOP - 10}>
        Friday · $10,000 position
      </text>

      {/* ---- 10x perp: wiped ---------------------------------------------- */}
      <rect className="go-ghost" x={130} y={TOP} width={210} height={BASE - TOP} rx={6} />
      <rect className="go-bar go-bar--down" x={130} y={BASE - 6} width={210} height={6} rx={2} />
      <text className="go-v go-v--down" x={235} y={170} textAnchor="middle">
        $0
      </text>
      <text className="go-tag go-tag--down" x={235} y={200} textAnchor="middle">
        LIQUIDATED
      </text>
      <text className="go-k" x={235} y={362} textAnchor="middle">
        10x PERP
      </text>
      <text className="go-n" x={235} y={382} textAnchor="middle">
        gap crossed the threshold while you slept
      </text>

      {/* ---- bare spot: you eat the gap ----------------------------------- */}
      <rect className="go-ghost" x={435} y={TOP} width={210} height={BASE - TOP} rx={6} />
      <rect
        className="go-bar go-bar--flat"
        x={435}
        y={y(8800)}
        width={210}
        height={BASE - y(8800)}
        rx={6}
      />
      <text className="go-v" x={540} y={y(8800) + 52} textAnchor="middle">
        $8,800
      </text>
      <text className="go-tag" x={540} y={y(8800) + 80} textAnchor="middle">
        −12%, IN FULL
      </text>
      <text className="go-k" x={540} y={362} textAnchor="middle">
        BARE STOCK
      </text>
      <text className="go-n" x={540} y={382} textAnchor="middle">
        no leverage, no protection, the whole move
      </text>

      {/* ---- the floor: capped --------------------------------------------- */}
      <rect className="go-ghost" x={740} y={TOP} width={210} height={BASE - TOP} rx={6} />
      <rect
        className="go-bar go-bar--up"
        x={740}
        y={y(9700)}
        width={210}
        height={BASE - y(9700)}
        rx={6}
      />
      <text className="go-v go-v--up" x={845} y={y(9700) + 52} textAnchor="middle">
        $9,700
      </text>
      <text className="go-tag go-tag--up" x={845} y={y(9700) + 80} textAnchor="middle">
        SOLD AT THE STRIKE
      </text>
      <text className="go-k" x={845} y={362} textAnchor="middle">
        GAP FLOOR
      </text>
      <text className="go-n" x={845} y={382} textAnchor="middle">
        the premium is the entire loss
      </text>

    </svg>
  )
}
