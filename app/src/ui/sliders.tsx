/* ============================================================================
   The slider, in the spirit of the bencho.dev/bench slider blocks. Written
   from scratch against the Voltrex tokens — the behaviour is the interesting
   part and it is reproduced here, not copied.

   WakeSlider — a thumbless bar field. Bars you sweep past spring up in a wake
   whose height follows the speed of the drag. Pointer- and keyboard-driven,
   with an ARIA slider role.

   This is deliberately the only slider in the kit: one continuous control per
   panel, everything else is a quick-pick pill.
   ========================================================================= */

import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent as RKeyboardEvent,
  type PointerEvent as RPointerEvent,
  type ReactNode,
} from 'react'

import { clamp, fracOf, quantize } from './math'

export { clamp, fracOf, quantize }

const reduceMotion = () =>
  typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches

/* -- pointer drag over a track -------------------------------------------- */

interface DragSample {
  /** Pointer position as a fraction of the track. NOT clamped — elastic needs the overshoot. */
  raw: number
  /** Pixels moved since the previous sample. */
  dx: number
}

function useTrackDrag<T extends HTMLElement>(
  onDrag: (s: DragSample) => void,
  onEnd?: () => void,
) {
  const ref = useRef<T | null>(null)
  const lastX = useRef(0)
  const [dragging, setDragging] = useState(false)

  const sample = (clientX: number, firstMove: boolean): DragSample | null => {
    const el = ref.current
    if (!el) return null
    const r = el.getBoundingClientRect()
    const raw = r.width ? (clientX - r.left) / r.width : 0
    const dx = firstMove ? 0 : clientX - lastX.current
    lastX.current = clientX
    return { raw, dx }
  }

  const onPointerDown = (e: RPointerEvent<T>) => {
    if (e.button !== 0) return
    ref.current?.setPointerCapture(e.pointerId)
    setDragging(true)
    const s = sample(e.clientX, true)
    if (s) onDrag(s)
  }

  const onPointerMove = (e: RPointerEvent<T>) => {
    if (!dragging) return
    const s = sample(e.clientX, false)
    if (s) onDrag(s)
  }

  const stop = (e: RPointerEvent<T>) => {
    if (!dragging) return
    setDragging(false)
    if (ref.current?.hasPointerCapture(e.pointerId)) ref.current.releasePointerCapture(e.pointerId)
    onEnd?.()
  }

  return {
    ref,
    dragging,
    handlers: {
      onPointerDown,
      onPointerMove,
      onPointerUp: stop,
      onPointerCancel: stop,
    },
  }
}

/** Arrow / Page / Home / End handling, shared by every slider here. */
function useSliderKeys(
  value: number,
  min: number,
  max: number,
  step: number,
  set: (v: number) => void,
) {
  return useCallback(
    (e: RKeyboardEvent) => {
      const page = (max - min) / 10
      let next: number
      switch (e.key) {
        case 'ArrowLeft':
        case 'ArrowDown':
          next = value - step
          break
        case 'ArrowRight':
        case 'ArrowUp':
          next = value + step
          break
        case 'PageDown':
          next = value - page
          break
        case 'PageUp':
          next = value + page
          break
        case 'Home':
          next = min
          break
        case 'End':
          next = max
          break
        default:
          return
      }
      e.preventDefault()
      set(quantize(next, min, max, step))
    },
    [value, min, max, step, set],
  )
}

/* -- shared props --------------------------------------------------------- */

export interface SliderProps {
  value: number
  onChange: (v: number) => void
  min?: number
  max?: number
  step?: number
  label?: ReactNode
  /** Rendered large next to the label. Defaults to the raw number. */
  format?: (v: number) => string
  /** Small captions under the track, spread evenly. */
  scale?: string[]
  /** Right-hand slot in the header — a badge, a hint, anything. */
  aside?: ReactNode
  disabled?: boolean
  'aria-label'?: string
}

