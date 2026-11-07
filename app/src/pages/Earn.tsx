/* ============================================================================
   Earn — the maker's books.

   Shipping collateral into 1inch Aqua has one property worth staring at: `ship`
   does not move a single token. It writes an allowance-like entry on Aqua's books
   against the MAKER's own wallet, keyed by (maker, router, strategyHash, token).
   The ERC-20 only moves at fill time, when `AQUA.pull` does a real transferFrom.
   So the two numbers this view puts side by side — what Aqua thinks is committed,
   and what the maker wallet actually holds — can disagree, and when they do, the
   next fill reverts for whoever tries it.

   In WeekendOptions the maker is the WeekendDesk contract (it implements the Aqua
   hooks that mint option tokens inside preTransferOut). An EOA cannot usefully
   ship an ASK — it would have to hold the per-series option token up front — so
   this page is the desk's monitor, not a "ship as yourself" form. Each shipped
   quote (ask series 0, ask series 1, bid series 1) is read straight from Aqua:
   committed = rawBalances(desk, router, strategyHash, backingToken), and wallet =
   backingToken.balanceOf(desk). The ASK is backed by the option token (the cap the
   desk can write); the BID is backed by USDC (the budget the desk can spend buying
   options back).

   Contract surface: AQUA.rawBalances, router.hash, OptionToken/USDC.balanceOf,
   weekendOptions.hashStrategy. All reads — the desk ships from script/ShipAsk and
   ShipBid, by design.
   ========================================================================= */

