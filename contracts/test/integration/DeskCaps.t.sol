// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { stdError } from "forge-std/StdError.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapVM } from "swapvm/interfaces/ISwapVM.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import { AquaOpcodes } from "swapvm/opcodes/AquaOpcodes.sol";
import { FeeProtocol } from "swapvm/instructions/FeeProtocol.sol";

import { WeekendDesk } from "../../src/desk/WeekendDesk.sol";
import { DeskFixture } from "../helpers/DeskFixture.sol";
import { OrderLib } from "../helpers/OrderLib.sol";

/// @title DeskCaps
/// @notice What actually bounds a resting option quote. Review Focus #1 and #2.
///
/// @dev THE WHOLE POINT. `Extruction`'s own NatSpec tells a maker to bound an amount-limited
///      strategy with `StaticBalances` plus `InvalidateTokenIn` / `InvalidateTokenOut`.
///      **`AquaOpcodes` dispatches none of those three** — they exist in `OpcodeList` but this
///      router cannot run them, which `test_theOpcodesExtructionPrescribesAreNotDispatched`
///      pins at the opcode level. So the Aqua ledger is the only hard cap this design has, and
///      everything below exists to prove it really binds rather than merely being documented.
///
///      Two caps, two mechanisms, both cumulative and neither per-fill:
///
///        Aqua ledger   `pull` does `prevBalance - amount` on a checked `uint248`, accruing
///                      across every fill of one order hash. Exhaustion is an arithmetic panic.
///        `maxShort`    `WeekendDesk._mintShortfall` compares `APP.written(id, desk)` — the
///                      running total — against the cap AFTER each write, not this fill's size.
///
///        FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/DeskCaps.t.sol'
contract DeskCapsTest is DeskFixture {
    /// @dev `setUp` deliberately ships nothing, so each test owns its ledger entries.
    bytes32 internal constant FEE_SALT_A = bytes32(uint256(0xFEE0));
    bytes32 internal constant FEE_SALT_B = bytes32(uint256(0xFEE1));
    bytes32 internal constant FRESH_SALT = bytes32(uint256(0xA17E));

    address internal constant FEE_RECEIVER = address(0xFEE);
    /// @dev `FeeReceiverLib.BPS` is 1e7, so this is 1%.
    uint24 internal constant FEE_BPS = 100_000;

    /// @dev No `maxIn` ceiling — these tests bound supply, never price.
    uint256 internal constant NO_MAX_IN = type(uint128).max;

    // ------------------------------------------------------------- the premise

    /// @dev If any of these three ever starts dispatching, the "ledger is the only cap" claim
    ///      in this file and in `OrderLib.program` has to be re-derived. 0x41/0x42 are
    ///      `InvalidateTokenIn` / `InvalidateTokenOut`, 0x90 is `StaticBalances`.
    function test_theOpcodesExtructionPrescribesAreNotDispatched() public {
        uint8[3] memory opcodes = [0x41, 0x42, 0x90];
        for (uint256 i; i < opcodes.length; ++i) {
            OrderLib.Params memory p = params(SIDE_ASK, bytes32(uint256(opcodes[i])));
            ISwapVM.Order memory o = _orderWithPrefix(p, OrderLib.instruction(opcodes[i], new bytes(64)));
            _shipOrder(o, optionToken, 10e18, address(quote));

            vm.expectRevert(abi.encodeWithSelector(AquaOpcodes.UnknownOpcode.selector, uint256(opcodes[i])));
            fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
        }
    }

    // ------------------------------------------------------------- Review Focus #1

    /// @notice THE test. Ten 1e18 fills drain a 10e18 strategy; the eleventh underflows.
    ///
    /// @dev A per-fill bound would wave every one of these through — each is a tenth of the
    ///      shipped amount. Nothing in the program looks at the ledger (no `StaticBalances`,
    ///      no invalidator), so the only thing standing between a 10e18 offer and an unbounded
    ///      short is `Aqua.pull`'s `prevBalance - amount` on a `uint248`.
    function test_manySmallFillsCannotExceedTheShippedCap() public {
        (bytes32 hash_, ISwapVM.Order memory o) = shipAsk(10e18);

        for (uint256 i; i < 10; ++i) {
            fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
            (uint248 left,) = aqua.rawBalances(address(desk), address(router), hash_, optionToken);
            assertEq(left, 10e18 - (i + 1) * 1e18, "ledger decrements cumulatively, fill by fill");
        }

        assertEq(optionTokenBalance(TAKER), 10e18, "taker holds exactly the shipped cap");
        assertEq(written(), 10e18, "the desk wrote exactly the shipped cap");

        // Eleventh. `preTransferOut` happily mints another option — the cap is not its job —
        // and then the pull underflows on an exhausted ledger.
        vm.expectRevert(stdError.arithmeticError);
        fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));

        // ...and the revert really did unwind the mint.
        assertEq(written(), 10e18, "no eleventh option escaped");
        assertEq(optionTokenBalance(TAKER), 10e18, "taker got nothing more");
    }

    /// @dev The same bound, reached in one step instead of ten: a single oversized fill is
    ///      rejected by exactly the same arithmetic, so the two paths agree.
    function test_oneOversizedFillHitsTheSameLedgerBound() public {
        (bytes32 hash_, ISwapVM.Order memory o) = shipAsk(10e18);

        vm.expectRevert(stdError.arithmeticError);
        fill(o, 10e18 + 1, takerTraits(o, address(quote), false, false, NO_MAX_IN));

        // Exactly the cap in one fill is fine — the bound is the total, not the fill size.
        fill(o, 10e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
        (uint248 left,) = aqua.rawBalances(address(desk), address(router), hash_, optionToken);
        assertEq(left, 0, "drained");
    }

    // ------------------------------------------------------------- Review Focus #2

    /// @notice The protocol fee is a SECOND, separate `AQUA.pull` against the same ledger entry,
    ///         so the shipped amount has to cover `amountOut + feeOut`, not `amountOut`.
    ///
    /// @dev Proved on the bid, where the desk pays quote out of a wallet far deeper than any
    ///      budget here (`DESK_CASH`), so the ledger is unambiguously the thing that binds.
    ///      The ask side cannot carry a token-out fee at all today — see
    ///      `test_anAskSideFeeUnderMintsBecauseTheHookSeesTheNetAmount`.
    function test_theLedgerMustCoverAmountOutPlusTheProtocolFee() public {
        // The taker needs options before it can sell any back.
        (, ISwapVM.Order memory ask) = shipAsk(10e18);
        fill(ask, 4e18, takerTraits(ask, address(quote), false, false, NO_MAX_IN));

        // A generously funded fee-bearing bid, to measure what one sell-back really costs.
        ISwapVM.Order memory loose = _feeOrder(params(SIDE_BID, FEE_SALT_A));
        bytes32 hLoose = _shipOrder(loose, address(quote), 10_000e6, optionToken);

        (uint248 before_,) = aqua.rawBalances(address(desk), address(router), hLoose, address(quote));
        (, uint256 paid) = fill(loose, 1e18, takerTraits(loose, optionToken, true, false, 0));
        (uint248 after_,) = aqua.rawBalances(address(desk), address(router), hLoose, address(quote));

        uint256 feeOut = quote.balanceOf(FEE_RECEIVER);
        assertGt(feeOut, 0, "a fee was actually charged");
        assertEq(before_ - after_, paid + feeOut, "ONE ledger entry funded both pulls");

        // The binding case: a ledger holding exactly the taker's payout is short by the fee.
        ISwapVM.Order memory tight = _feeOrder(params(SIDE_BID, FEE_SALT_B));
        bytes32 hTight = _shipOrder(tight, address(quote), paid, optionToken);

        vm.expectRevert(stdError.arithmeticError);
        fill(tight, 1e18, takerTraits(tight, optionToken, true, false, 0));

        (uint248 untouched,) = aqua.rawBalances(address(desk), address(router), hTight, address(quote));
        assertEq(untouched, paid, "the whole fill unwound");
    }

    /// @notice FINDING, not a design choice. A token-out protocol fee breaks the ask outright:
    ///         `preTransferOut` is handed `ctx.swap.amountOut` AFTER `FeeProtocol` has subtracted
    ///         the fee, so `_mintShortfall` mints the net while the router then pulls net + fee
    ///         out of the desk. The desk is short by exactly the fee and the ERC-20 transfer
    ///         fails — with a ledger that has plenty left.
    ///
    /// @dev Shipped at 10e18 for a 1e18 fill, so this cannot be confused with a ledger bound.
    ///      Fixing it means minting the gross (the hook would need the fee, which only
    ///      `postTransferOut` receives) or keeping a float. Until then: do not attach a
    ///      token-out `FeeProtocol` to an ask.
    function test_anAskSideFeeUnderMintsBecauseTheHookSeesTheNetAmount() public {
        ISwapVM.Order memory o = _feeOrder(params(SIDE_ASK, FEE_SALT_A));
        bytes32 hash_ = _shipOrder(o, optionToken, 10e18, address(quote));

        // `SafeTransferFromFailed`, wrapping `ERC20InsufficientBalance(desk, net, gross)`:
        // the desk holds what it minted, the router wants what the taker plus the fee need.
        vm.expectRevert(abi.encodeWithSignature("SafeTransferFromFailed()"));
        fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));

        (uint248 left,) = aqua.rawBalances(address(desk), address(router), hash_, optionToken);
        assertEq(left, 10e18, "the ledger was never the binding constraint here");
    }

    // ------------------------------------------------------------- immutability

    /// @notice `Aqua.ship` enforces `StrategiesMustBeImmutable`: there is no restock.
    /// @dev `setUp` ships nothing, so the first call here is the strategy's one and only ship.
    function test_anExhaustedStrategyCannotBeRestockedWithoutANewSalt() public {
        (bytes32 hash_, ISwapVM.Order memory o) = shipAsk(2e18);
        fill(o, 2e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));

        (uint248 left,) = aqua.rawBalances(address(desk), address(router), hash_, optionToken);
        assertEq(left, 0, "exhausted");

        // Same salt, same order, same hash — refused even though the entry is empty.
        vm.expectRevert(
            abi.encodeWithSelector(IAqua.StrategiesMustBeImmutable.selector, address(router), hash_)
        );
        shipAsk(SERIES_CAP);

        (uint248 stillEmpty,) = aqua.rawBalances(address(desk), address(router), hash_, optionToken);
        assertEq(stillEmpty, 0, "a refused restock changes nothing");
    }

    /// @notice A new salt is a new order hash, which is a new, independent ledger entry.
    function test_aNewSaltIsAFreshLedgerEntry() public {
        (bytes32 oldHash, ISwapVM.Order memory old) = shipAsk(2e18);
        fill(old, 2e18, takerTraits(old, address(quote), false, false, NO_MAX_IN));

        (bytes32 newHash, ISwapVM.Order memory fresh) = shipAsk(FRESH_SALT, 3e18);
        assertTrue(newHash != oldHash, "a new salt must not collide with the exhausted entry");

        fill(fresh, 3e18, takerTraits(fresh, address(quote), false, false, NO_MAX_IN));
        assertEq(optionTokenBalance(TAKER), 5e18, "both entries sold their own cap and no more");

        (uint248 leftOld,) = aqua.rawBalances(address(desk), address(router), oldHash, optionToken);
        (uint248 leftNew,) = aqua.rawBalances(address(desk), address(router), newHash, optionToken);
        assertEq(leftOld, 0, "the old entry stayed exhausted");
        assertEq(leftNew, 0, "the new entry carried the new cap");
    }

    // ------------------------------------------------------------- maxShort

    /// @notice `_mintShortfall` checks `written` cumulatively. Four 1e18 buys against a 3e18
    ///         short cap trip on the fourth, not on any one fill's size.
    /// @dev The ledger is deliberately shipped far above the cap so that `ShortLimit` — and not
    ///      an Aqua underflow — is what answers.
    function test_maxShortIsCumulativeAcrossManySmallFills() public {
        listSeries(3e18);
        (, ISwapVM.Order memory o) = shipAsk(100e18);

        for (uint256 i; i < 3; ++i) {
            fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
            assertEq(written(), (i + 1) * 1e18, "written accrues, it does not reset per fill");
        }

        vm.expectRevert(abi.encodeWithSelector(WeekendDesk.ShortLimit.selector, callId, 4e18, 3e18));
        fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));

        assertEq(written(), 3e18, "the fourth write unwound");
    }

    /// @notice One 4e18 buy trips `maxShort` at exactly the same cumulative point, with exactly
    ///         the same arguments, as four 1e18 buys do.
    function test_oneLargeBuyTripsMaxShortAtTheSameCumulativePoint() public {
        listSeries(3e18);
        (, ISwapVM.Order memory o) = shipAsk(100e18);

        vm.expectRevert(abi.encodeWithSelector(WeekendDesk.ShortLimit.selector, callId, 4e18, 3e18));
        fill(o, 4e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));

        // Right up to the cap still clears, from the same starting state.
        fill(o, 3e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
        assertEq(written(), 3e18, "the cap is reachable, just not passable");
    }

    /// @notice `maxShort` bounds the desk's short, NOT the order. A fresh salt resets the Aqua
    ///         ledger but shares `written`, so the short cap survives a re-offer.
    function test_maxShortSurvivesAReShipUnderANewSalt() public {
        listSeries(3e18);
        (, ISwapVM.Order memory first) = shipAsk(2e18);
        fill(first, 2e18, takerTraits(first, address(quote), false, false, NO_MAX_IN));

        (, ISwapVM.Order memory second) = shipAsk(FRESH_SALT, 100e18);
        fill(second, 1e18, takerTraits(second, address(quote), false, false, NO_MAX_IN));
        assertEq(written(), 3e18, "written is per-desk, not per-order");

        vm.expectRevert(abi.encodeWithSelector(WeekendDesk.ShortLimit.selector, callId, 4e18, 3e18));
        fill(second, 1e18, takerTraits(second, address(quote), false, false, NO_MAX_IN));
    }

    // ------------------------------------------------------------- helpers

    function optionTokenBalance(address who) internal view returns (uint256) {
        return IERC20(optionToken).balanceOf(who);
    }

    /// @dev `order.data` is `tokenA || tokenB || program` and the maker traits put every
    ///      hook-data slice at offset 40, so the program is simply `data[40:]`. Prepending an
    ///      instruction there is therefore a legal program edit — and it changes the order hash,
    ///      which is exactly why each variant below needs its own salt and its own ship.
    function _orderWithPrefix(OrderLib.Params memory p, bytes memory prefix)
        internal
        pure
        returns (ISwapVM.Order memory o)
    {
        o = orderOf(p);
        (address tokenA, address tokenB) =
            p.quote < p.optionToken ? (p.quote, p.optionToken) : (p.optionToken, p.quote);
        o.data = bytes.concat(abi.encodePacked(tokenA, tokenB), prefix, OrderLib.program(p));
    }

    /// @dev A `FeeProtocol` charging `FEE_BPS` in the token OUT — the only configuration whose
    ///      fee is a maker-side `AQUA.pull` (`ProtocolFeeLib.resolveOutAquaPullMaker`). A
    ///      token-IN fee on this route is a plain router transfer and never touches the ledger.
    ///      It goes first in the program because `FeeProtocol.exec` wraps the rest via
    ///      `ctx.runLoop()` and must see the price `Extruction` produces.
    function _feeOrder(OrderLib.Params memory p) internal pure returns (ISwapVM.Order memory) {
        FeeProtocol.ReceiverConfig[] memory receivers = new FeeProtocol.ReceiverConfig[](1);
        receivers[0] = FeeProtocol.ReceiverConfig({ receiver: FEE_RECEIVER, feeBps: FEE_BPS, surplusBps: 0 });
        return _orderWithPrefix(p, FeeProtocol.build(false, receivers, new FeeProtocol.ProviderConfig[](0)));
    }

    /// @dev `DeskFixture.ship` builds its order from `Params`; these orders are hand-edited, so
    ///      they ship through `desk.ship` directly. Both legs, as always.
    function _shipOrder(ISwapVM.Order memory o, address sell, uint256 amount, address zero)
        internal
        returns (bytes32)
    {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (sell, amount);
        (tokens[1], amounts[1]) = (zero, 0);
        return desk.ship(address(router), abi.encode(o), tokens, amounts);
    }
}
