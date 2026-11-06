/* The sentence Gap is actually selling, with the numbers filled in.
   Same notional, two instruments: this capped option, and the 10x perp a trader
   would otherwise reach for. Presentational only — no reads, no writes. */

import { Badge, Card, KeyValue } from '../ui'
import { QUOTE_DECIMALS } from '../lib/strategy'

export interface CounterfactualProps {
  spot: number
  size: number
  premium: number
  /** cap x size — the most this option can ever pay out. */
  maxPayout: number
  isCall: boolean
}

/** 10x means a 10% adverse move eats the whole margin. */
const PERP_LEVERAGE = 10

export function Counterfactual({ spot, size, premium, maxPayout, isCall }: CounterfactualProps) {
  const notional = spot * size
  const margin = notional / PERP_LEVERAGE
  const liq = isCall ? spot * (1 - 1 / PERP_LEVERAGE) : spot * (1 + 1 / PERP_LEVERAGE)
  const side = isCall ? 'long' : 'short'

  return (
    <Card sunken pad>
      <div className="vx-row--between" style={{ marginBottom: 8 }}>
        <div style={{ font: '600 13px/18px var(--sans)' }}>Same bet, two ways</div>
        <Badge tone="outline">{notional.toFixed(0)} USDC notional</Badge>
      </div>

      <KeyValue
        rows={[
          [
            <span key="a">
              <Badge tone={isCall ? 'green' : 'red'}>this option</Badge> worst case
            </span>,
            <span key="b" className="mono">
              −{premium.toFixed(QUOTE_DECIMALS)} USDC (the premium)
            </span>,
          ],
          ['Best case', `+${Math.max(0, maxPayout - premium).toFixed(2)} USDC`],
          ['Liquidation price', 'none — there is no liquidation'],
          [
            <span key="c">
              <Badge tone="amber">10x perp {side}</Badge> liquidated at
            </span>,
            <span key="d" className="vx-down mono">
              ${liq.toFixed(2)}
            </span>,
          ],
          ['Loss there', `−${margin.toFixed(2)} USDC (the entire margin)`],
        ]}
      />

      <p style={{ margin: '10px 0 0', font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
        A 10x {side} on this size is liquidated at <b>${liq.toFixed(2)}</b>. This option&rsquo;s worst
        case is the <b>${premium.toFixed(2)}</b> premium, and it is paid up front.
      </p>
      <p style={{ margin: '6px 0 0', font: 'var(--t-body-s)', color: 'var(--muted)' }}>
        The perp figure is the bare arithmetic: {PERP_LEVERAGE}x margin wiped by a{' '}
        {(100 / PERP_LEVERAGE).toFixed(0)}% move. Funding, trading fees and maintenance margin are
        ignored, all of which make the real liquidation closer than this.
      </p>
    </Card>
  )
}
