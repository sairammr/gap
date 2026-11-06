// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/contracts/Aqua.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Kind, WeekendOptions } from "../src/WeekendOptions.sol";
import { OptionTokenFactory } from "../src/OptionToken.sol";
import { WeekendDesk } from "../src/desk/WeekendDesk.sol";
import { V4SpotOracle } from "../src/oracle/V4SpotOracle.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockStateView } from "./helpers/MockStateView.sol";

/// @notice Unit-level cover for `WeekendDesk`: the hooks are called directly, as the router
///         would, with no SwapVM in the picture.
///
/// @dev WHY THERE IS NO ROUTER HERE. SwapVM does not compile under the default Foundry profile,
///      and nothing in this file needs it: the hooks are plain external functions whose only
///      relationship to the router is `msg.sender`, which `vm.prank` reproduces exactly. The
///      real `AquaSwapVMRouter` path — order encoding, the Aqua ledger cap, fees, the taker's
///      choice of transfer order as an actual trait bit — is wave 3, under `[profile.swapvm]`.
///
///      Everything else is real: the real `Aqua`, the real `WeekendOptions`, the real
///      `V4SpotOracle`, real ERC-20s. The only double is the v4 `StateView` lens, which §13
///      permits.
contract DeskTest is Test {
    /// @dev sqrtPriceX96 for an 18dp underlying / 6dp quote at spot = 205e6, currency0 = asset.
    ///      Same constant the core write tests use.
    uint160 internal constant SQRT_PRICE_205 = 1134374654051415993876480;
    bytes32 internal constant POOL_ID = bytes32(uint256(1));

    uint256 internal constant STRIKE = 205e6;
    uint256 internal constant VOL = 0.5e18;
    uint256 internal constant CAP = 100e18;
    /// @dev Underlying the desk has on hand to write against. One per option, CALL is covered.
    uint256 internal constant COVER = 50e18;

    address internal constant ROUTER = address(0x7007);
    address internal constant TAKER = address(0xBEEF);
    address internal constant STRANGER = address(0xBAD);

    Aqua internal aqua;
    WeekendOptions internal app;
    WeekendDesk internal desk;
    V4SpotOracle internal oracle;
    MockERC20 internal usdc;
    MockERC20 internal nvdax;
    MockERC20 internal stray;

    uint256 internal callId;
    address internal optionToken;
    uint64 internal expiry;

    function setUp() public {
        aqua = new Aqua();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);
        stray = new MockERC20("Stray", "STRAY", 18);

        MockStateView stateView = new MockStateView(SQRT_PRICE_205);
        oracle = new V4SpotOracle(stateView, 6);
        oracle.setPool(address(nvdax), POOL_ID, 18, true);

        OptionTokenFactory factory = new OptionTokenFactory();
        app = new WeekendOptions(address(usdc), factory, IAqua(address(aqua)), oracle);

        expiry = uint64(block.timestamp + 7 days);
        callId = app.createSeries(address(nvdax), expiry, Kind.CALL, STRIKE);
        optionToken = address(app.getSeries(callId).token);

        desk = new WeekendDesk(app, IAqua(address(aqua)), ROUTER, address(usdc));
        _list(CAP);

        // The desk's own core-protocol strategy: it is maker and taker of its own write.
        desk.setOwnStrategy(_ownStrategy());

        // Cover to write against, and quote to round-trip the self-write premium through.
        nvdax.mint(address(desk), COVER);
        usdc.mint(address(desk), 1_000_000e6);

        // Review Focus #5: without these, every ask fill reverts inside `AQUA.pull`.
        desk.approveAqua(address(nvdax), type(uint256).max);
        desk.approveAqua(address(usdc), type(uint256).max);

        // Ship the desk's own cover. Both legs must be present or the premium push reverts
        // with `PushToNonActiveStrategyPrevented`.
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (address(nvdax), COVER);
        (tokens[1], amounts[1]) = (address(usdc), 0);
        vm.prank(address(desk));
        aqua.ship(address(app), abi.encode(_ownStrategy()), tokens, amounts);
    }

    // ------------------------------------------------------------------ helpers

    function _ownStrategy() internal view returns (WeekendOptions.Strategy memory) {
        return WeekendOptions.Strategy({
            app: address(app),
            maker: address(desk),
            underlying: address(nvdax),
            quote: address(usdc),
            volWad: VOL,
            minPremiumBps: 0,
            salt: bytes32(0)
        });
    }

    function _list(uint256 cap) internal {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory caps = new uint256[](1);
        (ids[0], caps[0]) = (callId, cap);
        desk.listSeries(ids, caps);
    }

    /// @dev The ask leg: taker pays quote, desk ships options.
    function _ask(uint256 amountOut) internal {
        vm.prank(ROUTER);
        desk.preTransferOut(address(desk), TAKER, address(usdc), optionToken, 1e6, amountOut, bytes32(0), "", "");
    }

    /// @dev The ask's other hook: the premium landing. Must be a no-op in either order.
    function _askPremium(uint256 amountIn) internal {
        vm.prank(ROUTER);
        desk.postTransferIn(address(desk), TAKER, address(usdc), optionToken, amountIn, 1e18, 0, bytes32(0), "", "");
    }

    /// @dev The bid leg: taker delivers options, desk closes what it can.
    function _bid(uint256 amountIn) internal {
        vm.prank(ROUTER);
        desk.postTransferIn(address(desk), TAKER, optionToken, address(usdc), amountIn, 1e6, 0, bytes32(0), "", "");
    }

    function _written() internal view returns (uint256) {
        return app.written(callId, address(desk));
    }

    function _inventory() internal view returns (uint256) {
        return IERC20(optionToken).balanceOf(address(desk));
    }

    // ------------------------------------------------------------------ access

    function test_hooksRejectAnyCallerButTheRouter() public {
        vm.expectRevert(WeekendDesk.NotRouter.selector);
        desk.preTransferOut(address(desk), TAKER, address(usdc), optionToken, 1, 1, bytes32(0), "", "");

        vm.expectRevert(WeekendDesk.NotRouter.selector);
        desk.postTransferIn(address(desk), TAKER, address(usdc), optionToken, 1, 1, 0, bytes32(0), "", "");
    }

    function test_hooksRejectAForeignMaker() public {
        vm.startPrank(ROUTER);
        vm.expectRevert(WeekendDesk.NotMaker.selector);
        desk.preTransferOut(address(0xDEAD), TAKER, address(usdc), optionToken, 1, 1, bytes32(0), "", "");

        vm.expectRevert(WeekendDesk.NotMaker.selector);
        desk.postTransferIn(address(0xDEAD), TAKER, address(usdc), optionToken, 1, 1, 0, bytes32(0), "", "");
        vm.stopPrank();
    }

    /// @dev Review Focus #4. The reference desk checks `active` only in `preTransferOut`, which
    ///      is safe there solely because ERC-1271 rejects a dead maker's signature first. The
    ///      Aqua path has no signature, so the gap is live and both hooks must check.
    function test_bothHooksRefuseWhenInactive() public {
        desk.setActive(false);
        vm.startPrank(ROUTER);
        vm.expectRevert(WeekendDesk.Inactive.selector);
        desk.preTransferOut(address(desk), TAKER, address(usdc), optionToken, 1, 1, bytes32(0), "", "");

        vm.expectRevert(WeekendDesk.Inactive.selector);
        desk.postTransferIn(address(desk), TAKER, optionToken, address(usdc), 1, 1, 0, bytes32(0), "", "");
        vm.stopPrank();
    }

    function test_rejectsAPairWithNoQuoteLeg() public {
        vm.prank(ROUTER);
        vm.expectRevert(WeekendDesk.BadPair.selector);
        desk.preTransferOut(address(desk), TAKER, address(stray), optionToken, 1, 1, bytes32(0), "", "");
    }

    function test_rejectsAnUnlistedOptionToken() public {
        vm.startPrank(ROUTER);
        vm.expectRevert(abi.encodeWithSelector(WeekendDesk.UnknownToken.selector, address(stray)));
        desk.preTransferOut(address(desk), TAKER, address(usdc), address(stray), 1, 1, bytes32(0), "", "");

        vm.expectRevert(abi.encodeWithSelector(WeekendDesk.UnknownToken.selector, address(stray)));
        desk.postTransferIn(address(desk), TAKER, address(stray), address(usdc), 1, 1, 0, bytes32(0), "", "");
        vm.stopPrank();
    }

    /// @dev The order ships two hook flags. If a third is ever set, fail closed rather than
    ///      silently succeeding on a hook that does no accounting.
    function test_theTwoUnusedHooksFailClosed() public {
        vm.startPrank(ROUTER);
        vm.expectRevert(WeekendDesk.UnusedHook.selector);
        desk.preTransferIn(address(desk), TAKER, address(usdc), optionToken, 1, 1, bytes32(0), "", "");

        vm.expectRevert(WeekendDesk.UnusedHook.selector);
        desk.postTransferOut(address(desk), TAKER, address(usdc), optionToken, 1, 1, 0, bytes32(0), "", "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ admin

    function test_listSeriesMapsTheOptionTokenToItsSeries() public view {
        assertEq(desk.seriesOfToken(optionToken), callId + 1, "id + 1, so 0 means unlisted");
        assertEq(desk.maxShort(callId), CAP);
    }

    function test_listSeriesRejectsMismatchedLengths() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory caps = new uint256[](1);
        vm.expectRevert(WeekendDesk.LengthMismatch.selector);
        desk.listSeries(ids, caps);
    }

    /// @dev A strategy naming someone else would pull THEIR collateral and accrue `written` to
    ///      them, detaching the short cap from the position it bounds.
    function test_setOwnStrategyRejectsAForeignMaker() public {
        WeekendOptions.Strategy memory s = _ownStrategy();
        s.maker = STRANGER;
        vm.expectRevert(WeekendDesk.BadStrategy.selector);
        desk.setOwnStrategy(s);
    }

    function test_adminIsOwnerOnly() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        desk.setActive(false);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        desk.approveAqua(address(usdc), 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        desk.setOwnStrategy(_ownStrategy());
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ ask

    /// @dev The whole point of the desk: no inventory existed a moment ago.
    function test_askMintsJustInTimeAgainstTheDeskSOwnCollateral() public {
        assertEq(_written(), 0);
        _ask(1e18);
        assertEq(_written(), 1e18, "the desk is the writer of record");
        assertEq(_inventory(), 1e18, "minted to the desk, pullable by Aqua one call later");
        assertEq(nvdax.balanceOf(address(app)), 1e18, "cover left the desk's wallet");
    }

    function test_onlyTheShortfallIsMinted() public {
        _ask(1e18);
        _ask(1.5e18);
        assertEq(_written(), 1.5e18, "0.5 more written, not 1.5");
        assertEq(_inventory(), 1.5e18);
    }

    function test_inventoryIsSpentBeforeMinting() public {
        _ask(1e18);
        uint256 writtenAfterFirst = _written();
        _ask(1e18); // the taker of the first ask never pulled; inventory still covers it
        assertEq(_written(), writtenAfterFirst, "nothing new written");
        assertEq(_inventory(), 1e18);
    }

    /// @dev Review Focus #1 in miniature: the cap is cumulative `written`, checked after the
    ///      write, never a per-fill bound. The Aqua ledger is the hard one; this is the soft
    ///      per-series one the desk owns.
    function test_shortCapTripsOnTheFillThatCrossesIt() public {
        _list(1.5e18);
        _ask(1e18);
        vm.expectRevert(abi.encodeWithSelector(WeekendDesk.ShortLimit.selector, callId, 2e18, 1.5e18));
        _ask(2e18);
        assertEq(_written(), 1e18, "the crossing fill unwound whole");
    }

    /// @dev Review Focus #5. Minting does not credit the Aqua ledger; the tokens are pullable
    ///      only because `pull` is a real `transferFrom`. Revoke the approval and the desk
    ///      cannot even take its own cover.
    function test_withoutAnAquaApprovalTheAskCannotTakeItsCover() public {
        desk.approveAqua(address(nvdax), 0);
        vm.expectRevert();
        _ask(1e18);
    }

    // ------------------------------------------------------------------ transfer ordering

    /// @dev Review Focus #3. `IS_FIRST_TRANSFER_FROM_TAKER` is a TAKER trait — the maker cannot
    ///      force it — so the two hooks fire in either order for the same fill. Neither may
    ///      depend on the premium having landed.
    function test_askWorksWithTheDeskShippingFirst() public {
        _ask(1e18);
        _askPremium(5e6);
        assertEq(_written(), 1e18);
        assertEq(_inventory(), 1e18);
    }

    function test_askWorksWithTheTakerPayingFirst() public {
        _askPremium(5e6);
        _ask(1e18);
        assertEq(_written(), 1e18, "identical to the desk-first ordering");
        assertEq(_inventory(), 1e18);
    }

    function test_bidWorksInEitherOrder() public {
        _ask(1e18); // give the desk a written position and inventory to sell back into

        // Desk-first: the quote leaves before the options arrive.
        vm.prank(ROUTER);
        desk.preTransferOut(address(desk), TAKER, optionToken, address(usdc), 1e18, 1e6, bytes32(0), "", "");
        uint256 writtenMid = _written();
        _bid(1e18);
        assertLe(_written(), writtenMid);

        // Taker-first: `postTransferIn` runs with no preceding `preTransferOut` at all.
        _ask(1e18);
        _bid(1e18);
    }

    // ------------------------------------------------------------------ bid

    /// @dev Load-bearing: `close` is extractable today (spec §10 OPEN HAZARD) and may not even
    ///      exist on the core yet, so the bid branch must absorb a revert and keep the options
    ///      as inventory instead of failing the fill. This test passes either way — what it
    ///      pins is that whatever is burned equals whatever is unwound, and the fill survives.
    function test_bidToleratesAFailingClose() public {
        _ask(2e18);
        uint256 writtenBefore = _written();
        uint256 inventoryBefore = _inventory();

        _bid(2e18); // must not revert

        assertLe(_written(), writtenBefore, "close never increases the short");
        assertEq(
            writtenBefore - _written(), inventoryBefore - _inventory(), "burned exactly what was unwound, or nothing"
        );
    }

    /// @dev `close` can only burn against the caller's own `written`; the excess is inventory.
    function test_bidClosesAtMostWhatTheDeskWrote() public {
        _ask(1e18);
        uint256 writtenBefore = _written();
        _bid(5e18); // the taker is selling back more than the desk ever wrote
        assertLe(writtenBefore - _written(), 1e18, "never unwinds past `written`");
    }

    function test_bidWithNothingWrittenIsANoOp() public {
        assertEq(_written(), 0);
        _bid(1e18); // must not revert on the zero guard
        assertEq(_written(), 0);
        assertEq(_inventory(), 0);
    }
}
