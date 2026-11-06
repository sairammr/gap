// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { V4SpotOracle } from "../src/oracle/V4SpotOracle.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockStateView } from "./helpers/MockStateView.sol";

/// @notice Unit tests for the v4 spot oracle: instantaneous spot reads, converted to
///         quote-token units, and a once-only recorded settlement price per (asset, expiry).
contract V4SpotOracleTest is Test {
    // sqrtPriceX96 constant derived from the 18dp underlying / 6dp quote,
    // underlyingIsCurrency0 = true base `spot = 100e18 -> 792281625142643375935439`,
    // scaled by sqrt(205/100). Only the 205 price is exercised by this file's tests.
    uint160 internal constant SQRT_PRICE_205 = 1134374654051415993876480;

    MockStateView stateView;
    V4SpotOracle oracle;
    MockERC20 nvdax;
    bytes32 constant POOL_ID = bytes32(uint256(1));
    uint64 expiry;

    function setUp() public {
        nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);
        stateView = new MockStateView(SQRT_PRICE_205);
        oracle = new V4SpotOracle(stateView, 6);
        oracle.setPool(address(nvdax), POOL_ID, 18, true);
        expiry = uint64(block.timestamp + 1 days);
    }

    function test_spot_returnsQuoteUnitsAndNow() public {
        stateView.setSqrtPriceX96(SQRT_PRICE_205);
        (uint256 p, uint256 at) = oracle.spot(address(nvdax));
        assertApproxEqAbs(p, 205e6, 1e3);
        assertEq(at, block.timestamp);
    }

    function test_spot_returnsZeroZeroWhenPoolUninitialised() public {
        stateView.setSqrtPriceX96(0);
        (uint256 p, uint256 at) = oracle.spot(address(nvdax));
        assertEq(p, 0);
        assertEq(at, 0);
    }

    function test_settlementPrice_notOkUntilRecorded() public {
        (, bool ok) = oracle.settlementPrice(address(nvdax), expiry);
        assertFalse(ok);
        vm.warp(expiry);
        oracle.recordSettlement(address(nvdax), expiry);
        (uint256 p, bool ok2) = oracle.settlementPrice(address(nvdax), expiry);
        assertTrue(ok2);
        assertApproxEqAbs(p, 205e6, 1e3);
    }

    function test_recordSettlement_rejectsEarlyAndDouble() public {
        vm.expectRevert(V4SpotOracle.TooEarly.selector);
        oracle.recordSettlement(address(nvdax), expiry);
        vm.warp(expiry);
        oracle.recordSettlement(address(nvdax), expiry);
        vm.expectRevert(V4SpotOracle.AlreadyRecorded.selector);
        oracle.recordSettlement(address(nvdax), expiry);
    }

    /// @dev Ruling 3 / Task 7 grace-period dependency: an asset that was never `setPool`'d
    ///      must read as (0, 0), never revert `NotConfigured()` out of `spot`.
    function test_spot_unconfiguredAsset_returnsZeroZeroWithoutReverting() public {
        MockERC20 other = new MockERC20("Other xStock", "OTHRx", 18);
        (uint256 p, uint256 at) = oracle.spot(address(other));
        assertEq(p, 0);
        assertEq(at, 0);
    }

    /// @dev Ruling 3: the "already recorded" guard must be independent of whether the recorded
    ///      price is zero. If the pool reads zero at settlement time (e.g. uninitialised), the
    ///      slot must still be permanently recorded (never re-recordable) while `settlementPrice`
    ///      keeps reporting `ok = false` for it, so Task 7's grace-period path can fall through.
    ///      A naive guard derived from `settlement[asset][expiry] != 0` would let this slot be
    ///      recorded over and over, since a zero price never trips it.
    function test_recordSettlement_zeroPriceStaysRecordedAndUnexercisable() public {
        stateView.setSqrtPriceX96(0);
        vm.warp(expiry);
        oracle.recordSettlement(address(nvdax), expiry);

        (, bool ok) = oracle.settlementPrice(address(nvdax), expiry);
        assertFalse(ok);

        vm.expectRevert(V4SpotOracle.AlreadyRecorded.selector);
        oracle.recordSettlement(address(nvdax), expiry);
    }
}
