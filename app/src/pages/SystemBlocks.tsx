/* ============================================================================
   The block diagram: maker, taker, and what happens between them.

   An earlier version of this slide led with "two boxes are 1inch, we changed
   neither". That is a true sentence and a terrible one — it sells the absence
   of work. Nobody funds a team for what it did not write.

   So this one is a flow, and every block in the middle lane is something we
   built. The maker enters on the left, the taker on the right, and the five
   numbered steps down the centre are the transaction: ship, swap, price,
   write, settle. Aqua and the router appear as the rails they are.

   The one claim worth making about 1inch is not that we left it alone — it is
   that the option is EXPRESSIBLE as one of its orders at all, which is the
   footer strip at the bottom.
   ========================================================================= */

const W = 1100
const LANE = { x: 330, w: 440 }
const SIDE = 228
const H = 76

/** One step in the centre lane. */
interface Step {
  n: string
  label: string
  sub: string
  y: number
  cls: string
}

const STEPS: Step[] = [
  { n: '1', label: 'Aqua', sub: 'ledger entry · no tokens move', y: 36, cls: 'sb-box--inch' },
  { n: '2', label: 'AquaSwapVMRouter', sub: 'runs the order as bytecode', y: 152, cls: 'sb-box--inch' },
  { n: '3', label: 'WeekendPricer', sub: 'Black-Scholes, on-path', y: 268, cls: 'sb-box--ours' },
  { n: '4', label: 'WeekendDesk', sub: 'writes the option just-in-time', y: 384, cls: 'sb-box--ours' },
  { n: '5', label: 'WeekendOptions', sub: 'mints OptionToken to the taker', y: 500, cls: 'sb-box--ours' },
]

export function SystemBlocks() {
  return (
    <svg
      className="sb"
      viewBox={`0 0 ${W} 640`}
      role="img"
      aria-label="The maker ships collateral to Aqua, which records a ledger entry without moving tokens. The taker calls swap on the AquaSwapVMRouter, which prices the fill through WeekendPricer and calls the WeekendDesk maker hook; the desk writes the option just-in-time and WeekendOptions mints the option token to the taker. Collateral leaves the maker through Aqua.pull and the premium arrives through Aqua.push, both inside that one transaction."
    >
      {/* --- the two humans ------------------------------------------------ */}
      <rect className="sb-box sb-box--actor" x={24} y={36} width={SIDE} height={H} rx={10} />
      <text className="sb-t" x={44} y={67}>
        Maker
      </text>
      <text className="sb-s" x={44} y={89}>
        owns the collateral
      </text>

      <rect className="sb-box sb-box--actor" x={W - SIDE - 24} y={152} width={SIDE} height={H} rx={10} />
      <text className="sb-t" x={W - SIDE - 4} y={183}>
        Taker
      </text>
      <text className="sb-s" x={W - SIDE - 4} y={205}>
        wants the option
      </text>

      {/* --- the centre lane ------------------------------------------------ */}
      {STEPS.map((s, i) => (
        <g key={s.n}>
          <rect className={`sb-box ${s.cls}`} x={LANE.x} y={s.y} width={LANE.w} height={H} rx={10} />
          <circle className={`sb-n ${s.cls}`} cx={LANE.x + 28} cy={s.y + H / 2} r={15} />
          <text className="sb-n-t" x={LANE.x + 28} y={s.y + H / 2 + 5} textAnchor="middle">
            {s.n}
          </text>
          <text className="sb-t" x={LANE.x + 58} y={s.y + 33}>
            {s.label}
          </text>
          <text className="sb-s" x={LANE.x + 58} y={s.y + 55}>
            {s.sub}
          </text>
          {i < STEPS.length - 1 && (
            <line
              className="sb-wire sb-wire--down"
              x1={LANE.x + LANE.w / 2}
              y1={s.y + H}
              x2={LANE.x + LANE.w / 2}
              y2={STEPS[i + 1].y}
              markerEnd="url(#sb-arrow)"
            />
          )}
        </g>
      ))}

      <defs>
        <marker
          id="sb-arrow"
          viewBox="0 0 10 10"
          refX="9"
          refY="5"
          markerWidth="6"
          markerHeight="6"
          orient="auto-start-reverse"
        >
          <path d="M0 0 L10 5 L0 10 z" className="sb-head" />
        </marker>
      </defs>

      {/* --- the two entries ------------------------------------------------- */}
      <line className="sb-wire" x1={24 + SIDE} y1={74} x2={LANE.x - 6} y2={74} markerEnd="url(#sb-arrow)" />
      <text className="sb-call" x={(24 + SIDE + LANE.x) / 2} y={62} textAnchor="middle">
        ship()
      </text>

      <line
        className="sb-wire"
        x1={W - SIDE - 24}
        y1={190}
        x2={LANE.x + LANE.w + 6}
        y2={190}
        markerEnd="url(#sb-arrow)"
      />
      <text className="sb-call" x={(W - SIDE - 24 + LANE.x + LANE.w) / 2} y={178} textAnchor="middle">
        swap()
      </text>

      {/* --- the delivery back out ------------------------------------------- */}
      <path
        className="sb-wire sb-wire--out"
        d={`M${LANE.x + LANE.w} 538 H${W - 64} V 228`}
        markerEnd="url(#sb-arrow)"
      />
      <text className="sb-call sb-call--up" x={W - 76} y={400} textAnchor="end">
        OptionToken
      </text>

      {/* --- where the value actually moves ----------------------------------- */}
      <path
        className="sb-wire sb-wire--pull"
        d={`M${24 + SIDE / 2} 112 V 422 H${LANE.x - 6}`}
        markerEnd="url(#sb-arrow)"
      />
      <text className="sb-call sb-call--pull" x={24 + SIDE / 2 + 10} y={300}>
        Aqua.pull
      </text>
      <text className="sb-s sb-s--dim" x={24 + SIDE / 2 + 10} y={318}>
        collateral, once
      </text>

      {/* --- the footer claim --------------------------------------------------- */}
      <rect className="sb-foot" x={24} y={578} width={W - 48} height={46} rx={10} />
      <text className="sb-foot-t" x={44} y={606}>
        One transaction. The option is written, paid for and delivered inside it.
      </text>
    </svg>
  )
}
