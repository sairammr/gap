/* ============================================================================
   The architecture, as one drawing.

   Hand-laid inline SVG rather than a chart library: the arrangement is fixed,
   so a layout engine would be more code than the coordinates. Inline means the
   diagram inherits the deck's CSS custom properties and restyles with the
   tokens instead of carrying its own palette.

   Three bands, and each exists to land exactly one claim:

     1 · SHIP   nothing moves. The zero is drawn at headline size because it is
                the whole reason a maker can quote without giving up custody,
                and in the previous version it was a line of prose nobody read.

     2 · FILL   everything moves, atomically. The dashed container is the
                transaction boundary — without it the band reads as five
                separate calls that might land in pieces, which is the opposite
                of what happens. The pull/push bar sits inside it, because the
                first token transfer in the whole system happens there.

     3 · AFTER  a FORK, not a chain. The previous version drew
                exercise → expiry → redeem with arrows between them, which says
                you exercise and then also settle. You do one or the other:
                exercising is terminal, and settlement only ever covers what
                nobody exercised.
   ========================================================================= */

export function ArchitectureDiagram() {
  return (
    <svg
      className="ad"
      viewBox="0 0 1200 592"
      role="img"
      aria-label="GAP on Aqua architecture in three bands. First, shipping: the maker posts a SwapVM order and Aqua writes a ledger entry against their own wallet, transferring zero tokens. Second, the fill: inside one atomic transaction a taker calls the AquaSwapVMRouter, which runs the maker's program, prices it through Extruction into WeekendPricer against Uniswap v4 spot, calls the WeekendDesk maker hook which writes the option just-in-time in WeekendOptions, and only then does Aqua.pull move collateral and Aqua.push move the premium. Third, afterwards the holder takes one of two exclusive paths: exercise physically before expiry with no oracle read, or let it expire, in which case a single oracle price settles whatever nobody exercised and redeemFor and claimFor pay both sides."
    >
      <defs>
        <marker
          id="ad-arrow"
          viewBox="0 0 10 10"
          refX="9"
          refY="5"
          markerWidth="6"
          markerHeight="6"
          orient="auto-start-reverse"
        >
          <path d="M0 0 L10 5 L0 10 z" className="ad-head" />
        </marker>
      </defs>

      {/* ============ 1 · SHIP ============================================= */}

      <text className="ad-band" x={24} y={14}>
        1 · SHIP — the maker commits, and nothing moves
      </text>

      <rect className="ad-box" x={24} y={26} width={226} height={62} rx={14} />
      <text className="ad-t" x={44} y={52}>
        Maker wallet
      </text>
      <text className="ad-s" x={44} y={73}>
        NVDAx + USDC · still theirs
      </text>

      <line className="ad-wire" x1={250} y1={57} x2={318} y2={57} markerEnd="url(#ad-arrow)" />
      <text className="ad-l" x={284} y={47} textAnchor="middle">
        ship()
      </text>

      <rect className="ad-box ad-box--teal" x={324} y={26} width={286} height={62} rx={14} />
      <text className="ad-t" x={344} y={52}>
        Aqua
      </text>
      <text className="ad-s" x={344} y={73}>
        writes one ledger entry
      </text>

      {/* The claim the whole design rests on, at the size it deserves. */}
      <rect className="ad-zero-box" x={660} y={26} width={516} height={62} rx={14} />
      <text className="ad-zero" x={694} y={75}>
        0
      </text>
      <text className="ad-t" x={756} y={52}>
        tokens transferred
      </text>
      <text className="ad-s" x={756} y={73}>
        the ERC-20 moves only when a fill pulls it
      </text>

      <rect className="ad-strip" x={24} y={100} width={1152} height={54} rx={14} />
      <text className="ad-l" x={44} y={121}>
        THE ASK, POSTED AS A SWAPVM PROGRAM
      </text>
      <text className="ad-code" x={44} y={143}>
        Deadline + Salt + RequireMinRate + Extruction(pricer, args)
      </text>
      <text className="ad-code ad-code--dim" x={1156} y={143} textAnchor="end">
        hash(order) == Aqua.strategyHash
      </text>

      {/* ============ 2 · FILL ============================================= */}

      <text className="ad-band" x={24} y={178}>
        2 · FILL — one transaction
      </text>

      {/* The transaction boundary. Everything inside lands together or not at all. */}
      <rect className="ad-txn" x={24} y={190} width={1152} height={282} rx={18} />
      <text className="ad-txn-l" x={1152} y={212} textAnchor="end">
        ALL OF THIS, OR NONE OF IT
      </text>

      <rect className="ad-box" x={46} y={226} width={148} height={62} rx={14} />
      <text className="ad-t" x={64} y={252}>
        Taker
      </text>
      <text className="ad-s" x={64} y={273}>
        buys an option
      </text>

      <line className="ad-wire" x1={194} y1={257} x2={252} y2={257} markerEnd="url(#ad-arrow)" />
      <text className="ad-l" x={223} y={247} textAnchor="middle">
        swap
      </text>

      <rect className="ad-box ad-box--teal" x={258} y={216} width={442} height={136} rx={16} />
      <text className="ad-t" x={278} y={242}>
        AquaSwapVMRouter
      </text>
      <text className="ad-s" x={278} y={262}>
        1inch code · our deployment
      </text>

      <rect className="ad-pill" x={278} y={278} width={88} height={34} rx={10} />
      <text className="ad-p" x={322} y={300} textAnchor="middle">
        Deadline
      </text>
      <rect className="ad-pill" x={374} y={278} width={54} height={34} rx={10} />
      <text className="ad-p" x={401} y={300} textAnchor="middle">
        Salt
      </text>
      <rect className="ad-pill" x={436} y={278} width={132} height={34} rx={10} />
      <text className="ad-p" x={502} y={300} textAnchor="middle">
        RequireMinRate
      </text>
      <rect className="ad-pill ad-pill--violet" x={576} y={278} width={104} height={34} rx={10} />
      <text className="ad-p ad-p--violet" x={628} y={300} textAnchor="middle">
        Extruction
      </text>
      <text className="ad-code ad-code--dim" x={278} y={336}>
        [1b opcode][1b argsLen][args]
      </text>

      {/* The maker hook: the desk gets called mid-fill. */}
      <line className="ad-wire" x1={700} y1={248} x2={752} y2={248} markerEnd="url(#ad-arrow)" />
      <text className="ad-l" x={726} y={238} textAnchor="middle">
        hook
      </text>

      <rect className="ad-box ad-box--violet" x={758} y={216} width={396} height={58} rx={14} />
      <text className="ad-t" x={778} y={240}>
        WeekendDesk
      </text>
      <text className="ad-s" x={778} y={261}>
        the maker, as a contract
      </text>

      <line className="ad-wire" x1={956} y1={274} x2={956} y2={292} markerEnd="url(#ad-arrow)" />
      <text className="ad-l" x={968} y={288}>
        writes just-in-time
      </text>

      <rect className="ad-box ad-box--violet" x={758} y={294} width={396} height={58} rx={14} />
      <text className="ad-t" x={778} y={318}>
        WeekendOptions
      </text>
      <text className="ad-s" x={778} y={339}>
        mints the option to the taker
      </text>

      {/* Extruction reaches out of the VM into our pricer. */}
      <line className="ad-wire" x1={628} y1={312} x2={628} y2={364} markerEnd="url(#ad-arrow)" />
      <text className="ad-l" x={638} y={350}>
        calls out
      </text>

      <rect className="ad-box ad-box--violet" x={480} y={366} width={296} height={60} rx={14} />
      <text className="ad-t" x={500} y={390}>
        WeekendPricer
      </text>
      <text className="ad-s" x={500} y={411}>
        Black-Scholes, on the live price
      </text>

      <rect className="ad-box" x={820} y={366} width={296} height={60} rx={14} />
      <text className="ad-t" x={840} y={390}>
        Uniswap v4 spot
      </text>
      <text className="ad-s" x={840} y={411}>
        sqrtPriceX96 to USDC
      </text>

      <line className="ad-wire" x1={816} y1={396} x2={780} y2={396} markerEnd="url(#ad-arrow)" />

      {/* The first token movement in the entire system. */}
      <rect className="ad-move" x={46} y={426} width={1108} height={32} rx={10} />
      <text className="ad-move-t" x={66} y={447}>
        FIRST TOKEN MOVEMENT
      </text>
      <text className="ad-code" x={252} y={447}>
        Aqua.pull — collateral, maker to protocol · Aqua.push — premium, taker to maker
      </text>

      {/* ============ 3 · AFTER ============================================ */}

      <text className="ad-band" x={24} y={500}>
        3 · AFTER — two ways out, never both
      </text>

      <rect className="ad-box" x={24} y={516} width={196} height={62} rx={14} />
      <text className="ad-t" x={42} y={542}>
        You hold the option
      </text>
      <text className="ad-s" x={42} y={562}>
        one ERC-20 per series
      </text>

      {/* A fork, not a chain: exercising is terminal, and settlement only ever
          covers whatever nobody exercised. */}
      <line className="ad-wire" x1={220} y1={547} x2={252} y2={547} markerEnd="url(#ad-arrow)" />

      <rect className="ad-box ad-box--green" x={258} y={516} width={400} height={62} rx={14} />
      <text className="ad-t" x={278} y={542}>
        Exercise before expiry
      </text>
      <text className="ad-s" x={278} y={562}>
        pay the strike, take the stock — no oracle read
      </text>

      <text className="ad-or" x={690} y={553} textAnchor="middle">
        OR
      </text>

      <rect className="ad-box ad-box--amber" x={722} y={516} width={454} height={62} rx={14} />
      <text className="ad-t" x={742} y={542}>
        Or let it expire
      </text>
      <text className="ad-s" x={742} y={562}>
        one oracle price, then redeemFor / claimFor pay both sides
      </text>
    </svg>
  )
}
