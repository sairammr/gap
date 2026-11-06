import { useEffect, useMemo, useState } from 'react'
import {
  Zap,
  Wallet,
  Lock,
  Clock,
  TrendingUp,
  TrendingDown,
  ArrowUpRight,
  Crosshair,
  Layers,
  ShieldCheck,
  Info,
  RefreshCw,
  CheckCircle2,
} from 'lucide-react'
import {
  useAccount,
  useConnect,
  useDisconnect,
  usePublicClient,
  useWriteContract,
} from 'wagmi'
import { formatUnits, parseUnits } from 'viem'
import { gapOptionsAppAbi, gapTakerAbi } from './lib/abi'
import { loadDeployment, isDeployed, type Deployment } from './lib/deployment'
import { buildStrategy, DEFAULT_VOL, QUOTE_DECIMALS } from './lib/strategy'
import { KIND, previewPremium, cappedPayoffPerUnit, type OptionKind } from './lib/pricing'
import { useSpotSeries } from './hooks/useSpotSeries'
import { PriceChart } from './components/PriceChart'

type LocalPosition = {
  positionId: string
  kind: OptionKind
  strike: number
  cap: number
  size: number
  expiry: number
  premium: number
}

export default function App() {
  const { address, isConnected } = useAccount()
  const { connect, connectors } = useConnect()
  const { disconnect } = useDisconnect()
  const publicClient = usePublicClient()
  const { writeContractAsync, isPending } = useWriteContract()

  const [deployment, setDeployment] = useState<Deployment | null>(null)
  const [loadingDeploy, setLoadingDeploy] = useState(true)
  const deployed = isDeployed(deployment)

  // --- option ticket state ---
  const [kind, setKind] = useState<OptionKind>(KIND.CALL)
  const [strike, setStrike] = useState(100)
  const [cap, setCap] = useState(5)
  const [size, setSize] = useState(1)
  const [hoursToExpiry, setHoursToExpiry] = useState(16) // overnight-ish

  const [onchainPremium, setOnchainPremium] = useState<number | null>(null)
  const [quoteErr, setQuoteErr] = useState<string | null>(null)
  const [positions, setPositions] = useState<LocalPosition[]>([])
  const [toast, setToast] = useState<string | null>(null)

  useEffect(() => {
    loadDeployment()
      .then(setDeployment)
      .finally(() => setLoadingDeploy(false))
  }, [])

  const spot = useSpotSeries(deployment, deployed)
  const spotPrice = spot.lastSpot ?? 100

  const secondsToExpiry = Math.max(0, Math.round(hoursToExpiry * 3600))

  // --- client-side premium preview (mirror of GapPricing) ---
  const preview = useMemo(
    () => previewPremium(kind, spotPrice, strike, cap, secondsToExpiry, DEFAULT_VOL, size),
    [kind, spotPrice, strike, cap, secondsToExpiry, size],
  )

  // Payoff telemetry (zero-jargon): max payout, breakeven, premium-as-% of max.
  const maxPayout = cap * size
  const breakeven = kind === KIND.CALL ? strike + preview / size : strike - preview / size
  const payoffAtTarget =
    cappedPayoffPerUnit(kind, kind === KIND.CALL ? strike + cap : strike - cap, strike, cap) * size

  // --- binding on-chain quotePremium read ---
  useEffect(() => {
    let cancelled = false
    setQuoteErr(null)
    if (!deployed || !deployment || !publicClient || !address) {
      setOnchainPremium(null)
      return
    }
    const strategy = buildStrategy(deployment, address)
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
  }, [deployed, deployment, publicClient, address, kind, strike, cap, size, secondsToExpiry])

  const canBuyOnChain = deployed && isConnected && !!deployment?.gapTaker

  async function handleBuy() {
    if (!deployment || !address) return
    const strategy = buildStrategy(deployment, address)
    const expiry = BigInt(Math.floor(Date.now() / 1000) + secondsToExpiry)
    const bindingPremium = onchainPremium ?? preview
    const maxPremium = parseUnits((bindingPremium * 1.02).toFixed(QUOTE_DECIMALS), QUOTE_DECIMALS)
    // takerData = abi.encode(maker, strategyHash) — the GapTaker helper decodes it
    // and pushes USDC into the maker's Aqua balance (see DemoTaker.gapOptionCallback).
    const strategyHash = (await publicClient!.readContract({
      address: deployment.gapOptionsApp as `0x${string}`,
      abi: gapOptionsAppAbi,
      functionName: 'hashStrategy',
      args: [strategy],
    })) as `0x${string}`
    const takerData = encodeTakerData(address, strategyHash)
    await writeContractAsync({
      address: deployment.gapTaker as `0x${string}`,
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
  }

  // Visual-only local mint so the positions panel demonstrates its shape even when
  // on-chain buy is deferred. Marked as a preview entry.
  function addPreviewPosition() {
    const bindingPremium = onchainPremium ?? preview
    setPositions((p) => [
      {
        positionId: 'preview-' + Math.random().toString(36).slice(2, 8),
        kind,
        strike,
        cap,
        size,
        expiry: Math.floor(Date.now() / 1000) + secondsToExpiry,
        premium: bindingPremium,
      },
      ...p,
    ])
    setToast('Preview position added (not on-chain)')
  }

  useEffect(() => {
    if (!toast) return
    const id = setTimeout(() => setToast(null), 3000)
    return () => clearTimeout(id)
  }, [toast])

  const gapPct = ((breakeven - spotPrice) / spotPrice) * 100

  return (
    <div className="app">
      <header className="header">
        <div className="brand">
          <div className="brand-mark">
            <Zap size={16} />
            <span className="dot pulse" style={{ position: 'absolute', top: -3, right: -3 }} />
          </div>
          <div>
            <div className="brand-title">
              GAP <span className="slash">//</span> PROTOCOL
            </div>
            <div className="brand-sub">overnight gap options</div>
          </div>
        </div>
        <div className="header-right">
          <span className="chip amber">
            <Lock size={13} /> Base Sepolia
          </span>
          <span className="chip">
            <span className="dot pulse" /> {spot.synthetic ? 'synthetic spot' : 'live v4 spot'}
          </span>
          {isConnected ? (
            <button className="btn ghost" onClick={() => disconnect()}>
              <Wallet size={13} /> {address?.slice(0, 6)}…{address?.slice(-4)}
            </button>
          ) : (
            <button
              className="btn primary"
              onClick={() => connectors[0] && connect({ connector: connectors[0] })}
              disabled={!connectors.length}
            >
              <Wallet size={13} /> Connect
            </button>
          )}
        </div>
      </header>

      {!loadingDeploy && !deployed && (
        <div className="banner">
          <Info size={15} />
          Not deployed yet — set contract addresses in app/public/deployments/base-sepolia.json
          (populated by a live deploy). Running in read-only PREVIEW mode: premiums are
          client-side estimates and the chart series is synthetic.
        </div>
      )}
      {deployed && (
        <div className="banner ok">
          <CheckCircle2 size={15} />
          Deployment loaded — reading live v4 spot and on-chain quotePremium.
        </div>
      )}

      <div className="main">
        {/* LEFT: chart + gap visualizer + positions */}
        <div className="col">
          <div className="panel">
            <div className="panel-head">
              <div className="panel-title">
                <TrendingUp size={14} /> NVDAx / USDC — v4 spot
              </div>
              <div className="chip mono">
                <RefreshCw size={12} /> {spotPrice ? spotPrice.toFixed(2) : '—'} USDC
              </div>
            </div>
            <PriceChart candles={spot.candles} synthetic={spot.synthetic} />
            <div className="footnote">
              v4 exposes no TWAP; spot is the instantaneous sqrtPriceX96 from StateView.getSlot0.
              The candle series is built from sampled reads (one candle per 15s poll). With no
              deployment or thin history it shows a synthetic random walk, badged above.
            </div>
          </div>

          <div className="panel">
            <div className="panel-head">
              <div className="panel-title">
                <Crosshair size={14} /> close → open gap
              </div>
            </div>
            <div className="gapviz">
              <div className="node">
                <div className="label">spot (close anchor)</div>
                <div className="price blueq">{spotPrice.toFixed(2)}</div>
              </div>
              <div className="arrow">
                {gapPct >= 0 ? (
                  <ArrowUpRight size={22} className="pos" />
                ) : (
                  <TrendingDown size={22} className="neg" />
                )}
                <div className={`gappct ${gapPct >= 0 ? 'pos' : 'neg'}`}>
                  {gapPct >= 0 ? '+' : ''}
                  {gapPct.toFixed(2)}%
                </div>
              </div>
              <div className="node">
                <div className="label">breakeven open</div>
                <div className={`price ${gapPct >= 0 ? 'pos' : 'neg'}`}>{breakeven.toFixed(2)}</div>
              </div>
            </div>
          </div>

          <div className="panel">
            <div className="panel-head">
              <div className="panel-title">
                <Layers size={14} /> your positions
              </div>
            </div>
            <div className="poslist">
              {positions.length === 0 ? (
                <div className="empty">
                  No positions. Buy an option to mint an ERC-1155 position here. On-chain buy is
                  deferred to a live deploy (see the ticket).
                </div>
              ) : (
                positions.map((p) => (
                  <PositionRow
                    key={p.positionId}
                    p={p}
                    canSettle={deployed && isConnected}
                    onSettle={() => settlePosition(p)}
                  />
                ))
              )}
            </div>
          </div>
        </div>

        {/* RIGHT: 3-step ticket */}
        <div className="col">
          <div className="panel">
            <div className="panel-head">
              <div className="panel-title">
                <ShieldCheck size={14} /> build option
              </div>
              <span className="chip mono">capped {kind === KIND.CALL ? 'CALL' : 'PUT'}</span>
            </div>
            <div className="panel-body">
              <div className="steps">
                {/* step 1 — direction */}
                <div className="step">
                  <div className="step-head">
                    <span className="step-num">1</span>
                    <span className="step-title">Pick a direction</span>
                  </div>
                  <div className="step-body">
                    <div className="seg">
                      <button
                        className={kind === KIND.CALL ? 'active-call' : ''}
                        onClick={() => setKind(KIND.CALL)}
                      >
                        <TrendingUp size={13} style={{ verticalAlign: '-2px' }} /> GAP UP (CALL)
                      </button>
                      <button
                        className={kind === KIND.PUT ? 'active-put' : ''}
                        onClick={() => setKind(KIND.PUT)}
                      >
                        <TrendingDown size={13} style={{ verticalAlign: '-2px' }} /> GAP DOWN (PUT)
                      </button>
                    </div>
                    <div className="hint">
                      Capped {kind === KIND.CALL ? 'call' : 'put'}: you win if the open gaps{' '}
                      {kind === KIND.CALL ? 'above' : 'below'} your strike, up to the cap. Payoff is
                      bounded — no unlimited tails, so the writer fully collateralises it.
                    </div>
                  </div>
                </div>

                {/* step 2 — terms */}
                <div className="step">
                  <div className="step-head">
                    <span className="step-num">2</span>
                    <span className="step-title">Set your terms</span>
                  </div>
                  <div className="step-body">
                    <div className="grid2">
                      <div className="field">
                        <label>strike (USDC)</label>
                        <input
                          type="number"
                          value={strike}
                          min={0}
                          step={1}
                          onChange={(e) => setStrike(Number(e.target.value))}
                        />
                      </div>
                      <div className="field">
                        <label>cap / max payout (USDC)</label>
                        <input
                          type="number"
                          value={cap}
                          min={0}
                          step={0.5}
                          onChange={(e) => setCap(Number(e.target.value))}
                        />
                      </div>
                      <div className="field">
                        <label>size (units)</label>
                        <input
                          type="number"
                          value={size}
                          min={0}
                          step={0.5}
                          onChange={(e) => setSize(Number(e.target.value))}
                        />
                      </div>
                      <div className="field">
                        <label>
                          <span>hours to expiry</span>
                          <span className="mono">{hoursToExpiry}h</span>
                        </label>
                        <input
                          type="range"
                          min={1}
                          max={48}
                          step={1}
                          value={hoursToExpiry}
                          onChange={(e) => setHoursToExpiry(Number(e.target.value))}
                        />
                      </div>
                    </div>
                  </div>
                </div>

                {/* step 3 — review + act */}
                <div className="step">
                  <div className="step-head">
                    <span className="step-num">3</span>
                    <span className="step-title">Review &amp; buy</span>
                  </div>
                  <div className="step-body">
                    <div className="telemetry">
                      <div className="cell">
                        <div className="k">premium (preview)</div>
                        <div className="v">{preview.toFixed(QUOTE_DECIMALS)} USDC</div>
                      </div>
                      <div className="cell">
                        <div className="k">max payout</div>
                        <div className="v pos">{maxPayout.toFixed(2)} USDC</div>
                      </div>
                      <div className="cell">
                        <div className="k">breakeven open</div>
                        <div className="v">{breakeven.toFixed(2)}</div>
                      </div>
                      <div className="cell">
                        <div className="k">payout if capped</div>
                        <div className="v amberq">{payoffAtTarget.toFixed(2)} USDC</div>
                      </div>
                    </div>

                    <div className="row-between">
                      <div>
                        <div className="k mono" style={{ fontSize: 10, color: 'var(--muted)' }}>
                          BINDING ON-CHAIN QUOTE
                        </div>
                        <div className="binding">
                          {onchainPremium != null
                            ? `${onchainPremium.toFixed(QUOTE_DECIMALS)} USDC`
                            : deployed
                              ? quoteErr
                                ? 'quote unavailable'
                                : 'reading…'
                              : 'connect + deploy for binding quote'}
                        </div>
                      </div>
                      <div className="big-premium">{(onchainPremium ?? preview).toFixed(2)}</div>
                    </div>

                    {canBuyOnChain ? (
                      <button className="btn primary" onClick={handleBuy} disabled={isPending}>
                        {isPending ? 'confirming…' : 'Buy option (via GapTaker)'}
                      </button>
                    ) : (
                      <button className="btn" onClick={addPreviewPosition}>
                        Add preview position (on-chain buy deferred)
                      </button>
                    )}

                    <div className="hint">
                      <strong>Buy routes through a GapTaker helper contract</strong>, never an EOA:
                      buyOption requires msg.sender to implement IGapOptionCallback and push the
                      premium into the maker's Aqua balance (see DemoTaker). The UI calls
                      GapTaker.buy with takerData = abi.encode(maker, strategyHash). Live buy/settle
                      is <strong>deferred to a live deploy</strong> (user adds contracts/.env); the
                      GapTaker address goes in the deployment JSON under <code>gapTaker</code>.
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div className="panel">
            <div className="panel-head">
              <div className="panel-title">
                <Clock size={14} /> how settlement works
              </div>
            </div>
            <div className="panel-body hint">
              After expiry anyone can call <code>settle(strategy, positionId, holder)</code>. The app
              reads the realised v4 spot, pays the holder{' '}
              <code>min(max(0, ±(spot − strike)), cap) × size</code> in USDC from the maker's held
              backing, and returns the remainder to the maker. Cash-settled, fully collateralised.
            </div>
          </div>
        </div>
      </div>

      {toast && (
        <div
          className="chip ok"
          style={{
            position: 'fixed',
            bottom: 20,
            left: '50%',
            transform: 'translateX(-50%)',
            background: '#081310',
            borderColor: 'rgba(0,245,155,0.4)',
            color: 'var(--green)',
            zIndex: 40,
          }}
        >
          <CheckCircle2 size={13} /> {toast}
        </div>
      )}
    </div>
  )

  async function settlePosition(p: LocalPosition) {
    if (!deployment || !address || !p.positionId.startsWith('0x')) {
      setToast('Settle is on-chain only (needs a live position + deploy)')
      return
    }
    const strategy = buildStrategy(deployment, address)
    await writeContractAsync({
      address: deployment.gapOptionsApp as `0x${string}`,
      abi: gapOptionsAppAbi,
      functionName: 'settle',
      args: [strategy, BigInt(p.positionId), address],
    })
    setToast('Settle submitted')
  }
}

function PositionRow({
  p,
  canSettle,
  onSettle,
}: {
  p: LocalPosition
  canSettle: boolean
  onSettle: () => void
}) {
  const expired = p.expiry <= Math.floor(Date.now() / 1000)
  return (
    <div className="posrow">
      <div>
        <span className={`tag ${p.kind === KIND.CALL ? 'call' : 'put'}`}>
          {p.kind === KIND.CALL ? (
            <TrendingUp size={11} />
          ) : (
            <TrendingDown size={11} />
          )}
          {p.kind === KIND.CALL ? 'CALL' : 'PUT'}
        </span>
        <div className="mono" style={{ fontSize: 12, marginTop: 6, color: 'var(--muted)' }}>
          K {p.strike} · cap {p.cap} · size {p.size} · prem {p.premium.toFixed(2)} USDC
        </div>
      </div>
      <button
        className="btn danger"
        disabled={!canSettle || !expired}
        onClick={onSettle}
        title={!expired ? 'not expired yet' : !canSettle ? 'connect + live deploy' : 'settle'}
      >
        Settle
      </button>
    </div>
  )
}

// abi.encode(address maker, bytes32 strategyHash) — matches DemoTaker's takerData.
function encodeTakerData(maker: `0x${string}`, strategyHash: `0x${string}`): `0x${string}` {
  const makerPadded = maker.slice(2).toLowerCase().padStart(64, '0')
  const hashHex = strategyHash.slice(2)
  return `0x${makerPadded}${hashHex}` as `0x${string}`
}