import { useEffect, useMemo, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { formatUnits } from 'viem'
import { Anchor, ArrowDownRight, ArrowUpRight, Wallet } from 'lucide-react'
import { aquaAbi, erc20Abi, optionTokenAbi, routerAbi } from '../lib/abi'
import { volPct, QUOTE_DECIMALS, UNDERLYING_DECIMALS } from '../lib/strategy'
import {
  makerQuotes,
  type Deployment,
  type MakerQuote,
} from '../lib/deployment'
import { orderForQuote } from '../lib/orders'
import { Alert, Badge, Card, EmptyState, KeyValue, Panel, StatCard } from '../ui'
import { Inbox } from 'lucide-react'

export interface EarnProps {
  deployment: Deployment | null
  deployed: boolean
  onToast: (msg: string) => void
}

/** One shipped quote's Aqua backing, read live. */
interface QuoteBooks {
  quote: MakerQuote
  /** Which token backs this side: ASK = option token, BID = USDC. */
  backingToken: `0x${string}`
  backingSymbol: string
  decimals: number
  /** AQUA.rawBalances — what the router may pull against this strategy. */
  committed: number
  /** The desk wallet's real balance of the backing token. */
  wallet: number
  /** Does the rebuilt SwapVM order still hash to the shipped strategy? */
  hashOk: boolean
}

export function Earn({ deployment, deployed, onToast }: EarnProps) {
  void onToast
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
    const desk = deployment.desk as `0x${string}`
    const router = deployment.swapVmRouter as `0x${string}`

    void (async () => {
      try {
        const rows = await Promise.all(
          quotes.map(async (q): Promise<QuoteBooks> => {
            // ASK backing is the option token (the writable cap); BID backing is USDC.
            const isAsk = q.side === 'ask'
            const backingToken = (isAsk ? q.optionToken : deployment.usdc) as `0x${string}`
            const decimals = isAsk ? UNDERLYING_DECIMALS : QUOTE_DECIMALS

            // Gate the shipped quote exactly as the Trade side does: rebuild the
            // SwapVM order and confirm router.hash == the shipped strategyHash.
            const order = orderForQuote(deployment, q)

            const [raw, wallet, onchainHash, symbol] = await Promise.all([
              publicClient.readContract({
                address: deployment.aqua as `0x${string}`,
                abi: aquaAbi,
                functionName: 'rawBalances',
                args: [desk, router, q.strategyHash as `0x${string}`, backingToken],
              }) as Promise<readonly [bigint, number]>,
              publicClient.readContract({
                address: backingToken,
                abi: erc20Abi,
                functionName: 'balanceOf',
                args: [desk],
              }) as Promise<bigint>,
              publicClient.readContract({
                address: router,
                abi: routerAbi,
                functionName: 'hash',
                args: [order],
              }) as Promise<`0x${string}`>,
              isAsk
                ? (publicClient.readContract({
                    address: backingToken,
                    abi: optionTokenAbi,
                    functionName: 'symbol',
                  }) as Promise<string>)
                : Promise.resolve('USDC'),
            ])

            return {
              quote: q,
              backingToken,
              backingSymbol: symbol,
              decimals,
              committed: Number(formatUnits(raw[0], decimals)),
              wallet: Number(formatUnits(wallet, decimals)),
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
              Each shipped quote is a resting order backed by a real token sitting in the desk
              wallet. <b>An ASK is backed by the option token</b> (the cap the desk can write);{' '}
              <b>a BID is backed by USDC</b> (the budget it can spend buying options back). Nothing
              is escrowed — the backing stays put until a buyer turns up.
            </p>
            <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
              If <em>committed</em> ever exceeds <em>wallet</em>, Aqua&rsquo;s books overstate what a
              <code>pull</code> can actually draw, and the next fill large enough to need the missing
              tokens reverts. This view is how you catch that before a taker does.
            </p>
          </div>
        </Panel>

        {err && (
          <Alert tone="error" title="Could not read the desk's Aqua books">
            <code>{err}</code>
          </Alert>
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
            title={loading ? 'Reading the desk&rsquo;s books…' : 'No shipped quotes'}
            description="The desk ships asks and bids from script/ShipAsk and ShipBid."
          />
        )}
      </div>

      <div className="vx-col">
        {books.map((b) => {
          const underfunded = b.committed > 0 && b.wallet < b.committed
          const isAsk = b.quote.side === 'ask'
          return (
            <Card key={b.quote.key}>
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
                    pair="Committed on Aqua"
                    color="#7b61ff"
                    value={b.committed.toFixed(2)}
                    sub={`rawBalances · ${b.backingSymbol}`}
                  />
                  <StatCard
                    pair="Desk wallet"
                    color={underfunded ? '#ef4444' : '#22c55e'}
                    value={b.wallet.toFixed(2)}
                    sub={`${b.backingSymbol}.balanceOf(desk)`}
                  />
                </div>

                {underfunded && (
                  <Alert tone="error" title="Books overstate the wallet">
                    Aqua says <b>{b.committed.toFixed(2)} {b.backingSymbol}</b> is committed, but the
                    desk wallet holds <b>{b.wallet.toFixed(2)}</b>. The next fill that needs the
                    missing backing reverts at <code>pull</code>.
                  </Alert>
                )}

                {!underfunded && b.committed > 0 && (
                  <Alert tone="success" title="Backing is real">
                    Committed and held match — fills inside{' '}
                    <b>{b.committed.toFixed(2)} {b.backingSymbol}</b> clear without reverting.
                  </Alert>
                )}

                <KeyValue
                  rows={[
                    ['Strategy hash', <code key="h">{b.quote.strategyHash}</code>],
                    ['Backing token', `${b.backingSymbol} (${isAsk ? 'option cap' : 'USDC budget'})`],
                    ['Gate', b.hashOk ? 'router.hash matches shipped' : 'HASH MISMATCH'],
                    ['Min premium', `${b.quote.minPremiumBps} bps floor`],
                  ]}
                />
              </div>
            </Card>
          )
        })}

        {canRead && books.length > 0 && (
          <Panel title="Why it's read-only" icon={<Wallet size={16} />}>
            <p style={{ margin: 0, font: 'var(--t-body-s)', color: 'var(--muted)' }}>
              The maker is the <code>WeekendDesk</code> contract — it implements the Aqua hooks that
              mint option tokens mid-fill, which an EOA can&rsquo;t do. Shipping happens from{' '}
              <code>script/ShipAsk.s.sol</code> / <code>ShipBid.s.sol</code> as the desk; this page
              watches the result.
            </p>
          </Panel>
        )}
      </div>
    </div>
  )
}
