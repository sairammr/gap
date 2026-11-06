// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";
import { ISwapVM } from "swapvm/interfaces/ISwapVM.sol";

import { DeskFixture } from "../helpers/DeskFixture.sol";

/// @title DeskOrdering
/// @notice Owns Review Focus #3 / spec §12.7: `IS_FIRST_TRANSFER_FROM_TAKER` (`0x0020`) is a
///         **taker** trait. The maker cannot force it, cannot forbid it, and cannot see it
///         coming. Unset — the common case — SwapVM runs `_transferOut` BEFORE `_transferIn`,
///         so the desk mints and ships option tokens before a single quote unit of premium has
///         landed. Set, the premium arrives first.
///
/// @dev Every hook case below is run TWICE against the same fresh state — once each way — and
///      the two end states are compared field by field. The invariant is not "both orderings
///      succeed"; it is "both orderings are indistinguishable afterwards". A hook that read a
///      balance only the counter-leg puts there would still pass a liveness test and fail here.
///
///      Mechanism: `vm.snapshotState()` before the scenario, `vm.revertToState()` after. Memory
///      survives the revert, so the recorded `End` outlives the state it was taken from and the
///      second ordering starts from byte-identical state rather than from a replayed `setUp`.
///
///        FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/DeskOrdering.t.sol'
contract DeskOrderingTest is DeskFixture {
    /// @dev Everything a fill can move. If the ordering flag leaks anywhere, it leaks here.
    /// @dev `keccak256("Transfer(address,address,uint256)")`.
    bytes32 private constant TRANSFER = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    struct End {
        uint256 amountIn;
        uint256 amountOut;
        uint256 written;
        uint256 inventory; // desk's option balance
        uint256 takerOptions;
        uint256 takerQuote;
        uint256 deskQuote;
        uint256 deskUnderlying; // collateral locked by the self-write
        uint256 ledgerSell; // Aqua leg the maker is selling down
        uint256 ledgerZero; // the mirror leg, present only for `safeBalances`
    }

    // ------------------------------------------------------------------ the two liveness cases

    /// @dev Plan Task 9, step 1. Premium first — the friendlier ordering.
    function test_buyWorksWithTheTakerPayingFirst() public {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
        (uint256 amountIn, uint256 amountOut) = fill(o, 100e6, takerTraits(o, address(quote), true, true, 0));
        assertEq(amountIn, 100e6, "exact-in pays exactly");
        assertGt(amountOut, 0, "taker got options");
    }

    /// @dev The DEFAULT, and the one that matters: the desk mints and ships before it is paid.
    function test_buyWorksWithTheDeskShippingFirst() public {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
        (uint256 amountIn, uint256 amountOut) = fill(o, 100e6, takerTraits(o, address(quote), true, false, 0));
        assertEq(amountIn, 100e6, "exact-in pays exactly");
        assertGt(amountOut, 0, "taker got options");
    }

    /// @dev THE GUARD ON EVERY OTHER TEST IN THIS FILE. Each equivalence test asserts two runs
    ///      are identical; that assertion is worth nothing unless the two runs actually differed.
    ///      Here the real `Transfer` logs of one ask fill are read back and the premium leg is
    ///      shown to cross before the option leg with the flag set, and after it with the flag
    ///      clear. If SwapVM ever stops honouring `0x0020`, this fails and the rest of the file
    ///      goes quietly, uselessly green.
    function test_theFlagActuallyFlipsTheTransferOrder() public {
        (int256 premiumAt, int256 optionAt) = _legOrder(true);
        assertTrue(premiumAt >= 0 && optionAt >= 0, "takerFirst: both legs must appear");
        assertLt(premiumAt, optionAt, "takerFirst = true: premium must cross first");

        (premiumAt, optionAt) = _legOrder(false);
        assertTrue(premiumAt >= 0 && optionAt >= 0, "deskFirst: both legs must appear");
        assertGt(premiumAt, optionAt, "takerFirst = false: the desk must ship before it is paid");
    }

    /// @dev Log indices of the two legs of one ask fill, or -1 if a leg never appeared.
    function _legOrder(bool takerFirst) private returns (int256 premiumAt, int256 optionAt) {
        uint256 snap = vm.snapshotState();
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
        bytes memory tt = takerTraits(o, address(quote), true, takerFirst, 0);

        vm.recordLogs();
        fill(o, 100e6, tt);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (premiumAt, optionAt) = (-1, -1);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 3 || logs[i].topics[0] != TRANSFER) continue;
            address from = address(uint160(uint256(logs[i].topics[1])));
            address to = address(uint160(uint256(logs[i].topics[2])));
            // The premium leaving the taker, and the options arriving at it. The desk's own
            // self-write moves quote too, which is why `from == TAKER` is part of the match.
            if (premiumAt < 0 && logs[i].emitter == address(quote) && from == TAKER) premiumAt = int256(i);
            if (optionAt < 0 && logs[i].emitter == optionToken && to == TAKER) optionAt = int256(i);
        }
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ equivalence

    function test_askExactInIsIdenticalUnderBothOrderings() public {
        _assertSame(_ask(true, true, 100e6), _ask(false, true, 100e6), "ask exact-in");
    }

    function test_askExactOutIsIdenticalUnderBothOrderings() public {
        _assertSame(_ask(true, false, 10e18), _ask(false, false, 10e18), "ask exact-out");
    }

    /// @dev Two fills of ONE order hash. The second mints against a ledger the first already
    ///      drew down and against `written` the first already raised, so a hook that only looks
    ///      right on a virgin order shows up here.
    function test_askPartialFillsAreIdenticalUnderBothOrderings() public {
        _assertSame(_askTwice(true), _askTwice(false), "ask partial fills");
    }

    /// @dev The bid runs the OTHER hook (`postTransferIn`), and runs it on the leg where the
    ///      desk is paying out. With the flag unset the desk pays the taker before the options
    ///      arrive; `_tryClose` must therefore close against `written`, never against a balance.
    function test_bidIsIdenticalUnderBothOrderings() public {
        _assertSame(_bid(true, 5e18), _bid(false, 5e18), "bid");
    }

    function test_bidPartialFillsAreIdenticalUnderBothOrderings() public {
        _assertSame(_bidTwice(true), _bidTwice(false), "bid partial fills");
    }

    // ------------------------------------------------------------------ scenarios

    /// @dev One ask fill on a fresh ship. `takerFirst` is the only thing that varies.
    function _ask(bool takerFirst, bool exactIn, uint256 amount) internal returns (End memory e) {
        uint256 snap = vm.snapshotState();
        (bytes32 h, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
        (e.amountIn, e.amountOut) = fill(o, amount, takerTraits(o, address(quote), exactIn, takerFirst, 0));
        _record(e, h, optionToken, address(quote));
        vm.revertToState(snap);
    }

    function _askTwice(bool takerFirst) internal returns (End memory e) {
        uint256 snap = vm.snapshotState();
        (bytes32 h, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
        bytes memory tt = takerTraits(o, address(quote), true, takerFirst, 0);
        (uint256 in1, uint256 out1) = fill(o, 100e6, tt);
        (uint256 in2, uint256 out2) = fill(o, 100e6, tt);
        (e.amountIn, e.amountOut) = (in1 + in2, out1 + out2);
        _record(e, h, optionToken, address(quote));
        vm.revertToState(snap);
    }

    /// @dev Sell-back. The taker is stocked by an ask fill pinned to ONE ordering — only the
    ///      bid under test varies — so any difference the assertions find belongs to the bid.
    function _bid(bool takerFirst, uint256 amount) internal returns (End memory e) {
        uint256 snap = vm.snapshotState();
        _stockTheTaker();
        (bytes32 h, ISwapVM.Order memory o) = shipBid(1_000e6);
        (e.amountIn, e.amountOut) = fill(o, amount, takerTraits(o, optionToken, true, takerFirst, 0));
        _record(e, h, address(quote), optionToken);
        vm.revertToState(snap);
    }

    function _bidTwice(bool takerFirst) internal returns (End memory e) {
        uint256 snap = vm.snapshotState();
        _stockTheTaker();
        (bytes32 h, ISwapVM.Order memory o) = shipBid(1_000e6);
        bytes memory tt = takerTraits(o, optionToken, true, takerFirst, 0);
        (uint256 in1, uint256 out1) = fill(o, 2e18, tt);
        (uint256 in2, uint256 out2) = fill(o, 2e18, tt);
        (e.amountIn, e.amountOut) = (in1 + in2, out1 + out2);
        _record(e, h, address(quote), optionToken);
        vm.revertToState(snap);
    }

    /// @dev Give `TAKER` options to sell back. Exact-out so the stock is a round number and the
    ///      bid scenarios start from identical inventory whichever way the bid then runs.
    function _stockTheTaker() private {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
        fill(o, 10e18, takerTraits(o, address(quote), false, false, 0));
    }

    // ------------------------------------------------------------------ record / compare

    function _record(End memory e, bytes32 strategyHash, address sell, address zero) private view {
        e.written = written();
        e.inventory = inventory();
        e.takerOptions = IERC20(optionToken).balanceOf(TAKER);
        e.takerQuote = quote.balanceOf(TAKER);
        e.deskQuote = quote.balanceOf(address(desk));
        e.deskUnderlying = underlying.balanceOf(address(desk));
        (e.ledgerSell, e.ledgerZero) = aqua.safeBalances(address(desk), address(router), strategyHash, sell, zero);
    }

    /// @dev `takerFirst = true` is `a`, `false` is `b`. A failure here is a finding about the
    ///      desk, not about this file: it means a hook depended on the counter-leg having
    ///      already landed.
    function _assertSame(End memory a, End memory b, string memory what) private pure {
        assertEq(a.amountIn, b.amountIn, string.concat(what, ": amountIn"));
        assertEq(a.amountOut, b.amountOut, string.concat(what, ": amountOut"));
        assertEq(a.written, b.written, string.concat(what, ": written"));
        assertEq(a.inventory, b.inventory, string.concat(what, ": desk inventory"));
        assertEq(a.takerOptions, b.takerOptions, string.concat(what, ": taker options"));
        assertEq(a.takerQuote, b.takerQuote, string.concat(what, ": taker quote"));
        assertEq(a.deskQuote, b.deskQuote, string.concat(what, ": desk quote"));
        assertEq(a.deskUnderlying, b.deskUnderlying, string.concat(what, ": desk underlying"));
        assertEq(a.ledgerSell, b.ledgerSell, string.concat(what, ": aqua ledger, sell leg"));
        assertEq(a.ledgerZero, b.ledgerZero, string.concat(what, ": aqua ledger, zero leg"));
        // A no-op scenario would satisfy every line above. It did not happen.
        assertGt(a.amountIn, 0, string.concat(what, ": nothing was filled"));
        assertGt(a.amountOut, 0, string.concat(what, ": nothing was filled"));
    }
}
