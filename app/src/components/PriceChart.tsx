/* ============================================================================
   Price chart with the tool set kuru.io/trade exposes.

   kuru self-hosts TradingView Advanced Charts, which is free to use but is not
   redistributable and is not on npm — it ships from a private repo once you
   accept their licence. This is the same tool set rebuilt on lightweight-charts
   (same vendor, open source): interval, chart type, indicators, undo/redo, a
   drawing rail, magnet, measure, scale modes, screenshot and fullscreen.

   The chart is isolated behind this one component. If the TradingView licence
   comes through, replace the body and keep the props.
   ========================================================================= */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  AreaSeries,
  BarSeries,
  BaselineSeries,
  CandlestickSeries,
  ColorType,
  CrosshairMode,
  HistogramSeries,
  LineSeries,
  LineStyle,
  PriceScaleMode,
  createChart,
  type IChartApi,
  type ISeriesApi,
  type MouseEventParams,
  type SeriesType,
  type UTCTimestamp,
} from 'lightweight-charts'
import {
  Camera,
  CandlestickChart,
  Crosshair,
  Eraser,
  Expand,
  FunctionSquare,
  Magnet,
  Minus,
  MoveUpRight,
  PenLine,
  Redo2,
  Ruler,
  Shrink,
  Square,
  Trash2,
  TrendingUp,
  Type as TypeIcon,
  Undo2,
  Waves,
} from 'lucide-react'
import {
  bollinger,
  ema,
  macd,
  resample,
  rsi,
  sma,
  trueRange,
  type Bar,
  type Maybe,
} from './chart/indicators'
import {
  FIB_LEVELS,
  anchorsNeeded,
  drawId,
  hitTest,
  measure,
  plotSize,
  snapToBar,
  type Anchor,
  type DrawKind,
  type Drawing,
  type Px,
} from './chart/drawings'

export interface Candle {
  time: number
  open: number
  high: number
  low: number
  close: number
}

interface Props {
  candles: Candle[]
  synthetic: boolean
}

/* -- options the toolbars offer ------------------------------------------- */

const INTERVALS = [
  { key: '1m', seconds: 60 },
  { key: '5m', seconds: 300 },
  { key: '15m', seconds: 900 },
  { key: '1h', seconds: 3600 },
  { key: '4h', seconds: 14400 },
  { key: '1d', seconds: 86400 },
] as const

const CHART_TYPES = [
  { key: 'candles', label: 'Candles' },
  { key: 'hollow', label: 'Hollow candles' },
  { key: 'bars', label: 'Bars' },
  { key: 'line', label: 'Line' },
  { key: 'area', label: 'Area' },
  { key: 'baseline', label: 'Baseline' },
] as const
type ChartType = (typeof CHART_TYPES)[number]['key']

const INDICATORS = [
  { key: 'ma', label: 'MA (20)', color: '#7b61ff' },
  { key: 'ema', label: 'EMA (50)', color: '#ffb020' },
  { key: 'boll', label: 'Bollinger (20, 2)', color: '#14ccbb' },
  { key: 'range', label: 'Bar range', color: '#cbd5e1' },
  { key: 'rsi', label: 'RSI (14)', color: '#7b61ff' },
  { key: 'macd', label: 'MACD (12, 26, 9)', color: '#14ccbb' },
] as const
type IndicatorKey = (typeof INDICATORS)[number]['key']

const TOOLS: { key: DrawKind | 'cursor'; label: string; icon: React.ReactNode }[] = [
  { key: 'cursor', label: 'Cross', icon: <Crosshair size={15} /> },
  { key: 'trend', label: 'Trend line', icon: <TrendingUp size={15} /> },
  { key: 'ray', label: 'Ray', icon: <MoveUpRight size={15} /> },
  { key: 'hline', label: 'Horizontal line', icon: <Minus size={15} /> },
  { key: 'vline', label: 'Vertical line', icon: <Minus size={15} style={{ rotate: '90deg' }} /> },
  { key: 'rect', label: 'Rectangle', icon: <Square size={15} /> },
  { key: 'fib', label: 'Fib retracement', icon: <Waves size={15} /> },
  { key: 'brush', label: 'Brush', icon: <PenLine size={15} /> },
  { key: 'text', label: 'Text', icon: <TypeIcon size={15} /> },
  { key: 'measure', label: 'Measure', icon: <Ruler size={15} /> },
]

