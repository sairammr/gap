/* ============================================================================
   Gap desk — the overnight-gap options interface.

   Chrome and components come from ./ui (the Voltrex-derived kit); the desk
   layout — market strip, workspace tabs, depth ladder, order form with its
   available-balance slider — follows kuru.io/trade. All five bench-style
   sliders drive real ticket state:

     HistogramRange  strike + cap, picked as a band over the pricing distribution
     WakeSlider      size in units
     TapeSlider      hours to expiry
     BudgetSlider    max payout (cap x size) read against the maker's backing
     ElasticSlider   premium slippage tolerance

   The on-chain path is unchanged: client-side preview for instant feedback,
   `quotePremium` for the binding number, buy routed through GapTaker.
   ========================================================================= */

import { useEffect, useMemo, useRef, useState } from 'react'
import {
  Activity as ActivityIcon,
  Anchor,
  ArrowLeftRight,
  BarChart3,
  BookOpen,
  Clock,
  Coins,
  Inbox,
  Layers,
  Lock,
  TrendingDown,
  TrendingUp,
  Umbrella,
  Wallet,
  Palette,
} from 'lucide-react'
import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { usePrivy } from '@privy-io/react-auth'
import { formatUnits, parseUnits } from 'viem'
import { aquaAbi, erc20Abi, gapOptionsAppAbi, gapTakerAbi } from './lib/abi'
import { loadDeployment, isDeployed, type Deployment } from './lib/deployment'
import { buildStrategy, DEFAULT_VOL, QUOTE_DECIMALS, volFromWad } from './lib/strategy'
import { usePositions, type Position } from './hooks/usePositions'
import { KIND, previewPremium, cappedPremiumPerUnit, type OptionKind } from './lib/pricing'
import { useSpotSeries } from './hooks/useSpotSeries'
import { PriceChart } from './components/PriceChart'
import { Earn } from './pages/Earn'
import {
  ActivityList,
  Alert,
  Backdrop,
  Badge,
  Button,
  Card,
  Delta,
  EmptyState,
  Field,
  Input,
  KeyValue,
  Ladder,
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
  WakeSlider,
  type LadderRow,
} from './ui'

// Fallback only. The real figure is AQUA.rawBalances(maker, app, strategyHash,
// usdc), read below once a deployment is loaded.
const MAKER_BACKING_USDC = 500

const NAV = [
  { key: 'trade', label: 'Trade', icon: <ArrowLeftRight size={16} /> },
  { key: 'earn', label: 'Earn', icon: <Anchor size={16} /> },
  { key: 'protect', label: 'Protect', icon: <Umbrella size={16} /> },
  { key: 'positions', label: 'Positions', icon: <Layers size={16} /> },
  { key: 'strikes', label: 'Strike ladder', icon: <BarChart3 size={16} /> },
  { key: 'activity', label: 'Activity', icon: <ActivityIcon size={16} /> },
  { key: 'docs', label: 'How it settles', icon: <BookOpen size={16} /> },
  { key: 'kit', label: 'UI kit', icon: <Palette size={16} /> },
]

