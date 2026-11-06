// sqrtPriceX96 -> spot price (quote per underlying), as a plain JS number.
// Mirrors contracts/src/lib/UniV4Spot.fromSqrtPriceX96, but returns a human-unit
// double for charting/preview rather than a WAD bigint.
//
//   price1Per0 (raw) = (sqrtPriceX96 / 2^96)^2        // raw currency1 per raw currency0
//   adjust by token decimals, then orient to quote-per-underlying.

const Q96 = 2 ** 96

export function spotFromSqrtPriceX96(
  sqrtPriceX96: bigint,
  underlyingDecimals: number,
  quoteDecimals: number,
  underlyingIsCurrency0: boolean,
): number {
  if (sqrtPriceX96 === 0n) return 0
  const sp = Number(sqrtPriceX96) / Q96
  // raw currency1 units per raw currency0 unit
  const rawRatio = sp * sp

  if (underlyingIsCurrency0) {
    // quote = currency1, underlying = currency0.
    // human price = rawRatio * 10^(underlyingDecimals - quoteDecimals)
    return rawRatio * 10 ** (underlyingDecimals - quoteDecimals)
  }
  // quote = currency0, underlying = currency1 -> invert.
  if (rawRatio === 0) return 0
  return (1 / rawRatio) * 10 ** (underlyingDecimals - quoteDecimals)
}
