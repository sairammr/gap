/* ============================================================================
   GAP desk — the trade interface.

   Layout follows kuru.io/trade 1:1: resting orders listed on the LEFT (one row
   per shipped maker quote, ASK green above / BID red below the v4 mid), the
   chart + position tabs in the CENTER, and the Buy/Sell order ticket on the
   RIGHT. Clicking a resting order loads its series + maker into the ticket.

   The product is GAP on 1inch Aqua (Base Sepolia): fully-collateralised
   physically-settled CALL/PUT on NVDAx, one ERC-20 per series, priced + settled in
   USDC. Fills go through the REAL AquaSwapVMRouter — the exact path proven on-chain
   in contracts/script/Lifecycle.s.sol:
     Buy  = swap(ASK order, optionsOut, tt(usdc,   maxIn,  exactOut))
     Sell = swap(BID order, optionsIn,  tt(option, minOut, exactIn))
   Every order is rebuilt in-app (lib/orders.ts, byte-identical to OrderLib.sol)
   and GATED (router.hash(order) == the shipped strategyHash) before any fill.

   The BUY is exact-OUT on purpose. `WeekendPricer._fillMissingLeg` derives whichever
   amount the taker did not name, so an exact-in buy of "premium + slack" quietly
   returns `slack` more options than the ticket said. Naming the option count makes
   the number on screen the number that lands, and the slack becomes a `maxIn`.
   ========================================================================= */

import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Activity as ActivityIcon,
  Anchor,
  ArrowLeftRight,
  Clock,
  Coins,
  ExternalLink,
  Inbox,
  Layers,
  Lock,
  TrendingDown,
  TrendingUp,
  Wallet,
  Presentation,
} from 'lucide-react'
import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { usePrivy } from '@privy-io/react-auth'
import { formatUnits, parseUnits } from 'viem'
import { erc20Abi, optionTokenAbi, oracleAbi, routerAbi, weekendOptionsAbi } from './lib/abi'
import { readCapacity, type Capacity } from './lib/capacity'
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
import { pricingStrategy, volPct } from './lib/strategy'
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
  Table,
  Tabs,
  TokenDot,
  Toast,
} from './ui'

const BASESCAN = 'https://sepolia.basescan.org'

/** No ceiling. See the quote call in `handleBuy`. */
const MAX_UINT256 = (1n << 256n) - 1n

const NAV = [
  { key: 'trade', label: 'Trade', icon: <ArrowLeftRight size={16} /> },
  { key: 'earn', label: 'Earn', icon: <Anchor size={16} /> },
  { key: 'positions', label: 'Positions', icon: <Layers size={16} /> },
  { key: 'pitch', label: 'Pitch', icon: <Presentation size={16} /> },
]

