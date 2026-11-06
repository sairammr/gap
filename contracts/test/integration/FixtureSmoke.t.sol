// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISwapVM } from "swapvm/interfaces/ISwapVM.sol";

import { DeskFixture } from "../helpers/DeskFixture.sol";

/// @notice Proves the fixture itself: the real `AquaSwapVMRouter` deploys and links against our
///         contracts, and an order shipped to the real `Aqua` lands under exactly the hash the
///         router will look it up by.
///
/// @dev The buy and sell fills are wave 3. This file only has to fail loudly if the wiring that
///      every one of those tests inherits is wrong.
///
///        FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/*'
contract FixtureSmokeTest is DeskFixture {
    function test_everythingIsDeployedAndWired() public view {
        assertGt(address(router).code.length, 0, "router has no code");
        assertEq(address(router.AQUA()), address(aqua), "router points at our Aqua");
        assertEq(desk.ROUTER(), address(router), "desk trusts the router");
        assertEq(app.written(callId, address(desk)), 0, "nothing written yet");
        assertEq(desk.seriesOfToken(optionToken), callId + 1, "series is listed");
        assertTrue(desk.ownStrategyHash() != bytes32(0), "own strategy is set");
    }

    /// @dev The load-bearing identity of this whole design: `Aqua.ship` hashes the strategy
    ///      bytes, `SwapVM.hash` hashes the order, and on the Aqua path those are the same
    ///      bytes. One ledger entry backs exactly one quote. If this drifts, `safeBalances`
    ///      reverts before a single opcode runs and nothing else in wave 3 can work.
    function test_shippedStrategyHashIsTheRoutersOrderHash() public {
        (bytes32 strategyHash, ISwapVM.Order memory o) = shipAsk(SERIES_CAP);
        assertEq(strategyHash, router.hash(o), "aqua.ship hash != router.hash(order)");

        (uint256 optionLeg, uint256 quoteLeg) =
            aqua.safeBalances(address(desk), address(router), strategyHash, optionToken, address(quote));
        assertEq(optionLeg, SERIES_CAP, "the cap is the option leg");
        assertEq(quoteLeg, 0, "the quote leg is there to satisfy safeBalances, not as a budget");
    }

    /// @dev The bid ships the mirror pair. Both legs again, budget on the quote side.
    function test_bidShipsTheMirrorPair() public {
        (bytes32 strategyHash, ISwapVM.Order memory o) = shipBid(1_000e6);
        assertEq(strategyHash, router.hash(o), "aqua.ship hash != router.hash(order)");

        (uint256 quoteLeg, uint256 optionLeg) =
            aqua.safeBalances(address(desk), address(router), strategyHash, address(quote), optionToken);
        assertEq(quoteLeg, 1_000e6, "the budget is the quote leg");
        assertEq(optionLeg, 0, "zero leg");
    }

    /// @dev The ask and the bid are different orders with different hashes — they differ by
    ///      salt, side and vol, all of which ride inside the program bytes.
    function test_askAndBidAreDistinctOrders() public view {
        assertTrue(
            router.hash(orderOf(params(SIDE_ASK, ASK_SALT))) != router.hash(orderOf(params(SIDE_BID, BID_SALT))),
            "two sides must not collide on one ledger entry"
        );
    }
}
