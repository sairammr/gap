// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/contracts/Aqua.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import { Kind, WeekendOptions } from "../src/WeekendOptions.sol";
import { WeekendTaker } from "../src/WeekendTaker.sol";
import { OptionTokenFactory } from "../src/OptionToken.sol";
import { V4SpotOracle } from "../src/oracle/V4SpotOracle.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockStateView } from "./helpers/MockStateView.sol";

/// @notice American physical exercise: any holder, any time before expiry, any amount up to
///         their balance, no oracle read. This is the product's headline claim — every other
///         settlement route in this protocol depends on a price; this one deliberately does not.
/// @dev Runs against the real `Aqua` contract (Task 4's write path funds the position); exercise
///      itself never touches Aqua or the oracle, only direct ERC-20 legs against the pool the
///      app already holds.
contract ExerciseTest is Test {
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

        // The buyer pays the premium through the taker (Task 4's write path) and, separately,
        // pays the strike (or delivers the underlying) directly to the app at exercise time.
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

    /// @dev Local hash, so no external call stands between `expectRevert` and the call it guards.
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

    /// @dev Ships whatever cover `collateralFor` says this series actually needs (underlying for
    ///      a CALL, quote cash for a PUT), then buys. Write.t.sol's helper of the same name only
    ///      ever ships underlying because it is only ever exercised against CALL series there;
    ///      this one is also used for PUT, so it has to pick the right cover token.
    function _shipAndBuy(uint256 id, uint256 amount, address to) internal returns (uint256) {
        (address token, uint256 need) = app.collateralFor(id, amount);
        _ship(maker, token, need);
        return _buy(id, amount, to);
    }

    // ------------------------------------------------------------------ tests

    // Golden vector, spec §9
    function test_exerciseCall_paysStrikeReceivesStock() public {
        uint256 id = _callSeries(); // strike 205e6
        _shipAndBuy(id, 10e18, buyer);
        uint256 u0 = usdc.balanceOf(buyer);
        vm.prank(buyer);
        app.exercise(id, 10e18);
        assertEq(nvdax.balanceOf(buyer), 10e18);
        assertEq(u0 - usdc.balanceOf(buyer), 2050e6);
        assertEq(app.getSeries(id).poolUnderlying, 0);
        assertEq(app.getSeries(id).poolCash, 2050e6);
    }

    // Review Focus 5 — the oracle must never be touched.
    //
    // `stateView.setSqrtPriceX96(0)` makes the oracle answer spot 0, which Task 4 made provably
    // fatal: `buyOption` reverts `NoPrice()` and `quotePremium` floors to 0 under exactly this
    // condition (see test_buy_revertsWhenTheOracleHasNoPrice in Write.t.sol). So this is not an
    // assertion that exercise "doesn't call the oracle" by inspection — it is a proof: if
    // `exercise` touched the oracle through any path that matters (spot, or anything derived
    // from it), it would see the same zero and fail the same way `buyOption` does. It doesn't.
    //
    // Rider C: a zero spot proves exercise does not REQUIRE a valid price, but `V4SpotOracle`
    // answers (0, 0) instead of reverting, so an accidental no-op oracle call added to `exercise`
    // later would see that zero and still pass. `vm.mockCallRevert` makes ANY call to the oracle
    // unconditionally revert, so an added call would fail loudly -- this converts the headline
    // claim from "established by code inspection" into "enforced by CI".
    function test_exercise_readsNoOracle() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 20e18, buyer);

        stateView.setSqrtPriceX96(0); // any oracle read would now price at zero
        vm.prank(buyer);
        app.exercise(id, 10e18); // must still succeed
        assertEq(nvdax.balanceOf(buyer), 10e18);

        // Stronger than the zero-spot case above: the oracle now reverts outright on any call,
        // so a no-op read that would have survived a zero spot cannot survive this.
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(oracle.spot.selector), "oracle must not be read");
        vm.prank(buyer);
        app.exercise(id, 10e18); // must still succeed with the oracle unconditionally reverting
        assertEq(nvdax.balanceOf(buyer), 20e18);
    }

    // Ruling 4: assert the delta across the exercise call, not an absolute balance — the buyer
    // already paid a premium to acquire the option, so an absolute `usdc.balanceOf(buyer)`
    // assertion would be wrong regardless of exercise's own correctness.
    function test_exercisePut_deliversStockReceivesCash() public {
        uint256 id = _putSeries();
        _shipAndBuy(id, 10e18, buyer);
        deal(address(nvdax), buyer, 10e18);
        uint256 u0 = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        nvdax.approve(address(app), 10e18);
        app.exercise(id, 10e18);
        vm.stopPrank();
        assertEq(usdc.balanceOf(buyer) - u0, 2050e6);
        assertEq(nvdax.balanceOf(buyer), 0);
        assertEq(app.getSeries(id).poolUnderlying, 10e18);
        assertEq(app.getSeries(id).poolCash, 0);
    }

    function test_exercise_partialLeavesRemainder() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        vm.prank(buyer);
        app.exercise(id, 4e18);
        assertEq(app.getSeries(id).token.balanceOf(buyer), 6e18);
        assertEq(app.getSeries(id).poolUnderlying, 6e18);
        assertEq(app.getSeries(id).poolCash, 820e6);
    }

    // Review Focus 5 — the boundary is load-bearing: at expiry itself, exercise is too late, not
    // one second later. Tested both exactly at expiry and strictly after it.
    function test_exercise_revertsAtAndAfterExpiry() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);

        vm.warp(expiry);
        vm.prank(buyer);
        vm.expectRevert(WeekendOptions.Expired.selector);
        app.exercise(id, 10e18);

        vm.warp(expiry + 1);
        vm.prank(buyer);
        vm.expectRevert(WeekendOptions.Expired.selector);
        app.exercise(id, 10e18);
    }

    function test_exercise_revertsOnZeroAmount() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        vm.prank(buyer);
        vm.expectRevert(WeekendOptions.BadAmount.selector);
        app.exercise(id, 0);
    }

    // Beyond the brief: exercising more than you hold must revert (the option token's own
    // ERC-20 balance check inside `burn`, not a bespoke guard).
    function test_exercise_revertsWhenExceedingHoldings() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        vm.prank(buyer);
        vm.expectRevert();
        app.exercise(id, 10e18 + 1);
    }

    // Beyond the brief: two partials summing to the full position must land exactly where a
    // single full exercise would.
    function test_exercise_twoPartialsSumToFull() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);

        vm.prank(buyer);
        app.exercise(id, 4e18);
        vm.prank(buyer);
        app.exercise(id, 6e18);

        assertEq(nvdax.balanceOf(buyer), 10e18);
        assertEq(app.getSeries(id).token.balanceOf(buyer), 0);
        assertEq(app.getSeries(id).poolUnderlying, 0);
        assertEq(app.getSeries(id).poolCash, 2050e6);
    }
}