const RANGES = [
  { key: '1d', bars: 96 },
  { key: '5d', bars: 480 },
  { key: '3m', bars: 2160 },
  { key: 'all', bars: 0 },
] as const

const INK = '#0f172a'
const UP = '#22c55e'
const DOWN = '#f5c84b'

/** Pair an indicator array with its bar times, dropping the leading nulls. */
function lineData(bars: Bar[], values: Maybe) {
  const out: { time: UTCTimestamp; value: number }[] = []
  for (let i = 0; i < bars.length; i++) {
    const v = values[i]
    if (v != null && Number.isFinite(v)) out.push({ time: bars[i].time as UTCTimestamp, value: v })
  }
  return out
}

export function PriceChart({ candles, synthetic }: Props) {
  const wrapRef = useRef<HTMLDivElement | null>(null)
  const plotRef = useRef<HTMLDivElement | null>(null)
  const chartRef = useRef<IChartApi | null>(null)
  const mainRef = useRef<ISeriesApi<SeriesType> | null>(null)
  const extraRef = useRef<ISeriesApi<SeriesType>[]>([])
  const panesRef = useRef<number[]>([])

  const [interval, setInterval] = useState<string>('15m')
  const [type, setType] = useState<ChartType>('candles')
  const [active, setActive] = useState<Record<IndicatorKey, boolean>>({
    ma: false,
    ema: false,
    boll: false,
    range: false,
    rsi: false,
    macd: false,
  })
  const [tool, setTool] = useState<DrawKind | 'cursor'>('cursor')
  const [magnet, setMagnet] = useState(false)
  const [erasing, setErasing] = useState(false)
  const [scaleMode, setScaleMode] = useState<'normal' | 'log' | 'percent'>('normal')
  const [autoFit, setAutoFit] = useState(true)
  const [full, setFull] = useState(false)
  const [rail, setRail] = useState(false)
  const [open, setOpen] = useState<string | null>(null)

  const [drawings, setDrawings] = useState<Drawing[]>([])
  // `pending` is mirrored in a ref: two clicks can land in one JS turn (a fast
  // double-click, or a scripted one), and React state would still read stale on
  // the second, losing the anchor. The ref is the source of truth.
  const pendingRef = useRef<Anchor[]>([])
  const [pending, setPendingState] = useState<Anchor[]>([])
  const setPending = useCallback((v: Anchor[]) => {
    pendingRef.current = v
    setPendingState(v)
  }, [])
  const [hover, setHover] = useState<Px | null>(null)
  const undoRef = useRef<Drawing[][]>([])
  const redoRef = useRef<Drawing[][]>([])
  const [, force] = useState(0)
  const repaint = useCallback(() => force((n) => n + 1), [])

  const [ohlc, setOhlc] = useState<Bar | null>(null)
  const [clock, setClock] = useState(() => new Date())

  const barSeconds = INTERVALS.find((i) => i.key === interval)?.seconds ?? 900
  const bars = useMemo(() => resample(candles, barSeconds), [candles, barSeconds])

  /* -- clock ------------------------------------------------------------- */
  useEffect(() => {
    const id = window.setInterval(() => setClock(new Date()), 1000)
    return () => window.clearInterval(id)
  }, [])

  /* -- chart lifecycle --------------------------------------------------- */
  useEffect(() => {
    const el = plotRef.current
    if (!el) return
    const chart = createChart(el, {
      layout: {
        background: { type: ColorType.Solid, color: 'transparent' },
        textColor: '#64748b',
        fontFamily: "'JetBrains Mono', monospace",
        attributionLogo: false,
      },
      grid: {
        vertLines: { color: 'rgba(226,232,240,0.9)' },
        horzLines: { color: 'rgba(226,232,240,0.9)' },
      },
      rightPriceScale: { borderColor: 'transparent' },
      timeScale: { borderColor: 'transparent', timeVisible: true, secondsVisible: false },
      crosshair: { mode: CrosshairMode.Normal },
      autoSize: true,
    })
    chartRef.current = chart

    const onCross = (p: MouseEventParams) => {
      const s = mainRef.current
      if (!s || !p.time) {
        setOhlc(null)
        return
      }
      const d = p.seriesData.get(s) as Partial<Bar> | undefined
      if (d && 'open' in d) setOhlc({ ...(d as Bar), time: Number(p.time) })
      else setOhlc(null)
    }
    chart.subscribeCrosshairMove(onCross)
    chart.timeScale().subscribeVisibleLogicalRangeChange(repaint)

    const ro = new ResizeObserver(repaint)
    ro.observe(el)

    return () => {
      ro.disconnect()
      chart.unsubscribeCrosshairMove(onCross)
      chart.remove()
      chartRef.current = null
      mainRef.current = null
      extraRef.current = []
      panesRef.current = []
    }
  }, [repaint])

  /* -- main series, rebuilt on chart-type change ------------------------- */
  useEffect(() => {
    const chart = chartRef.current
    if (!chart) return
    if (mainRef.current) {
      chart.removeSeries(mainRef.current)
      mainRef.current = null
    }
    let s: ISeriesApi<SeriesType>
    switch (type) {
      case 'bars':
        s = chart.addSeries(BarSeries, { upColor: UP, downColor: DOWN })
        break
      case 'line':
        s = chart.addSeries(LineSeries, { color: INK, lineWidth: 2 })
        break
      case 'area':
        s = chart.addSeries(AreaSeries, {
          lineColor: INK,
          topColor: 'rgba(15,23,42,0.18)',
          bottomColor: 'rgba(15,23,42,0.01)',
          lineWidth: 2,
        })
        break
      case 'baseline':
        s = chart.addSeries(BaselineSeries, {
          topLineColor: UP,
          bottomLineColor: '#ef4444',
          topFillColor1: 'rgba(34,197,94,0.22)',
          topFillColor2: 'rgba(34,197,94,0.02)',
          bottomFillColor1: 'rgba(239,68,68,0.02)',
          bottomFillColor2: 'rgba(239,68,68,0.22)',
        })
        break
      case 'hollow':
        s = chart.addSeries(CandlestickSeries, {
          upColor: 'rgba(0,0,0,0)',
          downColor: DOWN,
          borderUpColor: UP,
          borderDownColor: DOWN,
          wickUpColor: UP,
          wickDownColor: DOWN,
        })
        break
      default:
        s = chart.addSeries(CandlestickSeries, {
          upColor: UP,
          downColor: DOWN,
          borderUpColor: UP,
          borderDownColor: DOWN,
          wickUpColor: '#1fa855',
          wickDownColor: '#d9a81f',
        })
    }
    mainRef.current = s
    repaint()
  }, [type, repaint])

  /* -- data -------------------------------------------------------------- */
  useEffect(() => {
    const s = mainRef.current
    if (!s || !bars.length) return
    const ohlcData = bars.map((b) => ({ ...b, time: b.time as UTCTimestamp }))
    if (type === 'line' || type === 'area' || type === 'baseline') {
      s.setData(bars.map((b) => ({ time: b.time as UTCTimestamp, value: b.close })))
    } else {
      s.setData(ohlcData)
    }
    if (autoFit) chartRef.current?.timeScale().fitContent()
    repaint()
  }, [bars, type, autoFit, repaint])

  /* -- indicators -------------------------------------------------------- */
  useEffect(() => {
    const chart = chartRef.current
    if (!chart) return
    for (const s of extraRef.current) chart.removeSeries(s)
    extraRef.current = []
    for (const idx of panesRef.current.slice().reverse()) {
      try {
        chart.removePane(idx)
      } catch {
        /* pane already gone with its series */
      }
    }
    panesRef.current = []
    if (!bars.length) return

    const closes = bars.map((b) => b.close)
    const add = (
      def: typeof LineSeries | typeof HistogramSeries,
      opts: Record<string, unknown>,
      data: { time: UTCTimestamp; value: number }[],
      pane?: number,
    ) => {
      const s = chart.addSeries(def as typeof LineSeries, opts, pane)
      s.setData(data)
      extraRef.current.push(s)
      return s
    }

    if (active.ma) {
      add(LineSeries, { color: '#7b61ff', lineWidth: 1.5, priceLineVisible: false, lastValueVisible: false }, lineData(bars, sma(closes, 20)))
    }
    if (active.ema) {
      add(LineSeries, { color: '#ffb020', lineWidth: 1.5, priceLineVisible: false, lastValueVisible: false }, lineData(bars, ema(closes, 50)))
    }
    if (active.boll) {
      const b = bollinger(closes, 20, 2)
      const style = { color: '#14ccbb', lineWidth: 1, priceLineVisible: false, lastValueVisible: false }
      add(LineSeries, style, lineData(bars, b.upper))
      add(LineSeries, { ...style, lineStyle: LineStyle.Dotted }, lineData(bars, b.middle))
      add(LineSeries, style, lineData(bars, b.lower))
    }
    if (active.range) {
      const tr = trueRange(bars)
      const s = add(
        HistogramSeries,
        { color: 'rgba(100,116,139,0.35)', priceFormat: { type: 'volume' }, priceLineVisible: false, lastValueVisible: false },
        bars.map((b, i) => ({ time: b.time as UTCTimestamp, value: tr[i] })),
      )
      // Pin it to the bottom fifth so it reads as a footer, not a second price.
      s.priceScale().applyOptions({ scaleMargins: { top: 0.82, bottom: 0 } })
    }
    if (active.rsi) {
      const pane = chart.addPane()
      const i = pane.paneIndex()
      panesRef.current.push(i)
      add(LineSeries, { color: '#7b61ff', lineWidth: 1.5, priceLineVisible: false }, lineData(bars, rsi(closes, 14)), i)
    }
    if (active.macd) {
      const pane = chart.addPane()
      const i = pane.paneIndex()
      panesRef.current.push(i)
      const m = macd(closes)
      add(LineSeries, { color: '#14ccbb', lineWidth: 1.5, priceLineVisible: false }, lineData(bars, m.line), i)
      add(LineSeries, { color: '#ef4444', lineWidth: 1.2, priceLineVisible: false }, lineData(bars, m.signal), i)
      add(HistogramSeries, { color: 'rgba(100,116,139,0.4)', priceLineVisible: false }, lineData(bars, m.hist), i)
    }
    repaint()
  }, [active, bars, repaint])

  /* -- price scale ------------------------------------------------------- */
  useEffect(() => {
    const s = mainRef.current
    if (!s) return
    s.priceScale().applyOptions({
      mode:
        scaleMode === 'log'
          ? PriceScaleMode.Logarithmic
          : scaleMode === 'percent'
            ? PriceScaleMode.Percentage
            : PriceScaleMode.Normal,
      autoScale: autoFit,
    })
  }, [scaleMode, autoFit])

  /* -- fullscreen repaint ------------------------------------------------ */
  useEffect(() => {
    const id = window.setTimeout(repaint, 60)
    return () => window.clearTimeout(id)
  }, [full, repaint])

  /* -- geometry helpers -------------------------------------------------- */
  const toPx = useCallback((a: Anchor): Px | null => {
    const chart = chartRef.current
    const s = mainRef.current
    if (!chart || !s) return null
    const x = chart.timeScale().logicalToCoordinate(a.logical as never)
    const y = s.priceToCoordinate(a.price)
    if (x == null || y == null) return null
    return { x, y }
  }, [])

  const fromPx = useCallback(
    (x: number, y: number): Anchor | null => {
      const chart = chartRef.current
      const s = mainRef.current
      if (!chart || !s) return null
      const logical = chart.timeScale().coordinateToLogical(x)
      const price = s.coordinateToPrice(y)
      if (logical == null || price == null) return null
      let p = price as number
      if (magnet) {
        // Snap to the OHLC of the bar under the pointer.
        const idx = Math.round(logical as number)
        p = snapToBar(p, bars[idx])
      }
      return { logical: logical as number, price: p }
    },
    [magnet, bars],
  )

  /* -- drawing interaction -----------------------------------------------
     History depth lives in state, not just the ref: the Undo/Redo buttons read
     it to decide `disabled`, and a ref read during render would leave them
     stale until something unrelated re-rendered. */
  const [depth, setDepth] = useState({ undo: 0, redo: 0 })
  const sync = useCallback(
    () => setDepth({ undo: undoRef.current.length, redo: redoRef.current.length }),
    [],
  )

  /** Push the current drawings onto the undo stack and apply an update. */
  const commit = useCallback(
    (update: (prev: Drawing[]) => Drawing[]) => {
      setDrawings((prev) => {
        const next = update(prev)
        if (next === prev) return prev
        undoRef.current.push(prev)
        redoRef.current = []
        return next
      })
      sync()
    },
    [sync],
  )

  const armed = tool !== 'cursor' || erasing

  function onOverlayDown(e: React.PointerEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect()
    const x = e.clientX - rect.left
    const y = e.clientY - rect.top

    if (erasing) {
      const size = plotSize(rect.width, rect.height)
      commit((prev) => {
        const hit = prev.findIndex((d) => {
          const pts = d.anchors.map(toPx).filter((q): q is Px => !!q)
          return pts.length ? hitTest(d.kind, pts, { x, y }, size) : false
        })
        return hit >= 0 ? prev.filter((_, i) => i !== hit) : prev
      })
      return
    }

    if (tool === 'cursor') return
    const a = fromPx(x, y)
    if (!a) return

    const need = anchorsNeeded(tool)
    if (need === Infinity) {
      setPending([a])
      e.currentTarget.setPointerCapture(e.pointerId)
      return
    }
    const next = [...pendingRef.current, a]
    if (next.length >= need) {
      const text = tool === 'text' ? (prompt('Label') ?? '') : undefined
      if (tool === 'text' && !text) {
        setPending([])
        return
      }
      commit((prev) => [
        ...prev,
        { id: drawId(), kind: tool, anchors: next, color: INK, width: 1.5, text },
      ])
      setPending([])
      // Measure is a one-shot read, so drop back to the cursor after it lands.
      if (tool === 'measure') setTool('cursor')
    } else {
      setPending(next)
    }
  }

  function onOverlayMove(e: React.PointerEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect()
    const x = e.clientX - rect.left
    const y = e.clientY - rect.top
    setHover({ x, y })
    if (tool === 'brush' && pendingRef.current.length && e.buttons === 1) {
      const a = fromPx(x, y)
      if (a) setPending([...pendingRef.current, a])
    }
  }

  function onOverlayUp() {
    const stroke = pendingRef.current
    if (tool === 'brush' && stroke.length > 1) {
      commit((prev) => [...prev, { id: drawId(), kind: 'brush', anchors: stroke, color: INK, width: 1.5 }])
      setPending([])
    }
  }

  function undo() {
    const prev = undoRef.current.pop()
    if (!prev) return
    setDrawings((cur) => {
      redoRef.current.push(cur)
      return prev
    })
    sync()
  }
  function redo() {
    const next = redoRef.current.pop()
    if (!next) return
    setDrawings((cur) => {
      undoRef.current.push(cur)
      return next
    })
    sync()
  }
  function clearAll() {
    commit((prev) => (prev.length ? [] : prev))
    setPending([])
  }

  /* -- screenshot -------------------------------------------------------- */
  function screenshot() {
    const canvas = chartRef.current?.takeScreenshot()
    if (!canvas) return
    const a = document.createElement('a')
    a.download = `gap-${interval}-${Date.now()}.png`
    a.href = canvas.toDataURL('image/png')
    a.click()
  }

  function applyRange(barsBack: number) {
    const ts = chartRef.current?.timeScale()
    if (!ts) return
    setAutoFit(false)
    if (!barsBack) {
      ts.fitContent()
      return
    }
    ts.setVisibleLogicalRange({ from: Math.max(0, bars.length - barsBack), to: bars.length + 2 })
  }

  /* -- render ------------------------------------------------------------ */
  const live = ohlc ?? bars[bars.length - 1] ?? null
  const chg = live ? live.close - live.open : 0
  const chgPct = live && live.open ? (chg / live.open) * 100 : 0

  // The rubber-band preview has to read live chart coordinates while rendering;
  // the chart is an external mutable system, not render state, and `repaint()`
  // is what drives the redraw. oxlint flags the ref read here — intentional.
  const previewDrawing: Drawing | null =
    pending.length && tool !== 'cursor'
      ? {
          id: 'pending',
          kind: tool,
          anchors:
            anchorsNeeded(tool) === Infinity || pending.length >= 2
              ? pending
              : hover
                ? [...pending, fromPx(hover.x, hover.y)].filter((a): a is Anchor => !!a)
                : pending,
          color: '#14ccbb',
          width: 1.5,
        }
      : null

  return (
    <div className={'ch' + (full ? ' ch--full' : '')} ref={wrapRef}>
      {/* ---- top row: intervals left, tools right (reference layout) ---- */}
      <div className="ch-top">
        <div className="vx-seg vx-seg--light" role="tablist" aria-label="Interval">
          {INTERVALS.map((i) => (
            <button
              key={i.key}
              type="button"
              role="tab"
              aria-selected={interval === i.key}
              className="vx-seg__btn"
              onClick={() => setInterval(i.key)}
            >
              {i.key}
            </button>
          ))}
        </div>

        <span className="vx-spacer" />

        <div className="ch-pop-wrap">
          <button
            type="button"
            className="ch-btn ch-btn--icon"
            aria-expanded={open === 'type'}
            onClick={() => setOpen(open === 'type' ? null : 'type')}
            title="Chart type"
            aria-label="Chart type"
          >
            <CandlestickChart size={16} />
          </button>
          {open === 'type' && (
            <div className="ch-pop ch-pop--right" role="menu">
              <div className="ch-pop__h">Chart type</div>
              {CHART_TYPES.map((c) => (
                <button
                  key={c.key}
                  type="button"
                  role="menuitemradio"
                  aria-checked={c.key === type}
                  className="ch-opt"
                  onClick={() => {
                    setType(c.key)
                    setOpen(null)
                  }}
                >
                  {c.label}
                </button>
              ))}
            </div>
          )}
        </div>

        <div className="ch-pop-wrap">
          <button
            type="button"
            className="ch-btn ch-btn--icon"
            aria-expanded={open === 'ind'}
            onClick={() => setOpen(open === 'ind' ? null : 'ind')}
            title="Indicators"
            aria-label="Indicators"
          >
            <FunctionSquare size={16} />
          </button>
          {open === 'ind' && (
            <div className="ch-pop ch-pop--right" role="menu">
              <div className="ch-pop__h">Indicators</div>
              {INDICATORS.map((ind) => (
                <button
                  key={ind.key}
                  type="button"
                  role="menuitemcheckbox"
                  aria-checked={active[ind.key]}
                  className="ch-opt"
                  onClick={() => setActive((x) => ({ ...x, [ind.key]: !x[ind.key] }))}
                >
                  <span className="vx-row" style={{ gap: 8 }}>
                    <span className="ch-opt__sw" style={{ background: ind.color }} />
                    {ind.label}
                  </span>
                  {active[ind.key] && <span className="ch-opt__k">on</span>}
                </button>
              ))}
            </div>
          )}
        </div>

        <button
          type="button"
          className="ch-btn ch-btn--icon"
          aria-pressed={rail}
          onClick={() => setRail((r) => !r)}
          title="Drawing tools"
          aria-label="Drawing tools"
        >
          <PenLine size={16} />
        </button>

        <button
          className="ch-btn ch-btn--icon"
          type="button"
          aria-pressed={full}
          onClick={() => setFull((f) => !f)}
          title={full ? 'Exit fullscreen' : 'Fullscreen'}
          aria-label={full ? 'Exit fullscreen' : 'Fullscreen'}
        >
          {full ? <Shrink size={16} /> : <Expand size={16} />}
        </button>

        <button
          className="ch-btn ch-btn--icon"
          type="button"
          onClick={screenshot}
          title="Save as image"
          aria-label="Save as image"
        >
          <Camera size={16} />
        </button>
      </div>

      {/* ---- body: rail + plot ---- */}
      <div className="ch-body">
        {rail && (
        <div className="ch-rail">
          {TOOLS.map((t) => (
            <button
              key={t.key}
              type="button"
              className="ch-btn ch-btn--icon"
              aria-pressed={tool === t.key && !erasing}
              title={t.label}
              aria-label={t.label}
              onClick={() => {
                setErasing(false)
                setTool(t.key)
                setPending([])
              }}
            >
              {t.icon}
            </button>
          ))}
          <span className="ch-sep" style={{ width: '100%', height: 1, margin: '4px 0' }} />
          <button
            type="button"
            className="ch-btn ch-btn--icon"
            aria-pressed={erasing}
            title="Erase a drawing"
            aria-label="Erase a drawing"
            onClick={() => {
              setErasing((e) => !e)
              setTool('cursor')
            }}
          >
            <Eraser size={15} />
          </button>
          <button
            type="button"
            className="ch-btn ch-btn--icon"
            title="Remove all drawings"
            aria-label="Remove all drawings"
            onClick={clearAll}
            disabled={!drawings.length}
          >
            <Trash2 size={15} />
          </button>
          <button
            type="button"
            className="ch-btn ch-btn--icon"
            aria-pressed={magnet}
            onClick={() => setMagnet((m) => !m)}
            title="Magnet — snap to OHLC"
            aria-label="Magnet"
          >
            <Magnet size={15} />
          </button>
          <button className="ch-btn ch-btn--icon" type="button" onClick={undo} title="Undo" aria-label="Undo" disabled={!depth.undo}>
            <Undo2 size={15} />
          </button>
          <button className="ch-btn ch-btn--icon" type="button" onClick={redo} title="Redo" aria-label="Redo" disabled={!depth.redo}>
            <Redo2 size={15} />
          </button>
        </div>
        )}

        <div className="ch-plot">
          <div ref={plotRef} className="ch-canvas" />

          <div className="ch-legend">
            <span>{interval}</span>
            {live && (
              <span className="ch-legend__o">
                <span><i>O</i>{live.open.toFixed(2)}</span>
                <span><i>H</i>{live.high.toFixed(2)}</span>
                <span><i>L</i>{live.low.toFixed(2)}</span>
                <span><i>C</i>{live.close.toFixed(2)}</span>
                <span style={{ color: chg >= 0 ? UP : '#ef4444' }}>
                  {chg >= 0 ? '+' : ''}{chg.toFixed(2)} ({chgPct.toFixed(2)}%)
                </span>
              </span>
            )}
          </div>

          {synthetic && (
            <span className="ch-flag">
              <span className="vx-badge vx-badge--amber">Synthetic series</span>
            </span>
          )}

          <svg
            className={'ch-overlay' + (armed ? ' is-armed' : '') + (erasing ? ' is-erasing' : '')}
            onPointerDown={onOverlayDown}
            onPointerMove={onOverlayMove}
            onPointerUp={onOverlayUp}
            onPointerLeave={() => setHover(null)}
          >
            {[...drawings, previewDrawing].map((d) =>
              d ? <Shape key={d.id} d={d} toPx={toPx} barSeconds={barSeconds} /> : null,
            )}
          </svg>
        </div>
      </div>

      {/* ---- bottom row ---- */}
      <div className="ch-bottom">
        {RANGES.map((r) => (
          <button key={r.key} type="button" className="ch-btn" onClick={() => applyRange(r.bars)}>
            {r.key}
          </button>
        ))}
        <span className="vx-spacer" />
        <span className="ch-clock">
          {clock.toLocaleTimeString()} (UTC{-clock.getTimezoneOffset() / 60 >= 0 ? '+' : ''}
          {-clock.getTimezoneOffset() / 60})
        </span>
        <span className="ch-sep" />
        <button
          type="button"
          className="ch-btn"
          aria-pressed={scaleMode === 'percent'}
          onClick={() => setScaleMode((m) => (m === 'percent' ? 'normal' : 'percent'))}
          title="Percentage scale"
        >
          %
        </button>
        <button
          type="button"
          className="ch-btn"
          aria-pressed={scaleMode === 'log'}
          onClick={() => setScaleMode((m) => (m === 'log' ? 'normal' : 'log'))}
          title="Logarithmic scale"
        >
          log
        </button>
        <button
          type="button"
          className="ch-btn"
          aria-pressed={autoFit}
          onClick={() => setAutoFit((a) => !a)}
          title="Auto-fit the price scale"
        >
          auto
        </button>
      </div>
    </div>
  )
}

