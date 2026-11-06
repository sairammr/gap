// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib as F } from "solady/utils/FixedPointMathLib.sol";

/// @title GapPricing
/// @notice Black-Scholes (r = 0) pricing for plain vanilla options.
/// @dev All prices are WAD (1e18) quote-per-underlying. Sizes are applied by the caller.
///
/// Rates are intentionally omitted: these options live for hours, so `r * T` is noise next to the
/// overnight gap itself.
library GapPricing {
    /// @dev seconds in a 365-day year, WAD
    int256 internal constant YEAR = 365 days;

    uint8 internal constant CALL = 0;
    uint8 internal constant PUT = 1;

    /// @notice Vanilla Black-Scholes call, r = 0. WAD in, WAD out.
    function call(uint256 spot, uint256 strike, uint256 secondsToExpiry, uint256 volWad)
        internal
        pure
        returns (uint256)
    {
        if (strike == 0) return spot;
        if (spot == 0) return 0;

        // sigma * sqrt(T), WAD
        uint256 sigmaRootT = _sigmaRootT(secondsToExpiry, volWad);
        // Degenerate: no time or no vol leaves only intrinsic value.
        if (sigmaRootT == 0) return spot > strike ? spot - strike : 0;

        // d1 = ( ln(S/K) + sigmaRootT^2 / 2 ) / sigmaRootT ; d2 = d1 - sigmaRootT
        int256 lnMoneyness = F.lnWad(int256(F.divWad(spot, strike)));
        int256 half = int256(F.mulWad(sigmaRootT, sigmaRootT) / 2);
        int256 d1 = ((lnMoneyness + half) * 1e18) / int256(sigmaRootT);
        int256 d2 = d1 - int256(sigmaRootT);

        uint256 term1 = F.mulWad(spot, normalCdf(d1));
        uint256 term2 = F.mulWad(strike, normalCdf(d2));
        return term1 > term2 ? term1 - term2 : 0;
    }

    /// @notice Vanilla Black-Scholes put, r = 0, via put-call parity `P = C - S + K`.
    function put(uint256 spot, uint256 strike, uint256 secondsToExpiry, uint256 volWad)
        internal
        pure
        returns (uint256)
    {
        if (strike == 0) return 0;
        uint256 c = call(spot, strike, secondsToExpiry, volWad);
        // C + K >= S always holds for a non-negative call, so this cannot underflow.
        return c + strike - spot;
    }

    /// @dev sigma * sqrt(T) in WAD, with T measured in years.
    function _sigmaRootT(uint256 secondsToExpiry, uint256 volWad) private pure returns (uint256) {
        if (secondsToExpiry == 0 || volWad == 0) return 0;
        uint256 tWad = F.divWad(secondsToExpiry, uint256(YEAR));
        return F.mulWad(volWad, F.sqrtWad(tWad));
    }

    // --- Normal CDF --------------------------------------------------------

    // Abramowitz & Stegun 26.2.17 coefficients, WAD. |error| < 7.5e-8 on the whole real line.
    int256 private constant P = 231641900000000000; // 0.2316419
    int256 private constant B1 = 319381530000000000; // 0.31938153
    int256 private constant B2 = -356563782000000000; // -0.356563782
    int256 private constant B3 = 1781477937000000000; // 1.781477937
    int256 private constant B4 = -1821255978000000000; // -1.821255978
    int256 private constant B5 = 1330274429000000000; // 1.330274429
    // 1 / sqrt(2 * pi), WAD
    int256 private constant INV_SQRT_2PI = 398942280401432678;

    /// @notice Standard normal CDF, WAD in, WAD out (0 .. 1e18).
    function normalCdf(int256 x) internal pure returns (uint256) {
        // Beyond +-8 sigma the tail is below the approximation's own error floor.
        if (x <= -8e18) return 0;
        if (x >= 8e18) return 1e18;

        bool negative = x < 0;
        uint256 ax = uint256(negative ? -x : x);

        // t = 1 / (1 + p*|x|)
        uint256 t = F.divWad(1e18, 1e18 + uint256(P) * ax / 1e18);

        // Horner on (((b5 t + b4) t + b3) t + b2) t + b1, then one more t.
        int256 poly = B5;
        poly = B4 + poly * int256(t) / 1e18;
        poly = B3 + poly * int256(t) / 1e18;
        poly = B2 + poly * int256(t) / 1e18;
        poly = B1 + poly * int256(t) / 1e18;
        poly = poly * int256(t) / 1e18;

        // pdf(|x|) = exp(-x^2/2) / sqrt(2*pi)
        uint256 pdf = F.mulWad(uint256(INV_SQRT_2PI), uint256(F.expWad(-int256(F.mulWad(ax, ax) / 2))));

        int256 upperTail = int256(F.mulWad(pdf, uint256(poly))); // ~= 1 - N(|x|)
        if (upperTail < 0) upperTail = 0;
        if (upperTail > 1e18) upperTail = 1e18;

        // N(|x|) = 1 - upperTail ; N(-|x|) = upperTail
        return negative ? uint256(upperTail) : uint256(1e18 - upperTail);
    }
}
