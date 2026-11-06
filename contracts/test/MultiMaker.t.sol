// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {Aqua} from "@1inch/aqua/contracts/Aqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {GapTaker} from "../src/GapTaker.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockStateView} from "./helpers/MockStateView.sol";

/// @notice Covers `makerCapacity` + `quoteBest`: Gap as a multi-maker market where Aqua's
///         `Shipped` log IS the order book and makers compete on implied vol.
/// @dev The load-bearing case is `test_quoteBest_skipsMakerWithEmptyWallet`. Aqua's `ship`
///      records an accounting entry only; the ERC-20 does not move until `pull` time, out of
///      the maker's own wallet. A maker can look fully collateralised on Aqua's books and
///      still blow up `buyOption` with `ERC20InsufficientBalance`. That bug bit the live
///      Base Sepolia deploy; `makerCapacity`'s `min()` is the fix and this is its test.
contract MultiMakerTest is Test {
    Aqua internal aqua;
    GapOptionsApp internal app;
    GapTaker internal taker;
    MockERC20 internal nvdax;
    MockERC20 internal usdc;
    MockStateView internal stateView;

    address internal m45 = address(0xA45); // cheapest: 45% IV
    address internal m50 = address(0xA50);
    address internal m60 = address(0xA60); // dearest: 60% IV
    address internal buyer = address(0xB0B);

    uint256 internal constant CAP = 5e18;
    uint256 internal constant SIZE = 1e18;
    uint256 internal constant CAP_BACKING = 5e6; // CAP * SIZE / 1e30
    uint256 internal constant STRIKE = 100e18; // at the money vs SQRT_PRICE_100
    uint160 internal constant SQRT_PRICE_100 = 792281625142643375935439;

    uint64 internal expiry;

    function setUp() public {
        aqua = new Aqua();
        nvdax = new MockERC20("NVIDIA xStock", "NVDAx", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stateView = new MockStateView(SQRT_PRICE_100);
        app = new GapOptionsApp(IAqua(address(aqua)), IStateView(address(stateView)));
        taker = new GapTaker(IAqua(address(aqua)), address(app));
        expiry = uint64(block.timestamp + 1 days);
    }

    // ------------------------------------------------------------------
    // fixtures
    // ------------------------------------------------------------------

    function _strategy(address maker, uint256 volWad) internal view returns (GapOptionsApp.Strategy memory s) {
        s = GapOptionsApp.Strategy({
            app: address(app),
            maker: maker,
            underlying: address(nvdax),
            quote: address(usdc),
            poolId: bytes32(uint256(0xABCD)),
            underlyingIsCurrency0: true,
            underlyingDecimals: 18,
            quoteDecimals: 6,
            volWad: volWad,
            salt: bytes32(0)
        });
    }

    /// @dev Ship `amount` into Aqua AND leave `amount` in the maker's wallet to honour the
    ///      later pull — both halves, as a real maker must.
    function _ship(GapOptionsApp.Strategy memory s, uint256 amount) internal {
        usdc.mint(s.maker, amount);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.startPrank(s.maker);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.ship(address(app), abi.encode(s), tokens, amounts);
        vm.stopPrank();
    }

    /// @dev Three solvent makers at 45% / 50% / 60% IV, shipped and wallet-backed.
    function _threeMakers() internal returns (GapOptionsApp.Strategy[] memory ss) {
        ss = new GapOptionsApp.Strategy[](3);
        ss[0] = _strategy(m50, 0.50e18);
        ss[1] = _strategy(m60, 0.60e18);
        ss[2] = _strategy(m45, 0.45e18);
        for (uint256 i; i < ss.length; ++i) {
            _ship(ss[i], CAP_BACKING);
        }
    }

    function _best(GapOptionsApp.Strategy[] memory ss) internal view returns (uint256, uint256, address) {
        return app.quoteBest(ss, 0 /*CALL*/, STRIKE, CAP, expiry, SIZE);
    }

    // ------------------------------------------------------------------
    // competition on implied vol
    // ------------------------------------------------------------------

    /// @dev `quotePremium` ignores `s.maker`, so the only thing separating these three is
    ///      `volWad`. The cheapest vol must win, and it must not be the first in the array.
    function test_quoteBest_picksCheapestVol() public {
        GapOptionsApp.Strategy[] memory ss = _threeMakers();

        uint256 p50 = app.quotePremium(ss[0], 0, STRIKE, CAP, expiry, SIZE);
        uint256 p60 = app.quotePremium(ss[1], 0, STRIKE, CAP, expiry, SIZE);
        uint256 p45 = app.quotePremium(ss[2], 0, STRIKE, CAP, expiry, SIZE);
        assertLt(p45, p50, "lower IV must quote cheaper");
        assertLt(p50, p60, "higher IV must quote dearer");

        (uint256 idx, uint256 premium, address maker) = _best(ss);
        assertEq(idx, 2, "should pick the 45% maker, not merely the first entry");
        assertEq(premium, p45, "best premium should be the 45% quote");
        assertEq(maker, m45, "best maker should be the 45% maker");
    }

    // ------------------------------------------------------------------
    // solvency: the min() that matters
    // ------------------------------------------------------------------

    /// @dev THE bug. The maker ships, then spends their wallet (on the live deploy: seeding
    ///      the v4 pool). Aqua's books still show full collateral, but the pull would revert.
    ///      `quoteBest` must skip them even though they quote the cheapest premium.
    function test_quoteBest_skipsMakerWithEmptyWallet() public {
        GapOptionsApp.Strategy[] memory ss = _threeMakers();

        // The 45% maker (cheapest, index 2) drains their wallet after shipping.
        // Read the balance BEFORE the prank: an argument expression is itself a call and
        // would otherwise consume the single-shot prank.
        uint256 drained = usdc.balanceOf(m45);
        vm.prank(m45);
        usdc.transfer(address(0xDEAD), drained);

        (uint256 committed, uint256 wallet, uint256 backable) = app.makerCapacity(ss[2]);
        assertEq(committed, CAP_BACKING, "aqua still shows the full commitment");
        assertEq(wallet, 0, "wallet is empty");
        assertEq(backable, 0, "backable is min(commitment, wallet) == 0");

        (uint256 idx,, address maker) = _best(ss);
        assertEq(idx, 0, "insolvent cheapest maker must be skipped");
        assertEq(maker, m50, "next-cheapest SOLVENT maker wins");
    }

    /// @dev Under-collateralised on Aqua's side: wallet is fine, the commitment is not.
    function test_quoteBest_skipsMakerBelowCapBacking() public {
        GapOptionsApp.Strategy[] memory ss = new GapOptionsApp.Strategy[](2);
        ss[0] = _strategy(m45, 0.45e18);
        ss[1] = _strategy(m50, 0.50e18);

        _ship(ss[0], CAP_BACKING - 1); // one wei short of what a buy pulls
        _ship(ss[1], CAP_BACKING);

        (,, uint256 backable) = app.makerCapacity(ss[0]);
        assertEq(backable, CAP_BACKING - 1, "backable is the short commitment");
        assertLt(backable, app.capBacking(CAP, SIZE), "and it is below the buy threshold");

        (uint256 idx,, address maker) = _best(ss);
        assertEq(idx, 1, "under-collateralised maker must be skipped");
        assertEq(maker, m50);
    }

    /// @dev An empty market must render, not revert.
    function test_quoteBest_allInsolventReturnsSentinel() public view {
        GapOptionsApp.Strategy[] memory ss = new GapOptionsApp.Strategy[](2);
        ss[0] = _strategy(m45, 0.45e18);
        ss[1] = _strategy(m50, 0.50e18);
        // Neither has ever shipped: committed == 0, wallet == 0.

        (uint256 idx, uint256 premium, address maker) = _best(ss);
        assertEq(idx, type(uint256).max, "sentinel index");
        assertEq(premium, 0, "no premium");
        assertEq(maker, address(0), "no maker");
    }

    function test_quoteBest_emptyArrayReturnsSentinel() public view {
        GapOptionsApp.Strategy[] memory ss = new GapOptionsApp.Strategy[](0);
        (uint256 idx, uint256 premium, address maker) = _best(ss);
        assertEq(idx, type(uint256).max);
        assertEq(premium, 0);
        assertEq(maker, address(0));
    }

    /// @dev A strategy bound to another app is not this market's business, however cheap and
    ///      however well collateralised it looks there.
    function test_quoteBest_skipsStrategyBoundToAnotherApp() public {
        GapOptionsApp other = new GapOptionsApp(IAqua(address(aqua)), IStateView(address(stateView)));

        GapOptionsApp.Strategy[] memory ss = new GapOptionsApp.Strategy[](2);
        ss[0] = _strategy(m45, 0.45e18);
        ss[0].app = address(other); // cheapest, but foreign
        ss[1] = _strategy(m50, 0.50e18);

        _ship(ss[1], CAP_BACKING);
        // Ship the foreign one properly too, so the ONLY reason to skip it is the app binding.
        usdc.mint(m45, CAP_BACKING);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = CAP_BACKING;
        vm.startPrank(m45);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.ship(address(other), abi.encode(ss[0]), tokens, amounts);
        vm.stopPrank();

        (uint256 idx,, address maker) = _best(ss);
        assertEq(idx, 1, "foreign-app strategy must be skipped");
        assertEq(maker, m50);
    }

    // ------------------------------------------------------------------
    // a quote that cannot be filled is worse than no quote
    // ------------------------------------------------------------------

    /// @dev End-to-end consistency: feed `quoteBest`'s winner straight into a real buy
    ///      through `GapTaker` and require it to clear, at exactly the quoted premium.
    function test_quoteBest_winnerIsActuallyFillable() public {
        GapOptionsApp.Strategy[] memory ss = _threeMakers();
        (uint256 idx, uint256 premium, address maker) = _best(ss);
        assertEq(idx, 2);

        usdc.mint(buyer, 100e6);
        uint256 positionId = _buy(ss[idx], premium);

        assertEq(app.balanceOf(buyer, positionId), SIZE, "position not minted to buyer");
        assertEq(usdc.balanceOf(address(app)), CAP_BACKING, "app did not pull the winner's backing");
        (, address pMaker,,,,,,,,,) = app.positions(positionId);
        assertEq(pMaker, maker, "position written against the quoted maker");

        // The winner's wallet funded the pull, so their capacity is now exhausted and
        // quoteBest must fall through to the next solvent maker.
        (,, uint256 backableAfter) = app.makerCapacity(ss[idx]);
        assertLt(backableAfter, app.capBacking(CAP, SIZE), "winner's capacity not consumed");
        (uint256 idx2,, address maker2) = _best(ss);
        assertEq(idx2, 0, "market rolls to the next solvent maker");
        assertEq(maker2, m50);
    }

    /// @dev Own frame: the 10-argument `buy` plus an inline `abi.encode` overflows the stack
    ///      when written at the test's top level.
    function _buy(GapOptionsApp.Strategy memory s, uint256 premium) internal returns (uint256 positionId) {
        bytes memory takerData = abi.encode(s.maker, app.hashStrategy(s));
        vm.startPrank(buyer);
        usdc.approve(address(taker), premium);
        positionId = taker.buy(app, s, 0, STRIKE, CAP, expiry, SIZE, premium, buyer, takerData);
        vm.stopPrank();
    }
}
