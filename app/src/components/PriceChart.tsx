import { useEffect, useRef } from 'react'
import {
  createChart,
  CandlestickSeries,
  ColorType,
  CrosshairMode,
  type IChartApi,
  type ISeriesApi,
  type CandlestickData,
  type UTCTimestamp,
} from 'lightweight-charts'

export interface Candle {
  time: number // unix seconds
  open: number
  high: number
  low: number
  close: number
}

interface Props {
  candles: Candle[]
  synthetic: boolean
}

export function PriceChart({ candles, synthetic }: Props) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const chartRef = useRef<IChartApi | null>(null)
  const seriesRef = useRef<ISeriesApi<'Candlestick'> | null>(null)

  // Create chart once.
  useEffect(() => {
    const el = containerRef.current
    if (!el) return

    const chart = createChart(el, {
      layout: {
        background: { type: ColorType.Solid, color: '#0b0d13' },
        textColor: '#8b93a7',
        fontFamily: "'JetBrains Mono', monospace",
      },
      grid: {
        vertLines: { color: 'rgba(30,34,45,0.5)' },
        horzLines: { color: 'rgba(30,34,45,0.5)' },
      },
      rightPriceScale: { borderColor: '#1e222d' },
      timeScale: { borderColor: '#1e222d', timeVisible: true, secondsVisible: false },
      crosshair: { mode: CrosshairMode.Normal },
      autoSize: true,
    })

    const series = chart.addSeries(CandlestickSeries, {
      upColor: '#00f59b',
      downColor: '#ff3366',
      borderUpColor: '#00f59b',
      borderDownColor: '#ff3366',
      wickUpColor: '#00f59b',
      wickDownColor: '#ff3366',
    })

    chartRef.current = chart
    seriesRef.current = series

    return () => {
      chart.remove()
      chartRef.current = null
      seriesRef.current = null
    }
  }, [])

  // Push data whenever candles change.
  useEffect(() => {
    const series = seriesRef.current
    if (!series) return
    const data: CandlestickData[] = candles.map((c) => ({
      time: c.time as UTCTimestamp,
      open: c.open,
      high: c.high,
      low: c.low,
      close: c.close,
    }))
    series.setData(data)
    chartRef.current?.timeScale().fitContent()
  }, [candles])

  return (
    <div style={{ position: 'relative' }}>
      <div ref={containerRef} className="chart-wrap" />
      {synthetic && (
        <div
          className="mono"
          style={{
            position: 'absolute',
            top: 8,
            left: 8,
            fontSize: 10,
            letterSpacing: '0.12em',
            textTransform: 'uppercase',
            color: '#f5a623',
            border: '1px solid rgba(245,166,35,0.4)',
            background: '#14110b',
            padding: '3px 7px',
            pointerEvents: 'none',
          }}
        >
          Synthetic series
        </div>
      )}
    </div>
  )
}
