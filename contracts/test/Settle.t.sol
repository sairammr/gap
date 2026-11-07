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
import { MockPriceOracle } from "./helpers/MockPriceOracle.sol";

/// @notice Post-expiry settlement (spec §10): fixes the holder/writer payout split once a
///         series has expired, using the oracle's time-weighted settlement price, falling back
///         to spot after a grace window, and to a worthless price if neither ever arrives.
/// @dev Ruling 2 (binding): every arithmetic / golden-vector test here is driven through
///      `MockPriceOracle` (exact, settable prices) rather than the real `V4SpotOracle` — the v4
///      sqrt round-trip is only accurate to ~1e3 quote units, which would move `holderUnderlying`
///      by ~4.6e13 wei, far past what a wei-exact golden vector can tolerate. Exactly two tests
///      exercise the real `V4SpotOracle` end to end: one plain wiring check (tolerant), and the
///      mandated `KNOWN_EXPOSURE` test, which needs the real oracle's permissionless
///      `recordSettlement` to demonstrate the manipulation risk.
contract SettleTest is Test {
    // sqrtPriceX96 constants for the 18dp underlying / 6dp quote, underlyingIsCurrency0 = true,
    // reused verbatim from the sibling test files (Close.t.sol, Exercise.t.sol, PoolFork.t.sol).
    uint160 internal constant SQRT_PRICE_205 = 1134374654051415993876480;
    uint160 internal constant SQRT_PRICE_100 = 792281625142643375935439;

    bytes32 internal constant POOL_ID = bytes32(uint256(1));
    uint256 internal constant STRIKE = 205e6;
    uint256 internal constant VOL = 0.5e18;
    uint64 internal constant MAX_TENOR = 30 days;

    Aqua internal aqua;
    WeekendOptions internal app;
    WeekendTaker internal taker;
    MockPriceOracle internal oracle;
    MockERC20 internal nvdax;
    MockERC20 internal usdc;

    address internal maker = address(0xBEEF);
    address internal buyer = address(0xB0B);

    uint64 internal expiry;

    function setUp() public {
        aqua = new Aqua();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);

        oracle = new MockPriceOracle();
        oracle.setSpot(address(nvdax), 205e6, block.timestamp);

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
            maxSecondsToExpiry: MAX_TENOR,
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

    /// @dev Warps to `expiry` (if not already there) and records a time-weighted settlement
    ///      price, so `_settle`'s oracle step 1 (`ok == true`) fires.
    function _recordSettlementAt(uint256 price) internal {
        if (block.timestamp < expiry) vm.warp(expiry);
        oracle.setSettlementPrice(address(nvdax), expiry, price);
    }

    // ------------------------------------------------------------------ golden vectors (spec §9/§10)

    function test_settle_itmCall_snapshotsHolderAndWriterShares() public {
        uint256 id = _callSeries(); // strike 205e6
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(212e6);

        vm.expectEmit(true, false, false, true, address(app));
        emit WeekendOptions.Settled(id, 212e6, 330188679245283018, 0);
        app.settle(id);

        WeekendOptions.Series memory s = app.getSeries(id);
        assertEq(s.settlePrice, 212e6);
        assertEq(s.supplyAtSettle, 10e18);
        // Ruling 5 (amended): wei-exact, not ±10. §9's "...981" is the source's own JS assertion
        // taken under tolerance; §10's exact subtraction yields "...982".
        assertEq(s.holderUnderlying, 330188679245283018);
        assertEq(s.writerUnderlying, 9669811320754716982);
        assertEq(s.holderUnderlying + s.writerUnderlying, 10e18); // structural invariant
        assertEq(s.writtenAtSettle, 10e18);
        assertEq(s.poolUnderlying, 10e18); // pools are NOT decremented — frozen stale
        assertEq(s.holderCash, 0); // a CALL never touches the cash leg
        assertEq(s.writerCash, 0);
    }

    function test_settle_otmCall_writerTakesEverything() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(201e6);
        app.settle(id);

        WeekendOptions.Series memory s = app.getSeries(id);
        assertEq(s.holderUnderlying, 0);
        assertEq(s.writerUnderlying, 10e18);
    }

    function test_settle_itmPut_paysHolderCash() public {
        uint256 id = _putSeries(); // strike 205e6, 10 options -> 2050e6 cash
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(185e6);
        app.settle(id);

        WeekendOptions.Series memory s = app.getSeries(id);
        assertEq(s.holderCash, 200e6); // 10e18 * 20e6 / 1e18
        assertEq(s.writerCash, 1850e6);
        assertEq(s.holderCash + s.writerCash, 2050e6);
        assertEq(s.holderUnderlying, 0); // a PUT never touches the underlying leg
        assertEq(s.writerUnderlying, 0);
    }

    /// @dev Review Focus 4 — a CALL series holds BOTH legs after a partial exercise, and
    ///      `_settle` must still only compute the CALL branch (`hU`); `holderCash` stays 0.
    function test_settle_afterPartialExercise_paysFromStockAndReturnsAccruedCash() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        vm.prank(buyer);
        app.exercise(id, 4e18); // pool: 6e18 stock + 820e6 cash
        _recordSettlementAt(212e6);
        app.settle(id);

        WeekendOptions.Series memory s = app.getSeries(id);
        assertEq(s.supplyAtSettle, 6e18);
        assertEq(s.holderUnderlying, 198113207547169811); // floor(6e18 * 7e6 / 212e6)
        assertEq(s.writerUnderlying, 6e18 - s.holderUnderlying); // exact subtraction
        assertEq(s.holderCash, 0); // a CALL never pays holders cash
        assertEq(s.writerCash, 820e6); // exercise proceeds go to writers
    }

    /// @dev Review Focus 1 — ported quirk: a GENUINE settlement price of exactly zero pays PUT
    ///      holders nothing even though intrinsic would then be the full strike. Zero is
    ///      overloaded as "no price". Intentional, ported as-is from the source protocol.
    function test_settle_zeroPrice_paysPutHoldersNothing() public {
        uint256 id = _putSeries();
        _shipAndBuy(id, 10e18, buyer);
        vm.warp(expiry + app.SETTLEMENT_GRACE());
        oracle.setSpot(address(nvdax), 0, expiry); // spot() -> (0, expiry): a genuine zero price

        app.settle(id);

        WeekendOptions.Series memory s = app.getSeries(id);
        assertEq(s.settlePrice, 0);
        assertEq(s.holderCash, 0); // intrinsic would be the full strike -- paid nothing anyway
        assertEq(s.writerCash, 2050e6);
    }

    // ------------------------------------------------------------------ oracle sequence / guards

    function test_settle_revertsBeforeExpiryAndInsideGraceWithoutPrice() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);

        vm.expectRevert(WeekendOptions.NotExpired.selector);
        app.settle(id);

        vm.warp(expiry); // at expiry, nothing recorded yet -> inside the grace window
        vm.expectRevert(WeekendOptions.OracleNotReady.selector);
        app.settle(id);

        vm.warp(expiry + app.SETTLEMENT_GRACE() - 1); // one second before grace ends
        vm.expectRevert(WeekendOptions.OracleNotReady.selector);
        app.settle(id);
    }

    function test_settle_revertsOnSecondCall() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(212e6);
        app.settle(id);

        vm.expectRevert(WeekendOptions.AlreadySettled.selector);
        app.settle(id);
    }

    /// @dev Oracle step 3, accept branch: past grace, no settlement price, but the oracle's
    ///      latest spot WAS published at/after expiry -> that spot stands in.
    function test_settle_gracePath_usesSpotPublishedAfterExpiry() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        vm.warp(expiry + app.SETTLEMENT_GRACE());
        oracle.setSpot(address(nvdax), 212e6, expiry); // published exactly at expiry -- accepted

        app.settle(id);

        WeekendOptions.Series memory s = app.getSeries(id);
        assertEq(s.settlePrice, 212e6);
        assertEq(s.holderUnderlying, 330188679245283018);
    }

    /// @dev Oracle step 3, reject branch: a spot published BEFORE expiry is stale and must be
    ///      rejected outright -- `p` becomes 0, not the stale number.
    function test_settle_gracePath_rejectsSpotPublishedBeforeExpiry() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        oracle.setSpot(address(nvdax), 212e6, expiry - 1); // published one second before expiry
        vm.warp(expiry + app.SETTLEMENT_GRACE());

        app.settle(id);

        WeekendOptions.Series memory s = app.getSeries(id);
        assertEq(s.settlePrice, 0); // stale spot rejected, not used
        assertEq(s.holderUnderlying, 0);
        assertEq(s.writerUnderlying, 10e18);
    }

    // ------------------------------------------------------------------ Rider D: maxSecondsToExpiry

    /// @dev `Strategy` binds no series/strike/expiry and `createSeries` is permissionless out to
    ///      400 days, so without this bound a maker's weekend-calibrated vol could be applied to
    ///      a series an attacker opens far in the future, locking the maker's cover for over a
    ///      year against a premium priced for a two-day tenor.
    function test_buyOption_revertsOnTenorTooLong() public {
        uint64 farExpiry = uint64(block.timestamp + 30 days);
        uint256 id = app.createSeries(address(nvdax), farExpiry, Kind.CALL, STRIKE);

        WeekendOptions.Strategy memory tight = WeekendOptions.Strategy({
            app: address(app),
            maker: maker,
            underlying: address(nvdax),
            quote: address(usdc),
            volWad: VOL,
            minPremiumBps: 0,
            maxSecondsToExpiry: 7 days, // far shorter than the 30-day series above
            salt: bytes32(0)
        });

        nvdax.mint(maker, 10e18);
        vm.startPrank(maker);
        nvdax.approve(address(aqua), type(uint256).max);
        usdc.approve(address(aqua), type(uint256).max);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (address(nvdax), 10e18);
        (tokens[1], amounts[1]) = (address(usdc), 0);
        aqua.ship(address(app), abi.encode(tight), tokens, amounts);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(WeekendOptions.TenorTooLong.selector);
        taker.buy(
            app, tight, id, 10e18, type(uint256).max, buyer, abi.encode(maker, keccak256(abi.encode(tight)))
        );
    }

    // ------------------------------------------------------------------ real V4SpotOracle (not MockPriceOracle)

    struct RealOracleHarness {
        Aqua aqua;
        WeekendOptions app;
        WeekendTaker taker;
        V4SpotOracle oracle;
        MockStateView stateView;
        MockERC20 nvdax;
        MockERC20 usdc;
    }

    /// @dev Fresh deployment wired to the REAL `V4SpotOracle`, reused by the two tests below that
    ///      deliberately exercise it instead of `MockPriceOracle`.
    function _deployRealOracleHarness() internal returns (RealOracleHarness memory h) {
        h.aqua = new Aqua();
        h.usdc = new MockERC20("USD Coin", "USDC", 6);
        h.nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);

        h.stateView = new MockStateView(SQRT_PRICE_205);
        h.oracle = new V4SpotOracle(h.stateView, 6);
        h.oracle.setPool(address(h.nvdax), POOL_ID, 18, true);

        OptionTokenFactory factory = new OptionTokenFactory();
        h.app = new WeekendOptions(address(h.usdc), factory, IAqua(address(h.aqua)), h.oracle);
        h.taker = new WeekendTaker(IAqua(address(h.aqua)), address(h.app));

        h.usdc.mint(buyer, 1_000_000e6);
        vm.startPrank(buyer);
        h.usdc.approve(address(h.taker), type(uint256).max);
        h.usdc.approve(address(h.app), type(uint256).max);
        vm.stopPrank();
    }

    function _realStrategy(RealOracleHarness memory h) internal view returns (WeekendOptions.Strategy memory) {
        return WeekendOptions.Strategy({
            app: address(h.app),
            maker: maker,
            underlying: address(h.nvdax),
            quote: address(h.usdc),
            volWad: VOL,
            minPremiumBps: 0,
            maxSecondsToExpiry: MAX_TENOR,
            salt: bytes32(0)
        });
    }

    function _realShip(RealOracleHarness memory h, address token, uint256 need) internal {
        h.nvdax.mint(maker, need);
        bool quoteIsCover = token == address(h.usdc);
        address[] memory tokens = new address[](quoteIsCover ? 1 : 2);
        uint256[] memory amounts = new uint256[](quoteIsCover ? 1 : 2);
        tokens[0] = token;
        amounts[0] = need;
        if (!quoteIsCover) {
            tokens[1] = address(h.usdc);
            amounts[1] = 0;
        }
        WeekendOptions.Strategy memory strat = _realStrategy(h);
        vm.startPrank(maker);
        MockERC20(token).approve(address(h.aqua), type(uint256).max);
        h.usdc.approve(address(h.aqua), type(uint256).max);
        h.aqua.ship(address(h.app), abi.encode(strat), tokens, amounts);
        vm.stopPrank();
    }

    function _realBuy(RealOracleHarness memory h, uint256 id, uint256 amount) internal {
        WeekendOptions.Strategy memory strat = _realStrategy(h);
        bytes32 hash = keccak256(abi.encode(strat));
        vm.prank(buyer);
        h.taker.buy(h.app, strat, id, amount, type(uint256).max, buyer, abi.encode(maker, hash));
    }

    function _realShipAndBuy(RealOracleHarness memory h, uint256 id, uint256 amount) internal {
        (address token, uint256 need) = h.app.collateralFor(id, amount);
        _realShip(h, token, need);
        _realBuy(h, id, amount);
    }

    /// @notice The one integration test that keeps the real `V4SpotOracle` wired end to end
    ///         (Ruling 2). The oracle's sqrt round-trip is only accurate to ~1e3 quote units, so
    ///         the recorded price is checked with a tolerance; `holderUnderlying` is instead
    ///         recomputed in-test off the ACTUAL realized `settlePrice` (spec §10's own floor
    ///         formula) and compared exactly, which proves `_settle`'s wiring and arithmetic
    ///         without fighting the oracle's own imprecision.
    function test_settle_integration_realV4SpotOracle_itmCall() public {
        RealOracleHarness memory h = _deployRealOracleHarness();
        uint64 realExpiry = uint64(block.timestamp + 7 days);
        uint256 strike = 200e6; // below the real oracle's ~205e6 spot -> ITM
        uint256 id = h.app.createSeries(address(h.nvdax), realExpiry, Kind.CALL, strike);
        _realShipAndBuy(h, id, 10e18);

        vm.warp(realExpiry);
        h.oracle.recordSettlement(address(h.nvdax), realExpiry);
        h.app.settle(id);

        WeekendOptions.Series memory s = h.app.getSeries(id);
        assertApproxEqAbs(s.settlePrice, 205e6, 1e3); // real wiring: oracle's own tolerance
        assertGt(s.settlePrice, strike); // still genuinely ITM despite the rounding

        uint256 expectedHU = (s.settlePrice > strike) ? (s.supplyAtSettle * (s.settlePrice - strike)) / s.settlePrice : 0;
        assertEq(s.holderUnderlying, expectedHU); // exact given the realized price
        assertEq(s.holderUnderlying + s.writerUnderlying, s.poolUnderlying);
    }

    /// @notice KNOWN, ACCEPTED EXPOSURE (user-reviewed; not fixed by this task).
    /// @dev FULL SCOPE (I2): this test pins only ONE slice of it -- the two-step
    ///      `recordSettlement` route, and only the WRITER-favourable direction. The real exposure
    ///      is broader on both axes:
    ///      1. EVERY `oracle.spot()` read reachable from `_settle` is manipulable, not just the
    ///         one behind `recordSettlement`. Past `expiry + SETTLEMENT_GRACE`, the grace
    ///         fallback reads `spot()` INSIDE `settle`/`redeem`/`claim` themselves -- and all
    ///         three are permissionless and lazily invoked. So the attack is atomic in ONE
    ///         transaction (flash-loan -> move `slot0` -> `redeem`/`claim` -> unwind), strictly
    ///         easier than this test's two-step, two-transaction, `AlreadyRecorded`-raced route.
    ///         See `test_settle_KNOWN_EXPOSURE_atomicGracePathManipulationLetsHoldersTakeTheWriterPool`.
    ///      2. It is bidirectional. This test only demonstrates DEPRESSING the price (writers
    ///         keep everything, holders get zeroed). PUMPING it is exactly as exploitable in the
    ///         other direction: on a CALL, `hU = supply*(p-K)/p -> supply` as `p` rises, so
    ///         holders can take (effectively) the writers' whole pool; on a PUT, depressing `p`
    ///         toward zero gives `hC = supply*K/1e18`, capped by the `min` at `poolCash` --
    ///         again the whole writer pool, from the other side.
    ///      `_settle`'s oracle sequence is a faithful §10 port; the defect is in the oracle, not
    ///      here. If the oracle is ever replaced these tests change shape -- that is the point.
    ///
    ///      THE FIX NOW EXISTS, UNWIRED: `src/oracle/PythSettlementOracle.sol` implements the
    ///      same `IPriceOracle` and closes both halves of this -- see
    ///      `PythSettlementOracle.t.sol::test_CLOSES_EXPOSURE_oneAdversarialSampleIsDilutedNotDecisive`,
    ///      which is this test's assertions inverted. These two tests stay, and stay passing,
    ///      for as long as `V4SpotOracle` is what a deployment actually points at. Deleting
    ///      them is the LAST step of that swap, not the first.
    function test_settle_KNOWN_EXPOSURE_manipulatedSettlementPriceZeroesHolders() public {
        RealOracleHarness memory h = _deployRealOracleHarness();
        uint64 realExpiry = uint64(block.timestamp + 7 days);
        uint256 strike = 200e6; // genuinely ITM at the real ~205e6 spot used to write/buy
        uint256 id = h.app.createSeries(address(h.nvdax), realExpiry, Kind.CALL, strike);
        _realShipAndBuy(h, id, 10e18);

        vm.warp(realExpiry);
        // The attack: depress the pool's instantaneous price below the strike, record it
        // (irrevocably), then unwind -- the recorded settlement price never reflects the
        // depression ever having been undone.
        h.stateView.setSqrtPriceX96(SQRT_PRICE_100); // instantaneous spot -> ~100e6, <= strike
        h.oracle.recordSettlement(address(h.nvdax), realExpiry);
        h.stateView.setSqrtPriceX96(SQRT_PRICE_205); // unwind back to the "real" price

        h.app.settle(id);

        WeekendOptions.Series memory s = h.app.getSeries(id);
        assertLe(s.settlePrice, strike); // the manipulated, permanently-recorded price
        assertEq(s.holderUnderlying, 0); // ITM holders get nothing
        assertEq(s.writerUnderlying, s.poolUnderlying); // writers take the whole pool
    }

    /// @notice KNOWN, ACCEPTED EXPOSURE (user-reviewed; not fixed by this task) -- see the FULL
    ///         SCOPE note on the sibling test above.
    /// @dev This is the STRICTLY EASIER, BIDIRECTIONAL half of the same exposure:
    ///      1. No `recordSettlement` call anywhere in this test, no `AlreadyRecorded` race to
    ///         win, no second transaction. Past `expiry + SETTLEMENT_GRACE`, `redeem` lazily
    ///         calls `_settle`, which falls through to `oracle.spot()` INSIDE that same call. An
    ///         attacker just moves `slot0` and calls `redeem` -- one transaction, their choice of
    ///         block, `recorded(asset, expiry)` never even touches `true` (asserted below).
    ///      2. The OTHER direction from the sibling test: PUMPING the price, not depressing it.
    ///         On a CALL, `hU = supply*(p-K)/p` strictly approaches `supply` as `p -> infinity`
    ///         (it can never reach it exactly for a strike `K > 0`, so the `min(hU, poolUnderlying)`
    ///         cap never literally binds here) but gets arbitrarily close: at 250,000x the
    ///         strike, writers are left with 4e13 wei of dust out of a 1e19 pool (0.0004%) --
    ///         holders take, for every practical purpose, the writers' entire pool.
    function test_settle_KNOWN_EXPOSURE_atomicGracePathManipulationLetsHoldersTakeTheWriterPool() public {
        RealOracleHarness memory h = _deployRealOracleHarness();
        uint64 realExpiry = uint64(block.timestamp + 7 days);
        uint256 strike = 200e6;
        uint256 id = h.app.createSeries(address(h.nvdax), realExpiry, Kind.CALL, strike);
        _realShipAndBuy(h, id, 10e18);

        vm.warp(realExpiry + h.app.SETTLEMENT_GRACE()); // past grace -- `redeem` can lazy-settle
        // The attack, atomic: pump the pool's instantaneous price, then immediately redeem.
        // sqrtPriceX96 chosen so `spot()` reads exactly 50,000,000e6 (250,000x the 200e6 strike).
        h.stateView.setSqrtPriceX96(560227709747861407246843904);

        vm.prank(buyer);
        h.app.redeem(id, 10e18); // no `settle()`, no `recordSettlement` -- one call, lazy-settles

        assertFalse(h.oracle.recorded(address(h.nvdax), realExpiry)); // the record step never ran

        WeekendOptions.Series memory s = h.app.getSeries(id);
        assertEq(s.settlePrice, 50_000_000e6);
        assertEq(s.holderUnderlying, 9_999_960_000_000_000_000); // floor(10e18 * (p-K)/p)
        assertEq(s.writerUnderlying, 40_000_000_000_000); // dust: 0.0004% of the 1e19 pool
        assertEq(h.nvdax.balanceOf(buyer), s.holderUnderlying);

        h.app.claimFor(id, maker); // writer collects what little is left
        assertEq(h.nvdax.balanceOf(maker), s.writerUnderlying);
    }
}
