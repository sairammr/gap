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

/// @notice Covers the `GapTaker` router: the contract that lets an EOA buy an option.
/// @dev `GapOptionsApp.buyOption` calls `IGapOptionCallback` back on `msg.sender`, so an EOA
///      can never be the direct caller. `GapTaker` is that caller. The two things worth
///      testing are (a) the happy path really pays the premium out of the EOA's wallet, and
///      (b) the callback cannot be driven by anyone other than the app mid-buy — it holds an
///      allowance on every user who has ever approved it, so an unguarded callback would let
///      anyone drain those allowances.
contract GapTakerTest is Test {
    Aqua internal aqua;
    GapOptionsApp internal app;
    GapTaker internal taker;
    MockERC20 internal nvdax;
    MockERC20 internal usdc;
    MockStateView internal stateView;

    address internal maker = address(0xBEEF);
    address internal buyer = address(0xB0B);
    address internal attacker = address(0xBAD);

    uint256 internal constant CAP = 5e18;
    uint256 internal constant SIZE = 1e18;
    uint256 internal constant CAP_COLLATERAL = 5e6;
    uint160 internal constant SQRT_PRICE_100 = 792281625142643375935439;

    function setUp() public {
        aqua = new Aqua();
        nvdax = new MockERC20("NVIDIA xStock", "NVDAx", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stateView = new MockStateView(SQRT_PRICE_100);
        app = new GapOptionsApp(IAqua(address(aqua)), IStateView(address(stateView)));
        taker = new GapTaker(IAqua(address(aqua)), address(app));
    }

    function _strategy() internal view returns (GapOptionsApp.Strategy memory s) {
        s = GapOptionsApp.Strategy({
            app: address(app),
            maker: maker,
            underlying: address(nvdax),
            quote: address(usdc),
            poolId: bytes32(uint256(0xABCD)),
            underlyingIsCurrency0: true,
            underlyingDecimals: 18,
            quoteDecimals: 6,
            volWad: 0.5e18,
            salt: bytes32(0)
        });
    }

    /// @dev Maker ships `CAP_COLLATERAL` USDC and keeps a wallet balance to honour the pull.
    function _ship(GapOptionsApp.Strategy memory s) internal returns (bytes32 hash) {
        hash = app.hashStrategy(s);
        usdc.mint(maker, CAP_COLLATERAL);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = CAP_COLLATERAL;
        vm.startPrank(maker);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.ship(address(app), abi.encode(s), tokens, amounts);
        vm.stopPrank();
    }

    /// @dev The buy itself, in its own frame: the 10-argument call plus an inline
    ///      `abi.encode` overflows the stack when written at the test's top level.
    function _buy(GapOptionsApp.Strategy memory s, bytes32 hash, uint64 expiry, uint256 premium)
        internal
        returns (uint256 positionId)
    {
        bytes memory takerData = abi.encode(maker, hash);
        vm.startPrank(buyer);
        usdc.approve(address(taker), premium);
        positionId = taker.buy(app, s, 0, 100e18, CAP, expiry, SIZE, premium, buyer, takerData);
        vm.stopPrank();
    }

    function test_buy_paysPremiumFromBuyerWallet() public {
        GapOptionsApp.Strategy memory s = _strategy();
        bytes32 hash = _ship(s);

        usdc.mint(buyer, 100e6);
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 premium = app.quotePremium(s, 0, 100e18, CAP, expiry, SIZE);
        assertGt(premium, 0, "premium should be non-zero");

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 positionId = _buy(s, hash, expiry, premium);

        // The buyer holds the position and paid exactly the premium out of their own wallet.
        assertEq(app.balanceOf(buyer, positionId), SIZE, "position not minted to buyer");
        assertEq(buyerBefore - usdc.balanceOf(buyer), premium, "buyer did not pay exactly the premium");
        // The router is a pure pass-through: it must never retain funds between calls.
        assertEq(usdc.balanceOf(address(taker)), 0, "router retained funds");
        // The app holds the pulled backing.
        assertEq(usdc.balanceOf(address(app)), CAP_COLLATERAL, "app did not take the backing");
    }

    /// @dev The callback must be callable only by the app. It is the guard standing between
    ///      an attacker and every allowance users have granted this shared router.
    function test_callback_revertsWhenNotApp() public {
        vm.prank(attacker);
        vm.expectRevert(GapTaker.OnlyApp.selector);
        taker.gapOptionCallback(attacker, address(usdc), 1e6, abi.encode(maker, bytes32(0)));
    }

    /// @dev Even the app cannot drive the callback outside a live `buy` — `payer` is transient
    ///      and is zero unless a buy is in flight, so there is no one to charge.
    function test_callback_revertsWithNoBuyInFlight() public {
        vm.prank(address(app));
        vm.expectRevert(GapTaker.NoBuyInFlight.selector);
        taker.gapOptionCallback(buyer, address(usdc), 1e6, abi.encode(maker, bytes32(0)));
    }

    /// @dev `payer` must not survive the call that set it, or the next victim to approve the
    ///      router could be charged by a stale entry.
    function test_payer_isClearedAfterBuy() public {
        GapOptionsApp.Strategy memory s = _strategy();
        bytes32 hash = _ship(s);
        usdc.mint(buyer, 100e6);
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 premium = app.quotePremium(s, 0, 100e18, CAP, expiry, SIZE);

        _buy(s, hash, expiry, premium);

        vm.prank(address(app));
        vm.expectRevert(GapTaker.NoBuyInFlight.selector);
        taker.gapOptionCallback(buyer, address(usdc), 1e6, abi.encode(maker, hash));
    }
}
