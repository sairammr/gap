// Client-side premium PREVIEW — a TypeScript mirror of contracts/src/lib/GapPricing.sol.
//
// This is a UI ESTIMATE only. It uses JS floating-point numbers (prices in plain
// units, e.g. "100.0" USDC per NVDAx), NOT WAD bigints. The authoritative premium
// is the on-chain `quotePremium` view read, which the ticket also displays as the
// binding quote. This mirror exists so the ticket can show a premium instantly as
// the user drags sliders, before the RPC round-trip.
//
// The Solidity contract works in WAD (1e18) and Abramowitz-Stegun 26.2.17 for the
// normal CDF (|error| < 7.5e-8). We reproduce the exact same math in doubles.

const CALL = 0
const PUT = 1

// A&S 26.2.17 coefficients (same constants as GapPricing.sol, as plain doubles).
const AS_P = 0.2316419
const B1 = 0.31938153
const B2 = -0.356563782
const B3 = 1.781477937
const B4 = -1.821255978
const B5 = 1.330274429
const INV_SQRT_2PI = 0.3989422804014327

/** Standard normal CDF via Abramowitz-Stegun 26.2.17. Mirrors GapPricing.normalCdf. */
export function normalCdf(x: number): number {
  if (x <= -8) return 0
  if (x >= 8) return 1
  const negative = x < 0
  const ax = Math.abs(x)
  const t = 1 / (1 + AS_P * ax)
  // Horner: (((b5 t + b4) t + b3) t + b2) t + b1, then one more t.
  let poly = B5
  poly = B4 + poly * t
  poly = B3 + poly * t
  poly = B2 + poly * t
  poly = B1 + poly * t
  poly = poly * t
  const pdf = INV_SQRT_2PI * Math.exp(-(ax * ax) / 2)
  let upperTail = pdf * poly // ~= 1 - N(|x|)
  if (upperTail < 0) upperTail = 0
  if (upperTail > 1) upperTail = 1
  return negative ? upperTail : 1 - upperTail
}

const YEAR_SECONDS = 365 * 24 * 60 * 60

/** sigma * sqrt(T) with T in years. Mirrors GapPricing._sigmaRootT. */
function sigmaRootT(secondsToExpiry: number, vol: number): number {
  if (secondsToExpiry <= 0 || vol <= 0) return 0
  const tYears = secondsToExpiry / YEAR_SECONDS
  return vol * Math.sqrt(tYears)
}

/** Vanilla Black-Scholes call, r = 0. Mirrors GapPricing.call. */
export function bsCall(spot: number, strike: number, secondsToExpiry: number, vol: number): number {
  if (strike === 0) return spot
  if (spot === 0) return 0
  const srt = sigmaRootT(secondsToExpiry, vol)
  if (srt === 0) return spot > strike ? spot - strike : 0
  const lnMoneyness = Math.log(spot / strike)
  const half = (srt * srt) / 2
  const d1 = (lnMoneyness + half) / srt
  const d2 = d1 - srt
  const c = spot * normalCdf(d1) - strike * normalCdf(d2)
  return c > 0 ? c : 0
}

/** Vanilla Black-Scholes put via parity P = C - S + K. Mirrors GapPricing.put. */
export function bsPut(spot: number, strike: number, secondsToExpiry: number, vol: number): number {
  if (strike === 0) return 0
  const c = bsCall(spot, strike, secondsToExpiry, vol)
  return c + strike - spot
}

export type OptionKind = typeof CALL | typeof PUT

/**
 * Premium of a plain (uncapped) option, quote-per-1-unit of underlying (NOT scaled by
 * size). GAP options are vanilla calls/puts — WeekendOptions.quotePremium calls
 * GapPricing.call/put directly with no cap. This is the UI estimate only; the binding
 * number is the on-chain quotePremium read.
 */
export function premiumPerUnit(
  kind: OptionKind,
  spot: number,
  strike: number,
  secondsToExpiry: number,
  vol: number,
): number {
  if (kind === CALL) return bsCall(spot, strike, secondsToExpiry, vol)
  if (kind === PUT) return bsPut(spot, strike, secondsToExpiry, vol)
  throw new Error(`unknown option kind ${kind}`)
}

/** Total premium in quote units = per-unit premium * size (both plain numbers). */
export function previewPremium(
  kind: OptionKind,
  spot: number,
  strike: number,
  secondsToExpiry: number,
  vol: number,
  size: number,
): number {
  return premiumPerUnit(kind, spot, strike, secondsToExpiry, vol) * size
}

/** Realized intrinsic payoff per unit at settlement spot (no cap). */
export function payoffPerUnit(kind: OptionKind, spot: number, strike: number): number {
  return kind === CALL ? Math.max(0, spot - strike) : Math.max(0, strike - spot)
}

export const KIND = { CALL, PUT } as const
