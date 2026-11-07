/* ============================================================================
   Earn — the maker's books.

   Shipping collateral into 1inch Aqua has one property worth staring at: `ship`
   does not move a single token. It writes an allowance-like entry on Aqua's books
   against the MAKER's own wallet, keyed by (maker, router, strategyHash, token).
   The ERC-20 only moves at fill time, when `AQUA.pull` does a real transferFrom.

   WHAT "BACKED" MEANS IS DIFFERENT ON EACH SIDE, and getting that wrong is how an
   earlier version of this page painted two red alarms over a perfectly healthy desk.

     BID — the desk owes USDC. The backing is literal: it must HOLD the quote token,
       and `committed > balanceOf(desk)` genuinely means the next large fill reverts
       inside `pull`.

     ASK — the desk owes OPTION TOKENS, and it holds ZERO of them by design. There is
       no inventory to hold: `WeekendDesk._mintShortfall` mints the exact shortfall
       inside `preTransferOut`, and `AQUA.pull` then moves tokens that did not exist
       one call earlier. `balanceOf(desk) == 0` is the NORMAL state, not a fault.
       What actually backs an ask is the COVER behind the mint — the desk's own
       core-protocol strategy — capped by `maxShort`. So this page compares the
       shipped option cap against what can really be written, which is what
       `lib/capacity.ts` computes for the ticket.

   Contract surface: AQUA.rawBalances, router.hash, WeekendOptions.getSeries /
   written, WeekendDesk.maxShort, ERC-20 balanceOf. All reads — the desk ships from
   script/ShipAsk and ShipBid, by design.
   ========================================================================= */

