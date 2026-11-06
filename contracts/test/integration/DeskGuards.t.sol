// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import { ISwapVM } from "swapvm/interfaces/ISwapVM.sol";

import { Kind } from "../../src/WeekendOptions.sol";
import { WeekendDesk } from "../../src/desk/WeekendDesk.sol";
import { WeekendPricer } from "../../src/desk/WeekendPricer.sol";
import { DeskFixture } from "../helpers/DeskFixture.sol";
import { OrderLib } from "../helpers/OrderLib.sol";

/// @notice Every refusal path on the desk route, driven through the REAL `AquaSwapVMRouter` and
///         the REAL `Aqua`. Nothing here is a unit test of a modifier: each guard is reached by
///         an actual `router.swap`, because the thing being proved is that the guard is still
///         standing once SwapVM has loaded balances, run the program and called the hooks.
///
///        FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/DeskGuards.t.sol'
///
/// @dev The happy paths live in Task 6/8/9/10's files. Everything below reverts on purpose; the
///      only non-reverting fills here are the setup leg of the short-cap test.
contract DeskGuardsTest is DeskFixture {
    /// @dev A maximum `maxIn` for exact-out fills. `takerTraits` treats 0 as "no threshold",
    ///      which would make every exact-out fill revert on `amountIn <= 0` instead of on the
    ///      guard under test.
    uint256 private constant NO_MAX_IN = type(uint256).max;

    // ------------------------------------------------------------------ direction gate

    /// @dev THE security property of this route, end to end.
    ///
    ///      `AquaOpcodes` ships no `LimitSwap`, so nothing validates swap direction for free.
    ///      An ask order accrues quote in the maker's Aqua counter as it fills; without
    ///      `WeekendPricer._gateDirection` that growing counter is a standing allowance for
    ///      anyone to fill the REVERSE direction — selling options back to the desk at the
    ///      desk's own ask price, which is the wrong side of its own spread.
    function test_anAskOrderCannotBeFilledInReverse() public {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        // option -> quote against an ASK order.
        vm.expectPartialRevert(WeekendPricer.WrongSwapDirection.selector);
        fill(o, 1e18, takerTraits(o, optionToken, true, false, 0));
    }

    /// @dev The mirror. A bid order is the desk's quote budget; lifting it in the ask direction
    ///      would be buying options out of a counter that was never meant to sell any.
    function test_aBidOrderCannotBeFilledInReverse() public {
        (, ISwapVM.Order memory o) = shipBid(1_000e6);

        // quote -> option against a BID order.
        vm.expectPartialRevert(WeekendPricer.WrongSwapDirection.selector);
        fill(o, 100e6, takerTraits(o, address(quote), true, false, 0));
    }

    // ------------------------------------------------------------------ kill switch

    /// @dev Review Focus #4. The reference desk checks `active` in `preTransferOut` only, and
    ///      gets away with it because ERC-1271 rejects a dead maker's signature before any hook
    ///      runs. These orders set `useAquaInsteadOfSignature`, so there is no signature and no
    ///      ERC-1271 — `onlyFill` is the only thing standing. Both directions, both hooks.
    function test_inactiveDeskRefusesBothDirections() public {
        (, ISwapVM.Order memory ask) = shipAsk(SERIES_CAP);
        (, ISwapVM.Order memory bid) = shipBid(1_000e6);

        // One real fill while the desk is live, purely so the taker holds options to offer
        // back below. Without it the `takerFirst` leg would revert in the taker's own
        // `transferFrom` and prove nothing about the hook.
        fill(ask, 1e18, takerTraits(ask, address(quote), false, false, NO_MAX_IN));

        desk.setActive(false);

        vm.expectRevert(WeekendDesk.Inactive.selector);
        fill(ask, 1e18, takerTraits(ask, address(quote), false, false, NO_MAX_IN));

        vm.expectRevert(WeekendDesk.Inactive.selector);
        fill(bid, 1e18, takerTraits(bid, optionToken, true, false, 0));

        // The same bid with `IS_FIRST_TRANSFER_FROM_TAKER` set, which is the TAKER's choice and
        // the maker cannot forbid. It reverses the hook order, so this is the leg that reaches
        // `postTransferIn` first — the hook the reference desk leaves ungated.
        vm.expectRevert(WeekendDesk.Inactive.selector);
        fill(bid, 1e18, takerTraits(bid, optionToken, true, true, 0));
    }

    // ------------------------------------------------------------------ listing

    /// @dev A series the core knows about but the desk never listed. The pricer is happy — the
    ///      order names a real series and the direction matches — so this has to be caught in
    ///      the hook, where `seriesOfToken` is the allowlist.
    function test_anUnlistedOptionTokenIsRejected() public {
        (uint256 foreignId, address foreignToken) = _foreignSeries();

        OrderLib.Params memory p = params(SIDE_ASK, bytes32(uint256(0xF0)));
        (p.seriesId, p.optionToken) = (foreignId, foreignToken);
        (, ISwapVM.Order memory o) = ship(p, SERIES_CAP);

        vm.expectRevert(abi.encodeWithSelector(WeekendDesk.UnknownToken.selector, foreignToken));
        fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
    }

    // ------------------------------------------------------------------ expiry

    /// @dev The order's own `Deadline` is 365 days out precisely so this trips on the SERIES
    ///      clock rather than on the order's, which are different guards in different places.
    function test_expiredSeriesCannotBeFilled() public {
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        vm.warp(expiry);

        vm.expectRevert(abi.encodeWithSelector(WeekendPricer.SeriesExpired.selector, expiry));
        fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
    }

    // ------------------------------------------------------------------ short cap

    /// @dev `maxShort` bounds CUMULATIVE `written[id][desk]`, not one fill. The fill that
    ///      crosses it is the one that reverts, and a per-fill check would have let these two
    ///      halves walk straight past a cap either one of them fits under.
    function test_shortCapTripsOnTheFillThatCrossesIt() public {
        listSeries(1e18); // re-list the same series with a cap of exactly one option
        (, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);

        bytes memory tt = takerTraits(o, address(quote), false, false, NO_MAX_IN);

        fill(o, 1e18, tt);
        assertEq(written(), 1e18, "first fill writes exactly to the cap");

        // Same size again. Fits in the shipped Aqua leg, fits any per-fill reading of the cap,
        // and must still fail: 2e18 > 1e18.
        vm.expectRevert(abi.encodeWithSelector(WeekendDesk.ShortLimit.selector, callId, 2e18, 1e18));
        fill(o, 1e18, tt);
    }

    // ------------------------------------------------------------------ premium floor

    /// @dev The maker's floor, carried in the program bytes and therefore in the order hash.
    ///      Set absurdly high (100% of strike notional) so a correctly-priced ATM 7-day call
    ///      sits far below it; the fixture's own `MIN_PREMIUM_BPS` is 1, which nothing real
    ///      crosses.
    function test_aFillBelowTheMakersPremiumFloorReverts() public {
        OrderLib.Params memory p = params(SIDE_ASK, bytes32(uint256(0xF1)));
        p.minPremiumBps = 10_000;
        (, ISwapVM.Order memory o) = ship(p, SERIES_CAP);

        vm.expectPartialRevert(WeekendPricer.PremiumBelowFloor.selector);
        fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
    }

    // ------------------------------------------------------------------ unused hooks

    /// @dev `OrderLib` never sets these two flags, so nothing below is reachable through a
    ///      fill today. That is exactly why they must fail closed: the day someone ships an
    ///      order with the other two hook bits set, the desk refuses rather than no-ops.
    function test_theTwoUnusedHooksFailClosed() public {
        vm.expectRevert(WeekendDesk.UnusedHook.selector);
        desk.preTransferIn(address(desk), TAKER, address(quote), optionToken, 0, 0, bytes32(0), "", "");

        vm.expectRevert(WeekendDesk.UnusedHook.selector);
        desk.postTransferOut(address(desk), TAKER, address(quote), optionToken, 0, 0, 0, bytes32(0), "", "");
    }

    // ------------------------------------------------------------------ hash coverage

    /// @dev The pricer address lives inside the `Extruction` instruction, inside the program,
    ///      inside `order.data`. Repointing it is a different order hash, so the Aqua ledger
    ///      key does not exist and `safeBalances` reverts before a single opcode runs. This is
    ///      why `WeekendPricer` needs no admin: pricing cannot be repointed after shipping.
    function test_repointingThePricerInvalidatesTheOrder() public {
        shipAsk(SERIES_CAP);

        OrderLib.Params memory p = params(SIDE_ASK, ASK_SALT);
        p.pricer = address(0xDEAD);
        ISwapVM.Order memory o = orderOf(p);
        assertTrue(router.hash(o) != router.hash(orderOf(params(SIDE_ASK, ASK_SALT))), "hash must move");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAqua.SafeBalancesForTokenNotInActiveStrategy.selector,
                address(desk),
                address(router),
                router.hash(o),
                address(quote)
            )
        );
        fill(o, 1e18, takerTraits(o, address(quote), false, false, NO_MAX_IN));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev A second real series on the same underlying, deliberately never passed to
    ///      `desk.listSeries`.
    function _foreignSeries() private returns (uint256 id, address token) {
        id = app.createSeries(address(underlying), expiry, Kind.CALL, STRIKE + 1e6);
        token = address(app.getSeries(id).token);
    }
}
