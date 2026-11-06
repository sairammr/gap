// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { stdError } from "forge-std/StdError.sol";

import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapVM } from "swapvm/interfaces/ISwapVM.sol";

import { WeekendOptions } from "../../src/WeekendOptions.sol";
import { WeekendTaker } from "../../src/WeekendTaker.sol";
import { WeekendDesk } from "../../src/desk/WeekendDesk.sol";
import { DeskFixture } from "../helpers/DeskFixture.sol";

/// @title DeskSellTest
/// @notice The BID path, end to end, on the real `AquaSwapVMRouter` and the real `Aqua`: a taker
///         delivers option tokens and walks away with quote, and the desk buys its own short
///         back in.
///
///        FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/DeskSell.t.sol'
///
/// @dev The bid is the ask run backwards through the OTHER hook. `postTransferIn` gets the
///      options after they have landed and calls `_tryClose`, which burns at most
///      `min(amountIn, written[id][desk])` against the desk's own written position and unlocks
///      the collateral behind it. Everything it cannot close stays in the wallet as inventory
///      and is spent by the next ask instead of being minted — same economics, no new short.
///
/// @dev THE REASON `_tryClose` TOLERATES A REVERT. `WeekendOptions.close` refuses once the
///      opposite pool leg is non-empty (`poolCash != 0` on a CALL, spec §10 / RULING 13), and
///      only `exercise` ever credits that leg pre-expiry. So the FIRST exercise anywhere in a
///      series shuts early unwind for the rest of that series's life — permanently, by design.
///      A desk that required `close` to succeed would have its whole bid side go dark at that
///      moment. `test_sellBackStillWorksAfterAHolderHasExercised` is that scenario, and it is
///      the test this file exists for.
contract DeskSellTest is DeskFixture {
    /// @dev Golden quotes, pinned at the fixture's `setUp` timestamp: ATM CALL, 7d. The ask
    ///      prices at `VOL_ASK` (0.6), the bid at `VOL_BID` (0.4) — one option, both sides.
    ///      Pinned so a silent repricing fails loudly rather than quietly widening the spread.
    uint256 internal constant BID_UNIT = 4529737; // quote paid for 1e18 options on the bid
    uint256 internal constant ASK_UNIT = 6793514; // quote charged for 1e18 options on the ask

    /// @dev A quote budget far past anything a single test spends; the binding cap is the wallet
    ///      only in `test_manySmallSellBacksCannotDrainPastTheShippedBudget`, which ships tight.
    uint256 internal constant BID_BUDGET = 1_000e6;

    /// @dev A second, independent writer. Options bought from ALICE are ones the desk never
    ///      wrote, which is the only honest way to hand the bid more than `written` to close.
    address internal constant ALICE = address(0xA11CE);
    bytes32 internal constant ALICE_SALT = bytes32(uint256(0xA11CE));

    /// @dev Lets `TAKER` (an EOA) buy from ALICE: `buyOption` calls `IGapOptionCallback` back on
    ///      `msg.sender`, so an EOA can never be the buyer directly.
    WeekendTaker internal weekendTaker;

    function setUp() public override {
        super.setUp();
        weekendTaker = new WeekendTaker(IAqua(address(aqua)), address(app));
    }

    // ------------------------------------------------------------------ the plain sell-back

    /// @notice A holder sells options back and is paid quote; the desk unwinds the short.
    function test_holderSellsOptionsBackAndReceivesQuote() public {
        _stockTheTaker(5e18);

        (bytes32 hash, ISwapVM.Order memory o) = shipBid(BID_BUDGET);

        uint256 takerOptionsBefore = IERC20(optionToken).balanceOf(TAKER);
        uint256 takerQuoteBefore = quote.balanceOf(TAKER);
        uint256 deskQuoteBefore = quote.balanceOf(address(desk));
        uint256 deskCoverBefore = underlying.balanceOf(address(desk));
        uint256 writtenBefore = written();

        (uint256 amountIn, uint256 amountOut) =
            fill(o, 2e18, takerTraits(o, optionToken, true, false, 0));

        assertEq(amountIn, 2e18, "exact-in means the taker delivers exactly what it named");
        assertEq(amountOut, 2 * BID_UNIT, "golden bid quote drifted");

        // The taker's side: options out, quote in.
        assertEq(takerOptionsBefore - IERC20(optionToken).balanceOf(TAKER), amountIn, "options left the taker");
        assertEq(quote.balanceOf(TAKER) - takerQuoteBefore, amountOut, "taker was paid");

        // The desk's side. The quote comes out of its own WALLET (`AQUA.pull` is a real
        // `transferFrom`); the Aqua entry is the ledger that bounds it, not the source of funds.
        assertEq(deskQuoteBefore - quote.balanceOf(address(desk)), amountOut, "desk paid from its own wallet");
        (uint256 quoteLeg, uint256 optionLeg) =
            aqua.safeBalances(address(desk), address(router), hash, address(quote), optionToken);
        assertEq(quoteLeg, BID_BUDGET - amountOut, "quote leg debited by the payout");
        assertEq(optionLeg, amountIn, "the delivered options credited to the same entry");

        // `postTransferIn` -> `_tryClose` -> `close`: the desk's own tokens are burned against
        // its written position and the collateral behind them comes straight back.
        assertEq(writtenBefore - written(), amountIn, "written unwound by the full amount in");
        assertEq(underlying.balanceOf(address(desk)) - deskCoverBefore, amountIn, "cover unlocked 1:1");
        assertEq(inventory(), 0, "a full close leaves nothing behind");
    }

    // ------------------------------------------------------------------ partial close

    /// @notice `_tryClose` closes at most `min(amountIn, written[id][desk])`. The excess is not a
    ///         failure — it is inventory.
    /// @dev The surplus options are ALICE's, written against ALICE's collateral. `close` can only
    ///      burn against the caller's own `written`, so a desk that closed the lot would be
    ///      unwinding someone else's short; a desk that insisted on closing the lot would reject
    ///      a perfectly good fill.
    function test_sellBackBeyondWhatTheDeskWroteIsHeldAsInventoryNotClosed() public {
        _stockTheTaker(2e18); // written by the DESK
        _aliceWrites(3e18); // written by someone else entirely

        uint256 deskWrote = written();
        assertEq(deskWrote, 2e18, "the desk is short only its own two");
        assertEq(IERC20(optionToken).balanceOf(TAKER), 5e18, "the taker holds more than the desk wrote");

        (, ISwapVM.Order memory o) = shipBid(BID_BUDGET);
        uint256 deskCoverBefore = underlying.balanceOf(address(desk));

        (uint256 amountIn, uint256 amountOut) = fill(o, 5e18, takerTraits(o, optionToken, true, false, 0));

        assertEq(amountIn, 5e18, "the whole lot was taken, not just the closable part");
        assertGt(amountOut, 0, "and paid for in full");
        assertEq(written(), 0, "closed exactly what the desk had written");
        assertEq(underlying.balanceOf(address(desk)) - deskCoverBefore, deskWrote, "only its own cover came back");
        assertEq(inventory(), amountIn - deskWrote, "the excess is held, not burned and not refused");
    }

    // ------------------------------------------------------------------ inventory

    /// @notice Inventory left by a buyback is spent by the next ask, which mints only the
    ///         shortfall. Same assertion shape as `DeskBuy.test_inventoryIsSpentBeforeMinting` —
    ///         here the stock arrives the way it really does, through the bid.
    function test_inventoryFromABuybackIsSpentByTheNextAsk() public {
        (, ISwapVM.Order memory ask) = shipAsk(SERIES_CAP);
        fill(ask, 2e18, takerTraits(ask, address(quote), false, false, 50e6));
        _aliceWrites(3e18);

        (, ISwapVM.Order memory bid) = shipBid(BID_BUDGET);
        fill(bid, 5e18, takerTraits(bid, optionToken, true, false, 0));

        uint256 stock = inventory();
        assertEq(stock, 3e18, "the buyback left the desk holding stock");
        assertEq(written(), 0, "and flat on its own book");

        uint256 coverBefore = underlying.balanceOf(address(desk));

        (, uint256 amountOut) = fill(ask, 5e18, takerTraits(ask, address(quote), false, false, 50e6));

        assertGt(amountOut, stock, "the fill has to be bigger than the stock or this proves nothing");
        assertEq(written(), amountOut - stock, "minted only the shortfall");
        assertEq(coverBefore - underlying.balanceOf(address(desk)), amountOut - stock, "locked only the shortfall");
        assertEq(inventory(), 0, "stock was spent, not stockpiled");
    }

    // ------------------------------------------------------------------ after an exercise

    /// @notice THE ONE. One exercise shuts `close` for the life of the series — and the bid side
    ///         keeps filling anyway, on inventory alone.
    ///
    /// @dev `close` reverts `CloseAfterExercise()` once `poolCash != 0` on a CALL, and nothing
    ///      ever puts that leg back to zero pre-expiry. `_tryClose` swallows the revert, emits
    ///      `CloseSkipped` and reports `closed = 0`; the fill completes, the taker is paid out of
    ///      the desk's wallet, `written` is untouched and the options pile up as inventory. The
    ///      collateral stays locked until settlement, which is the price of a bid side that does
    ///      not go dark.
    function test_sellBackStillWorksAfterAHolderHasExercised() public {
        _stockTheTaker(10e18);

        // One holder exercises. `exercise` pulls the strike in quote straight from the caller.
        vm.startPrank(TAKER);
        quote.approve(address(app), type(uint256).max);
        app.exercise(callId, 1e18);
        vm.stopPrank();
        assertGt(app.getSeries(callId).poolCash, 0, "the opposite leg is now non-empty: close is shut");

        // Shut, and permanently: the desk's own close reverts from here to expiry.
        vm.prank(address(desk));
        vm.expectRevert(WeekendOptions.CloseAfterExercise.selector);
        app.close(callId, 1e18);

        (, ISwapVM.Order memory o) = shipBid(BID_BUDGET);

        uint256 writtenBefore = written();
        uint256 takerQuoteBefore = quote.balanceOf(TAKER);
        uint256 deskCoverBefore = underlying.balanceOf(address(desk));

        // `_tryClose` caps at `min(amountIn, written)` BEFORE it tries, so the skipped amount is
        // the full 2e18 it attempted — not zero, and not what it ended up closing.
        vm.expectEmit(true, false, false, true, address(desk));
        emit WeekendDesk.CloseSkipped(callId, 2e18);

        (uint256 amountIn, uint256 amountOut) = fill(o, 2e18, takerTraits(o, optionToken, true, false, 0));

        assertEq(amountIn, 2e18, "the bid filled");
        assertGt(amountOut, 0, "and the taker was paid");
        assertEq(quote.balanceOf(TAKER) - takerQuoteBefore, amountOut, "paid in full, out of the desk's wallet");

        assertEq(written(), writtenBefore, "written is UNCHANGED: nothing was unwound");
        assertEq(underlying.balanceOf(address(desk)), deskCoverBefore, "and no collateral came back");
        assertEq(inventory(), amountIn, "the options sit in the desk's wallet as inventory");

        // Still shut on the next fill, and the desk still fills. This is the steady state for
        // the rest of the series' life, not a one-off.
        vm.expectEmit(true, false, false, true, address(desk));
        emit WeekendDesk.CloseSkipped(callId, 2e18);
        fill(o, 2e18, takerTraits(o, optionToken, true, false, 0));
        assertEq(written(), writtenBefore, "still unchanged");
        assertEq(inventory(), 4e18, "inventory keeps accruing");
    }

    // ------------------------------------------------------------------ the budget

    /// @notice The bid is bounded by its shipped quote budget, cumulatively. The mirror of
    ///         `DeskCaps.test_manySmallFillsCannotExceedTheShippedCap`, on the other side.
    /// @dev Nothing in the program reads the ledger (`AquaOpcodes` dispatches no `StaticBalances`
    ///      and no invalidator), so the only thing stopping an unbounded payout is `Aqua.pull`'s
    ///      `prevBalance - amount` on a checked `uint248`. Exhaustion is an arithmetic panic.
    function test_manySmallSellBacksCannotDrainPastTheShippedBudget() public {
        _stockTheTaker(10e18);

        uint256 budget = 3 * BID_UNIT;
        (bytes32 hash, ISwapVM.Order memory o) = shipBid(budget);
        bytes memory tt = takerTraits(o, optionToken, true, false, 0);

        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            (, uint256 amountOut) = fill(o, 1e18, tt);
            assertEq(amountOut, BID_UNIT, "golden bid quote drifted");
            paid += amountOut;
            (uint248 left,) = aqua.rawBalances(address(desk), address(router), hash, address(quote));
            assertEq(left, budget - paid, "the ledger decrements cumulatively, fill by fill");
        }

        // The fourth is a tenth of what was shipped and still cannot be paid: the bound is the
        // running total, and a per-fill check would have waved every one of these through.
        uint256 takerOptions = IERC20(optionToken).balanceOf(TAKER);
        vm.expectRevert(stdError.arithmeticError);
        fill(o, 1e18, tt);

        assertEq(IERC20(optionToken).balanceOf(TAKER), takerOptions, "the whole fill unwound");
        (uint248 drained,) = aqua.rawBalances(address(desk), address(router), hash, address(quote));
        assertEq(drained, 0, "drained to exactly the shipped budget, no further");
    }

    // ------------------------------------------------------------------ the spread

    /// @notice The spread is the vol gap and nothing else enforces one: the same option, round
    ///         tripped in the same block, comes back worth less than it cost.
    function test_bidPaysLessThanTheAskCharges() public {
        (, ISwapVM.Order memory ask) = shipAsk(SERIES_CAP);
        (uint256 askPaid,) = fill(ask, 1e18, takerTraits(ask, address(quote), false, false, 10e6));

        (, ISwapVM.Order memory bid) = shipBid(BID_BUDGET);
        (, uint256 bidGot) = fill(bid, 1e18, takerTraits(bid, optionToken, true, false, 0));

        assertEq(askPaid, ASK_UNIT, "golden ask quote drifted");
        assertEq(bidGot, BID_UNIT, "golden bid quote drifted");
        assertLt(bidGot, askPaid, "the desk must not buy back above its own offer");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Give `TAKER` options to sell back, written by the DESK. Exact-out so the stock — and
    ///      therefore `written[id][desk]` — is a round number.
    function _stockTheTaker(uint256 amount) private {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
        fill(o, amount, takerTraits(o, address(quote), false, false, 100e6));
    }

    /// @dev Give `TAKER` options written by ALICE against ALICE's own collateral, so the desk's
    ///      `written` is deliberately smaller than what can be sold back to it.
    function _aliceWrites(uint256 amount) private {
        WeekendOptions.Strategy memory s = ownStrategy();
        s.maker = ALICE;
        s.salt = ALICE_SALT;

        underlying.mint(ALICE, amount);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (address(underlying), amount);
        (tokens[1], amounts[1]) = (address(quote), 0); // the premium leg has to exist to be pushed to
        vm.startPrank(ALICE);
        underlying.approve(address(aqua), type(uint256).max);
        bytes32 hash = aqua.ship(address(app), abi.encode(s), tokens, amounts);
        vm.stopPrank();

        vm.startPrank(TAKER);
        quote.approve(address(weekendTaker), type(uint256).max);
        weekendTaker.buy(app, s, callId, amount, type(uint256).max, TAKER, abi.encode(ALICE, hash));
        vm.stopPrank();
    }
}
