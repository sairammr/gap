// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { GapPricing } from "../src/lib/GapPricing.sol";

/// @notice Unit tests for the Black-Scholes (r = 0) pricing library.
contract GapPricingTest is Test {
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
