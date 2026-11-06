// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/contracts/Aqua.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import { Kind, WeekendOptions } from "../src/WeekendOptions.sol";
import { WeekendTaker } from "../src/WeekendTaker.sol";
import { OptionToken, OptionTokenFactory } from "../src/OptionToken.sol";
import { V4SpotOracle } from "../src/oracle/V4SpotOracle.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockStateView } from "./helpers/MockStateView.sol";

/// @notice Pre-expiry writer unwind via `close`: burn written options back, take a pro-rata
///         share of both pool legs on the PRE-decrement `totalWritten`.
/// @dev Ruling 13 (binding divergence from the source protocol): `close` additionally reverts
///      `CloseAfterExercise` once the opposite pool leg is non-empty (`poolCash` on a CALL,
///      `poolUnderlying` on a PUT). Without that guard, a writer joining a CALL series AFTER
///      holders have exercised buys into a pool that already holds cash banked at the strike,
///      and `close`'s pro-rata-of-both-legs payout lets them extract it immediately at every
///      spot below strike — profitable, zero-sum against the other writers. One exercise
///      anywhere in a series's life shuts the path until expiry.
contract CloseTest is Test {
    // sqrtPriceX96 constant for the 18dp underlying / 6dp quote, underlyingIsCurrency0 = true
    // base `spot = 100e18 -> 792281625142643375935439`, scaled by sqrt(205/100).
    uint160 internal constant SQRT_PRICE_205 = 1134374654051415993876480;

    bytes32 internal constant POOL_ID = bytes32(uint256(1));
    uint256 internal constant STRIKE = 205e6;
    uint256 internal constant VOL = 0.5e18;

    Aqua internal aqua;
    WeekendOptions internal app;
    WeekendTaker internal taker;
    V4SpotOracle internal oracle;
    MockStateView internal stateView;
    MockERC20 internal nvdax;
    MockERC20 internal usdc;

    address internal maker = address(0xBEEF);
    address internal buyer = address(0xB0B);

    uint64 internal expiry;

    function setUp() public {
        aqua = new Aqua();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);

        stateView = new MockStateView(SQRT_PRICE_205);
        oracle = new V4SpotOracle(stateView, 6);
        oracle.setPool(address(nvdax), POOL_ID, 18, true);

        OptionTokenFactory factory = new OptionTokenFactory();
        app = new WeekendOptions(address(usdc), factory, IAqua(address(aqua)), oracle);
        taker = new WeekendTaker(IAqua(address(aqua)), address(app));

        expiry = uint64(block.timestamp + 7 days);

        usdc.mint(buyer, 1_000_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(taker), type(uint256).max);
        usdc.approve(address(app), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _strategy() internal view returns (WeekendOptions.Strategy memory) {
        return WeekendOptions.Strategy({
            app: address(app),
            maker: maker,
            underlying: address(nvdax),
            quote: address(usdc),
            volWad: VOL,
            minPremiumBps: 0,
            maxSecondsToExpiry: 30 days,
            salt: bytes32(0)
        });
    }

    function _hash() internal view returns (bytes32) {
        return keccak256(abi.encode(_strategy()));
    }

    function _callSeries() internal returns (uint256) {
        return app.createSeries(address(nvdax), expiry, Kind.CALL, STRIKE);
    }

    function _putSeries() internal returns (uint256) {
        return app.createSeries(address(nvdax), expiry, Kind.PUT, STRIKE);
    }

    function _ship(address who, address token, uint256 amount) internal {
        MockERC20(token).mint(who, amount);

        bool quoteIsCover = token == address(usdc);
        address[] memory tokens = new address[](quoteIsCover ? 1 : 2);
        uint256[] memory amounts = new uint256[](quoteIsCover ? 1 : 2);
        tokens[0] = token;
        amounts[0] = amount;
        if (!quoteIsCover) {
            tokens[1] = address(usdc);
            amounts[1] = 0;
        }

        vm.startPrank(who);
        MockERC20(token).approve(address(aqua), type(uint256).max);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.ship(address(app), abi.encode(_strategy()), tokens, amounts);
        vm.stopPrank();
    }

    function _buy(uint256 id, uint256 amount, address to) internal returns (uint256) {
        vm.prank(buyer);
        return taker.buy(app, _strategy(), id, amount, type(uint256).max, to, abi.encode(maker, _hash()));
    }

    function _shipAndBuy(uint256 id, uint256 amount, address to) internal returns (uint256) {
        (address token, uint256 need) = app.collateralFor(id, amount);
        _ship(maker, token, need);
        return _buy(id, amount, to);
    }

    // ------------------------------------------------------------------ tests

    /// @dev No exercises -> `poolCash == 0` for this CALL series, so the pro-rata arithmetic is
    ///      provable on the underlying leg alone without tripping the Ruling 13 guard.
    function test_close_returnsProRataOfBothPools() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer); // maker wrote 10, pool holds 10e18 underlying, 0 cash

        // The writer buys half their written position back and closes it. Hoist the token:
        // `app.getSeries(id)` is itself an external call, so a `vm.prank` placed right before
        // the chained `.token.transfer(...)` would be consumed by `getSeries`, not the transfer.
        OptionToken token = app.getSeries(id).token;
        vm.prank(buyer);
        token.transfer(maker, 5e18);
        uint256 makerUsdc0 = usdc.balanceOf(maker); // already holds the premium from the buy

        vm.expectEmit(true, true, false, true, address(app));
        emit WeekendOptions.Closed(id, maker, 5e18);
        vm.prank(maker);
        app.close(id, 5e18);

        // pro-rata on PRE-decrement totalWritten = 10e18
        assertEq(nvdax.balanceOf(maker), 5e18); // 10e18 * 5/10
        assertEq(usdc.balanceOf(maker), makerUsdc0); // no cash leg ever existed; close paid none
        assertEq(app.getSeries(id).totalWritten, 5e18);
        assertEq(app.getSeries(id).poolUnderlying, 5e18);
        assertEq(app.getSeries(id).poolCash, 0);
        assertEq(app.written(id, maker), 5e18);
    }

    /// @dev Ruling 13: once a holder has exercised, the opposite leg (`poolCash` on a CALL) is
    ///      non-empty and `close` must refuse outright — this is the guard that blocks the
    ///      profitable extraction the source protocol allowed.
    function test_close_revertsAfterExerciseOnCall() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer); // maker wrote 10
        vm.prank(buyer);
        app.exercise(id, 4e18); // pool is now 6e18 stock + 820e6 cash

        OptionToken token = app.getSeries(id).token;
        vm.prank(buyer);
        token.transfer(maker, 5e18); // buyer holds 6e18 after exercising 4e18

        vm.prank(maker);
        vm.expectRevert(WeekendOptions.CloseAfterExercise.selector);
        app.close(id, 5e18);

        // Nothing moved: the guard fired before any effect.
        assertEq(app.getSeries(id).totalWritten, 10e18);
        assertEq(app.written(id, maker), 10e18);
    }

    /// @dev Symmetric case: a PUT's opposite leg is `poolUnderlying`, credited only by
    ///      exercising a PUT (delivering stock, taking cash back out of the pool).
    function test_close_revertsAfterExerciseOnPut() public {
        uint256 id = _putSeries();
        _shipAndBuy(id, 10e18, buyer);
        deal(address(nvdax), buyer, 10e18);
        vm.startPrank(buyer);
        nvdax.approve(address(app), 10e18);
        app.exercise(id, 4e18); // pool is now 4e18 stock + 1230e6 cash
        app.getSeries(id).token.transfer(maker, 5e18);
        vm.stopPrank();

        vm.prank(maker);
        vm.expectRevert(WeekendOptions.CloseAfterExercise.selector);
        app.close(id, 5e18);
    }

    function test_close_revertsWithoutWrittenPositionOrTokens() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);

        // The buyer never wrote anything: written[id][buyer] == 0 < amount -> BadAmount.
        vm.prank(buyer);
        vm.expectRevert(WeekendOptions.BadAmount.selector);
        app.close(id, 1e18);

        // The maker wrote 10e18 but holds no option tokens (they're all with the buyer) ->
        // the ERC20 burn inside `OptionToken` reverts, not a bespoke guard.
        vm.prank(maker);
        vm.expectRevert();
        app.close(id, 1e18);
    }

    // Review: the boundary is load-bearing — at expiry itself, close is too late, not one
    // second later (mirrors Exercise.t.sol's own expiry-boundary test).
    function test_close_revertsAfterExpiry() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);

        vm.warp(expiry);
        vm.prank(maker);
        vm.expectRevert(WeekendOptions.Expired.selector);
        app.close(id, 1e18);

        vm.warp(expiry + 1);
        vm.prank(maker);
        vm.expectRevert(WeekendOptions.Expired.selector);
        app.close(id, 1e18);
    }
}
