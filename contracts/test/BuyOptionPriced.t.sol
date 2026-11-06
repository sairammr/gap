// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {Aqua} from "@1inch/aqua/contracts/Aqua.sol";
import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {UniV4Spot} from "../src/lib/UniV4Spot.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockStateView} from "./helpers/MockStateView.sol";
import {TakerStub} from "./helpers/TakerStub.sol";

contract BuyOptionPricedTest is Test {
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

    // sqrtPriceX96 that yields spotWad == 100e18 for 18dp underlying / 6dp quote,
    // underlyingIsCurrency0 = true. Derivation (see UniV4Spot.fromSqrtPriceX96):
    //   spotWad = (p^2 / Q96) * 1e18 * 10^18 / (Q96 * 10^6) = (p^2 / Q96) * 1e30 / Q96
    //   want 100e18  =>  p^2 = Q96^2 / 1e10  =>  p = Q96 / 1e5 = 2^96 / 100000.
    //   2^96 = 79228162514264337593543950336  =>  p = 792281625142643375935439 (floored).
    uint160 internal constant SQRT_PRICE_100 = 792281625142643375935439;

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

    /// @notice The chosen sqrtPriceX96 lands spot at ~100e18 (within 1 bp).
    function test_spotIsApproximately100() public view {
        GapOptionsApp.Strategy memory s = _strategy(bytes32(0));
        uint256 spot = UniV4Spot.spotWad(
            IStateView(address(stateView)),
            s.poolId,
            s.underlyingDecimals,
            s.quoteDecimals,
            s.underlyingIsCurrency0
        );
        assertApproxEqRel(spot, 100e18, 1e14, "spot ~= 100e18"); // 0.01% tolerance
    }

    /// @notice ATM 1-day call premium is a sane BS value, denominated in 6dp USDC.
    function test_quotePremium_atmCall_inBand() public view {
        GapOptionsApp.Strategy memory s = _strategy(bytes32(0));
        uint64 expiry = uint64(block.timestamp + 1 days);

        uint256 prem = app.quotePremium(s, 0 /*CALL*/, STRIKE, CAP, expiry, SIZE);

        // ATM call, spot~100, vol 0.6, T=1/365: BS value ~1.2 USDC/unit.
        // With size=1 unit and capped at 5, premium lands ~1.2e6 (6dp USDC).
        // Sane band: strictly positive, below the cap collateral, in a loose BS range.
        assertGt(prem, 0.5e6, "premium above lower BS band");
        assertLt(prem, 2.5e6, "premium below upper BS band");
        assertLt(prem, CAP_COLLATERAL, "premium below cap collateral");
    }

    /// @notice quotePremium does not underflow when probed at/after expiry.
    function test_quotePremium_atExpiry_noRevert() public view {
        GapOptionsApp.Strategy memory s = _strategy(bytes32(0));
        // expiry == now: secondsToExpiry defensively floors to 0 -> intrinsic only.
        uint256 prem = app.quotePremium(s, 0, STRIKE, CAP, uint64(block.timestamp), SIZE);
        // ATM intrinsic is 0.
        assertEq(prem, 0, "ATM intrinsic at expiry is zero");
    }

    /// @notice buyOption reverts PoolNotInitialized when the pool slot0 is zero.
    function test_buyOption_revertsPoolNotInitialized() public {
        GapOptionsApp.Strategy memory s = _strategy(bytes32(uint256(7)));
        bytes32 hash = app.hashStrategy(s);

        stateView.setSqrtPriceX96(0); // uninitialised pool

        usdc.mint(maker, CAP_COLLATERAL);
        vm.prank(maker);
        usdc.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(app), abi.encode(s), _arr(address(usdc)), _amt(CAP_COLLATERAL));

        usdc.mint(address(stub), 10e6);

        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory takerData = abi.encode(maker, hash);

        vm.prank(address(stub));
        vm.expectRevert(abi.encodeWithSelector(UniV4Spot.PoolNotInitialized.selector, s.poolId));
        app.buyOption(s, 0, STRIKE, CAP, expiry, SIZE, 10e6, buyerEOA, takerData);
    }

    /// @notice Full buy flow with the priced premium: taker pushes exactly quotePremium.
    function test_buyOption_pricedPremium_endToEnd() public {
        GapOptionsApp.Strategy memory s = _strategy(bytes32(0));
        bytes32 hash = app.hashStrategy(s);

        usdc.mint(maker, CAP_COLLATERAL);
        vm.prank(maker);
        usdc.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(app), abi.encode(s), _arr(address(usdc)), _amt(CAP_COLLATERAL));

        usdc.mint(address(stub), 10e6);

        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory takerData = abi.encode(maker, hash);

        uint256 expectedPremium = app.quotePremium(s, 0, STRIKE, CAP, expiry, SIZE);
        assertGt(expectedPremium, 0, "expected premium positive");

        // Premium pushed into maker matches quotePremium exactly.
        vm.expectEmit(true, true, true, true, address(aqua));
        emit IAqua.Pushed(maker, address(app), hash, address(usdc), expectedPremium);

        uint256 stubBefore = usdc.balanceOf(address(stub));

        vm.prank(address(stub));
        uint256 positionId =
            app.buyOption(s, 0 /*CALL*/, STRIKE, CAP, expiry, SIZE, 10e6 /*maxPremium*/, buyerEOA, takerData);

        assertEq(app.balanceOf(buyerEOA, positionId), SIZE, "position balance");
        assertEq(usdc.balanceOf(address(stub)), stubBefore - expectedPremium, "stub paid priced premium");

        (uint248 bal,) = aqua.rawBalances(maker, address(app), hash, address(usdc));
        assertEq(uint256(bal), expectedPremium, "maker aqua balance == premium");

        assertEq(usdc.balanceOf(address(app)), CAP_COLLATERAL, "app holds collateral");
    }

    /// @notice A premium above the taker's max reverts PremiumTooHigh.
    function test_buyOption_revertsPremiumTooHigh() public {
        GapOptionsApp.Strategy memory s = _strategy(bytes32(uint256(9)));
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
        vm.expectRevert(GapOptionsApp.PremiumTooHigh.selector);
        app.buyOption(s, 0, STRIKE, CAP, expiry, SIZE, 1 /*maxPremium too low*/, buyerEOA, takerData);
    }
}
