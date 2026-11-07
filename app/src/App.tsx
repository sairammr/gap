/* ============================================================================
   Weekend Options desk — the trade interface.

   Layout follows kuru.io/trade 1:1: resting orders listed on the LEFT (one row
   per shipped maker quote, ASK green above / BID red below the v4 mid), the
   chart + position tabs in the CENTER, and the Buy/Sell order ticket on the
   RIGHT. Clicking a resting order loads its series + maker into the ticket.

   The product is WeekendOptions on 1inch Aqua (Base Sepolia): fully-collateralised
   physically-settled CALL/PUT on NVDAx, one ERC-20 per series, priced + settled in
   USDC. Fills go through the REAL AquaSwapVMRouter — the exact path proven on-chain
   in contracts/script/Lifecycle.s.sol:
     Buy  = swap(ASK order, usdcIn,  tt(usdc, minOptionsOut))   exact-in USDC
     Sell = swap(BID order, optIn,   tt(option, minUsdcOut))    exact-in options
   Every order is rebuilt in-app (lib/orders.ts, byte-identical to OrderLib.sol)
   and GATED (router.hash(order) == the shipped strategyHash) before any fill.
   ========================================================================= */

import { useEffect, useMemo, useState } from 'react'
import {
  Activity as ActivityIcon,
  Anchor,
  ArrowLeftRight,
  BookOpen,
  Clock,
  Coins,
  Inbox,
  Layers,
  Lock,
  TrendingDown,
  TrendingUp,
  Wallet,
  Palette,
} from 'lucide-react'
import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { usePrivy } from '@privy-io/react-auth'
import { formatUnits, parseUnits } from 'viem'
import { erc20Abi, optionTokenAbi, routerAbi, weekendOptionsAbi } from './lib/abi'
import {
  loadDeployment,
  isDeployed,
  canTrade,
  makerQuotes,
  QUOTE_DECIMALS,
  UNDERLYING_DECIMALS,
  type Deployment,
  type MakerQuote,
} from './lib/deployment'
import { volPct } from './lib/strategy'
import { orderForQuote, takerTraits } from './lib/orders'
import { usePositions, type Position, type HistoryRow } from './hooks/usePositions'
import { KIND, premiumPerUnit, type OptionKind } from './lib/pricing'
import { useSpotSeries } from './hooks/useSpotSeries'
import { PriceChart } from './components/PriceChart'
import { Earn } from './pages/Earn'
import {
  Alert,
  Backdrop,
  Badge,
  Button,
  Card,
  EmptyState,
  Field,
  Input,
  KeyValue,
  Modal,
  Panel,
  QuickPills,
  Segmented,
  TopNav,
  StatCard,
  Table,
  Tabs,
  TokenDot,
  Toast,
} from './ui'

const NAV = [
  { key: 'trade', label: 'Trade', icon: <ArrowLeftRight size={16} /> },
  { key: 'earn', label: 'Earn', icon: <Anchor size={16} /> },
  { key: 'positions', label: 'Positions', icon: <Layers size={16} /> },
  { key: 'activity', label: 'History', icon: <ActivityIcon size={16} /> },
  { key: 'docs', label: 'How it settles', icon: <BookOpen size={16} /> },
  { key: 'kit', label: 'UI kit', icon: <Palette size={16} /> },
]