function Head({
  label,
  value,
  format,
  aside,
}: Pick<SliderProps, 'label' | 'format' | 'aside'> & { value: number }) {
  if (!label && !aside && !format) return null
  return (
    <div className="vx-slider__head">
      <div>
        {label && <div className="vx-slider__label">{label}</div>}
        <div className="vx-slider__value">{format ? format(value) : value}</div>
      </div>
      {aside}
    </div>
  )
}

const Scale = ({ scale }: { scale?: string[] }) =>
  scale?.length ? (
    <div className="vx-slider__scale">
      {scale.map((s, i) => (
        <span key={i}>{s}</span>
      ))}
    </div>
  ) : null

/* ========================================================================== */
/* Wake slider                                                                */
/* ========================================================================== */

export interface WakeSliderProps extends SliderProps {
  bars?: number
}

export function WakeSlider({
  value,
  onChange,
  min = 0,
  max = 100,
  step = 1,
  bars = 36,
  label,
  format,
  scale,
  aside,
  disabled,
  'aria-label': ariaLabel,
}: WakeSliderProps) {
  const barEls = useRef<(HTMLSpanElement | null)[]>([])
  const lift = useRef<number[]>([])
  const raf = useRef(0)

  const paint = useCallback(function step() {
    const L = lift.current
    let alive = false
    for (let i = 0; i < L.length; i++) {
      L[i] *= 0.86
      if (L[i] < 0.004) L[i] = 0
      else alive = true
      const el = barEls.current[i]
      if (el) el.style.transform = L[i] ? `scaleY(${(1 + L[i] * 1.9).toFixed(3)})` : ''
    }
    raf.current = alive ? requestAnimationFrame(step) : 0
  }, [])

  useEffect(
    () => () => {
      if (raf.current) cancelAnimationFrame(raf.current)
    },
    [],
  )

  const onDrag = ({ raw, dx }: DragSample) => {
    const next = quantize(min + clamp(raw, 0, 1) * (max - min), min, max, step)
    if (next !== value) onChange(next)

    if (reduceMotion()) return
    const L = lift.current
    if (L.length !== bars) {
      L.length = bars
      L.fill(0)
    }
    const power = Math.min(1, Math.abs(dx) / 14)
    if (power < 0.03) return
    const head = clamp(raw, 0, 1) * (bars - 1)
    const reach = 5
    for (let i = Math.max(0, Math.ceil(head - reach)); i <= Math.min(bars - 1, Math.floor(head + reach)); i++) {
      const d = Math.abs(i - head)
      L[i] = Math.min(1.15, L[i] + (1 - d / reach) * power * 0.9)
    }
    if (!raf.current) raf.current = requestAnimationFrame(paint)
  }

  const { ref, handlers } = useTrackDrag<HTMLDivElement>(onDrag)
  const onKeyDown = useSliderKeys(value, min, max, step, onChange)

  const frac = fracOf(value, min, max)
  const head = Math.round(frac * (bars - 1))

  return (
    <div className="vx-slider" data-disabled={disabled || undefined}>
      <Head label={label} value={value} format={format} aside={aside} />
      <div
        ref={ref}
        className="vx-wake"
        role="slider"
        tabIndex={disabled ? -1 : 0}
        aria-label={ariaLabel ?? (typeof label === 'string' ? label : 'value')}
        aria-valuemin={min}
        aria-valuemax={max}
        aria-valuenow={value}
        aria-valuetext={format ? format(value) : undefined}
        aria-disabled={disabled || undefined}
        onKeyDown={onKeyDown}
        {...handlers}
      >
        {Array.from({ length: bars }, (_, i) => (
          <span
            key={i}
            ref={(el) => {
              barEls.current[i] = el
            }}
            className={
              'vx-wake__bar' + (i <= head ? ' is-on' : '') + (i === head ? ' is-head' : '')
            }
          />
        ))}
      </div>
      <Scale scale={scale} />
    </div>
  )
}
