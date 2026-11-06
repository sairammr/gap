// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { GapPricing } from "../src/lib/GapPricing.sol";

/// @notice Unit tests for the Black-Scholes (r = 0) capped-gap pricing library.
contract GapPricingTest is Test {
    /// @dev A capped ATM call with real vol must sit strictly between 0 and the cap.
    function test_premium_cappedCall_withinBand() public pure {
        uint256 p = GapPricing.premium(GapPricing.CALL, 100e18, 100e18, 5e18, 1 days, 0.6e18);
        assertGt(p, 0);
        assertLe(p, 5e18);
    }

    /// @dev Zero vol collapses to intrinsic value, then the cap: min(max(0,S-K),cap).
    ///      S-K = 10e18, capped at 5e18.
    function test_premium_zeroVol_returnsCappedIntrinsic() public pure {
        uint256 p = GapPricing.premium(GapPricing.CALL, 110e18, 100e18, 5e18, 1 days, 0);
        assertEq(p, 5e18);
    }

    /// @dev An ATM vanilla call with zero vol has zero intrinsic value.
    function test_call_atm_zeroVol_isZero() public pure {
        assertEq(GapPricing.call(100e18, 100e18, 1 days, 0), 0);
    }

    /// @dev A vanilla ATM put with real vol is positive and below the spot.
    function test_put_atm_positiveAndSane() public pure {
        uint256 p = GapPricing.put(100e18, 100e18, 1 days, 0.6e18);
        assertGt(p, 0);
        assertLt(p, 100e18);
    }

    /// @dev Put-call parity with r = 0: C - P == S - K. ATM so S == K, hence C == P.
    function test_putCallParity_atm() public pure {
        uint256 c = GapPricing.call(100e18, 100e18, 1 days, 0.6e18);
        uint256 p = GapPricing.put(100e18, 100e18, 1 days, 0.6e18);
        // C - P = S - K = 0 at the money.
        assertApproxEqAbs(c, p, 1);
    }

    /// @dev N(0) = 0.5 for the standard normal CDF.
    function test_normalCdf_zero_isHalf() public pure {
        assertApproxEqAbs(GapPricing.normalCdf(0), 0.5e18, 1e14);
    }
}
