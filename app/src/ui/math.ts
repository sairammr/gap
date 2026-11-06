/* Pure helpers shared by the sliders. No React here, so they stay testable
   on their own (see math.selfcheck.ts). */

export const clamp = (v: number, a: number, b: number) => (v < a ? a : v > b ? b : v)

/** Snap to the step grid anchored at `min`, clamped to [min, max]. */
export function quantize(v: number, min: number, max: number, step: number): number {
  if (!step || step <= 0) return clamp(v, min, max)
  const n = Math.round((v - min) / step)
  const snapped = min + n * step
  // Kill float dust so 0.1-steps read as 0.1 and not 0.30000000000000004.
  const dp = (String(step).split('.')[1] ?? '').length
  return clamp(Number(snapped.toFixed(dp)), min, max)
}

/** Position of `v` within [min, max] as 0..1. */
export const fracOf = (v: number, min: number, max: number) =>
  max === min ? 0 : clamp((v - min) / (max - min), 0, 1)
