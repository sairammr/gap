// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapVM } from "swapvm/interfaces/ISwapVM.sol";

import { DeskFixture } from "../helpers/DeskFixture.sol";
import { WeekendOptions } from "../../src/WeekendOptions.sol";

/// @title DeskPutTest
/// @notice The cash-secured PUT, end to end, on the real `AquaSwapVMRouter` and the real `Aqua`.
///
///        FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/DeskPut.t.sol'
///
/// @dev WHY THIS FILE EXISTS. Every other integration test ships a CALL. The whole venue path —
///      desk hooks, pricer, Aqua ledger, just-in-time write — had never once run with `Kind.PUT`
///      on the other end, and a PUT is not the same trade with a sign flipped: its collateral is
///      the QUOTE token, which is the same token as the premium. That collision is the thing
///      worth testing, and it is load-bearing in three separate places:
///
///      1. `WeekendOptions._collectPremium` snapshots the maker's quote ledger AFTER `AQUA.pull`,
///         precisely because on a PUT the pull drains the very balance the premium is pushed
///         back into. Snapshot it before and the taker is asked to refund the cover as well.
///      2. `WeekendDesk.gapOptionCallback` tops the Aqua allowance up to max rather than to
///         `premiumOwed`, because `AQUA.push` spends the allowance to exactly zero — which on a
///         PUT desk kills the ask side outright, the cover itself being quote.
///      3. The desk's own strategy must ship a NONZERO quote leg (`DESK_SHIP_CASH`). On a CALL
///         that leg is plumbing; on a PUT it is the budget.
///
/// @dev The PUT and CALL series here are identical but for `Kind` — same underlying, expiry and
///      strike — so at r = 0 put-call parity makes their ATM premiums equal. Asserted below
///      rather than assumed: it is a free cross-check that the pricer dispatched on `Kind` at
///      all, which a pinned constant alone would not catch if both branches were wrong together.
contract DeskPutTest is DeskFixture {
    /// @dev Golden quotes, pinned at the fixture's `setUp` timestamp: ATM PUT, 7d, vol 0.6.
    ///      The real numbers the real router returns, not a recomputation of the formula.
    uint256 internal constant EXACT_OUT_OPTIONS = 1e18;
    uint256 internal constant EXACT_OUT_QUOTE = 6793514;
    uint256 internal constant EXACT_IN_QUOTE = 100e6;
    uint256 internal constant EXACT_IN_OPTIONS = 14.719922561431388821e18;

    /// @dev `collateralFor(putId, 1e18)` — the strike notional, which at a 1e18 size is the
    ///      strike itself. A PUT writer locks `size x strike` in quote and nothing else.
    uint256 internal constant COVER_PER_OPTION = STRIKE;

    // ------------------------------------------------------------------ the ask

    /// @dev The whole point: a cash-secured write through the venue, with the quote token doing
    ///      double duty as cover and as premium inside one `router.swap`.
    function test_ask_takerBuysPutsMintedAgainstQuoteCover() public {
        (bytes32 hash, ISwapVM.Order memory o) = shipPutAsk(SERIES_CAP);

        uint256 cashBefore = quote.balanceOf(address(desk));
        uint256 coverBefore = underlying.balanceOf(address(desk));

        (uint256 amountIn, uint256 amountOut) =
            fill(o, EXACT_OUT_OPTIONS, takerTraits(o, address(quote), false, false, 10e6));

        assertEq(amountOut, EXACT_OUT_OPTIONS, "exact-out means the taker gets what it named");
        assertEq(amountIn, EXACT_OUT_QUOTE, "golden PUT quote drifted");

        assertEq(IERC20(putOptionToken).balanceOf(TAKER), amountOut, "taker holds the puts");
        assertEq(putInventory(), 0, "the desk mints to itself and ships the lot");
        assertEq(putWritten(), amountOut, "desk is the writer of record");

        // A PUT locks quote, never the stock. The CALL series shares this desk and this wallet;
        // if cover were taken from the wrong leg, this is where it would show.
        assertEq(underlying.balanceOf(address(desk)), coverBefore, "the stock is untouched on a PUT");

        // Net quote at the desk: it received `amountIn` from the taker and sent `COVER_PER_OPTION`
        // to the protocol as cover. The self-write premium is desk -> desk and nets to zero.
        assertEq(
            int256(quote.balanceOf(address(desk))) - int256(cashBefore),
            int256(amountIn) - int256(COVER_PER_OPTION),
            "desk quote moves by premium in minus cover out"
        );
        assertEq(quote.balanceOf(address(app)), COVER_PER_OPTION, "the protocol holds the cash cover");

        WeekendOptions.Series memory s = app.getSeries(putId);
        assertEq(s.poolCash, COVER_PER_OPTION, "pool cash credited");
        assertEq(s.poolUnderlying, 0, "a PUT pool holds no stock until someone exercises");

        // The venue ledger behaves exactly as it does on a CALL: minting never credits it, so
        // the shipped option leg is the cumulative written cap.
        (uint256 optionLeg, uint256 quoteLeg) =
            aqua.safeBalances(address(desk), address(router), hash, putOptionToken, address(quote));
        assertEq(optionLeg, SERIES_CAP - amountOut, "ledger debited by the full amount out");
        assertEq(quoteLeg, amountIn, "premium credited to the same ledger entry");
    }

    /// @dev Point 1 of the file header, isolated. The desk's OWN strategy quote leg is both the
    ///      cover source and the premium sink; the net must be exactly `premium - cover`. A
    ///      `_collectPremium` that snapshotted before the pull would demand `cover + premium`
    ///      back and revert the fill instead.
    function test_ask_ownStrategyQuoteLegNetsPremiumMinusCover() public {
        (, ISwapVM.Order memory o) = shipPutAsk(SERIES_CAP);
        bytes32 ownHash = desk.ownStrategyHash();

        (uint248 before_,) = aqua.rawBalances(address(desk), address(app), ownHash, address(quote));
        assertEq(before_, DESK_SHIP_CASH, "the own strategy ships a real quote budget, not plumbing");

        fill(o, EXACT_OUT_OPTIONS, takerTraits(o, address(quote), false, false, 10e6));

        (uint248 after_,) = aqua.rawBalances(address(desk), address(app), ownHash, address(quote));

        // The taker's premium lands in the desk's WALLET, not this ledger entry; what is pushed
        // back here is the self-write premium, priced at `VOL_SELF`.
        assertLt(after_, before_, "cover left the own-strategy quote leg");
        assertEq(
            before_ - after_,
            COVER_PER_OPTION - _selfPremium(EXACT_OUT_OPTIONS),
            "net is cover out minus the self-write premium pushed back"
        );
    }

    /// @dev Exact-in on a PUT ask. Worth its own case even though the register branch is shared
    ///      with the CALL: here the option count is DERIVED from the quote the taker named, and
    ///      the cover is `ceil(derived * strike / 1e18)` of that same token. The two roundings
    ///      meet nowhere else, and a desk that collected less cover than it owed would still
    ///      look like a clean fill from the outside.
    function test_ask_exactInDerivesTheSizeAndStillTakesFullCover() public {
        (, ISwapVM.Order memory o) = shipPutAsk(SERIES_CAP);

        (uint256 amountIn, uint256 amountOut) =
            fill(o, EXACT_IN_QUOTE, takerTraits(o, address(quote), true, false, 0));

        assertEq(amountIn, EXACT_IN_QUOTE, "exact-in means the taker pays exactly what it named");
        assertEq(amountOut, EXACT_IN_OPTIONS, "golden PUT quote drifted");

        (, uint256 need) = app.collateralFor(putId, amountOut);
        assertEq(quote.balanceOf(address(app)), need, "the protocol holds the full ceil'd cover");
        assertEq(app.getSeries(putId).poolCash, need, "pool cash matches what actually arrived");
        assertEq(putWritten(), amountOut, "written matches the derived size exactly");
    }

    /// @dev Point 3. Strip the quote budget and the PUT ask fails solvency BEFORE anything
    ///      moves, with the core's own legible error rather than deep inside Aqua.
    function test_ask_revertsLegiblyWhenTheOwnStrategyQuoteLegIsExhausted() public {
        // A fresh desk-side strategy whose quote leg is empty: same shape as the fixture's, one
        // different salt, so it hashes to its own ledger entry.
        WeekendOptions.Strategy memory s = ownStrategy();
        s.salt = bytes32(uint256(0xDEAD));

        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (address(underlying), DESK_COVER);
        (tokens[1], amounts[1]) = (address(quote), 0);
        desk.ship(address(app), abi.encode(s), tokens, amounts);
        desk.setOwnStrategy(s);

        (, ISwapVM.Order memory o) = shipPutAsk(SERIES_CAP);

        vm.prank(TAKER);
        vm.expectRevert(WeekendOptions.InsufficientMakerCollateral.selector);
        router.swap(o, EXACT_OUT_OPTIONS, takerTraits(o, address(quote), false, false, 10e6));
    }

    // ------------------------------------------------------------------ the bid

    function test_bid_deskBuysPutsBackAndClosesTheShort() public {
        _stockTheTaker(EXACT_OUT_OPTIONS);
        assertEq(putWritten(), EXACT_OUT_OPTIONS, "desk is short one put");

        (, ISwapVM.Order memory b) = shipPutBid(100_000e6);

        uint256 cashBefore = quote.balanceOf(address(desk));

        (uint256 amountIn, uint256 amountOut) =
            fill(b, EXACT_OUT_OPTIONS, takerTraits(b, putOptionToken, true, false, 0));

        assertEq(amountIn, EXACT_OUT_OPTIONS, "taker delivered every put it held");
        assertGt(amountOut, 0, "taker was paid");
        assertLt(amountOut, EXACT_OUT_QUOTE, "the desk must not buy back above its own offer");

        // `close` burns the desk's own short and releases the cash cover straight to its wallet.
        // The opposite pool leg is still empty here, so the close guard does not trip.
        assertEq(putWritten(), 0, "short fully unwound");
        assertEq(putInventory(), 0, "nothing kept as inventory; close landed");
        assertEq(IERC20(putOptionToken).totalSupply(), 0, "the options are burned, not parked");

        WeekendOptions.Series memory s = app.getSeries(putId);
        assertEq(s.poolCash, 0, "cover released");
        assertEq(quote.balanceOf(address(app)), 0, "the protocol holds nothing");

        // Cover back in, bid paid out.
        assertEq(
            int256(quote.balanceOf(address(desk))) - int256(cashBefore),
            int256(COVER_PER_OPTION) - int256(amountOut),
            "desk quote moves by cover released minus the bid paid"
        );
    }

    /// @dev The desk's spread is vol and nothing else, on this side too.
    function test_bid_isBelowTheAskAndParityHoldsAgainstTheCall() public {
        (, ISwapVM.Order memory putAsk) = shipPutAsk(SERIES_CAP);
        (, ISwapVM.Order memory callAsk) = shipAsk(SERIES_CAP);

        (uint256 putPaid,) = previewFill(putAsk, EXACT_OUT_OPTIONS, takerTraits(putAsk, address(quote), false, false, 10e6));
        (uint256 callPaid,) =
            previewFill(callAsk, EXACT_OUT_OPTIONS, takerTraits(callAsk, address(quote), false, false, 10e6));

        assertEq(putPaid, EXACT_OUT_QUOTE, "golden PUT quote drifted");
        // r = 0 and the two series are identical but for `Kind`, so C - P = S - K = 0.
        assertEq(putPaid, callPaid, "put-call parity broken at the money");

        // Fill the ask already shipped above rather than `_stockTheTaker` — `Aqua.ship` is
        // immutable per hash (fixture fact 5), so re-shipping the same salt reverts.
        fill(putAsk, EXACT_OUT_OPTIONS, takerTraits(putAsk, address(quote), false, false, 10e6));
        (, ISwapVM.Order memory b) = shipPutBid(100_000e6);
        (, uint256 bidGot) = previewFill(b, EXACT_OUT_OPTIONS, takerTraits(b, putOptionToken, true, false, 0));

        assertLt(bidGot, putPaid, "bid below ask");
    }

    // ------------------------------------------------------------------ exercise

    /// @dev The physical leg, from a position opened through the venue. Reads no oracle: the
    ///      holder delivers the stock and names the price by taking the strike in cash.
    function test_exercise_holderDeliversStockAndTakesTheStrikeInCash() public {
        _stockTheTaker(EXACT_OUT_OPTIONS);

        underlying.mint(TAKER, EXACT_OUT_OPTIONS);
        uint256 cashBefore = quote.balanceOf(TAKER);

        vm.startPrank(TAKER);
        underlying.approve(address(app), type(uint256).max);
        app.exercise(putId, EXACT_OUT_OPTIONS);
        vm.stopPrank();

        assertEq(underlying.balanceOf(TAKER), 0, "the stock was delivered");
        assertEq(quote.balanceOf(TAKER) - cashBefore, COVER_PER_OPTION, "the holder took the strike in cash");
        assertEq(IERC20(putOptionToken).balanceOf(TAKER), 0, "the puts are burned");

        WeekendOptions.Series memory s = app.getSeries(putId);
        assertEq(s.poolUnderlying, EXACT_OUT_OPTIONS, "the stock landed in the pool");
        assertEq(s.poolCash, 0, "the cash left it");
        assertEq(quote.balanceOf(address(app)), 0, "no quote stranded in the protocol");
        assertEq(underlying.balanceOf(address(app)), EXACT_OUT_OPTIONS, "the stock is held against the short");
    }

    /// @dev Once anyone exercises, `close` is barred for the rest of the series' life
    ///      (`CloseAfterExercise`, a deliberate liveness-for-value trade). The desk must keep
    ///      filling its bid anyway — it absorbs the revert and parks the options as inventory.
    function test_bid_survivesTheCloseGuardOnAPutAndKeepsTheOptionsAsInventory() public {
        // Two puts: one exercised to trip the guard, one left to sell back.
        _stockTheTaker(2e18);

        underlying.mint(TAKER, 1e18);
        vm.startPrank(TAKER);
        underlying.approve(address(app), type(uint256).max);
        app.exercise(putId, 1e18);
        vm.stopPrank();

        assertGt(app.getSeries(putId).poolUnderlying, 0, "the opposite leg is now non-empty");

        uint256 shortBefore = putWritten();
        (, ISwapVM.Order memory b) = shipPutBid(100_000e6);

        (, uint256 amountOut) = fill(b, 1e18, takerTraits(b, putOptionToken, true, false, 0));

        assertGt(amountOut, 0, "the taker is still paid");
        assertEq(putWritten(), shortBefore, "close reverted, so the short is unchanged");
        assertEq(putInventory(), 1e18, "the options are kept as inventory instead of burned");
    }

    // ------------------------------------------------------------------ one desk, two series

    /// @dev One desk, one own-strategy, two series of opposite `Kind` on the same underlying.
    ///      Each side must take cover from its own leg and account its short separately.
    function test_oneDeskServesBothKindsWithoutCrossingCollateral() public {
        (, ISwapVM.Order memory putAsk) = shipPutAsk(SERIES_CAP);
        (, ISwapVM.Order memory callAsk) = shipAsk(SERIES_CAP);

        fill(putAsk, EXACT_OUT_OPTIONS, takerTraits(putAsk, address(quote), false, false, 10e6));
        fill(callAsk, EXACT_OUT_OPTIONS, takerTraits(callAsk, address(quote), false, false, 10e6));

        assertEq(putWritten(), EXACT_OUT_OPTIONS, "put short booked to the put series");
        assertEq(written(), EXACT_OUT_OPTIONS, "call short booked to the call series");

        // The CALL took stock, the PUT took cash. Neither reached for the other's leg.
        assertEq(underlying.balanceOf(address(app)), EXACT_OUT_OPTIONS, "exactly the call's cover in stock");
        assertEq(quote.balanceOf(address(app)), COVER_PER_OPTION, "exactly the put's cover in cash");
        assertEq(app.getSeries(callId).poolUnderlying, EXACT_OUT_OPTIONS, "call pool holds stock");
        assertEq(app.getSeries(callId).poolCash, 0, "call pool holds no cash yet");
        assertEq(app.getSeries(putId).poolCash, COVER_PER_OPTION, "put pool holds cash");
        assertEq(app.getSeries(putId).poolUnderlying, 0, "put pool holds no stock yet");
    }

    /// @dev The Aqua ledger binds a PUT ask exactly as it binds a CALL one, and it binds
    ///      cumulatively: the fill that crosses the shipped cap is the one that reverts.
    function test_ask_theShippedOptionLegIsTheCumulativeCap() public {
        (, ISwapVM.Order memory o) = shipPutAsk(2e18);

        fill(o, 1e18, takerTraits(o, address(quote), false, false, 10e6));
        fill(o, 1e18, takerTraits(o, address(quote), false, false, 10e6));
        assertEq(putWritten(), 2e18, "two fills, two options written");

        vm.prank(TAKER);
        vm.expectRevert();
        router.swap(o, 1, takerTraits(o, address(quote), false, false, 10e6));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Give `TAKER` `amount` puts, written by the desk through the venue.
    function _stockTheTaker(uint256 amount) private {
        (, ISwapVM.Order memory o) = shipPutAsk(SERIES_CAP);
        fill(o, amount, takerTraits(o, address(quote), false, false, 1000e6));
    }

    /// @dev What the desk pays itself for `amount` options at `VOL_SELF`. Read off the pricer
    ///      rather than recomputed, so this helper cannot drift from the thing it describes.
    function _selfPremium(uint256 amount) private view returns (uint256) {
        return (pricer.premiumPerOption(putId, VOL_SELF) * amount) / 1e18;
    }
}
