// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/contracts/Aqua.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import { Kind, WeekendOptions } from "../src/WeekendOptions.sol";
import { WeekendTaker } from "../src/WeekendTaker.sol";
import { OptionTokenFactory } from "../src/OptionToken.sol";
import { PythSettlementOracle } from "../src/oracle/PythSettlementOracle.sol";
import { IPyth, IMultiplierToken } from "../src/interfaces/IPyth.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockPyth } from "../src/mocks/MockPyth.sol";

/// @notice `PythSettlementOracle` — the drop-in that closes the settlement exposure
///         `V4SpotOracle` documents and accepts (spec §4, `Settle.t.sol`'s two
///         `KNOWN_EXPOSURE` tests).
///
/// @dev THE THREAT MODEL CHANGES SHAPE, and that is the point. Against `V4SpotOracle` an
///      attacker SETS the settlement price: `slot0` is whatever their last swap left behind, so
///      the realisable range is unbounded in both directions and one atomic transaction decides
///      the payout. Against this oracle they can only SELECT among prices Pyth's publishers
///      actually signed inside the window — and then only by racing honest samplers who can
///      dilute them back, permissionlessly, for the price of gas.
///
///      So the tests below pin the two properties that follow from that, rather than asserting
///      "manipulation is impossible":
///        * the settled price always lies inside the range of genuinely published prices, and
///        * no single sample decides it.
///      Neither property holds for `V4SpotOracle` at all.
contract PythSettlementOracleTest is Test {
    bytes32 internal constant PRICE_ID = bytes32(uint256(0xFEED));
    uint64 internal constant WINDOW = 30 minutes;
    uint256 internal constant STRIKE = 200e6;
    uint256 internal constant VOL = 0.5e18;
    uint64 internal constant MAX_TENOR = 30 days;
    /// @dev Pyth quotes US equities at `expo = -8`; the oracle rescales to the quote's 6 dp.
    int32 internal constant EXPO = -8;

    Aqua internal aqua;
    WeekendOptions internal app;
    WeekendTaker internal taker;
    PythSettlementOracle internal oracle;
    MockPyth internal pyth;
    MockERC20 internal nvdax;
    MockERC20 internal usdc;

    address internal maker = address(0xBEEF);
    address internal buyer = address(0xB0B);

    uint64 internal expiry;
    uint256 internal seriesId;

    function setUp() public {
        // Start well clear of zero so `publishTime` arithmetic is never near an underflow.
        vm.warp(1_700_000_000);

        aqua = new Aqua();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);

        pyth = new MockPyth();
        oracle = new PythSettlementOracle(IPyth(address(pyth)), WINDOW);
        // 60s staleness on `spot`, 100 bps max confidence.
        oracle.setFeed(address(nvdax), PRICE_ID, address(0), 60, 100);

        app = new WeekendOptions(address(usdc), new OptionTokenFactory(), IAqua(address(aqua)), oracle);
        taker = new WeekendTaker(IAqua(address(aqua)), address(app));

        usdc.mint(buyer, 1_000_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(taker), type(uint256).max);
        usdc.approve(address(app), type(uint256).max);
        vm.stopPrank();

        // A live spot so `buyOption` can price. 205 USD against a 200 strike: genuinely ITM.
        _publish(205e6, 0, uint64(block.timestamp));

        expiry = uint64(block.timestamp + 7 days);
        seriesId = app.createSeries(address(nvdax), expiry, Kind.CALL, STRIKE);
    }

    // ------------------------------------------------------------------ the averaging

    function test_settlementPrice_averagesEverySampleInTheWindow() public {
        vm.warp(expiry);
        _sample(204e6, uint64(expiry));
        _sample(206e6, uint64(expiry + 10 minutes));
        _sample(205e6, uint64(expiry + 20 minutes));

        (uint256 sum, uint256 count) = oracle.samples(address(nvdax), expiry);
        assertEq(count, 3, "three samples landed");
        assertEq(sum, 204e6 + 206e6 + 205e6, "sum is the raw accumulator");

        vm.warp(expiry + WINDOW + 1);
        (uint256 price, bool ok) = oracle.settlementPrice(address(nvdax), expiry);
        assertTrue(ok, "final once the window has closed");
        assertEq(price, 205e6, "the mean, not the last write");
    }

    /// @dev A running mean reported early would let a holder settle on one cherry-picked sample
    ///      before the honest ones that dilute it have landed. The window must CLOSE first.
    function test_settlementPrice_isNotFinalUntilTheWindowCloses() public {
        vm.warp(expiry);
        _sample(205e6, uint64(expiry));

        (, bool okDuring) = oracle.settlementPrice(address(nvdax), expiry);
        assertFalse(okDuring, "not final while the window is open");

        vm.warp(expiry + WINDOW);
        (, bool okAtEdge) = oracle.settlementPrice(address(nvdax), expiry);
        assertFalse(okAtEdge, "the boundary second is still open");

        vm.warp(expiry + WINDOW + 1);
        (, bool okAfter) = oracle.settlementPrice(address(nvdax), expiry);
        assertTrue(okAfter, "final one second past the window");
    }

    // ------------------------------------------------------------------ the exposure, closed

    /// @notice The counterpart to `Settle.t.sol`'s `KNOWN_EXPOSURE` tests.
    ///
    /// @dev Same series, same intent, different oracle. Under `V4SpotOracle` the attacker moves
    ///      `slot0` to ~100e6, records it, unwinds, and ITM holders settle for ZERO — asserted
    ///      there as `holderUnderlying == 0`.
    ///
    ///      Here they cannot sign a price at all. The strongest move left is to push the single
    ///      WORST genuinely-published print in the window (a brief 201e6 dip) and hope nobody
    ///      dilutes it. Anyone can, and does. Both outcomes are asserted: holders are paid, and
    ///      the settled price sits inside the range of real prints — a bound `V4SpotOracle` does
    ///      not have in either direction.
    function test_CLOSES_EXPOSURE_oneAdversarialSampleIsDilutedNotDecisive() public {
        _shipAndBuy(10e18);
        vm.warp(expiry);

        // The attacker gets there first with the worst real print of the session.
        uint256 adversarial = 201e6;
        _sample(adversarial, uint64(expiry));

        // Honest keepers dilute it. No permission needed, no reporter role, just gas.
        _sample(205e6, uint64(expiry + 5 minutes));
        _sample(206e6, uint64(expiry + 10 minutes));
        _sample(205e6, uint64(expiry + 15 minutes));

        vm.warp(expiry + WINDOW + 1);
        app.settle(seriesId);

        WeekendOptions.Series memory s = app.getSeries(seriesId);

        // Property 1: the settled price is strictly inside the range of what was actually
        // published. Under `V4SpotOracle` the realisable range is unbounded in both directions.
        assertGe(s.settlePrice, adversarial, "never below the lowest real print");
        assertLe(s.settlePrice, 206e6, "never above the highest real print");
        assertEq(s.settlePrice, (201e6 + 205e6 + 206e6 + 205e6) / 4, "the mean of all four");

        // Property 2: the holder is paid. This is the exact assertion that FAILS under
        // `V4SpotOracle` in `test_settle_KNOWN_EXPOSURE_manipulatedSettlementPriceZeroesHolders`.
        assertGt(s.settlePrice, STRIKE, "still in the money");
        assertGt(s.holderUnderlying, 0, "ITM holders are not zeroed");
        assertEq(
            s.holderUnderlying,
            (s.supplyAtSettle * (s.settlePrice - STRIKE)) / s.settlePrice,
            "spec section 10's floor formula, on the averaged price"
        );
        assertEq(s.holderUnderlying + s.writerUnderlying, s.poolUnderlying, "conservation");

        // And the attacker's single sample moved the payout by less than its own weight:
        // one of four, against a point read that would have decided it outright.
        uint256 hadItBeenAPointRead = (s.supplyAtSettle * (adversarial - STRIKE)) / adversarial;
        assertGt(s.holderUnderlying, hadItBeenAPointRead, "dilution strictly helped the holder");
    }

    /// @dev The other half of the same property: a lone adversarial sample pushed on a series
    ///      nobody else watches still cannot be re-pushed to weight itself.
    function test_recordSample_rejectsAReplayOfTheSameUpdate() public {
        vm.warp(expiry);
        _sample(205e6, uint64(expiry));

        vm.expectRevert(PythSettlementOracle.StaleOrDuplicate.selector);
        _sample(205e6, uint64(expiry));

        // Nor an older one, even though Pyth itself would accept the blob.
        vm.expectRevert(PythSettlementOracle.StaleOrDuplicate.selector);
        _sample(100e6, uint64(expiry - 1));
    }

    // ------------------------------------------------------------------ the gates

    function test_recordSample_rejectsPrintsOutsideTheWindow() public {
        vm.warp(expiry + 1);

        // Before expiry: describes a market that had not settled yet.
        vm.expectRevert(PythSettlementOracle.OutsideWindow.selector);
        _sample(205e6, uint64(expiry - 1));

        // After the window: simply late.
        vm.warp(expiry + WINDOW + 10);
        vm.expectRevert(PythSettlementOracle.OutsideWindow.selector);
        _sample(205e6, uint64(expiry + WINDOW + 1));
    }

    function test_recordSample_rejectsAWideConfidenceInterval() public {
        vm.warp(expiry);
        // 100 bps of 205e6 (at expo -8, raw 205e8) is 205e6 raw units of conf. One over.
        vm.expectRevert(PythSettlementOracle.LowConfidence.selector);
        _sampleWithConf(205e6, 205e6 + 1, uint64(expiry));

        // Exactly at the bound is accepted.
        _sampleWithConf(205e6, 205e6, uint64(expiry));
        (, uint256 count) = oracle.samples(address(nvdax), expiry);
        assertEq(count, 1, "the in-bounds sample landed");
    }

    function test_recordSample_rejectsAnAssetWithNoFeed() public {
        vm.warp(expiry);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PRICE_ID, int64(1), uint64(0), EXPO, uint64(expiry));
        vm.expectRevert(PythSettlementOracle.NoFeed.selector);
        oracle.recordSample{ value: 1 }(address(usdc), expiry, data);
    }

    function test_recordSample_refundsTheExcessFee() public {
        vm.warp(expiry);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PRICE_ID, _raw(205e6), uint64(0), EXPO, uint64(expiry));

        uint256 before_ = address(this).balance;
        oracle.recordSample{ value: 1 ether }(address(nvdax), expiry, data);

        // Fee is 1 wei per update in `MockPyth`; everything else comes back.
        assertEq(address(this).balance, before_ - 1, "excess refunded");
        assertEq(address(oracle).balance, 0, "nothing stranded in the oracle");
    }

    function test_constructor_refusesAWindowThatLosesToTheGraceFallback() public {
        // `>= SETTLEMENT_GRACE` means `_settle` falls through to a single `spot()` read before
        // the average is ever final — reintroducing the exposure this contract removes.
        vm.expectRevert(PythSettlementOracle.WindowTooLong.selector);
        new PythSettlementOracle(IPyth(address(pyth)), app.SETTLEMENT_GRACE());

        vm.expectRevert(PythSettlementOracle.WindowTooLong.selector);
        new PythSettlementOracle(IPyth(address(pyth)), 0);

        // One second under is fine.
        PythSettlementOracle ok = new PythSettlementOracle(IPyth(address(pyth)), 7 days - 1);
        assertEq(ok.WINDOW(), 7 days - 1);
    }

    // ------------------------------------------------------------------ spot

    function test_spot_reportsNoPriceWhenStale() public {
        (uint256 fresh,) = oracle.spot(address(nvdax));
        assertEq(fresh, 205e6, "fresh price in quote units");

        vm.warp(block.timestamp + 61); // past the feed's 60s staleness
        (uint256 stale, uint256 at) = oracle.spot(address(nvdax));
        assertEq(stale, 0, "a stale feed reports no price");
        assertGt(at, 0, "but still reports when it last published");
    }

    /// @dev A silent oracle must not be a free one: `buyOption` refuses a zero spot outright,
    ///      which is what keeps a stale feed from handing out options against a maker's cover.
    function test_spot_staleFeedBlocksTheWritePathRatherThanPricingAtZero() public {
        _ship(10e18);
        vm.warp(block.timestamp + 61);

        WeekendOptions.Strategy memory s = _strategy();
        vm.prank(buyer);
        vm.expectRevert(WeekendOptions.NoPrice.selector);
        taker.buy(app, s, seriesId, 1e18, type(uint256).max, buyer, abi.encode(maker, keccak256(abi.encode(s))));
    }

    function test_spot_appliesTheWrapperMultiplier() public {
        MockMultiplier m = new MockMultiplier(1.5e18);
        oracle.setFeed(address(nvdax), PRICE_ID, address(m), 60, 100);

        // One wrapper token is worth 1.5 shares after a reinvested dividend.
        (uint256 price,) = oracle.spot(address(nvdax));
        assertEq(price, 205e6 * 3 / 2, "share price scaled by the multiplier");
    }

    function test_spot_reportsNoPriceForAnUnconfiguredAsset() public view {
        (uint256 price, uint256 at) = oracle.spot(address(usdc));
        assertEq(price, 0);
        assertEq(at, 0);
    }

    // ------------------------------------------------------------------ the grace path

    /// @dev If nobody ever samples, `_settle` waits out `SETTLEMENT_GRACE` and then falls back
    ///      to `spot()`. Under `V4SpotOracle` that fallback is the EASIER attack (one atomic
    ///      transaction, no record step — see `Settle.t.sol`). Here the fallback is a signed
    ///      Pyth price too, so the escape hatch is no weaker than the main path.
    function test_settle_graceFallbackReadsASignedPriceToo() public {
        _shipAndBuy(10e18);

        vm.warp(expiry + app.SETTLEMENT_GRACE());
        // Nobody sampled, so the average is unavailable; republish so `spot` is not stale.
        _publish(210e6, 0, uint64(block.timestamp));

        app.settle(seriesId);

        WeekendOptions.Series memory s = app.getSeries(seriesId);
        (, uint256 count) = oracle.samples(address(nvdax), expiry);
        assertEq(count, 0, "the fallback fired, not the average");
        assertEq(s.settlePrice, 210e6, "the signed spot, which no swap can move");
        assertGt(s.holderUnderlying, 0, "ITM holders still paid");
    }

    /// @dev Before grace, an unsampled series is simply not settleable — never settled at zero.
    function test_settle_revertsWhileTheWindowIsOpenAndNobodyHasSampled() public {
        _shipAndBuy(10e18);
        vm.warp(expiry + 1);
        vm.expectRevert(WeekendOptions.OracleNotReady.selector);
        app.settle(seriesId);
    }

    // ------------------------------------------------------------------ helpers

    receive() external payable { }

    /// @dev `price` is in quote units (6 dp); Pyth carries it at `EXPO`.
    function _raw(uint256 price) internal pure returns (int64) {
        return int64(uint64(price * 100)); // 6 dp -> 8 dp
    }

    function _publish(uint256 price, uint64 conf, uint64 publishTime) internal {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PRICE_ID, _raw(price), conf, EXPO, publishTime);
        pyth.updatePriceFeeds{ value: 1 }(data);
    }

    function _sample(uint256 price, uint64 publishTime) internal {
        _sampleWithConf(price, 0, publishTime);
    }

    /// @dev `conf` is given in quote units and scaled the same way the price is.
    function _sampleWithConf(uint256 price, uint256 conf, uint64 publishTime) internal {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(PRICE_ID, _raw(price), uint64(conf), EXPO, publishTime);
        oracle.recordSample{ value: 1 }(address(nvdax), expiry, data);
    }

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

    function _ship(uint256 amount) internal {
        (address token, uint256 need) = app.collateralFor(seriesId, amount);
        nvdax.mint(maker, need);

        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (token, need);
        (tokens[1], amounts[1]) = (address(usdc), 0);

        vm.startPrank(maker);
        nvdax.approve(address(aqua), type(uint256).max);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.ship(address(app), abi.encode(_strategy()), tokens, amounts);
        vm.stopPrank();
    }

    function _shipAndBuy(uint256 amount) internal {
        _ship(amount);
        WeekendOptions.Strategy memory s = _strategy();
        vm.prank(buyer);
        taker.buy(app, s, seriesId, amount, type(uint256).max, buyer, abi.encode(maker, keccak256(abi.encode(s))));
    }
}

/// @dev A wrapper whose balance tracks corporate actions through a multiplier.
contract MockMultiplier is IMultiplierToken {
    uint256 internal _m;

    constructor(uint256 m) {
        _m = m;
    }

    function multiplier() external view returns (uint256) {
        return _m;
    }
}