const VIEW_KEYS = NAV.map((n) => n.key)
function viewFromHash(): string {
  const h = location.hash.replace(/^#/, '')
  return VIEW_KEYS.includes(h) ? h : 'trade'
}

/** Per-series facts read from `getSeries`, keyed by seriesId.
 *
 *  Chain truth, not JSON truth: the deployment file carries `strike`/`expiry` for
 *  the two series it happened to create, but `kind` not at all, and it goes stale
 *  the moment anyone calls `createSeries`. Everything the ticket shows is derived
 *  from here, with the JSON used only to find the addresses. `strikeRaw` stays a
 *  bigint — the float beside it is for display and nothing else. */
interface SeriesMeta {
  kind: OptionKind
  strikeRaw: bigint
  strike: number
  expiry: number
  settled: boolean
}
type KindMap = Record<number, SeriesMeta>

/** A write, described in full before it is allowed to open a wallet. */
interface PendingAction {
  title: string
  /** What the user is about to sign, in plain words. */
  summary: string
  /** label -> value. "You pay", "You receive", "Your balance". */
  rows: [string, string][]
  /** Set when the wallet cannot cover it; `run` is then never offered. */
  blocked?: string
  /** How many wallet prompts this will open, so the count is never a surprise. */
  steps: number
  run: () => Promise<void>
}

/** The wallet balances every action preview is checked against. */
interface Balances {
  usdc: bigint
  nvdax: bigint
}

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
  const [toast, setToast] = useState<string | null>(null)

  /* Every write goes through here first.
   *
   * The old flow opened a wallet prompt straight off a button: clicking Exercise
   * asked for a 756.97 USDC approval with nothing on screen saying what was being
   * paid or received, and the only sane reaction was to reject it. An action now
   * has to describe itself — what you pay, what you get, what you hold — and is
   * BLOCKED before the wallet ever opens if the balance cannot cover it. */
  const [pending, setPending] = useState<PendingAction | null>(null)
  const [running, setRunning] = useState(false)

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

  // The shipped resting orders, straight from the deployment (no log scan to paint).
  const quotes = useMemo(() => (deployment ? makerQuotes(deployment) : []), [deployment])

  // Bumped after every write so the series facts and the capacity ceilings re-read.
  // Positions have their own `refetch`; `refreshAll` fires both.
  const [refreshKey, setRefreshKey] = useState(0)

  // Series facts, read from chain so every row and the ticket agree with the contract.
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
        })) as { kind: number; strike: bigint; expiry: bigint; settled: boolean }
        const meta: SeriesMeta = {
          kind: (ser.kind === 1 ? KIND.PUT : KIND.CALL) as OptionKind,
          strikeRaw: ser.strike,
          strike: Number(formatUnits(ser.strike, QUOTE_DECIMALS)),
          expiry: Number(ser.expiry),
          settled: ser.settled,
        }
        return [id, meta] as const
      }),
    )
      .then((entries) => {
        if (!cancelled) setKinds(Object.fromEntries(entries))
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [deployed, deployment, publicClient, quotes, refreshKey])

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

  const meta = selected ? kinds[selected.seriesId] : undefined
  const seriesKind = meta?.kind ?? KIND.CALL
  const strikeUsd = meta?.strike ?? 0
  const expiry = meta?.expiry ?? 0
  const secondsToExpiry = Math.max(0, expiry - Math.floor(Date.now() / 1000))
  const vol = selected ? Number(selected.volWad) / 1e18 : 0.6

  // --- client-side premium preview (instant) -------------------------------
  const previewUnit = useMemo(
    () => (selected ? premiumPerUnit(seriesKind, spotPrice, strikeUsd, secondsToExpiry, vol) : 0),
    [selected, seriesKind, spotPrice, strikeUsd, secondsToExpiry, vol],
  )
  const previewTotal = previewUnit * size

  /* --- the book's own premiums -------------------------------------------
   *
   * One `quotePremium` per resting quote, priced for ONE option so the column
   * is comparable across rows of different size. These are the binding numbers,
   * not the client-side preview: a book that quotes one price and fills at
   * another is worse than a book with no prices in it.
   *
   * Keyed by `q.key` and re-read when spot moves, for the same reason the
   * ticket does — the pool price is the one input to a premium that changes
   * on its own. */
  const [premiums, setPremiums] = useState<Record<string, number>>({})
  useEffect(() => {
    if (!deployed || !deployment || !publicClient || quotes.length === 0) {
      setPremiums({})
      return
    }
    let cancelled = false
    void Promise.all(
      quotes.map(async (q) => {
        try {
          const p = (await publicClient.readContract({
            address: deployment.weekendOptions as `0x${string}`,
            abi: weekendOptionsAbi,
            functionName: 'quotePremium',
            args: [pricingStrategy(deployment, q), BigInt(q.seriesId), parseUnits('1', UNDERLYING_DECIMALS)],
          })) as bigint
          return [q.key, Number(formatUnits(p, QUOTE_DECIMALS))] as const
        } catch {
          // A series the desk never listed, or one past expiry: leave the cell
          // blank rather than printing a zero that reads like a free option.
          return [q.key, Number.NaN] as const
        }
      }),
    ).then((entries) => {
      if (cancelled) return
      setPremiums(Object.fromEntries(entries.filter(([, v]) => Number.isFinite(v))))
    })
    return () => {
      cancelled = true
    }
  }, [deployed, deployment, publicClient, quotes, spotPrice])

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
          pricingStrategy(deployment, selected),
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
  }, [deployed, deployment, publicClient, selected, size, spotPrice])

  const bindingPremium = onchainPremium ?? previewTotal

  /* --- how much each resting quote can actually fill ----------------------
   *
   * Three ceilings bind an ask and the smallest wins; `lib/capacity.ts` reads all
   * of them. Deliberately NOT `makerCapacity` — that hashes the Strategy tuple to
   * key the Aqua ledger, and no tuple rebuildable from this JSON hashes to one the
   * desk shipped, so it answered 0 against a desk holding ~9,982 NVDAx.
   *
   * Read for EVERY quote, not just the selected one, so the book rows can show a
   * real size instead of repeating the side back at the user. */
  const [caps, setCaps] = useState<Record<string, Capacity>>({})
  useEffect(() => {
    let cancelled = false
    if (!tradable || !deployment || !publicClient || quotes.length === 0) {
      setCaps({})
      return
    }
    // Needs the series facts first; the PUT cover conversion divides by the strike.
    const ready = quotes.filter((q) => kinds[q.seriesId])
    if (ready.length === 0) return
    void Promise.all(
      ready.map(async (q) => {
        const m = kinds[q.seriesId]
        return [q.key, await readCapacity(publicClient, deployment, q, m.kind, m.strikeRaw)] as const
      }),
    )
      .then((entries) => {
        if (!cancelled) setCaps(Object.fromEntries(entries))
      })
      .catch(() => {
        if (!cancelled) setCaps({})
      })
    return () => {
      cancelled = true
    }
  }, [tradable, deployment, publicClient, quotes, kinds, refreshKey])

  const cap = selected ? caps[selected.key] : undefined
  /** Options this quote can still fill. A bid's USDC budget is converted at the
   *  binding premium, which is what the taker would actually be paid. */
  const availableOptions = useMemo(() => {
    if (!cap) return null
    if (cap.side === 'ask') return Number(formatUnits(cap.options, UNDERLYING_DECIMALS))
    const perOption = bindingPremium / Math.max(size, 1e-9)
    if (perOption <= 0) return null
    return Number(formatUnits(cap.usdc, QUOTE_DECIMALS)) / perOption
  }, [cap, bindingPremium, size])

  const overCapacity = availableOptions != null && size > availableOptions

  // Positions + history off the chain.
  const chain = usePositions(deployment, deployed, address)

  /** Re-read everything a write could have moved. */
  const refreshAll = useCallback(() => {
    setRefreshKey((n) => n + 1)
    chain.refetch()
  }, [chain])

  // The wallet's spendable balances — what every action preview is checked against.
  const [bal, setBal] = useState<Balances>({ usdc: 0n, nvdax: 0n })
  useEffect(() => {
    if (!deployed || !deployment || !publicClient || !address) return
    let cancelled = false
    void Promise.all([
      publicClient.readContract({
        address: deployment.usdc as `0x${string}`,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [address],
      }) as Promise<bigint>,
      publicClient.readContract({
        address: deployment.nvdax as `0x${string}`,
        abi: erc20Abi,
        functionName: 'balanceOf',
        args: [address],
      }) as Promise<bigint>,
    ])
      .then(([usdc, nvdax]) => {
        if (!cancelled) setBal({ usdc, nvdax })
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [deployed, deployment, publicClient, address, refreshKey])

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

    /* EXACT-OUT. The taker names an option COUNT and pays the ceiling for it.
     *
     * Exact-in was wrong here in a way that does not revert: `_fillMissingLeg`
     * derives `amountOut = amountIn * 1e18 / premium`, so sending "premium + 2%
     * slack" bought 1.02 options for a ticket that said 1.00, and the confirm
     * modal said 1.00. Naming the out leg makes the number on screen the number
     * that lands; the slack moves to `maxIn`, where it belongs. */
    const optionsOut = parseUnits(String(size), UNDERLYING_DECIMALS)

    // Price it first so the approval and the ceiling are the router's own numbers,
    // not the preview's. Threshold 0 on a quote = no threshold (NOT "free").
    /* The threshold is NOT "unset" at zero. On an exact-OUT fill it is the max-IN
     * ceiling, and the router enforces it inside `quote` exactly as it does inside
     * `swap` — so quoting with 0 asks "price this, given I will pay at most
     * nothing" and reverts instead of returning a price. Quote unbounded, then put
     * the real ceiling on the swap below. */
    const ttQuote = takerTraits(deployment.usdc, selected.optionToken, deployment.usdc, MAX_UINT256, false)
    const [quotedIn] = (await publicClient.readContract({
      address: router,
      abi: routerAbi,
      functionName: 'quote',
      args: [order, optionsOut, ttQuote],
    })) as readonly [bigint, bigint, `0x${string}`]
    if (quotedIn === 0n) {
      setToast('Router quoted zero — refusing to send')
      return
    }
    // 2% ceiling, so a tick of the v4 spot between quote and mine does not revert.
    const maxIn = (quotedIn * 102n) / 100n

    const allowance = (await publicClient.readContract({
      address: deployment.usdc as `0x${string}`,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [address, router],
    })) as bigint
    if (allowance < maxIn) {
      setToast('Approving USDC for the router…')
      const approveHash = await writeContractAsync({
        address: deployment.usdc as `0x${string}`,
        abi: erc20Abi,
        functionName: 'approve',
        args: [router, maxIn],
      })
      await publicClient.waitForTransactionReceipt({ hash: approveHash })
    }

    const ttSwap = takerTraits(deployment.usdc, selected.optionToken, deployment.usdc, maxIn, false)
    const buyHash = await writeContractAsync({
      address: router,
      abi: routerAbi,
      functionName: 'swap',
      args: [order, optionsOut, ttSwap],
    })
    setToast('Buy submitted via SwapVM router')
    await publicClient.waitForTransactionReceipt({ hash: buyHash })
    refreshAll()
    setToast(`Bought ${size} option${size === 1 ? '' : 's'}`)
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

    // Exact-in: the taker names the options it delivers and takes what the bid pays.
    const optionIn = parseUnits(String(size), UNDERLYING_DECIMALS)
    const ttQuote = takerTraits(deployment.usdc, selected.optionToken, selected.optionToken, 0n)
    const [, quotedUsdc] = (await publicClient.readContract({
      address: router,
      abi: routerAbi,
      functionName: 'quote',
      args: [order, optionIn, ttQuote],
    })) as readonly [bigint, bigint, `0x${string}`]
    if (quotedUsdc === 0n) {
      setToast('Bid quoted zero — refusing to send')
      return
    }
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
    refreshAll()
    setToast('Options sold into the bid')
  }

  /** Describe the trade, check the wallet can pay for it, then offer it. */
  function reviewTrade() {
    if (!selected || !deployment) return
    const cost = parseUnits(bindingPremium.toFixed(QUOTE_DECIMALS), QUOTE_DECIMALS)
    const maxCost = (cost * 102n) / 100n
    const label = `${isCall ? 'CALL' : 'PUT'} #${selected.seriesId} · strike ${strikeUsd.toFixed(2)}`

    if (tab === 'buy') {
      setPending({
        title: `Buy ${size} ${size === 1 ? 'option' : 'options'}`,
        summary: `${label}. You pay USDC now and get the right — never the obligation — to buy ${size} NVDAx at ${strikeUsd.toFixed(2)} each, any time before expiry.`,
        rows: [
          ['You pay', `~${bindingPremium.toFixed(2)} USDC (max ${fmtQ(maxCost)})`],
          ['You receive', `${size} ${isCall ? 'CALL' : 'PUT'} option${size === 1 ? '' : 's'}`],
          ['Your USDC', fmtQ(bal.usdc)],
          ['Expires', new Date(expiry * 1000).toLocaleString()],
        ],
        blocked:
          bal.usdc < maxCost
            ? `Not enough USDC — you need about ${fmtQ(maxCost)} and hold ${fmtQ(bal.usdc)}. Use the “Test USDC” button up top.`
            : undefined,
        steps: 2,
        run: handleBuy,
      })
      return
    }

    setPending({
      title: `Sell ${size} ${size === 1 ? 'option' : 'options'}`,
      summary: `${label}. You hand the options back to the desk and take USDC at its bid, which is priced at a lower vol than the ask — that spread is the desk's.`,
      rows: [
        ['You deliver', `${size} option${size === 1 ? '' : 's'}`],
        ['You receive', `~${bindingPremium.toFixed(2)} USDC`],
      ],
      steps: 2,
      run: handleSell,
    })
  }

  /** Run whatever is in the modal, keeping errors on screen instead of in the console. */
  async function runPending() {
    const action = pending
    if (!action || action.blocked) return
    setPending(null)
    setRunning(true)
    try {
      await action.run()
    } catch (e) {
      setToast(friendlyError(e))
    } finally {
      setRunning(false)
    }
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
  const actions = usePositionActions(deployment, publicClient, writeContractAsync, setToast, refreshAll, bal)

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

      {/* The metrics that used to sit in four stacked tiles under the book.
          As a strip under the price they read as one instrument panel and
          stop stealing a screen's worth of the book's column. */}
      <div className="ck-metrics">
        <div className="ck-metric">
          <span className="ck-metric__k">Premium</span>
          <span className="ck-metric__v">{bindingPremium.toFixed(4)}</span>
          <span className="ck-metric__s">
            {selected ? `series ${selected.seriesId} · ${size} opt` : '—'}
          </span>
        </div>
        <div className="ck-metric">
          <span className="ck-metric__k">Strike</span>
          <span className="ck-metric__v">{strikeUsd.toFixed(2)}</span>
          <span className="ck-metric__s">
            {seriesKind === KIND.CALL ? 'CALL — writer locks NVDAx' : 'PUT — writer locks USDC'}
          </span>
        </div>
        <div className="ck-metric">
          <span className="ck-metric__k">Available</span>
          <span className="ck-metric__v">
            {availableOptions == null ? '—' : availableOptions.toFixed(2)}
          </span>
          <span className="ck-metric__s">options this quote can still fill</span>
        </div>
        <div className="ck-metric">
          <span className="ck-metric__k">Implied vol</span>
          <span className="ck-metric__v">{selected ? `${volPct(selected.volWad)}%` : '—'}</span>
          <span className="ck-metric__s">the maker&rsquo;s only pricing axis</span>
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
          <span style={{ textAlign: 'right' }}>Premium</span>
          <span style={{ textAlign: 'right' }}>IV</span>
          <span style={{ textAlign: 'right' }}>Size</span>
        </div>
        {/* ASKs above the mid (green) */}
        {asks.length === 0 && <div className="vx-book__empty">No asks shipped</div>}
        {asks.map((q) => (
          <QuoteRow
            key={q.key}
            q={q}
            meta={kinds[q.seriesId]}
            cap={caps[q.key]}
            premium={premiums[q.key]}
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
            meta={kinds[q.seriesId]}
            cap={caps[q.key]}
            premium={premiums[q.key]}
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
              disabled={
                !tradable || !isConnected || size <= 0 || noBindingQuote || sellDisabled || overCapacity
              }
              title={
                noBindingQuote
                  ? 'No binding on-chain quote — trading is unsafe'
                  : sellDisabled
                    ? 'No resting bid to sell into'
                    : overCapacity
                      ? 'Larger than this quote can fill'
                      : undefined
              }
              onClick={reviewTrade}
            >
              {tab === 'buy' ? 'Buy options' : 'Sell into bid'}
            </Button>

            {overCapacity && availableOptions != null && (
              <Alert tone="warning" title="Over this quote's depth">
                The shipped order can fill <b>{availableOptions.toFixed(2)}</b> more options.{' '}
                {cap?.side === 'ask' && cap.options === cap.ledgerOptions
                  ? 'The binding ceiling is the Aqua ledger — the shipped amount is a permanent cap, so re-offering needs a new salt.'
                  : 'The binding ceiling is the collateral the desk can still back.'}
              </Alert>
            )}

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
                    'Available',
                    availableOptions == null ? '—' : `${availableOptions.toFixed(2)} options`,
                  ],
                  [
                    tab === 'buy' ? 'Maker cover' : 'Maker budget',
                    cap == null
                      ? '—'
                      : cap.side === 'ask'
                        ? `${Number(formatUnits(cap.coverCommitted < cap.coverWallet ? cap.coverCommitted : cap.coverWallet, isCall ? UNDERLYING_DECIMALS : QUOTE_DECIMALS)).toFixed(2)} ${isCall ? 'NVDAx' : 'USDC'}`
                        : `${Number(formatUnits(cap.usdc, QUOTE_DECIMALS)).toFixed(2)} USDC`,
                  ],
                  ['Exercise', 'physical · no oracle'],
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
      pending={isPending || running}
      onReview={setPending}
    />
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
            <div className="vx-grid vx-grid--trade">
              <div className="vx-col vx-col--book">{restingOrders}</div>

              <div className="vx-col vx-col--chart">
                {chartPanel}
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

      {/* ONE review step for every write in the app — trade, exercise, close,
          record, settle, redeem, claim. Nothing opens a wallet until what it costs
          and what it returns has been on screen, and a balance that cannot cover it
          blocks the button rather than letting the wallet reject it. */}
      <Modal
        open={pending != null}
        title={pending?.title ?? ''}
        onClose={() => setPending(null)}
        footer={
          <>
            <Button variant="primary" disabled={!!pending?.blocked} onClick={runPending}>
              Confirm
            </Button>
            <Button variant="secondary" onClick={() => setPending(null)}>
              Cancel
            </Button>
          </>
        }
      >
        {pending && (
          <div className="vx-col">
            <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
              {pending.summary}
            </p>
            <KeyValue rows={pending.rows} />
            {pending.blocked ? (
              <Alert tone="error" title="Can't do this yet">
                {pending.blocked}
              </Alert>
            ) : (
              <Alert tone="info" title={`${pending.steps} wallet ${pending.steps === 1 ? 'prompt' : 'prompts'}`}>
                {pending.steps === 1
                  ? 'Your wallet will ask you to sign once.'
                  : 'Your wallet will ask twice — first to approve the token, then to run the trade. Both are needed.'}
              </Alert>
            )}
          </div>
        )}
      </Modal>

      {toast && <Toast>{toast}</Toast>}
    </Backdrop>
  )
}

/* ============================================================================
   Helpers + leaf components
   ========================================================================= */

function QuoteRow({
  q,
  meta,
  cap,
  premium,
  active,
  onClick,
}: {
  q: MakerQuote
  meta: SeriesMeta | undefined
  cap: Capacity | undefined
  /** Binding per-option premium from `quotePremium`, or undefined while loading. */
  premium: number | undefined
  active: boolean
  onClick: () => void
}) {
  const ask = q.side === 'ask'
  const kind = meta?.kind ?? KIND.CALL
  // The Size column is the real remaining depth, not the side repeated back: for an
  // ask the options still sellable, for a bid the USDC budget left to buy them with.
  const size =
    cap == null
      ? '…'
      : cap.side === 'ask'
        ? `${Number(formatUnits(cap.options, UNDERLYING_DECIMALS)).toFixed(2)}`
        : `$${Number(formatUnits(cap.usdc, QUOTE_DECIMALS)).toFixed(0)}`
  return (
    <button type="button" className={`vx-book__row${active ? ' is-active' : ''}`} onClick={onClick}>
      <span className={ask ? 'vx-up' : 'vx-down'}>
        {kind === KIND.CALL ? 'CALL' : 'PUT'} {(meta?.strike ?? 0).toFixed(0)} · #{q.seriesId}
      </span>
      <span style={{ textAlign: 'right' }}>
        {premium == null ? '…' : premium.toFixed(2)}
      </span>
      <span style={{ textAlign: 'right' }}>{volPct(q.volWad)}%</span>
      <span style={{ textAlign: 'right' }}>{size}</span>
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

/** 6dp quote units -> "1,234.56 USDC". */
const fmtQ = (v: bigint) => `${qfmt(v).toLocaleString(undefined, { maximumFractionDigits: 2 })} USDC`
/** 18dp -> "12.3457 NVDAx" (or options). */
const fmtU = (v: bigint, unit = 'NVDAx') => `${ufmt(v).toFixed(4)} ${unit}`

/**
 * Wallet and RPC errors are several hundred characters of stack by default, which
 * is why the old UI just swallowed them. Pull out the one line a person can act on.
 */
function friendlyError(e: unknown): string {
  const msg = e instanceof Error ? e.message : String(e)
  if (/User rejected|User denied|rejected the request/i.test(msg)) return 'Cancelled in your wallet'
  if (/insufficient funds/i.test(msg)) return 'Not enough ETH for gas on Base Sepolia'
  const named = msg.match(
    /\b(NotExpired|AlreadySettled|OracleNotReady|CloseAfterExercise|Expired|BadAmount|PremiumTooHigh|PremiumBelowFloor|ZeroPremium|InsufficientMakerCollateral|ShortLimit|TenorTooLong|AlreadyRecorded|TooEarly|StrategiesMustBeImmutable)\b/,
  )
  if (named) return `Reverted: ${named[1]}`
  return msg.split('\n')[0].slice(0, 140)
}

/** Each one DESCRIBES the write; the caller shows it and only then runs it. */
interface PositionActions {
  exercise: (p: Position) => PendingAction
  close: (p: Position) => PendingAction
  /** `oracle.recordSettlement` — the step before `settle` is even possible. */
  record: (p: Position) => PendingAction
  settle: (p: Position) => PendingAction
  redeem: (p: Position) => PendingAction
  claim: (p: Position) => PendingAction
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
  bal: Balances,
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
    /* Exercise: pay the strike, take the stock (CALL) — or deliver the stock and
     * take the strike (PUT). Reads NO oracle, which is the point of the product.
     *
     * This is the action that ambushed people: on a 7.57-option CALL at strike 100
     * it opens a 756.97 USDC approval, and nothing said so. Now the cost is stated
     * and the balance checked before a wallet is ever touched. */
    exercise(p) {
      const amount = p.balance
      const isCall = p.kind === KIND.CALL
      const pay = (amount * p.strikeRaw + 10n ** 18n - 1n) / 10n ** 18n // rounds up, as the contract does
      const short = isCall ? bal.usdc < pay : bal.nvdax < amount
      return {
        title: `Exercise ${ufmt(amount).toFixed(4)} ${isCall ? 'CALL' : 'PUT'} #${p.seriesId}`,
        summary: isCall
          ? `Pay the strike in USDC and take the NVDAx. Worth doing only while NVDAx trades ABOVE ${p.strike.toFixed(2)} — below that you would be overpaying, and letting it expire costs nothing.`
          : `Deliver the NVDAx and take the strike in USDC. Worth doing while NVDAx trades BELOW ${p.strike.toFixed(2)}.`,
        rows: isCall
          ? [
              ['You pay', fmtQ(pay)],
              ['You receive', fmtU(amount)],
              ['Your USDC', fmtQ(bal.usdc)],
              ['Strike', `${p.strike.toFixed(2)} USDC per NVDAx`],
            ]
          : [
              ['You deliver', fmtU(amount)],
              ['You receive', fmtQ(pay)],
              ['Your NVDAx', fmtU(bal.nvdax)],
            ],
        blocked: short
          ? isCall
            ? `Not enough USDC — this needs ${fmtQ(pay)} and you hold ${fmtQ(bal.usdc)}.`
            : `Not enough NVDAx — this needs ${fmtU(amount)} and you hold ${fmtU(bal.nvdax)}.`
          : undefined,
        steps: 2,
        async run() {
          if (!app || !publicClient || !deployment) return
          setToast(`Approving ${isCall ? 'USDC' : 'NVDAx'}…`)
          const a = await write({
            address: (isCall ? deployment.usdc : deployment.nvdax) as `0x${string}`,
            abi: erc20Abi,
            functionName: 'approve',
            args: [app, isCall ? pay : amount],
          })
          await publicClient.waitForTransactionReceipt({ hash: a })
          await send('exercise', [BigInt(p.seriesId), amount], 'Exercising…', 'Exercised')
        },
      }
    },

    /* Close: a WRITER burns their own options to unlock cover early. Barred the
     * moment anyone exercises the series (`CloseAfterExercise`), so say that here
     * rather than letting the revert explain it. */
    close(p) {
      return {
        title: `Close ${ufmt(p.written).toFixed(4)} written #${p.seriesId}`,
        summary:
          'Burn options you wrote and release your share of the collateral pool early. This is barred for the rest of the series the moment anyone exercises it.',
        rows: [
          ['You burn', `${ufmt(p.written).toFixed(4)} options`],
          ['You unlock', 'your pro-rata share of the pool'],
        ],
        steps: 1,
        async run() {
          await send('close', [BigInt(p.seriesId), p.written], 'Closing…', 'Closed')
        },
      }
    },

    /* Record the settlement price. PERMISSIONLESS and one-shot, and `settle` reverts
     * `OracleNotReady` until it has happened — without this step the demo dead-ends
     * at expiry on a Settle button that can only fail. */
    record(p) {
      return {
        title: `Record the settlement price for #${p.seriesId}`,
        summary:
          'Reads the Uniswap v4 pool once and freezes that price for this expiry. Anyone can call it, it can only be done once, and nothing settles until it has been.',
        rows: [['Series', `#${p.seriesId}`], ['Expired', new Date(p.expiry * 1000).toLocaleString()]],
        steps: 1,
        async run() {
          if (!deployment || !publicClient) return
          setToast('Recording the settlement price…')
          const hash = await write({
            address: deployment.oracle as `0x${string}`,
            abi: oracleAbi,
            functionName: 'recordSettlement',
            args: [deployment.nvdax as `0x${string}`, BigInt(p.expiry)],
          })
          await publicClient.waitForTransactionReceipt({ hash })
          refetch()
          setToast('Settlement price recorded')
        },
      }
    },

    settle(p) {
      return {
        title: `Settle series #${p.seriesId}`,
        summary:
          'Freezes how the collateral pool splits between holders and writers, using the recorded price. Permissionless, once per series — after this everyone just collects.',
        rows: [['Series', `#${p.seriesId}`]],
        steps: 1,
        async run() {
          await send('settle', [BigInt(p.seriesId)], 'Settling…', 'Settled')
        },
      }
    },

    redeem(p) {
      return {
        title: `Redeem ${ufmt(p.balance).toFixed(4)} #${p.seriesId}`,
        summary:
          'Burn your expired options and take your pro-rata share of the holder side of the pool. Out of the money, that share is zero and the options simply expire.',
        rows: [
          ['You burn', `${ufmt(p.balance).toFixed(4)} options`],
          ['Settlement price', p.settled ? `${p.settlePrice.toFixed(2)} USDC` : 'not settled yet'],
          ['Strike', `${p.strike.toFixed(2)} USDC`],
        ],
        steps: 1,
        async run() {
          await send('redeem', [BigInt(p.seriesId), p.balance], 'Redeeming…', 'Redeemed')
        },
      }
    },

    claim(p) {
      return {
        title: `Claim your written position in #${p.seriesId}`,
        summary:
          'Take back the collateral left on the writer side after holders are paid. One shot — it pays the whole position and a second call does nothing.',
        rows: [['You wrote', `${ufmt(p.written).toFixed(4)} options`]],
        steps: 1,
        async run() {
          await send('claim', [BigInt(p.seriesId)], 'Claiming…', 'Claimed')
        },
      }
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
  onReview,
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
  onReview: (a: PendingAction) => void
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
              <PositionButtons p={p} live={live} actions={actions} pending={pending} onReview={onReview} />
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
  onReview,
}: {
  p: Position
  live: boolean
  actions: PositionActions
  pending: boolean
  onReview: (a: PendingAction) => void
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
          <Button size="sm" variant="primary" loading={pending} onClick={() => onReview(actions.exercise(p))}>
            Exercise
          </Button>
        )}
        {writer && (
          <Button size="sm" variant="secondary" loading={pending} onClick={() => onReview(actions.close(p))}>
            Close
          </Button>
        )}
        {!holder && !writer && <span className="vx-dim">—</span>}
      </div>
    )
  }

  // Post-expiry the order is fixed and each step is permissionless: record the price
  // on the oracle, settle the series once, then redeem (holder) / claim (writer).
  // Offering Settle before the price is recorded is offering a button that reverts.
  return (
    <div className="vx-row" style={{ justifyContent: 'flex-end', gap: 6 }}>
      {!p.settled && !p.priceRecorded && (
        <Button
          size="sm"
          variant="primary"
          loading={pending}
          title="oracle.recordSettlement — permissionless, one-shot. settle() reverts until this lands."
          onClick={() => onReview(actions.record(p))}
        >
          Record price
        </Button>
      )}
      {!p.settled && p.priceRecorded && (
        <Button size="sm" variant="primary" loading={pending} onClick={() => onReview(actions.settle(p))}>
          Settle
        </Button>
      )}
      {p.settled && holder && (
        <Button size="sm" variant="primary" loading={pending} onClick={() => onReview(actions.redeem(p))}>
          Redeem
        </Button>
      )}
      {p.settled && writer && (
        <Button size="sm" variant="secondary" loading={pending} onClick={() => onReview(actions.claim(p))}>
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
          description="Fills through the desk, exercises and redemptions land here."
        />
      }
      columns={[
        {
          key: 'kind',
          header: 'Event',
          render: (r: HistoryRow) => <Badge tone={HISTORY_TONE[r.kind]}>{HISTORY_LABEL[r.kind]}</Badge>,
        },
        { key: 'series', header: 'Series', numeric: true, render: (r: HistoryRow) => `#${r.seriesId}` },
        { key: 'amt', header: 'Options', numeric: true, render: (r: HistoryRow) => ufmt(r.amount).toFixed(4) },
        {
          key: 'usdc',
          header: 'USDC',
          numeric: true,
          render: (r: HistoryRow) =>
            r.quoteAmount === 0n ? '—' : qfmt(r.quoteAmount).toFixed(QUOTE_DECIMALS),
        },
        { key: 'blk', header: 'Block', numeric: true, render: (r: HistoryRow) => String(r.blockNumber) },
        {
          key: 'tx',
          header: 'Receipt',
          numeric: true,
          // The log scan already carries the hash; it was just never shown. A
          // fill nobody can open on an explorer is a claim, not a receipt.
          render: (r: HistoryRow) =>
            r.txHash && r.txHash !== '0x' ? (
              <a
                className="vx-tx"
                href={`${BASESCAN}/tx/${r.txHash}`}
                target="_blank"
                rel="noreferrer"
                title={r.txHash}
              >
                {r.txHash.slice(0, 10)}…{r.txHash.slice(-4)}
                <ExternalLink size={12} />
              </a>
            ) : (
              '—'
            ),
        },
      ]}
    />
  )
}

const HISTORY_LABEL: Record<HistoryRow['kind'], string> = {
  bought: 'Bought',
  sold: 'Sold',
  exercised: 'Exercised',
  redeemed: 'Redeemed',
}

const HISTORY_TONE: Record<HistoryRow['kind'], 'green' | 'red' | 'violet' | 'slate'> = {
  bought: 'green',
  sold: 'red',
  exercised: 'violet',
  redeemed: 'slate',
}
