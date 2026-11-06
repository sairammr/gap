// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/contracts/Aqua.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import { Kind, WeekendOptions } from "../src/WeekendOptions.sol";
import { WeekendTaker } from "../src/WeekendTaker.sol";
import { OptionToken, OptionTokenFactory } from "../src/OptionToken.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockPriceOracle } from "./helpers/MockPriceOracle.sol";

/// @notice Pro-rata `redeem`/`claim` with permissionless keeper entry points (spec §10/§11).
/// @dev Ruling 2 (Task 7, binding here too): arithmetic/golden-vector tests run through
///      `MockPriceOracle`'s exact settable returns, never `V4SpotOracle` (its sqrt round-trip is
///      only accurate to ~1e3 quote units, which would move `holderUnderlying` by ~4.6e13 wei).
/// @dev Ruling 5 (amended, binding): the golden-vector pair for the ITM-CALL at strike 205 /
///      settlePrice 212 is asserted wei-exact with `assertEq`, not `assertApproxEqAbs`. §9's own
///      "...981" writer figure is the source's JS assertion taken under tolerance; §10's exact
///      subtraction (`writerUnderlying = poolUnderlying - holderUnderlying`) yields "...982", and
///      with no exercises outstanding this path is fully deterministic, so a tolerance would hide
///      exactly the rounding drift these vectors exist to catch.
contract PayoutTest is Test {
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
    address internal keeper = address(0xCAFE);

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

    // ------------------------------------------------------------------ helpers (shape lifted from Settle.t.sol)

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

    function test_redeemAndClaim_itmCall_matchTheSourceProtocolToTheWei() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(212e6);

        vm.prank(buyer);
        app.redeem(id, 10e18);
        // Ruling 5 (amended): wei-exact, not ±10.
        assertEq(nvdax.balanceOf(buyer), 330188679245283018);

        app.claimFor(id, maker);
        assertEq(nvdax.balanceOf(maker), 9669811320754716982);

        // Structural invariant: a full redeem plus a full claim never exceed the snapshot.
        assertEq(nvdax.balanceOf(buyer) + nvdax.balanceOf(maker), 10e18);
    }

    function test_redeem_lazySettlesOnFirstTouch() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(212e6);

        assertFalse(app.getSeries(id).settled);
        vm.prank(buyer);
        app.redeem(id, 10e18); // no explicit settle() call
        assertTrue(app.getSeries(id).settled);
    }

    function test_redeem_partialUsesSnapshotDenominator() public {
        // Two halves redeemed separately must sum to the SAME total as one full redeem would —
        // that is the entire point of freezing the denominator at `supplyAtSettle`.
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(212e6);

        vm.startPrank(buyer);
        (uint256 a,) = app.redeem(id, 5e18);
        (uint256 b,) = app.redeem(id, 5e18);
        vm.stopPrank();

        assertEq(a + b, 330188679245283018); // wei-exact, Ruling 5 (amended)
        assertEq(nvdax.balanceOf(buyer), 330188679245283018);
    }

    function test_claim_isOneShot() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(201e6);

        app.claimFor(id, maker);
        (uint256 u, uint256 c) = app.claimFor(id, maker);
        assertEq(u, 0);
        assertEq(c, 0);
        assertEq(app.written(id, maker), 0);
    }

    // Review Focus 11 (spec §6) — keeper pays everyone, permissionlessly, never itself.
    function test_redeemForAndClaimFor_payTheTargetNotTheCaller() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(212e6);

        vm.prank(keeper);
        app.redeemFor(id, buyer);
        vm.prank(keeper);
        app.claimFor(id, maker);

        assertEq(nvdax.balanceOf(keeper), 0);
        assertGt(nvdax.balanceOf(buyer), 0);
        assertGt(nvdax.balanceOf(maker), 0);
    }

    function test_redeemFor_returnsZeroForEmptyHolder() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        _recordSettlementAt(212e6);

        address stranger = address(0xD00D);
        (uint256 u, uint256 c) = app.redeemFor(id, stranger); // no revert
        assertEq(u, 0);
        assertEq(c, 0);
        assertEq(nvdax.balanceOf(stranger), 0);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    // Review Focus 2 — supplyAtSettle == 0 must not panic on a 0/0 division.
    function test_redeem_doesNotPanicWhenSupplyAtSettleIsZero() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        vm.prank(buyer);
        app.exercise(id, 10e18); // every option exercised before settlement -> supply is now 0
        _recordSettlementAt(212e6);
        app.settle(id);
        assertEq(app.getSeries(id).supplyAtSettle, 0);

        (uint256 u, uint256 c) = app.redeemFor(id, buyer);
        assertEq(u, 0);
        assertEq(c, 0);

        app.claimFor(id, maker); // writer still gets the whole pool (the exercise proceeds)
        assertGe(usdc.balanceOf(maker), 2050e6);
    }

    // ------------------------------------------------------------------ beyond the brief

    /// @dev Claim after a partial `close`: the writer bought part of their own written position
    ///      back and unwound it pre-expiry, so what pays at claim time must be the REMAINING
    ///      `written[id][maker]` (post-close), not the original amount they wrote. If `_claim`
    ///      used a stale pre-close figure here it would try to pay out more underlying than the
    ///      series pool actually still holds and the final transfer would revert.
    function test_claim_afterPartialClose_paysTheRemainingWrittenAmount() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer); // maker wrote 10e18, buyer holds all 10e18 option tokens

        OptionToken token = app.getSeries(id).token;
        vm.prank(buyer);
        token.transfer(maker, 5e18); // maker buys half their own position back to close it

        vm.prank(maker);
        app.close(id, 5e18); // written[id][maker]: 10e18 -> 5e18; poolUnderlying: 10e18 -> 5e18
        assertEq(app.written(id, maker), 5e18);

        _recordSettlementAt(201e6); // OTM: holders get nothing, writers take the remaining pool
        app.settle(id);
        assertEq(app.getSeries(id).writerUnderlying, 5e18); // what's left in the pool after close

        (uint256 outU,) = app.claimFor(id, maker);
        assertEq(outU, 5e18); // pro-rata of the REMAINING written amount, not the original 10e18
        assertEq(app.written(id, maker), 0);
        assertEq(nvdax.balanceOf(maker), 10e18); // 5e18 from the close + 5e18 from the claim
    }

    /// @dev A holder who never bought anything — they received their option tokens by a plain
    ///      ERC-20 transfer — redeems exactly as a buyer would. Option tokens are fungible and
    ///      `_redeem` pays against the pool snapshot, never against a record of who the original
    ///      buyer was.
    function test_redeem_byTransferRecipient_payoutIsIdenticalToABuyer() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);

        address strangerHolder = address(0xFEED);
        OptionToken token = app.getSeries(id).token;
        vm.prank(buyer);
        token.transfer(strangerHolder, 10e18); // buyer never redeems; strangerHolder owns it all

        _recordSettlementAt(212e6);
        vm.prank(strangerHolder);
        app.redeem(id, 10e18);

        assertEq(nvdax.balanceOf(strangerHolder), 330188679245283018); // same golden vector
        assertEq(nvdax.balanceOf(buyer), 0); // the original buyer gets nothing — they hold no tokens
    }

    // ------------------------------------------------------------------ multi-writer pro-rata (I1)

    /// @dev Every test above (and `Close.t.sol`'s) writes through a SINGLE maker, so
    ///      `written[id][maker] == writtenAtSettle` always holds and `_claim`'s two `fullMulDiv`
    ///      divisions could be replaced by `outU = s.writerUnderlying; outC = s.writerCash;`
    ///      without failing a single one of them. `_strategy()` hardcodes the one `maker` state
    ///      variable, so a second writer needs its own `Strategy` (same shape, different
    ///      `maker`) shipped and bought through directly instead of the shared helpers.
    function _strategyOf(address who) internal view returns (WeekendOptions.Strategy memory) {
        return WeekendOptions.Strategy({
            app: address(app),
            maker: who,
            underlying: address(nvdax),
            quote: address(usdc),
            volWad: VOL,
            minPremiumBps: 0,
            maxSecondsToExpiry: MAX_TENOR,
            salt: bytes32(0)
        });
    }

    function _shipFor(address who, address token, uint256 amount, WeekendOptions.Strategy memory s) internal {
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
        aqua.ship(address(app), abi.encode(s), tokens, amounts);
        vm.stopPrank();
    }

    function _shipAndBuyFor(uint256 id, address who, uint256 amount, address to) internal returns (uint256 need) {
        WeekendOptions.Strategy memory s = _strategyOf(who);
        address token;
        (token, need) = app.collateralFor(id, amount);
        _shipFor(who, token, need, s);
        vm.prank(buyer);
        taker.buy(app, s, id, amount, type(uint256).max, to, abi.encode(who, keccak256(abi.encode(s))));
    }

    /// @dev Two writers, uneven split (3e18/7e18), same golden ITM-CALL settlement (strike 205,
    ///      settlePrice 212, spec §9/§10) as `test_redeemAndClaim_itmCall_matchTheSourceProtocolToTheWei`
    ///      — so `writerUnderlying` is the same known 9669811320754716982, just split across two
    ///      makers instead of claimed whole by one. Each claim is asserted against its own
    ///      hand-computed floor, proving the division actually runs per-writer instead of handing
    ///      back the whole snapshot regardless of who asks.
    function test_claim_twoWriters_unevenSplit_eachGetsOwnFlooredShare() public {
        uint256 id = _callSeries();
        address maker2 = address(0xBEEF2);

        _shipAndBuyFor(id, maker, 3e18, buyer);
        _shipAndBuyFor(id, maker2, 7e18, buyer);
        assertEq(app.getSeries(id).totalWritten, 10e18);

        _recordSettlementAt(212e6);
        app.settle(id);
        assertEq(app.getSeries(id).writerUnderlying, 9669811320754716982);

        (uint256 outU1, uint256 outC1) = app.claimFor(id, maker);
        (uint256 outU2, uint256 outC2) = app.claimFor(id, maker2);

        // Hand-computed: floor(9669811320754716982 * 3e18 / 10e18) and the 7e18 complement.
        assertEq(outU1, 2900943396226415094);
        assertEq(outU2, 6768867924528301887);
        assertEq(outC1, 0); // no exercise ever touched the cash leg of this CALL
        assertEq(outC2, 0);
        assertEq(nvdax.balanceOf(maker), outU1);
        assertEq(nvdax.balanceOf(maker2), outU2);

        // At most 1 wei of floor dust per claimant per leg — here, 1 wei total across both.
        assertEq(app.getSeries(id).writerUnderlying - (outU1 + outU2), 1);
    }

    /// @dev `close`'s `fullMulDiv(poolUnderlying, amount, totalWritten)` has the same blind spot,
    ///      and `Close.t.sol`'s only test (`test_close_returnsProRataOfBothPools`) can never show
    ///      it: for a CALL pre-exercise, `poolUnderlying == totalWritten` identically (both grow
    ///      by the same `amount` on every write and shrink by the same `outU` on every close), so
    ///      that leg's pro-rata is a trivial identity for ANY split, exact or not. Only a PUT's
    ///      cash leg, built through `collateralFor`'s Ceil, can diverge from the write amount —
    ///      and only when a write's size isn't a round multiple does that Ceil actually round.
    ///      Two writers split a 10e18 PUT pool unevenly (1,234567890123456789 /
    ///      8,765432109876543211); writer1's `need` rounds UP by 1 wei at write time, and closing
    ///      their FULL position floors back DOWN — they get back exactly 1 wei LESS than they
    ///      shipped, proof the pro-rata genuinely divides and floors instead of just returning
    ///      the writer's own contribution.
    function test_close_twoWriters_oddSplit_prorataFloors() public {
        uint256 id = app.createSeries(address(nvdax), expiry, Kind.PUT, STRIKE);
        address maker2 = address(0xBEEF2);

        uint256 amt1 = 1_234567890123456789;
        uint256 amt2 = 8_765432109876543211;
        assertEq(amt1 + amt2, 10e18);

        uint256 need1 = _shipAndBuyFor(id, maker, amt1, buyer);
        uint256 need2 = _shipAndBuyFor(id, maker2, amt2, buyer);
        assertEq(need1, 253086418); // ceil(amt1 * 205e6 / 1e18) — rounds UP against the writer
        assertEq(need2, 1796913583);
        assertEq(app.getSeries(id).poolCash, 2050000001);
        assertEq(app.getSeries(id).totalWritten, 10e18);

        OptionToken token = app.getSeries(id).token;
        vm.prank(buyer);
        token.transfer(maker, amt1); // maker buys back their own full position to close it

        uint256 usdc0 = usdc.balanceOf(maker);
        vm.prank(maker);
        app.close(id, amt1);

        // Floored pro-rata, not a round number — 1 wei LESS than `need1`, the ceil they paid in.
        assertEq(usdc.balanceOf(maker) - usdc0, 253086417);
        assertEq(app.getSeries(id).poolCash, 2050000001 - 253086417);
        assertEq(app.getSeries(id).totalWritten, amt2);
    }
}
