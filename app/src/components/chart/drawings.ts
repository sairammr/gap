/* Drawing model and geometry.

   Drawings are stored in CHART space — a fractional bar index ("logical") and
   a price — never in pixels. That way they survive pan, zoom, resize and a
   change of interval; the render pass converts to pixels each frame through
   the chart's own logicalToCoordinate / priceToCoordinate.

   Everything here is pure so it can be checked without a chart
   (see drawings.selfcheck.ts). */

export type DrawKind =
  | 'trend'
  | 'hline'
  | 'vline'
  | 'ray'
  | 'rect'
  | 'fib'
  | 'text'
  | 'brush'
  | 'measure'

export interface Anchor {
  /** Fractional bar index. Valid beyond the data on both sides. */
  logical: number
  price: number
}

export interface Drawing {
  id: string
  kind: DrawKind
  anchors: Anchor[]
  color: string
  width: number
  text?: string
}

export interface Px {
  x: number
  y: number
}

/** How many clicks a tool takes. Infinity = freehand, finished on pointer-up. */
export function anchorsNeeded(kind: DrawKind): number {
  switch (kind) {
    case 'hline':
    case 'vline':
    case 'text':
      return 1
    case 'brush':
      return Infinity
    default:
      return 2
  }
}

export const FIB_LEVELS = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1] as const

/** Magnet: snap a price to the nearest of a bar's open/high/low/close. */
export function snapToBar(
  price: number,
  bar: { open: number; high: number; low: number; close: number } | undefined,
): number {
  if (!bar) return price
  let best = price
  let bestD = Infinity
  for (const v of [bar.open, bar.high, bar.low, bar.close]) {
    const d = Math.abs(v - price)
    if (d < bestD) {
      bestD = d
      best = v
    }
  }
  return best
}

/** Perpendicular distance from a point to a finite segment. */
export function distToSegment(p: Px, a: Px, b: Px): number {
  const vx = b.x - a.x
  const vy = b.y - a.y
  const len2 = vx * vx + vy * vy
  if (len2 === 0) return Math.hypot(p.x - a.x, p.y - a.y)
  // Project onto the segment and clamp to its ends.
  let t = ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2
  t = t < 0 ? 0 : t > 1 ? 1 : t
  return Math.hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy))
}

/** Distance to a ray: like a segment, but unbounded past `b`. */
export function distToRay(p: Px, a: Px, b: Px): number {
  const vx = b.x - a.x
  const vy = b.y - a.y
  const len2 = vx * vx + vy * vy
  if (len2 === 0) return Math.hypot(p.x - a.x, p.y - a.y)
  let t = ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2
  if (t < 0) t = 0 // clamp only at the origin end
  return Math.hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy))
}

/**
 * Is the pointer within `tol` pixels of this drawing?
 * `pts` are the drawing's anchors already converted to pixels, and `size` is
 * the plot area — needed for the shapes that extend to the edges.
 */
export function hitTest(
  kind: DrawKind,
  pts: Px[],
  p: Px,
  size: { width: number; height: number },
  tol = 6,
): boolean {
  if (!pts.length) return false
  // Anything outside the plot is a miss, whatever the shape.
  if (p.x < -tol || p.y < -tol || p.x > size.width + tol || p.y > size.height + tol) return false
  switch (kind) {
    case 'hline':
      return Math.abs(p.y - pts[0].y) <= tol
    case 'vline':
      return Math.abs(p.x - pts[0].x) <= tol
    case 'text':
      // A small grab box around the anchor.
      return Math.abs(p.x - pts[0].x) <= 44 && Math.abs(p.y - pts[0].y) <= 12
    case 'ray': {
      if (pts.length < 2) return false
      return distToRay(p, pts[0], pts[1]) <= tol
    }
    case 'rect': {
      if (pts.length < 2) return false
      const x0 = Math.min(pts[0].x, pts[1].x)
      const x1 = Math.max(pts[0].x, pts[1].x)
      const y0 = Math.min(pts[0].y, pts[1].y)
      const y1 = Math.max(pts[0].y, pts[1].y)
      const insideX = p.x >= x0 - tol && p.x <= x1 + tol
      const insideY = p.y >= y0 - tol && p.y <= y1 + tol
      if (!insideX || !insideY) return false
      // Edge hit only, so a big rectangle does not swallow every click.
      const nearV = Math.abs(p.x - x0) <= tol || Math.abs(p.x - x1) <= tol
      const nearH = Math.abs(p.y - y0) <= tol || Math.abs(p.y - y1) <= tol
      return nearV || nearH
    }
    case 'fib': {
      if (pts.length < 2) return false
      const [a, b] = pts
      const x0 = Math.min(a.x, b.x)
      const x1 = Math.max(a.x, b.x)
      if (p.x < x0 - tol || p.x > x1 + tol) return false
      return FIB_LEVELS.some((l) => Math.abs(p.y - (a.y + (b.y - a.y) * l)) <= tol)
    }
    case 'brush': {
      for (let i = 1; i < pts.length; i++) {
        if (distToSegment(p, pts[i - 1], pts[i]) <= tol) return true
      }
      return false
    }
    default: {
      if (pts.length < 2) return false
      return distToSegment(p, pts[0], pts[1]) <= tol
    }
  }
}

/** Keep `size` honest for the shapes that need it, without unused-arg noise. */
export const plotSize = (width: number, height: number) => ({ width, height })

/** A compact id that does not need crypto. Drawings are per-session, local. */
export function drawId(): string {
  return Math.random().toString(36).slice(2, 10)
}

/** Percentage and absolute move between two anchors — the measure tool's readout. */
export function measure(a: Anchor, b: Anchor, barSeconds: number) {
  const abs = b.price - a.price
  const pct = a.price === 0 ? 0 : (abs / a.price) * 100
  const bars = Math.round(Math.abs(b.logical - a.logical))
  return { abs, pct, bars, seconds: bars * barSeconds }
}