const VIEW_KEYS = NAV.map((n) => n.key)
function viewFromHash(): string {
  const h = location.hash.replace(/^#/, '')
  return VIEW_KEYS.includes(h) ? h : 'trade'
}

/** Series kind read from chain, keyed by seriesId. JSON carries no kind, so the
 *  resting rows show CALL until this resolves (both deployed series are CALL). */
type KindMap = Record<number, OptionKind>

export default function App() {
  const { address, isConnected } = useAccount()
  const { ready, authenticated, login, logout } = usePrivy()
  const publicClient = usePublicClient()
  const { writeContractAsync, isPending } = useWriteContract()

  const [deployment, setDeployment] = useState<Deployment | null>(null)
  const [loadingDeploy, setLoadingDeploy] = useState(true)
  const deployed = isDeployed(deployment)
  const tradable = canTrade(deployment)

  const [view, setView] = useState(viewFromHash)
  const [wsTab, setWsTab] = useState('positions')
  const [confirm, setConfirm] = useState(false)
  const [toast, setToast] = useState<string | null>(null)

  useEffect(() => {
    loadDeployment()
      .then(setDeployment)
      .finally(() => setLoadingDeploy(false))
  }, [])

  useEffect(() => {
    const onHash = () => setView(viewFromHash())
    addEventListener('hashchange', onHash)
    return () => removeEventListener('hashchange', onHash)
  }, [])

  useEffect(() => {
    if (!toast) return
    const id = setTimeout(() => setToast(null), 3200)
    return () => clearTimeout(id)
  }, [toast])

  const spot = useSpotSeries(deployment, deployed)
  const spotPrice = spot.lastSpot ?? 100
  const closes = useMemo(() => spot.candles.map((c) => c.close), [spot.candles])

  // The shipped resting orders, straight from the deployment (no log scan to paint).
  const quotes = useMemo(() => (deployment ? makerQuotes(deployment) : []), [deployment])

  // Series kind + strike/expiry, read once from chain so the rows are accurate.
  const [kinds, setKinds] = useState<KindMap>({})
  useEffect(() => {
    if (!deployed || !deployment || !publicClient) return
    let cancelled = false
    const ids = [...new Set(quotes.map((q) => q.seriesId))]
    void Promise.all(
      ids.map(async (id) => {
        const ser = (await publicClient.readContract({
          address: deployment.weekendOptions as `0x${string}`,
          abi: weekendOptionsAbi,
          functionName: 'getSeries',
          args: [BigInt(id)],
        })) as { kind: number }
        return [id, (ser.kind === 1 ? KIND.PUT : KIND.CALL) as OptionKind] as const
      }),
    )
      .then((entries) => {
        if (!cancelled) setKinds(Object.fromEntries(entries))
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [deployed, deployment, publicClient, quotes])

  // --- ticket state ---------------------------------------------------------
  // The ticket trades ONE selected resting order. Buy fills an ASK, sell fills a
  // BID. Default to the first ask so the ticket is live on first paint.
  const [tab, setTab] = useState<'buy' | 'sell'>('buy')
  const asks = useMemo(() => quotes.filter((q) => q.side === 'ask'), [quotes])
  const bids = useMemo(() => quotes.filter((q) => q.side === 'bid'), [quotes])
  const [selectedKey, setSelectedKey] = useState<string | null>(null)

  // Resolve the active quote: the clicked row if it matches the tab's side,
  // else the first order on that side.
  const sideQuotes = tab === 'buy' ? asks : bids
  const selected =
    sideQuotes.find((q) => q.key === selectedKey) ?? sideQuotes[0] ?? null

  const [size, setSize] = useState(1) // option units (18dp notional)

  const seriesKind = selected ? (kinds[selected.seriesId] ?? KIND.CALL) : KIND.CALL
  const strikeUsd = useMemo(() => {
    if (!deployment || !selected) return 0
    return selected.seriesId === deployment.shortSeriesId
      ? deployment.shortStrike / 10 ** QUOTE_DECIMALS
      : deployment.strike / 10 ** QUOTE_DECIMALS
  }, [deployment, selected])
  const expiry = useMemo(() => {
    if (!deployment || !selected) return 0
    return selected.seriesId === deployment.shortSeriesId ? deployment.shortExpiry : deployment.expiry
  }, [deployment, selected])
  const secondsToExpiry = Math.max(0, expiry - Math.floor(Date.now() / 1000))
  const vol = selected ? Number(selected.volWad) / 1e18 : 0.6

  // --- client-side premium preview (instant) -------------------------------
  const previewUnit = useMemo(
    () => (selected ? premiumPerUnit(seriesKind, spotPrice, strikeUsd, secondsToExpiry, vol) : 0),
    [selected, seriesKind, spotPrice, strikeUsd, secondsToExpiry, vol],
  )
  const previewTotal = previewUnit * size

  // --- binding on-chain quote: quotePremium for the premium shown ----------
  const [onchainPremium, setOnchainPremium] = useState<number | null>(null)
  const [quoteErr, setQuoteErr] = useState<string | null>(null)
  useEffect(() => {
    let cancelled = false
    setQuoteErr(null)
    if (!deployed || !deployment || !publicClient || !selected || size <= 0) {
      setOnchainPremium(null)
      return
    }
    publicClient
      .readContract({
        address: deployment.weekendOptions as `0x${string}`,
        abi: weekendOptionsAbi,
        functionName: 'quotePremium',
        args: [
          strategyFromQuote(deployment, selected),
          BigInt(selected.seriesId),
          parseUnits(String(size), UNDERLYING_DECIMALS),
        ],
      })
      .then((p) => {
        if (!cancelled) setOnchainPremium(Number(formatUnits(p as bigint, QUOTE_DECIMALS)))
      })
      .catch((e) => {
        if (!cancelled) {
          setOnchainPremium(null)
          setQuoteErr(e instanceof Error ? e.message.split('\n')[0] : 'quote read failed')
        }
      })
    return () => {
      cancelled = true
    }
  }, [deployed, deployment, publicClient, selected, size])

  const bindingPremium = onchainPremium ?? previewTotal

  // --- maker backable capacity (the real ceiling on size) ------------------
  const [backable, setBackable] = useState<number | null>(null)
  useEffect(() => {
    let cancelled = false
    if (!deployed || !deployment || !publicClient || !selected) {
      setBackable(null)
      return
    }
    // CALL cover is underlying (NVDAx, 18dp); PUT cover is USDC (6dp).
    const token = seriesKind === KIND.CALL ? deployment.nvdax : deployment.usdc
    const dec = seriesKind === KIND.CALL ? UNDERLYING_DECIMALS : QUOTE_DECIMALS
    publicClient
      .readContract({
        address: deployment.weekendOptions as `0x${string}`,
        abi: weekendOptionsAbi,
        functionName: 'makerCapacity',
        args: [strategyFromQuote(deployment, selected), token as `0x${string}`],
      })
      .then((res) => {
        if (cancelled) return
        const b = (res as readonly [bigint, bigint, bigint])[2]
        setBackable(Number(formatUnits(b, dec)))
      })
      .catch(() => {
        if (!cancelled) setBackable(null)
      })
    return () => {
      cancelled = true
    }
  }, [deployed, deployment, publicClient, selected, seriesKind])

  // Positions + history off the chain.
  const chain = usePositions(deployment, deployed, address)

  /* -- actions ------------------------------------------------------------ */

  // Buy: fill the selected ASK. Exact-in USDC (the premium), options out.
  async function handleBuy() {
    if (!deployment || !address || !publicClient || !selected) return
    const router = deployment.swapVmRouter as `0x${string}`
    const order = orderForQuote(deployment, selected)

    // Gate: the rebuilt order MUST hash to the shipped strategy or the fill
    // reverts inside Aqua. Refuse to even send if it does not.
    const onchainHash = (await publicClient.readContract({
      address: router,
      abi: routerAbi,
      functionName: 'hash',
      args: [order],
    })) as `0x${string}`
    if (onchainHash.toLowerCase() !== selected.strategyHash.toLowerCase()) {
      setToast('Order gate failed — rebuilt order does not match the shipped quote')
      return
    }

    // Spend the quoted premium + a little slack, exact-in USDC.
    const premiumIn = parseUnits((bindingPremium * 1.02).toFixed(QUOTE_DECIMALS), QUOTE_DECIMALS)
    const ttQuote = takerTraits(deployment.usdc, selected.optionToken, deployment.usdc, 1n)
    const [, quotedOut] = (await publicClient.readContract({
      address: router,
      abi: routerAbi,
      functionName: 'quote',
      args: [order, premiumIn, ttQuote],
    })) as readonly [bigint, bigint, `0x${string}`]
    const minOut = (quotedOut * 95n) / 100n

    const allowance = (await publicClient.readContract({
      address: deployment.usdc as `0x${string}`,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [address, router],
    })) as bigint
    if (allowance < premiumIn) {
      setToast('Approving USDC for the router…')
      const approveHash = await writeContractAsync({
        address: deployment.usdc as `0x${string}`,
        abi: erc20Abi,
        functionName: 'approve',
        args: [router, premiumIn],
      })
      await publicClient.waitForTransactionReceipt({ hash: approveHash })
    }

    const ttSwap = takerTraits(deployment.usdc, selected.optionToken, deployment.usdc, minOut)
    const buyHash = await writeContractAsync({
      address: router,
      abi: routerAbi,
      functionName: 'swap',
      args: [order, premiumIn, ttSwap],
    })
    setToast('Buy submitted via SwapVM router')
    await publicClient.waitForTransactionReceipt({ hash: buyHash })
    chain.refetch()
    setToast('Options bought')
  }

  // Sell: fill the selected BID. Exact-in options, USDC out (mirror Lifecycle.sellBack).
  async function handleSell() {
    if (!deployment || !address || !publicClient || !selected) return
    const router = deployment.swapVmRouter as `0x${string}`
    const order = orderForQuote(deployment, selected)

    const onchainHash = (await publicClient.readContract({
      address: router,
      abi: routerAbi,
      functionName: 'hash',
      args: [order],
    })) as `0x${string}`
    if (onchainHash.toLowerCase() !== selected.strategyHash.toLowerCase()) {
      setToast('Order gate failed — rebuilt order does not match the shipped quote')
      return
    }

    const optionIn = parseUnits(String(size), UNDERLYING_DECIMALS)
    const ttQuote = takerTraits(deployment.usdc, selected.optionToken, selected.optionToken, 1n)
    const [, quotedUsdc] = (await publicClient.readContract({
      address: router,
      abi: routerAbi,
      functionName: 'quote',
      args: [order, optionIn, ttQuote],
    })) as readonly [bigint, bigint, `0x${string}`]
    const minOut = (quotedUsdc * 95n) / 100n

    const allowance = (await publicClient.readContract({
      address: selected.optionToken as `0x${string}`,
      abi: optionTokenAbi,
      functionName: 'allowance',
      args: [address, router],
    })) as bigint
    if (allowance < optionIn) {
      setToast('Approving options for the router…')
      const approveHash = await writeContractAsync({
        address: selected.optionToken as `0x${string}`,
        abi: optionTokenAbi,
        functionName: 'approve',
        args: [router, optionIn],
      })
      await publicClient.waitForTransactionReceipt({ hash: approveHash })
    }

    const ttSwap = takerTraits(deployment.usdc, selected.optionToken, selected.optionToken, minOut)
    const sellHash = await writeContractAsync({
      address: router,
      abi: routerAbi,
      functionName: 'swap',
      args: [order, optionIn, ttSwap],
    })
    setToast('Sell submitted via SwapVM router')
    await publicClient.waitForTransactionReceipt({ hash: sellHash })
    chain.refetch()
    setToast('Options sold into the bid')
  }

  async function onPlace() {
    setConfirm(false)
    if (tab === 'buy') await handleBuy()
    else await handleSell()
  }

  async function mintTestUsdc() {
    if (!deployment?.usdc || !address) return
    await writeContractAsync({
      address: deployment.usdc as `0x${string}`,
      abi: erc20Abi,
      functionName: 'mint',
      args: [address, parseUnits('1000', QUOTE_DECIMALS)],
    })
    setToast('Minted 1,000 test USDC')
  }

  // Exercise / close / settle / redeem / claim, all per-position (Positions tab).
  const actions = usePositionActions(deployment, publicClient, writeContractAsync, setToast, chain.refetch)

  /* -- pieces ------------------------------------------------------------- */

  const chartPanel = (
    <Card>
      <div className="ck-head">
        <div>
          <div className="ck-pair">
            <TokenDot symbol="N" color="#76b900" /> NVDAx / USDC
          </div>
          <div className="ck-price">
            <b>{spotPrice.toFixed(2)}</b>
          </div>
        </div>
        <div className="ck-tools">
          <Badge tone={spot.synthetic ? 'amber' : 'green'}>
            {spot.synthetic ? 'synthetic spot' : 'live v4 spot'}
          </Badge>
        </div>
      </div>
      <PriceChart candles={spot.candles} synthetic={spot.synthetic} />
    </Card>
  )

  // LEFT panel — resting orders by side (Kuru's book column).
  const restingOrders = (
    <Card>
      <div className="vx-panel__head">
        <div className="vx-panel__title">Resting orders</div>
        <Badge tone="outline">NVDAx / USDC</Badge>
      </div>
      <div className="vx-book">
        <div className="vx-book__hd">
          <span>Series</span>
          <span style={{ textAlign: 'right' }}>IV</span>
          <span style={{ textAlign: 'right' }}>Size</span>
        </div>
        {/* ASKs above the mid (green) */}
        {asks.length === 0 && <div className="vx-book__empty">No asks shipped</div>}
        {asks.map((q) => (
          <QuoteRow
            key={q.key}
            q={q}
            kind={kinds[q.seriesId] ?? KIND.CALL}
            strikeUsd={quoteStrike(deployment, q)}
            active={selected?.key === q.key && tab === 'buy'}
            onClick={() => {
              setTab('buy')
              setSelectedKey(q.key)
            }}
          />
        ))}
        <div className="vx-book__mid">
          <span>v4 spot</span>
          <b>{spotPrice.toFixed(2)}</b>
        </div>
        {/* BIDs below the mid (red) */}
        {bids.length === 0 && <div className="vx-book__empty">No bids shipped</div>}
        {bids.map((q) => (
          <QuoteRow
            key={q.key}
            q={q}
            kind={kinds[q.seriesId] ?? KIND.CALL}
            strikeUsd={quoteStrike(deployment, q)}
            active={selected?.key === q.key && tab === 'sell'}
            onClick={() => {
              setTab('sell')
              setSelectedKey(q.key)
            }}
          />
        ))}
      </div>
    </Card>
  )

  const isCall = seriesKind === KIND.CALL
  const noBindingQuote = tradable && isConnected && onchainPremium === null
  const sellDisabled = tab === 'sell' && bids.length === 0

  // RIGHT panel — the Buy/Sell order ticket.
  const ticket = (
    <Card>
      <div className="vx-panel__body vx-col">
        <Segmented
          block
          value={tab}
          onChange={(v) => setTab(v as 'buy' | 'sell')}
          aria-label="Side"
          options={[
            { value: 'buy', label: 'Buy', tone: 'up' },
            { value: 'sell', label: 'Sell', tone: 'down' },
          ]}
        />

        {!selected ? (
          <EmptyState
            icon={<Inbox size={18} />}
            title={tab === 'buy' ? 'No ask to buy' : 'No bid to sell into'}
            description="Pick a resting order on the left, or ship one in the Earn view."
          />
        ) : (
          <>
            <div className="vx-row" style={{ justifyContent: 'space-between' }}>
              <Badge tone={isCall ? 'green' : 'red'} icon={isCall ? <TrendingUp size={12} /> : <TrendingDown size={12} />}>
                {isCall ? 'CALL' : 'PUT'} · series {selected.seriesId}
              </Badge>
              <Badge tone="outline">IV {volPct(selected.volWad)}%</Badge>
            </div>

            <Field label="Size" htmlFor="tk-size" aside={<Badge tone="outline">options</Badge>}>
              <Input
                id="tk-size"
                type="number"
                min={0}
                step={0.5}
                mono
                inputSize="lg"
                value={size}
                onChange={(e) => setSize(Math.max(0, Number(e.target.value)))}
                trailing="opt"
              />
            </Field>
            <QuickPills
              options={[1, 2, 5, 10]}
              value={size}
              onPick={setSize as never}
              format={(v) => Number(v).toFixed(0)}
            />

            <Button
              variant="primary"
              block
              size="lg"
              loading={isPending}
              disabled={!tradable || !isConnected || size <= 0 || noBindingQuote || sellDisabled}
              title={
                noBindingQuote
                  ? 'No binding on-chain quote — trading is unsafe'
                  : sellDisabled
                    ? 'No resting bid to sell into'
                    : undefined
              }
              onClick={() => setConfirm(true)}
            >
              {tab === 'buy' ? 'Buy options' : 'Sell into bid'}
            </Button>

            {noBindingQuote && (
              <Alert tone="warning" title="No binding quote">
                The on-chain <code>quotePremium</code> read failed
                {quoteErr ? ` (${quoteErr})` : ''}; the price shown is a client-side estimate only.
              </Alert>
            )}

            <div className="tk-sum">
              {(
                [
                  ['Strike', `${strikeUsd.toFixed(2)} USDC`],
                  ['Premium', `${bindingPremium.toFixed(QUOTE_DECIMALS)} USDC`],
                  ['Per option', `${(bindingPremium / Math.max(size, 1e-9)).toFixed(QUOTE_DECIMALS)} USDC`],
                  ['Expiry', new Date(expiry * 1000).toLocaleString()],
                  ['Implied vol', `${volPct(selected.volWad)}%`],
                  [
                    'Maker can back',
                    backable == null
                      ? '—'
                      : `${backable.toFixed(isCall ? 2 : 2)} ${isCall ? 'NVDAx' : 'USDC'}`,
                  ],
                  ['Exercise', 'physical — no price feed involved'],
                ] as [string, string][]
              ).map(([k, v]) => (
                <div className="tk-sum__r" key={k}>
                  <span className="tk-sum__k">{k}</span>
                  <span className="tk-sum__v">{v}</span>
                </div>
              ))}
            </div>
          </>
        )}
      </div>
    </Card>
  )

  const positionsTable = (
    <PositionsTable
      deployment={deployment}
      deployed={deployed}
      connected={isConnected}
      positions={chain.positions}
      kinds={kinds}
      loading={chain.loading}
      error={chain.error}
      actions={actions}
      pending={isPending}
    />
  )

  /* -- render ------------------------------------------------------------- */

  return (
    <Backdrop>
      <div className="vx-shell">
        <TopNav
          name="weekend options"
          items={NAV}
          active={view}
          onSelect={(k) => {
            location.hash = `#${k}`
          }}
          right={
            <>
              <Badge tone="outline" icon={<Lock size={12} />}>
                Base Sepolia
              </Badge>
              {deployed && isConnected && (
                <Button
                  size="sm"
                  icon={<Coins size={14} />}
                  onClick={mintTestUsdc}
                  title="Testnet only — mints 1,000 mock USDC to your address"
                >
                  Test USDC
                </Button>
              )}
              {ready &&
                (authenticated ? (
                  <Button variant="square" size="sm" icon={<Wallet size={14} />} onClick={logout}>
                    {address ? `${address.slice(0, 6)}…${address.slice(-4)}` : 'Sign out'}
                  </Button>
                ) : (
                  <Button variant="square" size="sm" icon={<Wallet size={14} />} onClick={login}>
                    Connect
                  </Button>
                ))}
            </>
          }
        />

        <main className="vx-main">
          {!loadingDeploy && !deployed && (
            <Alert tone="warning" title="Preview mode — no deployment loaded">
              Set contract addresses in <code>app/public/deployments/base-sepolia.json</code> (written
              by a live deploy). Premiums are client-side estimates; the chart shows real NVDA history
              with no live pool price on top.
            </Alert>
          )}

          {view === 'trade' && (
            <div className="vx-grid vx-grid--trade">
              <div className="vx-col vx-col--book">{restingOrders}</div>

              <div className="vx-col">
                {chartPanel}
                <div className="vx-grid vx-grid--stats">
                  <StatCard
                    pair="Spot (v4)"
                    color="#7b61ff"
                    value={spotPrice.toFixed(2)}
                    sub="sqrtPriceX96 → USDC"
                    series={closes.slice(-24)}
                  />
                  <StatCard
                    pair="Premium"
                    color="#14ccbb"
                    value={bindingPremium.toFixed(4)}
                    sub={selected ? `series ${selected.seriesId} · ${size} opt` : '—'}
                  />
                  <StatCard
                    pair="Strike"
                    color="#22c55e"
                    value={strikeUsd.toFixed(2)}
                    sub={isCall ? 'CALL — writer locks NVDAx' : 'PUT — writer locks USDC'}
                  />
                  <StatCard
                    pair="Maker backs"
                    color="#f59e0b"
                    value={backable == null ? '—' : backable.toFixed(2)}
                    sub={isCall ? 'NVDAx committed' : 'USDC committed'}
                  />
                </div>

                <Card>
                  <Tabs
                    aria-label="Workspace"
                    value={wsTab}
                    onChange={setWsTab}
                    tabs={[
                      { value: 'positions', label: 'Positions', count: chain.positions.length },
                      { value: 'history', label: 'History', count: chain.history.length },
                    ]}
                  />
                  {wsTab === 'positions' && positionsTable}
                  {wsTab === 'history' && <HistoryTable rows={chain.history} />}
                </Card>
              </div>

              <div className="vx-col vx-col--ticket">{ticket}</div>
            </div>
          )}

          {view === 'earn' && <Earn deployment={deployment} deployed={deployed} onToast={setToast} />}

          {view === 'positions' && (
            <Panel title="Your positions" icon={<Layers size={16} />} bodyless>
              {positionsTable}
            </Panel>
          )}

          {view === 'activity' && (
            <Panel title="History" icon={<ActivityIcon size={16} />} bodyless>
              <HistoryTable rows={chain.history} />
            </Panel>
          )}

          {view === 'docs' && (
            <Panel title="How settlement works" icon={<Clock size={16} />}>
              <div className="vx-col">
                <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
                  A holder can <code>exercise</code> any time before expiry — physical, reading{' '}
                  <b>no price feed</b>: pay the strike in USDC and take the NVDAx (CALL), or deliver
                  the NVDAx and take the strike (PUT). After expiry anyone calls <code>settle(id)</code>,
                  which touches the oracle once; holders <code>redeem</code> and writers{' '}
                  <code>claim</code> their pro-rata share of the series pool.
                </p>
                <KeyValue
                  rows={[
                    ['Collateral', 'CALL writer locks NVDAx; PUT writer locks USDC — stays in the maker wallet until a buy'],
                    ['Pricing', 'Black-Scholes, r = 0, off Uniswap v4 spot — vol is the only maker axis'],
                    ['Position', 'one ERC-20 per series (UP-id / FLOOR-id)'],
                    ['Capital path', '1inch Aqua ship / pull / push via the SwapVM router'],
                    ['Exercise', 'American, physical, oracle-free'],
                    ['Settlement', 'oracle touched once; permissionless after expiry'],
                  ]}
                />
              </div>
            </Panel>
          )}
        </main>
      </div>

      <Modal
        open={confirm}
        title="Confirm order"
        onClose={() => setConfirm(false)}
        footer={
          <>
            <Button variant="primary" onClick={onPlace}>
              {tab === 'buy' ? 'Confirm buy' : 'Confirm sell'}
            </Button>
            <Button variant="secondary" onClick={() => setConfirm(false)}>
              Cancel
            </Button>
          </>
        }
      >
        {selected && (
          <>
            <Card sunken pad style={{ marginBottom: 12 }}>
              <div className="vx-row">
                <TokenDot symbol="N" color="#76b900" /> <b>NVDAx / USDC</b>
              </div>
              <div className={isCall ? 'vx-up' : 'vx-down'} style={{ font: '500 13px/18px var(--mono)', marginTop: 4 }}>
                {tab === 'buy' ? 'Buy' : 'Sell'} {isCall ? 'CALL' : 'PUT'} · series {selected.seriesId} · K{' '}
                {strikeUsd.toFixed(2)}
              </div>
            </Card>
            <KeyValue
              rows={[
                ['Side', tab === 'buy' ? 'Buy (fill ask)' : 'Sell (fill bid)'],
                ['Size', `${size.toFixed(2)} options`],
                ['Strike', `${strikeUsd.toFixed(2)} USDC`],
                ['Premium', `${bindingPremium.toFixed(QUOTE_DECIMALS)} USDC`],
                ['Expiry', new Date(expiry * 1000).toLocaleString()],
              ]}
            />
          </>
        )}
      </Modal>

      {toast && <Toast>{toast}</Toast>}
    </Backdrop>
  )
}

/* ============================================================================
   Helpers + leaf components
   ========================================================================= */

import { buildStrategy } from './lib/strategy'
import type { StrategyTuple } from './lib/strategy'

/** The on-chain Strategy tuple for a quote — quotePremium / makerCapacity want it. */
function strategyFromQuote(d: Deployment, q: MakerQuote): StrategyTuple {
  return buildStrategy(d, q)
}

function quoteStrike(d: Deployment | null, q: MakerQuote): number {
  if (!d) return 0
  return q.seriesId === d.shortSeriesId ? d.shortStrike / 10 ** QUOTE_DECIMALS : d.strike / 10 ** QUOTE_DECIMALS
}

function QuoteRow({
  q,
  kind,
  strikeUsd,
  active,
  onClick,
}: {
  q: MakerQuote
  kind: OptionKind
  strikeUsd: number
  active: boolean
  onClick: () => void
}) {
  const ask = q.side === 'ask'
  return (
    <button type="button" className={`vx-book__row${active ? ' is-active' : ''}`} onClick={onClick}>
      <span className={ask ? 'vx-up' : 'vx-down'}>
        {kind === KIND.CALL ? 'CALL' : 'PUT'} {strikeUsd.toFixed(0)} · #{q.seriesId}
      </span>
      <span style={{ textAlign: 'right' }}>{volPct(q.volWad)}%</span>
      <span style={{ textAlign: 'right' }}>{ask ? 'ASK' : 'BID'}</span>
    </button>
  )
}

/** Seconds until `at`, re-read once a second, inside the leaf so the clock never
 *  re-renders the chart. */
function useSecondsLeft(at: number): number {
  const [left, setLeft] = useState(() => at - Math.floor(Date.now() / 1000))
  useEffect(() => {
    const tick = () => setLeft(at - Math.floor(Date.now() / 1000))
    tick()
    const id = setInterval(tick, 1000)
    return () => clearInterval(id)
  }, [at])
  return left
}

function Countdown({ expiry }: { expiry: number }) {
  const left = useSecondsLeft(expiry)
  if (left <= 0) return <span className="vx-down">expired</span>
  const d = Math.floor(left / 86400)
  const h = Math.floor((left % 86400) / 3600)
  const m = Math.floor((left % 3600) / 60)
  return (
    <span title={new Date(expiry * 1000).toLocaleString()}>
      {d > 0 ? `${d}d ` : ''}
      {h}h {String(m).padStart(2, '0')}m
    </span>
  )
}

const qfmt = (v: bigint) => Number(formatUnits(v, QUOTE_DECIMALS))
const ufmt = (v: bigint) => Number(formatUnits(v, UNDERLYING_DECIMALS))

interface PositionActions {
  exercise: (p: Position, size: number) => Promise<void>
  close: (p: Position, size: number) => Promise<void>
  settle: (p: Position) => Promise<void>
  redeem: (p: Position) => Promise<void>
  claim: (p: Position) => Promise<void>
}

type WriteAsync = (args: {
  address: `0x${string}`
  abi: readonly unknown[]
  functionName: string
  args: readonly unknown[]
}) => Promise<`0x${string}`>

/** Exercise / close / settle / redeem / claim, each gated by the contract itself.
 *  Collapsed into one object so the Positions table can wire per-row buttons. */
function usePositionActions(
  deployment: Deployment | null,
  publicClient: ReturnType<typeof usePublicClient>,
  write: WriteAsync,
  setToast: (s: string) => void,
  refetch: () => void,
): PositionActions {
  const app = deployment?.weekendOptions as `0x${string}` | undefined

  async function send(fn: string, args: readonly unknown[], pending: string, done: string) {
    if (!app || !publicClient) return
    setToast(pending)
    const hash = await write({ address: app, abi: weekendOptionsAbi, functionName: fn as never, args: args as never })
    await publicClient.waitForTransactionReceipt({ hash })
    refetch()
    setToast(done)
  }

  return {
    // CALL: approve USDC = ceil(amount*strike/1e18); PUT: approve NVDAx = amount.
    async exercise(p, size) {
      if (!app || !publicClient || !deployment) return
      const amount = parseUnits(String(size), UNDERLYING_DECIMALS)
      if (p.kind === KIND.CALL) {
        const strike6 = BigInt(Math.round(p.strike * 10 ** QUOTE_DECIMALS))
        const pay = (amount * strike6 + 10n ** 18n - 1n) / 10n ** 18n
        setToast('Approving USDC for exercise…')
        const a = await write({
          address: deployment.usdc as `0x${string}`,
          abi: erc20Abi,
          functionName: 'approve',
          args: [app, pay],
        })
        await publicClient.waitForTransactionReceipt({ hash: a })
      } else {
        setToast('Approving NVDAx for exercise…')
        const a = await write({
          address: deployment.nvdax as `0x${string}`,
          abi: erc20Abi,
          functionName: 'approve',
          args: [app, amount],
        })
        await publicClient.waitForTransactionReceipt({ hash: a })
      }
      await send('exercise', [BigInt(p.seriesId), amount], 'Exercising…', 'Exercised')
    },
    async close(p, size) {
      await send('close', [BigInt(p.seriesId), parseUnits(String(size), UNDERLYING_DECIMALS)], 'Closing…', 'Closed')
    },
    async settle(p) {
      await send('settle', [BigInt(p.seriesId)], 'Settling…', 'Settled')
    },
    async redeem(p) {
      await send('redeem', [BigInt(p.seriesId), p.balance], 'Redeeming…', 'Redeemed')
    },
    async claim(p) {
      await send('claim', [BigInt(p.seriesId)], 'Claiming…', 'Claimed')
    },
  }
}

function PositionsTable({
  deployment,
  deployed,
  connected,
  positions,
  kinds,
  loading,
  error,
  actions,
  pending,
}: {
  deployment: Deployment | null
  deployed: boolean
  connected: boolean
  positions: Position[]
  kinds: KindMap
  loading: boolean
  error: string | null
  actions: PositionActions
  pending: boolean
}) {
  void deployment
  void kinds
  const live = deployed && connected
  return (
    <>
      {error && (
        <div className="vx-panel__body">
          <Alert tone="warning" title="Could not read positions from chain">
            {error}
          </Alert>
        </div>
      )}
      <Table
        rows={positions}
        empty={
          <EmptyState
            icon={<Inbox size={18} />}
            title={loading ? 'Reading your positions…' : 'No positions yet'}
            description="Buying options mints the series ERC-20; writing cover shows as a written leg. Both appear here."
          />
        }
        columns={[
          {
            key: 'kind',
            header: 'Series',
            render: (p: Position) => (
              <div className="vx-row">
                <Badge tone={p.kind === KIND.CALL ? 'green' : 'red'} icon={p.kind === KIND.CALL ? <TrendingUp size={12} /> : <TrendingDown size={12} />}>
                  {p.kind === KIND.CALL ? 'CALL' : 'PUT'} #{p.seriesId}
                </Badge>
                {p.settled && <Badge tone="slate">settled</Badge>}
              </div>
            ),
          },
          { key: 'strike', header: 'Strike', numeric: true, render: (p: Position) => p.strike.toFixed(2) },
          { key: 'bal', header: 'Held', numeric: true, render: (p: Position) => ufmt(p.balance).toFixed(2) },
          { key: 'wrt', header: 'Written', numeric: true, render: (p: Position) => ufmt(p.written).toFixed(2) },
          {
            key: 'expiry',
            header: 'Expires',
            numeric: true,
            render: (p: Position) => <Countdown expiry={p.expiry} />,
          },
          {
            key: 'act',
            header: '',
            numeric: true,
            render: (p: Position) => (
              <PositionButtons p={p} live={live} actions={actions} pending={pending} />
            ),
          },
        ]}
      />
    </>
  )
}

/** The action buttons for one position row, each gated by expiry / balance /
 *  settled exactly as the contract would. Pre-expiry: a holder can exercise, a
 *  writer can close. Post-expiry: settle (once), then redeem (holder) / claim
 *  (writer). */
function PositionButtons({
  p,
  live,
  actions,
  pending,
}: {
  p: Position
  live: boolean
  actions: PositionActions
  pending: boolean
}) {
  const left = useSecondsLeft(p.expiry)
  const expired = left <= 0
  const holder = p.balance > 0n
  const writer = p.written > 0n

  if (!live) return <span className="vx-dim">connect</span>

  if (!expired) {
    return (
      <div className="vx-row" style={{ justifyContent: 'flex-end', gap: 6 }}>
        {holder && (
          <Button size="sm" variant="primary" loading={pending} onClick={() => actions.exercise(p, ufmt(p.balance))}>
            Exercise
          </Button>
        )}
        {writer && (
          <Button size="sm" variant="secondary" loading={pending} onClick={() => actions.close(p, ufmt(p.written))}>
            Close
          </Button>
        )}
        {!holder && !writer && <span className="vx-dim">—</span>}
      </div>
    )
  }

  return (
    <div className="vx-row" style={{ justifyContent: 'flex-end', gap: 6 }}>
      {!p.settled && (
        <Button size="sm" variant="primary" loading={pending} onClick={() => actions.settle(p)}>
          Settle
        </Button>
      )}
      {p.settled && holder && (
        <Button size="sm" variant="primary" loading={pending} onClick={() => actions.redeem(p)}>
          Redeem
        </Button>
      )}
      {p.settled && writer && (
        <Button size="sm" variant="secondary" loading={pending} onClick={() => actions.claim(p)}>
          Claim
        </Button>
      )}
      {p.settled && !holder && !writer && <span className="vx-dim">done</span>}
    </div>
  )
}

function HistoryTable({ rows }: { rows: HistoryRow[] }) {
  return (
    <Table
      rows={rows}
      empty={
        <EmptyState
          icon={<Inbox size={18} />}
          title="No history yet"
          description="Buys (OptionWritten) and exercises land here."
        />
      }
      columns={[
        {
          key: 'kind',
          header: 'Event',
          render: (r: HistoryRow) => (
            <Badge tone={r.kind === 'written' ? 'green' : 'violet'}>
              {r.kind === 'written' ? 'Bought' : 'Exercised'}
            </Badge>
          ),
        },
        { key: 'series', header: 'Series', numeric: true, render: (r: HistoryRow) => `#${r.seriesId}` },
        { key: 'amt', header: 'Options', numeric: true, render: (r: HistoryRow) => ufmt(r.amount).toFixed(2) },
        {
          key: 'prem',
          header: 'Premium',
          numeric: true,
          render: (r: HistoryRow) => (r.kind === 'written' ? qfmt(r.premium).toFixed(QUOTE_DECIMALS) : '—'),
        },
        { key: 'blk', header: 'Block', numeric: true, render: (r: HistoryRow) => String(r.blockNumber) },
      ]}
    />
  )
}
