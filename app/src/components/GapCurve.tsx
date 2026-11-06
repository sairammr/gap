/* ============================================================================
   The gap projection canvas, from basic-template-design.tsx.

   One picture of the whole trade: the regular session on the left, the 16:00
   freeze wall, the overnight window, and a dashed bezier from the close anchor
   to wherever you think Monday opens. Drag it vertically (or use the arrow
   keys) and the payoff follows.

   The one change from the template: our payoff is CAPPED, so the profit zone
   is a bounded band between breakeven and the cap, not an open-ended region.
   Drawing it unbounded would misstate the product.
   ========================================================================= */

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { cappedPayoffPerUnit, KIND, type OptionKind } from '../lib/pricing'

export interface GapCurveProps {
  /** The close anchor — v4 spot when the ticket was priced. */
  spot: number
  kind: OptionKind
  strike: number
  cap: number
  size: number
  /** Total premium paid, in quote units. */
  premium: number
  /** Annualised vol, for the 1-sigma cone. */
  vol: number
  secondsToExpiry: number
  /** Recent closes, drawn as the regular-session path. */
  history?: number[]
}

const W = 980
const H = 410
const PAD_Y = 36
const FREEZE_X = 330
const OPEN_X = 720
const MAX_GAP = 10 // +/- % on the vertical axis

