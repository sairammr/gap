// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {Aqua} from "@1inch/aqua/contracts/Aqua.sol";
import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockStateView} from "./helpers/MockStateView.sol";
import {TakerStub} from "./helpers/TakerStub.sol";

contract SettleTest is Test {
    Aqua internal aqua;
    GapOptionsApp internal app;
    MockERC20 internal nvdax;
    MockERC20 internal usdc;
    MockStateView internal stateView;
    TakerStub internal stub;

    address internal maker = address(0xBEEF);
    address internal buyerEOA = address(0xB0B);

    // cap=5e18, size=1e18 -> capCollateral = 5e18*1e18/1e30 = 5e6 (5 USDC)
    uint256 internal constant CAP = 5e18;
    uint256 internal constant SIZE = 1e18;
    uint256 internal constant CAP_COLLATERAL = 5e6;
    uint256 internal constant STRIKE = 100e18; // ATM

    // sqrtPriceX96 landing spot at exactly 100e18 (18dp underlying / 6dp quote,
    // underlyingIsCurrency0 = true). See BuyOptionPriced.t.sol derivation.
    uint160 internal constant SQRT_PRICE_100 = 792281625142643375935439;
    // spot == 103e18 (CALL ITM, intrinsic 3, under the cap of 5).
    uint160 internal constant SQRT_PRICE_103 = 804078030258772883013632;
    // spot == 97e18 (CALL OTM, intrinsic 0).
    uint160 internal constant SQRT_PRICE_97 = 780306906500582002917376;

    function setUp() public {
        aqua = new Aqua();
        nvdax = new MockERC20("NVIDIA xStock", "NVDAx", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stateView = new MockStateView(SQRT_PRICE_100);
        app = new GapOptionsApp(IAqua(address(aqua)), IStateView(address(stateView)));
        stub = new TakerStub(IAqua(address(aqua)), address(app));
    }

    function _arr(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _amt(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _strategy(bytes32 salt) internal view returns (GapOptionsApp.Strategy memory s) {
        s = GapOptionsApp.Strategy({
            app: address(app),
            maker: maker,
            underlying: address(nvdax),
            quote: address(usdc),
            poolId: bytes32(uint256(0xABCD)),
            underlyingIsCurrency0: true,
            underlyingDecimals: 18,
            quoteDecimals: 6,
            volWad: 0.6e18,
            salt: salt
        });
    }

    /// @dev Full CALL buy flow. Returns the strategy used and the minted positionId.
    function _buy(bytes32 salt) internal returns (GapOptionsApp.Strategy memory s, uint256 positionId) {
        s = _strategy(salt);
        bytes32 hash = app.hashStrategy(s);

        usdc.mint(maker, CAP_COLLATERAL);
        vm.prank(maker);
        usdc.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(app), abi.encode(s), _arr(address(usdc)), _amt(CAP_COLLATERAL));

        usdc.mint(address(stub), 10e6);

        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory takerData = abi.encode(maker, hash);

        vm.prank(address(stub));
        positionId = app.buyOption(s, 0 /*CALL*/, STRIKE, CAP, expiry, SIZE, 10e6, buyerEOA, takerData);
    }

    /// @notice settle before expiry reverts NotExpired.
    function test_settle_revertsNotExpired() public {
        (GapOptionsApp.Strategy memory s, uint256 positionId) = _buy(bytes32(0));
        vm.expectRevert(GapOptionsApp.NotExpired.selector);
        app.settle(s, positionId, buyerEOA);
    }

    /// @notice ITM CALL: holder paid capped intrinsic, maker returned the remainder,
    ///         position burned, app drained to zero, settled flag set.
    function test_settle_itmCall_paysHolderAndReturnsRemainder() public {
        (GapOptionsApp.Strategy memory s, uint256 positionId) = _buy(bytes32(0));

        stateView.setSqrtPriceX96(SQRT_PRICE_103); // spot ~103 -> intrinsic ~3 (< cap 5)
        vm.warp(block.timestamp + 2 days); // past expiry

        // payout = min(spot-100, cap 5) * size 1, WAD->6dp. The chosen sqrtPrice floors
        // spot a hair under 103e18, so payout is 2.999999 USDC (6dp). Assert the exact
        // on-chain value and that holder + maker splits sum back to the full backing.
        uint256 expectedPayout = 2_999_999;
        uint256 expectedRemainder = CAP_COLLATERAL - expectedPayout;

        uint256 holderBefore = usdc.balanceOf(buyerEOA);
        uint256 makerBefore = usdc.balanceOf(maker);

        app.settle(s, positionId, buyerEOA);

        assertEq(usdc.balanceOf(buyerEOA) - holderBefore, expectedPayout, "holder paid capped intrinsic");
        assertEq(usdc.balanceOf(maker) - makerBefore, expectedRemainder, "maker returned remainder");
        assertEq(usdc.balanceOf(address(app)), 0, "app backing drained");
        assertEq(app.balanceOf(buyerEOA, positionId), 0, "position burned");

        (,,,,,,,,, bool settled,) = app.positions(positionId);
        assertTrue(settled, "settled flag set");
    }

    /// @notice A second settle on the same position reverts AlreadySettled (idempotency).
    function test_settle_revertsAlreadySettled() public {
        (GapOptionsApp.Strategy memory s, uint256 positionId) = _buy(bytes32(0));
        stateView.setSqrtPriceX96(SQRT_PRICE_103);
        vm.warp(block.timestamp + 2 days);

        app.settle(s, positionId, buyerEOA);

        vm.expectRevert(GapOptionsApp.AlreadySettled.selector);
        app.settle(s, positionId, buyerEOA);
    }

    /// @notice A wrong strategy (hash mismatch) reverts StrategyMismatch.
    function test_settle_revertsStrategyMismatch() public {
        (, uint256 positionId) = _buy(bytes32(0));
        vm.warp(block.timestamp + 2 days);

        // A different strategy -> different hash -> mismatch.
        GapOptionsApp.Strategy memory wrong = _strategy(bytes32(uint256(42)));
        vm.expectRevert(GapOptionsApp.StrategyMismatch.selector);
        app.settle(wrong, positionId, buyerEOA);
    }

    /// @notice OTM CALL: holder gets nothing, maker gets the full backing back.
    function test_settle_otmCall_makerGetsFullBacking() public {
        (GapOptionsApp.Strategy memory s, uint256 positionId) = _buy(bytes32(0));

        stateView.setSqrtPriceX96(SQRT_PRICE_97); // spot 97 < strike 100 -> OTM
        vm.warp(block.timestamp + 2 days);

        uint256 holderBefore = usdc.balanceOf(buyerEOA);
        uint256 makerBefore = usdc.balanceOf(maker);

        app.settle(s, positionId, buyerEOA);

        assertEq(usdc.balanceOf(buyerEOA) - holderBefore, 0, "holder paid nothing (OTM)");
        assertEq(usdc.balanceOf(maker) - makerBefore, CAP_COLLATERAL, "maker gets full backing");
        assertEq(usdc.balanceOf(address(app)), 0, "app backing drained");
        assertEq(app.balanceOf(buyerEOA, positionId), 0, "position burned");
    }
}
