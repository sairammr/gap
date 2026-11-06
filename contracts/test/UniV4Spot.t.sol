// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { UniV4Spot } from "../src/lib/UniV4Spot.sol";

/// @dev External boundary so `vm.expectRevert` can observe a lower-depth revert.
///      The library function is `internal` and gets inlined into its caller, so a
///      direct call from the test contract reverts at the same depth as the cheatcode.
contract UniV4SpotHarness {
    function fromSqrtPriceX96(
        uint160 sqrtPriceX96,
        bytes32 poolId,
        uint8 underlyingDecimals,
        uint8 quoteDecimals,
        bool underlyingIsCurrency0
    ) external pure returns (uint256) {
        return UniV4Spot.fromSqrtPriceX96(
            sqrtPriceX96, poolId, underlyingDecimals, quoteDecimals, underlyingIsCurrency0
        );
    }
}

/// @notice Unit tests for the pure `fromSqrtPriceX96` normaliser.
contract UniV4SpotTest is Test {
    // sqrtPriceX96 for a raw 1:1 pool: 1 * 2**96.
    uint160 internal constant SQRT_1TO1 = 79228162514264337593543950336;
    bytes32 internal constant POOL_ID = bytes32(uint256(1));

    UniV4SpotHarness internal harness;

    function setUp() public {
        harness = new UniV4SpotHarness();
    }

    /// @dev 1:1 pool, both tokens 18dp, underlying is currency0 -> 1e18 WAD.
    function test_fromSqrtPriceX96_oneToOne_currency0_18dp() public pure {
        uint256 got = UniV4Spot.fromSqrtPriceX96(SQRT_1TO1, POOL_ID, 18, 18, true);
        assertApproxEqAbs(got, 1e18, 1e6);
    }

    /// @dev Inverted branch (underlying is currency1), underlying 18dp / quote 6dp.
    ///      num = fullMulDiv(Q96, Q96, Q96) = Q96, so the return is
    ///      fullMulDiv(Q96, 1e18 * 10**18, Q96) / 10**6 = 1e36 / 1e6 = 1e30.
    function test_fromSqrtPriceX96_inverted_18_6dp() public pure {
        uint256 got = UniV4Spot.fromSqrtPriceX96(SQRT_1TO1, POOL_ID, 18, 6, false);
        assertEq(got, 1e30);
    }

    /// @dev Zero sqrtPriceX96 means an uninitialized pool and must revert.
    function test_fromSqrtPriceX96_zero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(UniV4Spot.PoolNotInitialized.selector, POOL_ID));
        harness.fromSqrtPriceX96(0, POOL_ID, 18, 18, true);
    }
}