// Views are hash-routed, the same convention main.tsx uses for #kit — a
// shareable URL per surface without pulling in a router.
const VIEW_KEYS = NAV.map((n) => n.key)
function viewFromHash(): string {
  const h = location.hash.replace(/^#/, '')
  return VIEW_KEYS.includes(h) ? h : 'trade'
}

export default function App() {
  const { address, isConnected } = useAccount()
  const { ready, authenticated, login, logout } = usePrivy()
  const publicClient = usePublicClient()
  const { writeContractAsync, isPending } = useWriteContract()

  const [deployment, setDeployment] = useState<Deployment | null>(null)
  const [loadingDeploy, setLoadingDeploy] = useState(true)
  const deployed = isDeployed(deployment)

  const [view, setView] = useState(viewFromHash)
  const [wsTab, setWsTab] = useState('positions')
  const [confirm, setConfirm] = useState(false)

  // --- option ticket state ---
  const [kind, setKind] = useState<OptionKind>(KIND.CALL)
  const [strike, setStrike] = useState(100)
  // The Trade ticket picks a distance from spot, not an absolute strike — one
  // number instead of an option chain. `strike` stays the contract-facing
  // value and is derived from it; Protect still sets a strike directly.
  const [gapThreshold, setGapThreshold] = useState(2.0)
  const [cap, setCap] = useState(5)
  const [size, setSize] = useState(1)
  const [hoursToExpiry, setHoursToExpiry] = useState(16) // overnight-ish
  const SLIP_PCT = 2 // fixed premium tolerance on the buy; not worth a control

  const [onchainPremium, setOnchainPremium] = useState<number | null>(null)
  const [quoteErr, setQuoteErr] = useState<string | null>(null)
  // Preview rows are local-only demo entries (not connected / not deployed).
  // Real positions come from the chain via usePositions and are badged apart.
  const [previews, setPreviews] = useState<Position[]>([])
  const [makerBacking, setMakerBacking] = useState<number | null>(null)
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

  // Protect is the same contract call with kind = PUT, so entering it pins the
  // direction and seeds insurance-shaped defaults the first time.
  const protectSeeded = useRef(false)
  // The ticket boots at strike 100 from when the pool was seeded there. Live spot
  // is ~188, which makes the default option deep ITM and its premium equal to the
  // cap. Re-anchor once, the first time a real spot arrives.
  const strikeSeeded = useRef(false)

  const spot = useSpotSeries(deployment, deployed)

  useEffect(() => {
    if (view !== 'trade') return
    const anchor = spot.lastSpot
    if (anchor == null) return
    const dir = kind === KIND.CALL ? 1 : -1
    setStrike(round(anchor * (1 + (dir * gapThreshold) / 100), 0.5))
  }, [view, kind, gapThreshold, spot.lastSpot])

  const tier =
    gapThreshold < 1
      ? { label: 'High probability', tone: 'green' as const }
      : gapThreshold < 3.5
        ? { label: 'Sweet spot', tone: 'teal' as const }
        : { label: 'Convex', tone: 'amber' as const }

  const spotPrice = spot.lastSpot ?? 100

  // The real thing: OptionBought logs -> positions(id) + balanceOf(holder, id).
  const chain = usePositions(deployment, deployed, address)
  const positions = useMemo(() => [...chain.positions, ...previews], [chain.positions, previews])

  // The maker's pricing axis. `makers` is optional in the deployment JSON — with
  // it absent we fall back to the single top-level maker at the default IV.
  const makerEntry = deployment?.makers?.[0]
  const vol = makerEntry ? volFromWad(BigInt(makerEntry.volWad)) : DEFAULT_VOL
  const backing = makerBacking ?? MAKER_BACKING_USDC

  useEffect(() => {
    if (strikeSeeded.current || spot.lastSpot == null) return
    strikeSeeded.current = true
    setStrike(round(spot.lastSpot, 0.5))
    setCap(round(Math.max(1, spot.lastSpot * 0.03), 0.5))
  }, [spot.lastSpot])

  useEffect(() => {
    if (view !== 'protect') return
    setKind(KIND.PUT)
    // Seed off a REAL spot only — seeding off the 100 placeholder would quote
    // cover 48% below the market and read as a broken product.
    if (protectSeeded.current || spot.lastSpot == null) return
    protectSeeded.current = true
    setStrike(round(spot.lastSpot * 0.97, 0.5))
    setCap(round(Math.max(1, spot.lastSpot * 0.05), 0.5))
  }, [view, spot.lastSpot])

  const secondsToExpiry = Math.max(0, Math.round(hoursToExpiry * 3600))

  // --- client-side premium preview (mirror of GapPricing) ---
  const preview = useMemo(
    () => previewPremium(kind, spotPrice, strike, cap, secondsToExpiry, vol, size),
    [kind, spotPrice, strike, cap, secondsToExpiry, size, vol],
  )

  // Payoff telemetry (zero-jargon): max payout, breakeven, premium-as-% of max.
  const maxPayout = cap * size
  const breakeven = kind === KIND.CALL ? strike + preview / size : strike - preview / size
  const gapPct = ((breakeven - spotPrice) / spotPrice) * 100

  // --- binding on-chain quotePremium read ---
  useEffect(() => {
    let cancelled = false
    setQuoteErr(null)
    if (!deployed || !deployment || !publicClient || !address) {
      setOnchainPremium(null)
      return
    }
    const strategy = buildStrategy(deployment, makerEntry)
    const expiry = BigInt(Math.floor(Date.now() / 1000) + secondsToExpiry)
    const args = [
      strategy,
      kind,
      parseUnits(String(strike), 18),
      parseUnits(String(cap), 18),
      expiry,
      parseUnits(String(size), 18),
    ] as const
    publicClient
      .readContract({
        address: deployment.gapOptionsApp as `0x${string}`,
        abi: gapOptionsAppAbi,
        functionName: 'quotePremium',
        args,
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
  }, [deployed, deployment, publicClient, address, kind, strike, cap, size, secondsToExpiry, makerEntry])

  // The collateral gauge reads the maker's live Aqua balance: ship is only an
  // accounting entry, so this is the real ceiling on cap x size.
  useEffect(() => {
    let cancelled = false
    if (!deployed || !deployment?.aqua || !publicClient || !deployment.maker) {
      setMakerBacking(null)
      return
    }
    const strategy = buildStrategy(deployment, makerEntry)
    publicClient
      .readContract({
        address: deployment.gapOptionsApp as `0x${string}`,
        abi: gapOptionsAppAbi,
        functionName: 'hashStrategy',
        args: [strategy],
      })
      .then((hash) =>
        publicClient.readContract({
          address: deployment.aqua as `0x${string}`,
          abi: aquaAbi,
          functionName: 'rawBalances',
          args: [
            strategy.maker,
            deployment.gapOptionsApp as `0x${string}`,
            hash as `0x${string}`,
            deployment.usdc as `0x${string}`,
          ],
        }),
      )
      .then((res) => {
        if (cancelled) return
        const raw = (res as readonly [bigint, number])[0]
        setMakerBacking(Number(formatUnits(raw, QUOTE_DECIMALS)))
      })
      .catch(() => {
        if (!cancelled) setMakerBacking(null)
      })
    return () => {
      cancelled = true
    }
  }, [deployed, deployment, publicClient, makerEntry])

  // The maker is whoever shipped the collateral (deployment JSON) — if it is
  // missing the Strategy hashes to nobody and buyOption reverts.
  const canBuyOnChain =
    deployed && isConnected && !!deployment?.gapTaker && !!deployment?.maker
  const bindingPremium = onchainPremium ?? preview
  // No binding quote => maxPremium would come off the client preview, which can
  // undershoot the chain premium and revert PremiumTooHigh. Refuse to buy.
  const noBindingQuote = canBuyOnChain && onchainPremium === null

  /* -- derived views ------------------------------------------------------ */

  // The risk-neutral distribution of the open, at the strategy's IV. The ticket's
  // band is literally the slice of it the capped payoff pays on.
  const domain = useMemo(() => {
    const sd = spotPrice * vol * Math.sqrt(secondsToExpiry / 31_536_000)
    const reach = Math.max(spotPrice * 0.04, sd * 2.2)
    const bandLo = kind === KIND.CALL ? strike : strike - cap
    const bandHi = kind === KIND.CALL ? strike + cap : strike
    return {
      lo: round(Math.min(spotPrice - reach, bandLo - 0.5), 0.5),
      hi: round(Math.max(spotPrice + reach, bandHi + 0.5), 0.5),
    }
  }, [spotPrice, secondsToExpiry, kind, strike, cap, vol])

  const bins = useMemo(
    () => lognormalBins(spotPrice, vol, secondsToExpiry, domain.lo, domain.hi, 32),
    [spotPrice, secondsToExpiry, domain, vol],
  )

  // The payoff band: a call pays on [K, K+cap], a put on [K-cap, K].
  const band: [number, number] =
    kind === KIND.CALL ? [strike, strike + cap] : [strike - cap, strike]

  const ladder: LadderRow[] = useMemo(() => {
    const step = round((domain.hi - domain.lo) / 12, 0.5) || 0.5
    const strikes: number[] = []
    for (let k = round(domain.lo, 0.5); k <= domain.hi; k += step) strikes.push(round(k, 0.5))
    const prem = strikes.map((k) =>
      cappedPremiumPerUnit(kind, spotPrice, k, cap, secondsToExpiry, vol),
    )
    const peak = Math.max(...prem, 1e-9)
    const splitAt = strikes.findIndex((k) => k > spotPrice)
    return strikes.map((k, i) => ({
      key: String(k),
      side: (k >= spotPrice ? 'up' : 'down') as 'up' | 'down',
      depth: prem[i] / peak,
      active: Math.abs(k - strike) < step / 2,
      onSelect: () => setGapThreshold(Math.min(9.5, Math.abs(((k - spotPrice) / spotPrice) * 100))),
      cells: [
        <span key="k" className={k >= spotPrice ? 'vx-up' : 'vx-down'}>{k.toFixed(2)}</span>,
        prem[i].toFixed(4),
        (prem[i] * size).toFixed(QUOTE_DECIMALS),
      ],
      _split: splitAt,
    })) as LadderRow[]
  }, [domain, kind, spotPrice, cap, secondsToExpiry, strike, size, vol])

  const splitIndex = useMemo(
    () => ladder.findIndex((r) => Number(r.key) > spotPrice),
    [ladder, spotPrice],
  )

  const closes = useMemo(() => spot.candles.map((c) => c.close), [spot.candles])

  useEffect(() => {
    if (!toast) return
    const id = setTimeout(() => setToast(null), 3000)
    return () => clearTimeout(id)
  }, [toast])

  /* -- actions ------------------------------------------------------------ */

  async function handleBuy() {
    if (!deployment || !address || !publicClient) return
    const strategy = buildStrategy(deployment, makerEntry)
    const gapTaker = deployment.gapTaker as `0x${string}`
    const expiry = BigInt(Math.floor(Date.now() / 1000) + secondsToExpiry)
    const maxPremium = parseUnits(
      (bindingPremium * (1 + SLIP_PCT / 100)).toFixed(QUOTE_DECIMALS),
      QUOTE_DECIMALS,
    )

    // GapTaker.gapOptionCallback does quote.transferFrom(payer, ...) for the
    // premium, so the buyer must have approved it for at least maxPremium.
    const allowance = await publicClient.readContract({
      address: deployment.usdc as `0x${string}`,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [address, gapTaker],
    })
    if (allowance < maxPremium) {
      setToast('Approving USDC for the GapTaker…')
      const approveHash = await writeContractAsync({
        address: deployment.usdc as `0x${string}`,
        abi: erc20Abi,
        functionName: 'approve',
        args: [gapTaker, maxPremium],
      })
      await publicClient.waitForTransactionReceipt({ hash: approveHash })
    }

    // takerData = abi.encode(maker, strategyHash) — the GapTaker helper decodes it
    // and pushes USDC into the maker's Aqua balance (see DemoTaker.gapOptionCallback).
    const strategyHash = (await publicClient.readContract({
      address: deployment.gapOptionsApp as `0x${string}`,
      abi: gapOptionsAppAbi,
      functionName: 'hashStrategy',
      args: [strategy],
    })) as `0x${string}`
    const takerData = encodeTakerData(strategy.maker, strategyHash)
    const buyHash = await writeContractAsync({
      address: gapTaker,
      abi: gapTakerAbi,
      functionName: 'buy',
      args: [
        deployment.gapOptionsApp as `0x${string}`,
        strategy,
        kind,
        parseUnits(String(strike), 18),
        parseUnits(String(cap), 18),
        expiry,
        parseUnits(String(size), 18),
        maxPremium,
        address,
        takerData,
      ],
    })
    setToast('Buy submitted via GapTaker')
    // The panel reads the chain, so it only sees the position once the buy is
    // mined. Wait for the receipt, then rescan — no manual reload.
    await publicClient.waitForTransactionReceipt({ hash: buyHash })
    chain.refetch()
    setToast('Position minted')
  }

  // Testnet faucet: the mock quote token has a permissionless mint, so a fresh
  // wallet can fund itself without begging the deployer.
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

  // Visual-only local mint so the positions panel demonstrates its shape even when
  // on-chain buy is deferred. Marked as a preview entry.
  function addPreviewPosition() {
    setPreviews((p) => [
      {
        positionId: 'preview-' + Math.random().toString(36).slice(2, 8),
        onchain: false,
        kind,
        strike,
        cap,
        size,
        expiry: Math.floor(Date.now() / 1000) + secondsToExpiry,
        premium: bindingPremium,
        settled: false,
        balance: 0n,
      },
      ...p,
    ])
    setToast('Preview position added (not on-chain)')
  }

  async function settlePosition(p: Position) {
    if (!deployment || !address || !publicClient || !p.onchain || !p.strategyHash) {
      setToast('Settle is on-chain only (needs a live position + deploy)')
      return
    }
    // settle() re-hashes the tuple and reverts StrategyMismatch unless it equals
    // the hash stored on the position, so use the maker it was actually bought
    // from — NOT whichever maker the ticket happens to be quoting.
    const strategy = chain.strategyFor(p.strategyHash)
    if (!strategy) {
      setToast('No shipped maker matches this position’s strategy — cannot settle here')
      return
    }
    const hash = await writeContractAsync({
      address: deployment.gapOptionsApp as `0x${string}`,
      abi: gapOptionsAppAbi,
      functionName: 'settle',
      args: [strategy, BigInt(p.positionId), address],
    })
    setToast('Settle submitted')
    await publicClient.waitForTransactionReceipt({ hash })
    chain.refetch()
    setToast('Settled')
  }

  async function onPlace() {
    setConfirm(false)
    if (canBuyOnChain) await handleBuy()
    else addPreviewPosition()
  }

  /* -- pieces ------------------------------------------------------------- */

  const isCall = kind === KIND.CALL

  const chartPanel = (
    <Card>
      <div className="ck-head">
        <div>
          <div className="ck-pair">
            <TokenDot symbol="N" color="#76b900" /> NVDAx / USDC
          </div>
          <div className="ck-price">
            <b>{spotPrice.toFixed(2)}</b>
            <Delta value={gapPct} />
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

  const positionsTable = (
    <>
      {chain.error && (
        <div className="vx-panel__body">
          <Alert tone="warning" title="Could not read positions from chain">
            {chain.error}
          </Alert>
        </div>
      )}
      <Table
        rows={positions}
        empty={
          <EmptyState
            icon={<Inbox size={18} />}
            title={chain.loading ? 'Reading your positions…' : 'No positions yet'}
            description="Buying an option mints an ERC-1155 position. It shows up here with its strike, cap and expiry."
          />
        }
        columns={[
          {
            key: 'kind',
            header: 'Side',
            render: (p: Position) => (
              <div className="vx-row">
                <Badge tone={p.kind === KIND.CALL ? 'green' : 'red'} icon={p.kind === KIND.CALL ? <TrendingUp size={12} /> : <TrendingDown size={12} />}>
                  {p.kind === KIND.CALL ? 'GAP UP' : 'GAP DOWN'}
                </Badge>
                {/* Preview rows are local demo entries. Never let them read as real. */}
                {!p.onchain && <Badge tone="amber">preview</Badge>}
                {p.settled && <Badge tone="slate">settled</Badge>}
              </div>
            ),
          },
          { key: 'strike', header: 'Strike', numeric: true, render: (p: Position) => p.strike.toFixed(2) },
          { key: 'cap', header: 'Cap', numeric: true, render: (p: Position) => p.cap.toFixed(2) },
          { key: 'size', header: 'Size', numeric: true, render: (p: Position) => p.size.toFixed(2) },
          { key: 'prem', header: 'Premium', numeric: true, render: (p: Position) => p.premium.toFixed(QUOTE_DECIMALS) },
          { key: 'max', header: 'Max payout', numeric: true, render: (p: Position) => (p.cap * p.size).toFixed(2) },
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
            render: (p: Position) => <SettleButton p={p} enabled={deployed && isConnected} onSettle={settlePosition} />,
          },
        ]}
      />
    </>
  )

  const strikeLadder = (
    <Ladder
      template="1fr 1fr 1fr"
      columns={['Strike', 'Premium / unit', `Total (${size} u)`]}
      rows={ladder}
      mid={{
        k: 'v4 spot',
        v: spotPrice.toFixed(2),
        after: splitIndex < 0 ? ladder.length : splitIndex,
        right: <Badge tone="outline">IV {(vol * 100).toFixed(0)}%</Badge>,
      }}
    />
  )

  const ticket = (
    <div className="tk">
      <Segmented
        block
        value={kind}
        onChange={(v) => setKind(v as OptionKind)}
        aria-label="Direction"
        options={[
          { value: KIND.CALL, label: 'GAP UP', tone: 'up' },
          { value: KIND.PUT, label: 'GAP DOWN', tone: 'down' },
        ]}
      />

      {/* Size ------------------------------------------------------------ */}
      <div className="tk-card">
        <div className="tk-card__top">
          <span className="tk-card__k">Size</span>
          <span className="tk-card__unit">units</span>
        </div>
        <div className="tk-card__v">{size.toFixed(3)}</div>
        <QuickPills
          options={[1, 2, 5, 10, 15]}
          value={size}
          onPick={setSize as never}
          format={(v) => Number(v).toFixed(2)}
        />
      </div>

      {/* Gap threshold — the one continuous control --------------------- */}
      <div className="tk-card tk-card--slider">
        <div className="tk-card__top">
          <span className="tk-card__k">Gap threshold</span>
          <Badge tone={tier.tone}>{tier.label}</Badge>
        </div>
        <div className="tk-card__v">
          {isCall ? '+' : '−'}
          {gapThreshold.toFixed(1)}%
          <small>strike {strike.toFixed(2)}</small>
        </div>
        <WakeSlider
          value={gapThreshold}
          onChange={setGapThreshold}
          min={0}
          max={9.5}
          step={0.1}
          aria-label="Gap threshold"
          scale={['0%', '2%', '4.5%', '9.5%']}
        />
      </div>

      {/* Expiry ---------------------------------------------------------- */}
      <div className="tk-card">
        <div className="tk-card__top">
          <span className="tk-card__k">Expires in</span>
          <span className="tk-card__unit">{hoursToExpiry <= 20 ? 'overnight' : 'weekend'}</span>
        </div>
        <div className="tk-card__v">{hoursToExpiry}h</div>
        <QuickPills
          options={[8, 16, 24, 48]}
          value={hoursToExpiry}
          onPick={setHoursToExpiry as never}
          format={(v) => `${v}h`}
        />
      </div>

      {/* Cap -------------------------------------------------------------- */}
      <div className="tk-card">
        <div className="tk-card__top">
          <span className="tk-card__k">Max payout</span>
          <span className="tk-card__unit">USDC per unit</span>
        </div>
        <div className="tk-card__v is-up">{cap.toFixed(2)}</div>
        <QuickPills
          options={[1, 3, 5, 10, 25]}
          value={cap}
          onPick={setCap as never}
          format={(v) => Number(v).toFixed(0)}
        />
      </div>

      <Button
        variant="primary"
        block
        size="lg"
        className="tk-place"
        loading={isPending}
        onClick={() => setConfirm(true)}
      >
        {canBuyOnChain ? `Place ${isCall ? 'gap up' : 'gap down'}` : 'Add preview position'}
      </Button>

      <div className="tk-sum">
        {(
          [
            ['Premium', `${bindingPremium.toFixed(4)} USDC`],
            ['Breakeven open', breakeven.toFixed(2)],
            ['Most you can be paid', `${maxPayout.toFixed(2)} USDC`],
            ['Collateral locked', `${maxPayout.toFixed(2)} USDC`],
            ['Implied vol', `${(vol * 100).toFixed(0)}%`],
            ['Settles', 'cash, USDC, after expiry'],
          ] as [string, string][]
        ).map(([k, v]) => (
          <div className="tk-sum__r" key={k}>
            <span className="tk-sum__k">{k}</span>
            <span className="tk-sum__v">{v}</span>
          </div>
        ))}
      </div>
    </div>
  )


  /* -- render ------------------------------------------------------------- */

  return (
    <Backdrop>
      <div className="vx-shell">
        <TopNav
          name="gap"
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
            <div className="vx-grid vx-grid--desk">
              <div className="vx-col">
                {chartPanel}

                <div className="vx-grid vx-grid--stats">
                  <StatCard
                    pair="Spot (v4)"
                    color="#7b61ff"
                    value={spotPrice.toFixed(2)}
                    sub="sqrtPriceX96 → USDC"
                    change={gapPct}
                    series={closes.slice(-24)}
                  />
                  <StatCard
                    pair="Premium"
                    color="#14ccbb"
                    value={bindingPremium.toFixed(4)}
                    sub={`${((bindingPremium / Math.max(maxPayout, 1e-9)) * 100).toFixed(1)}% of max payout`}
                    series={bins.map((b) => b * 100)}
                  />
                  <StatCard
                    pair="Max payout"
                    color="#22c55e"
                    value={maxPayout.toFixed(2)}
                    sub={`${((maxPayout / backing) * 100).toFixed(1)}% of the maker's backing`}
                  />
                  <StatCard
                    pair="Breakeven open"
                    color={gapPct >= 0 ? '#22c55e' : '#ef4444'}
                    value={breakeven.toFixed(2)}
                    sub={`${isCall ? 'above' : 'below'} strike ${strike.toFixed(2)}`}
                    change={gapPct}
                  />
                </div>

                <Card>
                  <Tabs
                    aria-label="Workspace"
                    value={wsTab}
                    onChange={setWsTab}
                    tabs={[
                      { value: 'positions', label: 'Positions', count: positions.length },
                      { value: 'strikes', label: 'Strike ladder' },
                    ]}
                  />
                  {wsTab === 'positions' && positionsTable}
                  {wsTab === 'strikes' && strikeLadder}
                </Card>
              </div>

              <div className="vx-col">{ticket}</div>
            </div>
          )}

          {view === 'earn' && (
            <Earn deployment={deployment} deployed={deployed} onToast={setToast} />
          )}

          {view === 'protect' && (
            <div className="vx-grid vx-grid--desk">
              <div className="vx-col">
                {chartPanel}

                <div className="vx-grid vx-grid--stats">
                  <StatCard
                    pair="NVDAx you hold"
                    color="#76b900"
                    value={size.toFixed(2)}
                    sub={`${(size * spotPrice).toFixed(0)} USDC at today's spot`}
                  />
                  <StatCard
                    pair="Cover starts below"
                    color="#7b61ff"
                    value={strike.toFixed(2)}
                    sub={`${(((strike - spotPrice) / spotPrice) * 100).toFixed(1)}% from spot`}
                  />
                  <StatCard
                    pair="Most you can be paid"
                    color="#22c55e"
                    value={maxPayout.toFixed(2)}
                    sub={`${cap.toFixed(2)} per share x ${size.toFixed(2)} shares`}
                  />
                  <StatCard
                    pair="Cover costs"
                    color="#14ccbb"
                    value={bindingPremium.toFixed(QUOTE_DECIMALS)}
                    sub={`${((bindingPremium / Math.max(size * spotPrice, 1e-9)) * 100).toFixed(2)}% of the position`}
                  />
                </div>

                <Panel
                  title="What you are actually buying"
                  icon={<Umbrella size={16} />}
                  footer={
                    <>
                      There is no separate insurance contract. This is{' '}
                      <code>buyOption</code> with <code>kind = PUT</code> — the same capped put the
                      Trade desk sells, with the inputs renamed for someone who already owns the
                      shares. The payout is cash in USDC, never a forced sale of your NVDAx.
                    </>
                  }
                >
                  <KeyValue
                    rows={[
                      ['You keep', 'your NVDAx — nothing is pledged or locked'],
                      ['You pay', `${bindingPremium.toFixed(QUOTE_DECIMALS)} USDC, once, up front`],
                      ['Cover kicks in below', `${strike.toFixed(2)} USDC per share`],
                      ['Cover runs out below', `${Math.max(0, strike - cap).toFixed(2)} USDC per share`],
                      ['Paid out', 'USDC, after expiry, from collateral already held'],
                      ['Can you be liquidated', 'no — the premium is the entire downside'],
                    ]}
                  />
                </Panel>
              </div>

              <div className="vx-col">
                <Card>
                  <div className="vx-panel__head">
                    <div className="vx-panel__title">
                      <Umbrella size={16} /> Protect my NVDAx
                    </div>
                    <Badge tone="violet">gap-down cover</Badge>
                  </div>
                  <div className="vx-panel__body vx-col">
                    <Field
                      label="I hold"
                      htmlFor="pr-size"
                      aside={<Badge tone="outline">{(size * spotPrice).toFixed(0)} USDC</Badge>}
                    >
                      <Input
                        id="pr-size"
                        type="number"
                        min={0}
                        step={0.5}
                        mono
                        inputSize="lg"
                        value={size}
                        onChange={(e) => setSize(Math.max(0, Number(e.target.value)))}
                        trailing="NVDAx"
                      />
                    </Field>

                    <Field
                      label="Protect me below"
                      htmlFor="pr-strike"
                      hint={`Spot is ${spotPrice.toFixed(2)}. Cover only pays if NVDAx is under this at expiry.`}
                      aside={
                        <Button size="sm" onClick={() => setStrike(round(spotPrice * 0.97, 0.5))}>
                          3% under spot
                        </Button>
                      }
                    >
                      <Input
                        id="pr-strike"
                        type="number"
                        min={0}
                        step={0.5}
                        mono
                        inputSize="lg"
                        value={strike}
                        onChange={(e) => setStrike(Math.max(0, Number(e.target.value)))}
                        leading="$"
                      />
                    </Field>

                    <Field
                      label="Cover a drop of up to"
                      htmlFor="pr-cap"
                      hint="Per share. A bigger cover costs more, and the maker has to post all of it as collateral."
                    >
                      <Input
                        id="pr-cap"
                        type="number"
                        min={0}
                        step={0.5}
                        mono
                        inputSize="lg"
                        value={cap}
                        onChange={(e) => setCap(Math.max(0, Number(e.target.value)))}
                        leading="$"
                      />
                    </Field>

                    <WakeSlider
                      label="Cover until"
                      value={hoursToExpiry}
                      onChange={setHoursToExpiry}
                      min={1}
                      max={48}
                      step={1}
                      format={(v: number) => `${v}h from now`}
                      scale={['1h', '16h', '32h', '48h']}
                      aside={
                        <Badge tone={hoursToExpiry <= 20 ? 'teal' : 'amber'}>
                          {hoursToExpiry <= 20 ? 'next open' : 'over the weekend'}
                        </Badge>
                      }
                    />

                    <Card sunken pad>
                      <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
                        Costs <b>{bindingPremium.toFixed(QUOTE_DECIMALS)} USDC</b> today. If NVDAx
                        opens below <b>${strike.toFixed(2)}</b>, you are paid up to{' '}
                        <b>${cap.toFixed(2)} per share</b> — at most{' '}
                        <b>{maxPayout.toFixed(2)} USDC</b> across {size.toFixed(2)} shares. If it
                        opens above, the cover expires and you have lost the premium, nothing else.
                      </p>
                    </Card>

                    <Button
                      variant="primary"
                      block
                      size="lg"
                      loading={isPending}
                      disabled={noBindingQuote || size <= 0 || cap <= 0 || strike <= 0}
                      title={noBindingQuote ? 'No binding on-chain quote — buying is unsafe' : undefined}
                      onClick={() => setConfirm(true)}
                    >
                      {canBuyOnChain ? 'Buy cover' : 'Preview cover'}
                    </Button>

                    {noBindingQuote && (
                      <Alert tone="warning" title="Buy disabled — no binding quote">
                        The on-chain <code>quotePremium</code> read failed
                        {quoteErr ? ` (${quoteErr})` : ''}, so the price you see is a client-side
                        estimate only.
                      </Alert>
                    )}

                    {maxPayout > backing && (
                      <Alert tone="warning" title="More cover than the maker is backing">
                        This asks for {maxPayout.toFixed(2)} USDC of payout against{' '}
                        {backing.toFixed(2)} USDC committed on Aqua. Reduce the cover, or ship more
                        collateral in the Earn view.
                      </Alert>
                    )}
                  </div>
                </Card>
              </div>
            </div>
          )}

          {view === 'positions' && (
            <Panel title="Your positions" icon={<Layers size={16} />} bodyless>
              {positionsTable}
            </Panel>
          )}

          {view === 'strikes' && (
            <Panel
              title="Strike ladder"
              icon={<BarChart3 size={16} />}
              bodyless
              footer="Premium per unit from the client-side mirror of GapPricing, at the strategy's 50% IV and the ticket's cap and expiry. Click a strike to load it into the ticket."
            >
              {strikeLadder}
            </Panel>
          )}

          {view === 'activity' && (
            <Panel title="Activity" icon={<ActivityIcon size={16} />} bodyless>
              <ActivityList
                items={positions.map((p) => ({
                  icon: p.kind === KIND.CALL ? <TrendingUp size={15} /> : <TrendingDown size={15} />,
                  title: `${p.kind === KIND.CALL ? 'Bought capped call' : 'Bought capped put'} · K ${p.strike.toFixed(2)}`,
                  meta: `cap ${p.cap} · size ${p.size} · premium ${p.premium.toFixed(QUOTE_DECIMALS)} USDC`,
                  right: <Badge tone={p.onchain ? 'outline' : 'amber'}>{p.onchain ? 'on-chain' : 'preview'}</Badge>,
                }))}
                empty={
                  <EmptyState
                    icon={<Inbox size={18} />}
                    title="Nothing has happened yet"
                    description="Buys and settlements land here."
                  />
                }
              />
            </Panel>
          )}

          {view === 'docs' && (
            <Panel title="How settlement works" icon={<Clock size={16} />}>
              <div className="vx-col">
                <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
                  After expiry anyone can call <code>settle(strategy, positionId, holder)</code>. The
                  app reads the realised v4 spot, pays the holder{' '}
                  <code>min(max(0, ±(spot − strike)), cap) × size</code> in USDC from the maker's held
                  backing, and returns the remainder to the maker. Cash-settled, fully collateralised.
                </p>
                <KeyValue
                  rows={[
                    ['Collateral token', 'USDC (the quote) — NVDAx is pricing-only'],
                    ['Pricing', 'capped Black-Scholes, r = 0, off Uniswap v4 spot'],
                    ['Position', 'ERC-1155, one id per (strike, cap, expiry, kind)'],
                    ['Capital path', '1inch Aqua ship / pull / push'],
                    ['Settlement', 'permissionless after expiry, payout capped by held backing'],
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
              {canBuyOnChain ? 'Confirm buy' : 'Add preview'}
            </Button>
            <Button variant="secondary" onClick={() => setConfirm(false)}>
              Cancel
            </Button>
          </>
        }
      >
        <Card sunken pad style={{ marginBottom: 12 }}>
          <div className="vx-row">
            <TokenDot symbol="N" color="#76b900" /> <b>NVDAx / USDC</b>
          </div>
          <div className={isCall ? 'vx-up' : 'vx-down'} style={{ font: '500 13px/18px var(--mono)', marginTop: 4 }}>
            {isCall ? 'Buy capped CALL' : 'Buy capped PUT'} · pays on {band[0].toFixed(1)} – {band[1].toFixed(1)}
          </div>
        </Card>
        <KeyValue
          rows={[
            ['Strike', `${strike.toFixed(2)} USDC`],
            ['Cap', `${cap.toFixed(2)} USDC`],
            ['Size', `${size.toFixed(2)} units`],
            ['Expiry', `${hoursToExpiry}h from now`],
            ['Premium', `${bindingPremium.toFixed(QUOTE_DECIMALS)} USDC`],
            ['Max premium paid', `${(bindingPremium * (1 + SLIP_PCT / 100)).toFixed(QUOTE_DECIMALS)} USDC`],
            ['Max payout', `${maxPayout.toFixed(2)} USDC`],
          ]}
        />
      </Modal>

      {toast && <Toast>{toast}</Toast>}
    </Backdrop>
  )
}

/* -- small helpers --------------------------------------------------------- */

/** Seconds until `at`, re-read once a second. Kept inside the leaf cells so the
 *  clock never re-renders the chart. */
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
  const h = Math.floor(left / 3600)
  const m = Math.floor((left % 3600) / 60)
  const s = left % 60
  return (
    <span title={new Date(expiry * 1000).toLocaleString()}>
      {h > 0 ? `${h}h ` : ''}
      {String(m).padStart(2, '0')}m {String(s).padStart(2, '0')}s
    </span>
  )
}

/** settle() reverts before expiry, so the button stays disabled until the
 *  countdown actually reaches zero — hence its own tick. */
function SettleButton({
  p,
  enabled,
  onSettle,
}: {
  p: Position
  enabled: boolean
  onSettle: (p: Position) => void
}) {
  const expired = useSecondsLeft(p.expiry) <= 0
  const why = !p.onchain
    ? 'preview position — nothing to settle on chain'
    : p.settled
      ? 'already settled'
      : !expired
        ? 'not expired yet'
        : !enabled
          ? 'connect a wallet on a live deploy'
          : 'settle'
  return (
    <Button
      size="sm"
      variant="primary"
      disabled={!enabled || !expired || !p.onchain || p.settled}
      onClick={() => onSettle(p)}
      title={why}
    >
      Settle
    </Button>
  )
}

const round = (v: number, step: number) => Math.round(v / step) * step

/**
 * Risk-neutral density of the open under the same lognormal the pricer assumes
 * (r = 0). Bar i is the density at the centre of its slice — enough to draw.
 */
function lognormalBins(
  spot: number,
  vol: number,
  seconds: number,
  lo: number,
  hi: number,
  n: number,
): number[] {
  const srt = vol * Math.sqrt(Math.max(seconds, 60) / 31_536_000)
  const mu = Math.log(spot) - (srt * srt) / 2
  return Array.from({ length: n }, (_, i) => {
    const s = lo + ((i + 0.5) / n) * (hi - lo)
    if (s <= 0) return 0
    const z = (Math.log(s) - mu) / srt
    return Math.exp(-(z * z) / 2) / (s * srt)
  })
}

// abi.encode(address maker, bytes32 strategyHash) — matches DemoTaker's takerData.
function encodeTakerData(maker: `0x${string}`, strategyHash: `0x${string}`): `0x${string}` {
  const makerPadded = maker.slice(2).toLowerCase().padStart(64, '0')
  const hashHex = strategyHash.slice(2)
  return `0x${makerPadded}${hashHex}` as `0x${string}`
}