export function GapCurve({
  spot,
  kind,
  strike,
  cap,
  size,
  premium,
  vol,
  secondsToExpiry,
  history,
}: GapCurveProps) {
  const svgRef = useRef<SVGSVGElement | null>(null)
  const [dragging, setDragging] = useState(false)
  const [gapPct, setGapPct] = useState(kind === KIND.CALL ? 3 : -3)
  const gradId = useId().replace(/:/g, '')

  // Flip to a sensible side when the direction changes.
  useEffect(() => {
    setGapPct((g) => (kind === KIND.CALL ? Math.abs(g) : -Math.abs(g)))
  }, [kind])

  const pctToY = useCallback((pct: number) => {
    const usable = H - PAD_Y * 2
    const c = Math.max(-MAX_GAP, Math.min(MAX_GAP, pct))
    return PAD_Y + ((MAX_GAP - c) / (MAX_GAP * 2)) * usable
  }, [])
  const priceToY = useCallback(
    (price: number) => pctToY(((price - spot) / spot) * 100),
    [pctToY, spot],
  )

  const setFromClientY = useCallback(
    (clientY: number) => {
      const el = svgRef.current
      if (!el) return
      const r = el.getBoundingClientRect()
      // The SVG scales to its box, so work in viewBox units.
      const y = ((clientY - r.top) / r.height) * H
      const usable = H - PAD_Y * 2
      const pct = MAX_GAP - ((y - PAD_Y) / usable) * MAX_GAP * 2
      setGapPct(Math.max(-MAX_GAP, Math.min(MAX_GAP, Math.round(pct * 10) / 10)))
    },
    [],
  )

  useEffect(() => {
    if (!dragging) return
    const move = (e: PointerEvent) => setFromClientY(e.clientY)
    const up = () => setDragging(false)
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
    window.addEventListener('pointercancel', up)
    return () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      window.removeEventListener('pointercancel', up)
    }
  }, [dragging, setFromClientY])

  const isCall = kind === KIND.CALL
  const openPrice = spot * (1 + gapPct / 100)
  const perUnit = premium / Math.max(size, 1e-9)

  // Where the capped payoff actually pays: breakeven out to the cap.
  const breakeven = isCall ? strike + perUnit : strike - perUnit
  const capEdge = isCall ? strike + cap : strike - cap

  const payout = cappedPayoffPerUnit(kind, openPrice, strike, cap) * size
  const net = payout - premium
  const roi = premium > 0 ? payout / premium : 0

  const sigmaPct = vol * Math.sqrt(Math.max(secondsToExpiry, 60) / 31_536_000) * 100

  const closeY = pctToY(0)
  const targetY = pctToY(gapPct)
  const strikeY = priceToY(strike)
  const beY = priceToY(breakeven)
  const capY = priceToY(capEdge)
  const sdTopY = pctToY(sigmaPct)
  const sdBotY = pctToY(-sigmaPct)

  const sessionPath = useMemo(() => {
    const pts = (history && history.length > 1 ? history : [spot, spot]).slice(-60)
    return pts
      .map((p, i) => {
        const x = 40 + (i / (pts.length - 1)) * (FREEZE_X - 40)
        return `${i === 0 ? 'M' : 'L'} ${x.toFixed(1)} ${priceToY(p).toFixed(1)}`
      })
      .join(' ')
  }, [history, spot, priceToY])

  const inProfit = net > 0
  const curveColor = inProfit ? (isCall ? '#22c55e' : '#ef4444') : '#94a3b8'

  // The band that pays, clamped to the plot.
  const bandTop = Math.min(beY, capY)
  const bandBottom = Math.max(beY, capY)

  function onKeyDown(e: React.KeyboardEvent) {
    const step = e.shiftKey ? 1 : 0.1
    if (e.key === 'ArrowUp') setGapPct((g) => Math.min(MAX_GAP, Math.round((g + step) * 10) / 10))
    else if (e.key === 'ArrowDown') setGapPct((g) => Math.max(-MAX_GAP, Math.round((g - step) * 10) / 10))
    else if (e.key === 'Home') setGapPct(0)
    else return
    e.preventDefault()
  }

  return (
    <div className="gc">
      <svg
        ref={svgRef}
        className={'gc__svg' + (dragging ? ' is-dragging' : '')}
        viewBox={`0 0 ${W} ${H}`}
        role="slider"
        tabIndex={0}
        aria-label="Projected open gap"
        aria-valuemin={-MAX_GAP}
        aria-valuemax={MAX_GAP}
        aria-valuenow={gapPct}
        aria-valuetext={`${gapPct >= 0 ? '+' : ''}${gapPct.toFixed(1)} percent, open ${openPrice.toFixed(2)}`}
        onKeyDown={onKeyDown}
        onPointerDown={(e) => {
          setDragging(true)
          setFromClientY(e.clientY)
        }}
      >
        <defs>
          <linearGradient id={`${gradId}-pay`} x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor={isCall ? '#22c55e' : '#ef4444'} stopOpacity="0.07" />
            <stop offset="100%" stopColor={isCall ? '#22c55e' : '#ef4444'} stopOpacity="0.22" />
          </linearGradient>
          <linearGradient id={`${gradId}-night`} x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="#ffb020" stopOpacity="0.07" />
            <stop offset="55%" stopColor="#ffffff" stopOpacity="0" />
            <stop offset="100%" stopColor="#14ccbb" stopOpacity="0.07" />
          </linearGradient>
        </defs>

        {/* zones */}
        <rect x="0" y={PAD_Y} width={FREEZE_X} height={H - PAD_Y * 2} fill="#f5f6f8" />
        <rect x={FREEZE_X} y={PAD_Y} width={OPEN_X - FREEZE_X} height={H - PAD_Y * 2} fill={`url(#${gradId}-night)`} />

        {/* percentage grid */}
        {[-8, -6, -4, -2, 0, 2, 4, 6, 8].map((pct) => {
          const y = pctToY(pct)
          return (
            <g key={pct}>
              <line
                x1="0"
                y1={y}
                x2={W}
                y2={y}
                stroke={pct === 0 ? '#94a3b8' : '#e8ebef'}
                strokeWidth={pct === 0 ? 1.4 : 1}
                strokeDasharray={pct === 0 ? '4 4' : undefined}
              />
              <text x={W - 8} y={y - 5} textAnchor="end" className="gc__axis">
                {pct > 0 ? `+${pct}%` : `${pct}%`} · {(spot * (1 + pct / 100)).toFixed(1)}
              </text>
            </g>
          )
        })}

        {/* the band that pays — bounded by the cap, because the payoff is capped */}
        <rect
          x={FREEZE_X}
          y={bandTop}
          width={OPEN_X - FREEZE_X}
          height={Math.max(0, bandBottom - bandTop)}
          fill={`url(#${gradId}-pay)`}
        />
        <line x1={FREEZE_X} y1={beY} x2={OPEN_X + 54} y2={beY} stroke={isCall ? '#22c55e' : '#ef4444'} strokeWidth="1.2" strokeDasharray="5 4" />
        <text x={FREEZE_X + 8} y={beY + 14} className="gc__tag" fill={isCall ? '#15803d' : '#b91c1c'}>
          breakeven {breakeven.toFixed(2)}
        </text>
        <line x1={FREEZE_X} y1={capY} x2={OPEN_X + 54} y2={capY} stroke="#ffb020" strokeWidth="1.2" strokeDasharray="5 4" />
        <text x={FREEZE_X + 8} y={capY - 6} className="gc__tag" fill="#b45309">
          cap {capEdge.toFixed(2)} — payout stops here
        </text>

        {/* strike */}
        <line x1={FREEZE_X} y1={strikeY} x2={OPEN_X} y2={strikeY} stroke="#0f172a" strokeWidth="1" strokeDasharray="2 4" opacity="0.55" />
        <text x={OPEN_X - 8} y={strikeY - 6} textAnchor="end" className="gc__tag" fill="#334155">
          strike {strike.toFixed(2)}
        </text>

        {/* 1-sigma cone */}
        <line x1={FREEZE_X} y1={sdTopY} x2={OPEN_X} y2={sdTopY} stroke="#7b61ff" strokeWidth="1" strokeDasharray="3 5" opacity="0.6" />
        <line x1={FREEZE_X} y1={sdBotY} x2={OPEN_X} y2={sdBotY} stroke="#7b61ff" strokeWidth="1" strokeDasharray="3 5" opacity="0.6" />
        <text x={OPEN_X - 8} y={sdTopY - 5} textAnchor="end" className="gc__tag" fill="#5b45c7">
          +1σ ({sigmaPct.toFixed(1)}%)
        </text>
        <text x={OPEN_X - 8} y={sdBotY + 13} textAnchor="end" className="gc__tag" fill="#5b45c7">
          −1σ ({sigmaPct.toFixed(1)}%)
        </text>

        {/* regular session */}
        <path d={sessionPath} fill="none" stroke="#94a3b8" strokeWidth="2" />
        <text x="22" y={PAD_Y + 15} className="gc__label">REGULAR SESSION</text>

        {/* freeze wall */}
        <line x1={FREEZE_X} y1={PAD_Y - 10} x2={FREEZE_X} y2={H - PAD_Y + 10} stroke="#ffb020" strokeWidth="2" />
        <rect x={FREEZE_X - 68} y={PAD_Y - 25} width="136" height="19" rx="4" fill="#fff8ea" stroke="#ffb020" />
        <text x={FREEZE_X} y={PAD_Y - 11} textAnchor="middle" className="gc__label" fill="#b45309">
          16:00 CLOSE FREEZE
        </text>

        {/* open line */}
        <line x1={OPEN_X} y1={PAD_Y - 10} x2={OPEN_X} y2={H - PAD_Y + 10} stroke="#cbd5e1" strokeWidth="1.5" strokeDasharray="4 4" />
        <text x={OPEN_X} y={H - PAD_Y + 24} textAnchor="middle" className="gc__label">09:30 OPEN</text>

        {/* the projection */}
        <path
          d={`M ${FREEZE_X} ${closeY} C ${FREEZE_X + 140} ${closeY}, ${OPEN_X - 140} ${targetY}, ${OPEN_X} ${targetY}`}
          fill="none"
          stroke={curveColor}
          strokeWidth="3"
          strokeDasharray="6 4"
        />

        {/* close anchor */}
        <circle cx={FREEZE_X} cy={closeY} r="5" fill="#0f172a" />
        <text x={FREEZE_X - 10} y={closeY - 9} textAnchor="end" className="gc__tag" fill="#0f172a">
          close {spot.toFixed(2)}
        </text>

        {/* the draggable target */}
        <circle cx={OPEN_X} cy={targetY} r="11" fill={curveColor} opacity="0.2" />
        <circle cx={OPEN_X} cy={targetY} r="5.5" fill={curveColor} />
        <rect x={OPEN_X + 12} y={targetY - 15} width="120" height="30" rx="6" fill="#fff" stroke={curveColor} />
        <text x={OPEN_X + 20} y={targetY - 2} className="gc__val" fill="#0f172a">
          {openPrice.toFixed(2)}
        </text>
        <text x={OPEN_X + 20} y={targetY + 11} className="gc__tag" fill={curveColor}>
          {gapPct >= 0 ? '+' : ''}{gapPct.toFixed(1)}% gap
        </text>
      </svg>

      <div className="gc__read">
        <div className="gc__cell">
          <span className="gc__k">At this open</span>
          <span className="gc__v">{openPrice.toFixed(2)}</span>
        </div>
        <div className="gc__cell">
          <span className="gc__k">Payout</span>
          <span className="gc__v">{payout.toFixed(2)} USDC</span>
        </div>
        <div className="gc__cell">
          <span className="gc__k">Net after premium</span>
          <span className={'gc__v ' + (net >= 0 ? 'vx-up' : 'vx-down')}>
            {net >= 0 ? '+' : ''}{net.toFixed(2)} USDC
          </span>
        </div>
        <div className="gc__cell">
          <span className="gc__k">Return on premium</span>
          <span className="gc__v">{roi.toFixed(2)}×</span>
        </div>
      </div>
      <p className="gc__hint">
        Drag the canvas, or use the arrow keys, to move Monday&rsquo;s open. The shaded band is
        where this option pays — it stops at the cap, which is exactly why the writer can fully
        collateralise it.
      </p>
    </div>
  )
}
