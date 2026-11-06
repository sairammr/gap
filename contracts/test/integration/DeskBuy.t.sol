// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapVM } from "swapvm/interfaces/ISwapVM.sol";

import { DeskFixture } from "../helpers/DeskFixture.sol";

/// @title DeskBuyTest
/// @notice The ask path, end to end, on the real `AquaSwapVMRouter` and the real `Aqua`.
///
/// @dev §12.8: nothing in the fork exercises maker hooks together with an Aqua order. This is
///      that test. Every fill below is an actual `router.swap(...)`; the only doubles in scope
///      are the v4 `StateView` lens and, through it, the price the real `V4SpotOracle` reports.
///
///        FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/DeskBuy.t.sol'
///
/// @dev One fill chains four contracts that have never met: the router runs the maker's program,
///      `WeekendPricer` fills the missing amount register, the router calls `preTransferOut` on
///      the desk, which mints just-in-time through `WeekendOptions.buyOption` against its own
///      third Aqua strategy, and only then does `AQUA.pull` move the fresh tokens out. The
///      minted tokens are pullable solely because `pull` is a real `transferFrom`; the ledger
///      still decrements from the amount shipped, which is why the shipped option leg is the
///      cumulative cap and `approveAqua` is mandatory (review focus 5).
contract DeskBuyTest is DeskFixture {
    /// @dev Golden quote, pinned at the fixture's `setUp` timestamp: ATM CALL, 7d, vol 0.6.
    ///      These are the real numbers the real router returns, not a recomputation of the
    ///      pricer's formula — pinning them is what makes a silent repricing fail loudly.
    uint256 internal constant EXACT_IN_QUOTE = 100e6;
    uint256 internal constant EXACT_IN_OPTIONS = 14.719922561431388821e18;
    uint256 internal constant EXACT_OUT_OPTIONS = 1e18;
    uint256 internal constant EXACT_OUT_QUOTE = 6793514;

    // ------------------------------------------------------------------ exact in

    function test_exactIn_takerPaysQuoteAndReceivesOptionsMintedJustInTime() public {
        (bytes32 hash, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        uint256 coverBefore = underlying.balanceOf(address(desk));

        (uint256 amountIn, uint256 amountOut) =
            fill(o, EXACT_IN_QUOTE, takerTraits(o, address(quote), true, false, 0));

        assertEq(amountIn, EXACT_IN_QUOTE, "exact-in means the taker pays exactly what it named");
        assertEq(amountOut, EXACT_IN_OPTIONS, "golden quote drifted");

        // Option tokens are ERC-20, one contract per series.
        assertEq(IERC20(optionToken).balanceOf(TAKER), amountOut, "taker holds the options");
        assertEq(inventory(), 0, "the desk mints to itself and ships the lot; nothing is left over");

        // The desk is the writer of record, and a CALL's collateral is the underlying 1:1.
        assertEq(written(), amountOut, "desk is the writer of record");
        assertEq(coverBefore - underlying.balanceOf(address(desk)), amountOut, "cover locked 1:1");

        // Minting does not credit the ledger: the option leg decrements from the shipped cap.
        (uint256 optionLeg, uint256 quoteLeg) =
            aqua.safeBalances(address(desk), address(router), hash, optionToken, address(quote));
        assertEq(optionLeg, SERIES_CAP - amountOut, "ledger debited by the full amount out");
        assertEq(quoteLeg, amountIn, "premium credited to the same ledger entry");
    }

    // ------------------------------------------------------------------ exact out

    function test_exactOut_takerNamesTheOptionCountAndPaysTheCeiling() public {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        // Threshold is `maxIn` here. A literal 0 would mean "no threshold", not "free".
        (uint256 amountIn, uint256 amountOut) =
            fill(o, EXACT_OUT_OPTIONS, takerTraits(o, address(quote), false, false, 10e6));

        assertEq(amountOut, EXACT_OUT_OPTIONS, "exact-out means the taker gets exactly what it named");
        assertEq(amountIn, EXACT_OUT_QUOTE, "golden quote drifted");
        assertEq(IERC20(optionToken).balanceOf(TAKER), EXACT_OUT_OPTIONS, "taker holds the options");
        assertEq(written(), EXACT_OUT_OPTIONS, "desk wrote exactly one option");
    }

    // ------------------------------------------------------------------ the premium

    function test_premiumLandsAtTheDeskAndBacksTheNextWrite() public {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        uint256 cashBefore = quote.balanceOf(address(desk));

        (uint256 amountIn,) = fill(o, EXACT_IN_QUOTE, takerTraits(o, address(quote), true, false, 0));

        // The self-write's premium leg is desk -> desk and nets to zero, so the taker's premium
        // is the only quote that moved. It sits in the desk's wallet, which is exactly where
        // the NEXT self-write needs it: `gapOptionCallback` pushes out of this balance.
        assertEq(quote.balanceOf(address(desk)) - cashBefore, amountIn, "premium banked at the desk");

        // And it really does back the next write — the fill below is a second full round trip
        // through `buyOption`, which would revert if the first had eaten the quote balance or
        // (the bug fixed in 683b60d) burned the standing Aqua allowance down to zero.
        uint256 writtenBefore = written();
        (uint256 amountIn2, uint256 amountOut2) =
            fill(o, EXACT_IN_QUOTE, takerTraits(o, address(quote), true, false, 0));

        assertEq(written() - writtenBefore, amountOut2, "second write landed");
        assertEq(quote.balanceOf(address(desk)) - cashBefore, amountIn + amountIn2, "both premiums banked");
    }

    // ------------------------------------------------------------------ inventory

    function test_inventoryIsSpentBeforeMinting() public {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        // Give the desk inventory the plain way: a holder sends options back to it. (The bid
        // side is Task 10's; this test is about `_mintShortfall`, not about how stock arrives.)
        fill(o, EXACT_IN_QUOTE, takerTraits(o, address(quote), true, false, 0));
        uint256 stock = 5e18;
        vm.prank(TAKER);
        IERC20(optionToken).transfer(address(desk), stock);
        assertEq(inventory(), stock, "desk is holding stock");

        uint256 writtenBefore = written();
        uint256 coverBefore = underlying.balanceOf(address(desk));

        (, uint256 amountOut) = fill(o, EXACT_IN_QUOTE, takerTraits(o, address(quote), true, false, 0));

        assertGt(amountOut, stock, "the fill has to be bigger than the stock or this proves nothing");
        assertEq(written() - writtenBefore, amountOut - stock, "minted only the shortfall");
        assertEq(coverBefore - underlying.balanceOf(address(desk)), amountOut - stock, "locked only the shortfall");
        assertEq(inventory(), 0, "stock was spent, not stockpiled");
        assertEq(IERC20(optionToken).balanceOf(TAKER), EXACT_IN_OPTIONS - stock + amountOut, "taker still paid in full");
    }

    // ------------------------------------------------------------------ partials

    function test_partialFillsAccumulateAgainstOneOrderHash() public {
        (bytes32 hash, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        uint256 totalIn;
        uint256 totalOut;
        for (uint256 i; i < 3; ++i) {
            (uint256 amountIn, uint256 amountOut) = fill(o, 50e6, takerTraits(o, address(quote), true, false, 0));
            totalIn += amountIn;
            totalOut += amountOut;

            // Every leg of the accounting tracks the running total, not the last fill.
            assertEq(written(), totalOut, "written accumulates");
            assertEq(IERC20(optionToken).balanceOf(TAKER), totalOut, "taker balance accumulates");

            (uint256 optionLeg, uint256 quoteLeg) =
                aqua.safeBalances(address(desk), address(router), hash, optionToken, address(quote));
            assertEq(optionLeg, SERIES_CAP - totalOut, "the ledger is the cumulative cap, not a per-fill one");
            assertEq(quoteLeg, totalIn, "premiums accumulate on the same entry");
        }

        assertEq(totalIn, 150e6, "three 50e6 fills");
        // Three halves of the golden quote, within the rounding the pricer floors away.
        assertApproxEqAbs(totalOut, (EXACT_IN_OPTIONS * 3) / 2, 1e6, "same price across fills");
    }

    // ------------------------------------------------------------------ preview

    function test_previewFillMatchesTheRealFill() public {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        bytes memory ttIn = takerTraits(o, address(quote), true, false, 0);
        (uint256 pIn, uint256 pOut) = previewFill(o, EXACT_IN_QUOTE, ttIn);
        (uint256 aIn, uint256 aOut) = fill(o, EXACT_IN_QUOTE, ttIn);
        assertEq(pIn, aIn, "exact-in: quoted amountIn");
        assertEq(pOut, aOut, "exact-in: quoted amountOut");

        bytes memory ttOut = takerTraits(o, address(quote), false, false, 10e6);
        (uint256 qIn, uint256 qOut) = previewFill(o, EXACT_OUT_OPTIONS, ttOut);
        (uint256 bIn, uint256 bOut) = fill(o, EXACT_OUT_OPTIONS, ttOut);
        assertEq(qIn, bIn, "exact-out: quoted amountIn");
        assertEq(qOut, bOut, "exact-out: quoted amountOut");

        // `quote` runs the same program but must not move anything: if it had, the second fill
        // would price off a ledger the preview had already drained.
        assertEq(written(), aOut + bOut, "only the two real fills wrote");
    }
}