import { useEffect, useMemo, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { formatUnits } from 'viem'
import { Anchor, ArrowDownRight, ArrowUpRight, Inbox, Wallet } from 'lucide-react'
import { optionTokenAbi, routerAbi, weekendOptionsAbi } from '../lib/abi'
import { volPct, QUOTE_DECIMALS, UNDERLYING_DECIMALS } from '../lib/strategy'
import { readCapacity, type Capacity } from '../lib/capacity'
import { KIND, type OptionKind } from '../lib/pricing'
import { makerQuotes, type Deployment, type MakerQuote } from '../lib/deployment'
import { orderForQuote } from '../lib/orders'
import { Alert, Badge, Card, EmptyState, KeyValue, Panel, StatCard } from '../ui'
import { EarnShip } from './EarnShip'

export interface EarnProps {
  deployment: Deployment | null
  deployed: boolean
  onToast: (msg: string) => void
}

/** One shipped quote's Aqua backing, read live. */
interface QuoteBooks {
  quote: MakerQuote
  kind: OptionKind
  cap: Capacity
  /** ERC-20 symbol of whatever the side sells (option token / USDC). */
  symbol: string
  /** Does the rebuilt SwapVM order still hash to the shipped strategy? */
  hashOk: boolean
}

const u = (v: bigint) => Number(formatUnits(v, UNDERLYING_DECIMALS))
const q6 = (v: bigint) => Number(formatUnits(v, QUOTE_DECIMALS))

export function Earn({ deployment, deployed, onToast }: EarnProps) {
  const publicClient = usePublicClient()
  const quotes = useMemo(() => (deployment ? makerQuotes(deployment) : []), [deployment])

  const [books, setBooks] = useState<QuoteBooks[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const canRead = deployed && !!deployment?.aqua && !!deployment?.swapVmRouter && !!publicClient

  useEffect(() => {
    if (!canRead || !deployment || !publicClient) {
      setBooks([])
      return
    }
    let cancelled = false
    setLoading(true)
    const router = deployment.swapVmRouter as `0x${string}`

    void (async () => {
      try {
        const rows = await Promise.all(
          quotes.map(async (q): Promise<QuoteBooks> => {
            const isAsk = q.side === 'ask'
            const ser = (await publicClient.readContract({
              address: deployment.weekendOptions as `0x${string}`,
              abi: weekendOptionsAbi,
              functionName: 'getSeries',
              args: [BigInt(q.seriesId)],
            })) as { kind: number; strike: bigint }
            const kind = (ser.kind === 1 ? KIND.PUT : KIND.CALL) as OptionKind

            // Gate the shipped quote exactly as the Trade side does: rebuild the
            // SwapVM order and confirm router.hash == the shipped strategyHash.
            const order = orderForQuote(deployment, q)

            const [cap, onchainHash, symbol] = await Promise.all([
              readCapacity(publicClient, deployment, q, kind, ser.strike),
              publicClient.readContract({
                address: router,
                abi: routerAbi,
                functionName: 'hash',
                args: [order],
              }) as Promise<`0x${string}`>,
              isAsk
                ? (publicClient.readContract({
                    address: q.optionToken as `0x${string}`,
                    abi: optionTokenAbi,
                    functionName: 'symbol',
                  }) as Promise<string>)
                : Promise.resolve('USDC'),
            ])

            return {
              quote: q,
              kind,
              cap,
              symbol,
              hashOk: onchainHash.toLowerCase() === q.strategyHash.toLowerCase(),
            }
          }),
        )
        if (cancelled) return
        setBooks(rows)
        setErr(null)
      } catch (e) {
        if (cancelled) return
        setBooks([])
        setErr(e instanceof Error ? e.message.split('\n')[0] : 'Aqua read failed')
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [canRead, deployment, publicClient, quotes])

  return (
    <div className="vx-grid vx-grid--desk">
      <div className="vx-col">
        <Panel
          title="The desk's books on Aqua"
          icon={<Anchor size={16} />}
          footer={
            <>
              Collateral and premium both move through <strong>1inch Aqua</strong>:{' '}
              <code>ship</code> registers the commitment against the desk&rsquo;s wallet,{' '}
              <code>pull</code> draws the backing out when a fill lands, and <code>push</code>{' '}
              deposits the premium back. The app never custodies anything.
            </>
          }
        >
          <div className="vx-col">
            <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
              Each shipped quote is a resting order with a <b>permanent</b> cap:{' '}
              <code>Aqua.ship</code> is immutable, so the amount shipped is everything that order
              can ever sell. Re-offering after it is exhausted needs a new salt, which hashes to a
              different strategy.
            </p>
            <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
              <b>An ASK is not backed by inventory.</b> The desk holds zero option tokens and mints
              the exact shortfall inside <code>preTransferOut</code>, so what really backs it is the
              cover behind that mint — NVDAx for a CALL, USDC for a PUT — bounded by the desk&rsquo;s
              own <code>maxShort</code>. <b>A BID is backed literally</b>: the desk has to hold the
              USDC it owes.
            </p>
          </div>
        </Panel>

        {err && (
          <Alert tone="error" title="Could not read the desk's Aqua books">
            <code>{err}</code>
          </Alert>
        )}

        {canRead && (
          <EarnShip deployment={deployment} deployed={deployed} onToast={onToast} />
        )}

        {!canRead && (
          <Alert tone="info" title="Preview mode">
            Point <code>app/public/deployments/base-sepolia.json</code> at a live deploy to read the
            desk&rsquo;s shipped quotes off Aqua.
          </Alert>
        )}

        {canRead && books.length === 0 && (
          <EmptyState
            icon={<Inbox size={18} />}
            title={loading ? 'Reading the desk’s books…' : 'No shipped quotes'}
            description="The desk ships asks and bids from script/ShipAsk and ShipBid."
          />
        )}
      </div>

      <div className="vx-col">
        {books.map((b) => (
          <QuoteBooksCard key={b.quote.key} b={b} />
        ))}

        {canRead && books.length > 0 && (
          <Panel title="Who can be the maker" icon={<Wallet size={16} />}>
            <p style={{ margin: 0, font: 'var(--t-body-s)', color: 'var(--muted)' }}>
              The maker is the <code>WeekendDesk</code> contract — it implements the Aqua hooks that
              mint option tokens mid-fill, which an EOA can&rsquo;t do. But{' '}
              <code>WeekendDesk.ship</code> is <code>onlyOwner</code> and forwards to{' '}
              <code>AQUA.ship</code>, so the desk&rsquo;s owner can ship from a wallet, in the panel on the left.{' '}
              <code>script/ShipAsk.s.sol</code> only prints calldata because the EOA running it is
              not the desk.
            </p>
          </Panel>
        )}
      </div>
    </div>
  )
}

function QuoteBooksCard({ b }: { b: QuoteBooks }) {
  const cap = b.cap
  const isAsk = cap.side === 'ask'
  const isCall = b.kind === KIND.CALL
  const coverSymbol = isCall ? 'NVDAx' : 'USDC'
  const coverDp = isCall ? UNDERLYING_DECIMALS : QUOTE_DECIMALS

  // An ask is underfunded when the cover cannot write the cap Aqua is advertising —
  // NOT when the desk holds no option tokens, which is its permanent resting state.
  const shipped = cap.side === 'ask' ? cap.ledgerOptions : cap.ledgerUsdc
  const fillable = cap.side === 'ask' ? cap.options : cap.usdc
  const short = fillable < shipped

  return (
    <Card>
      <div className="vx-panel__head">
        <div className="vx-panel__title">
          {isAsk ? <ArrowUpRight size={16} /> : <ArrowDownRight size={16} />} Series{' '}
          {b.quote.seriesId} · {isAsk ? 'ASK' : 'BID'}
        </div>
        <Badge tone={isAsk ? 'green' : 'red'}>IV {volPct(b.quote.volWad)}%</Badge>
      </div>
      <div className="vx-panel__body vx-col">
        <div className="vx-grid vx-grid--stats">
          <StatCard
            pair="Shipped cap"
            color="#7b61ff"
            value={isAsk ? u(shipped).toFixed(2) : q6(shipped).toFixed(2)}
            sub={isAsk ? `${b.symbol} · immutable` : 'USDC budget · immutable'}
          />
          <StatCard
            pair="Can actually fill"
            color={short ? '#f59e0b' : '#22c55e'}
            value={isAsk ? u(fillable).toFixed(2) : q6(fillable).toFixed(2)}
            sub={isAsk ? 'options, cover + maxShort bound' : 'USDC the desk really holds'}
          />
        </div>

        {short && (
          <Alert tone="warning" title="Cover binds before the shipped cap">
            Aqua advertises <b>{isAsk ? u(shipped).toFixed(2) : q6(shipped).toFixed(2)}</b>, but only{' '}
            <b>{isAsk ? u(fillable).toFixed(2) : q6(fillable).toFixed(2)}</b> can be filled
            {isAsk ? ' against the cover and short cap the desk has left' : ' from the desk wallet'}.
            Fills above that revert at <code>pull</code>.
          </Alert>
        )}

        {!short && fillable > 0n && (
          <Alert tone="success" title="Backing is real">
            The full shipped amount can be filled — cover and caps clear it.
          </Alert>
        )}

        <KeyValue
          rows={
            isAsk && b.cap.side === 'ask'
              ? [
                  ['Strategy hash', <code key="h" title={b.quote.strategyHash}>{`${b.quote.strategyHash.slice(0, 10)}…${b.quote.strategyHash.slice(-8)}`}</code>],
                  [
                    'Cover committed',
                    `${Number(formatUnits(b.cap.coverCommitted, coverDp)).toFixed(2)} ${coverSymbol}`,
                  ],
                  [
                    'Cover in wallet',
                    `${Number(formatUnits(b.cap.coverWallet, coverDp)).toFixed(2)} ${coverSymbol}`,
                  ],
                  ['Short cap headroom', `${u(b.cap.shortHeadroom).toFixed(2)} options`],
                  ['Inventory held', `${u(b.cap.inventory).toFixed(2)} ${b.symbol} · minted JIT`],
                  ['Gate', b.hashOk ? 'router.hash matches shipped' : 'HASH MISMATCH'],
                  ['Min premium', `${b.quote.minPremiumBps} bps floor`],
                ]
              : [
                  ['Strategy hash', <code key="h" title={b.quote.strategyHash}>{`${b.quote.strategyHash.slice(0, 10)}…${b.quote.strategyHash.slice(-8)}`}</code>],
                  [
                    'USDC in wallet',
                    `${q6(b.cap.side === 'bid' ? b.cap.walletUsdc : 0n).toFixed(2)} USDC`,
                  ],
                  ['Gate', b.hashOk ? 'router.hash matches shipped' : 'HASH MISMATCH'],
                  ['Min premium', `${b.quote.minPremiumBps} bps floor`],
                ]
          }
        />
      </div>
    </Card>
  )
}