/* -- one drawing ----------------------------------------------------------- */

function Shape({
  d,
  toPx,
  barSeconds,
}: {
  d: Drawing
  toPx: (a: Anchor) => Px | null
  barSeconds: number
}) {
  const pts = d.anchors.map(toPx)
  if (pts.some((p) => !p)) return null
  const p = pts as Px[]
  const stroke = d.color
  const w = d.width

  switch (d.kind) {
    case 'hline':
      return <line x1={0} x2="100%" y1={p[0].y} y2={p[0].y} stroke={stroke} strokeWidth={w} strokeDasharray="5 4" />
    case 'vline':
      return <line y1={0} y2="100%" x1={p[0].x} x2={p[0].x} stroke={stroke} strokeWidth={w} strokeDasharray="5 4" />
    case 'text':
      return (
        <text x={p[0].x} y={p[0].y} fill={stroke} fontSize={12} fontWeight={600} fontFamily="var(--sans)">
          {d.text}
        </text>
      )
    case 'rect': {
      if (p.length < 2) return null
      return (
        <rect
          x={Math.min(p[0].x, p[1].x)}
          y={Math.min(p[0].y, p[1].y)}
          width={Math.abs(p[1].x - p[0].x)}
          height={Math.abs(p[1].y - p[0].y)}
          fill="rgba(20,204,187,0.10)"
          stroke={stroke}
          strokeWidth={w}
        />
      )
    }
    case 'fib': {
      if (p.length < 2) return null
      const x0 = Math.min(p[0].x, p[1].x)
      const x1 = Math.max(p[0].x, p[1].x)
      return (
        <g>
          {FIB_LEVELS.map((l) => {
            const y = p[0].y + (p[1].y - p[0].y) * l
            return (
              <g key={l}>
                <line x1={x0} x2={x1} y1={y} y2={y} stroke={stroke} strokeWidth={1} strokeDasharray="4 4" opacity={0.75} />
                <text x={x0 + 4} y={y - 3} fontSize={10} fontFamily="var(--mono)" fill={stroke} opacity={0.8}>
                  {(l * 100).toFixed(1)}%
                </text>
              </g>
            )
          })}
        </g>
      )
    }
    case 'brush':
      return (
        <polyline
          points={p.map((q) => `${q.x},${q.y}`).join(' ')}
          fill="none"
          stroke={stroke}
          strokeWidth={w}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      )
    case 'measure': {
      if (p.length < 2) return null
      const m = measure(d.anchors[0], d.anchors[1], barSeconds)
      const midX = (p[0].x + p[1].x) / 2
      const midY = (p[0].y + p[1].y) / 2
      const up = m.abs >= 0
      return (
        <g>
          <rect
            x={Math.min(p[0].x, p[1].x)}
            y={Math.min(p[0].y, p[1].y)}
            width={Math.abs(p[1].x - p[0].x)}
            height={Math.abs(p[1].y - p[0].y)}
            fill={up ? 'rgba(34,197,94,0.12)' : 'rgba(239,68,68,0.12)'}
            stroke={up ? '#22c55e' : '#ef4444'}
            strokeWidth={1}
          />
          <rect className="ch-measure" x={midX - 62} y={midY - 15} width={124} height={30} rx={5} />
          <text className="ch-measure__t" x={midX} y={midY - 2} textAnchor="middle">
            {up ? '+' : ''}{m.abs.toFixed(2)} ({m.pct.toFixed(2)}%)
          </text>
          <text className="ch-measure__t" x={midX} y={midY + 11} textAnchor="middle" opacity={0.6}>
            {m.bars} bars
          </text>
        </g>
      )
    }
    case 'ray': {
      if (p.length < 2) return null
      // Extend far past the second anchor; the SVG clips it at the plot edge.
      const dx = p[1].x - p[0].x
      const dy = p[1].y - p[0].y
      const k = 4000 / (Math.hypot(dx, dy) || 1)
      return <line x1={p[0].x} y1={p[0].y} x2={p[0].x + dx * k} y2={p[0].y + dy * k} stroke={stroke} strokeWidth={w} />
    }
    default: {
      if (p.length < 2) return null
      return <line x1={p[0].x} y1={p[0].y} x2={p[1].x} y2={p[1].y} stroke={stroke} strokeWidth={w} />
    }
  }
}
