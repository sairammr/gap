// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Kind, WeekendOptions } from "../src/WeekendOptions.sol";
import { OptionToken, OptionTokenFactory } from "../src/OptionToken.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/// @notice Unit tests for the series registry half of `WeekendOptions`.
contract SeriesTest is Test {
    WeekendOptions app;
    MockERC20 nvdax;
    MockERC20 usdc;
    uint64 expiry;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);
        OptionTokenFactory factory = new OptionTokenFactory();
        app = new WeekendOptions(address(usdc), factory);
        expiry = uint64(block.timestamp + 1 days);
    }

    function test_createSeries_dedupesOnKey() public {
        uint256 a = app.createSeries(address(nvdax), expiry, Kind.CALL, 205e6);
        uint256 b = app.createSeries(address(nvdax), expiry, Kind.CALL, 205e6);
        assertEq(a, b);
        assertEq(app.seriesCount(), 1);
    }

    function test_createSeries_rejectsPastExpiryAndZeroStrike() public {
        vm.expectRevert(WeekendOptions.BadSeries.selector);
        app.createSeries(address(nvdax), uint64(block.timestamp), Kind.CALL, 205e6);
        vm.expectRevert(WeekendOptions.BadSeries.selector);
        app.createSeries(address(nvdax), expiry, Kind.CALL, 0);
    }

    function test_collateralFor_callLocksUnderlyingPutLocksCashRoundedUp() public {
        uint256 c = app.createSeries(address(nvdax), expiry, Kind.CALL, 205e6);
        (address tc, uint256 nc) = app.collateralFor(c, 10e18);
        assertEq(tc, address(nvdax));
        assertEq(nc, 10e18);

        uint256 p = app.createSeries(address(nvdax), expiry, Kind.PUT, 205e6);
        (address tp, uint256 np) = app.collateralFor(p, 10e18);
        assertEq(tp, address(usdc));
        assertEq(np, 2050e6);
        // 1 wei of options still costs 1 unit of cash: Ceil, never free
        (, uint256 dust) = app.collateralFor(p, 1);
        assertEq(dust, 1);
    }

    function test_optionToken_onlyProtocolMintsAndBurns() public {
        uint256 id = app.createSeries(address(nvdax), expiry, Kind.CALL, 205e6);
        OptionToken t = app.getSeries(id).token;
        vm.expectRevert(OptionToken.OnlyProtocol.selector);
        t.mint(address(this), 1e18);
    }
}
