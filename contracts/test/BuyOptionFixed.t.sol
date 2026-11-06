// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {Aqua} from "@1inch/aqua/contracts/Aqua.sol";
import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {TakerStub} from "./helpers/TakerStub.sol";

contract BuyOptionFixedTest is Test {
    Aqua internal aqua;
    GapOptionsApp internal app;
    MockERC20 internal nvdax;
    MockERC20 internal usdc;
    TakerStub internal stub;

    address internal maker = address(0xBEEF);
    address internal buyerEOA = address(0xB0B);

    // cap=5e18, size=1e18 -> capCollateral = 5e18*1e18/1e30 = 5e6 (5 USDC)
    uint256 internal constant CAP = 5e18;
    uint256 internal constant SIZE = 1e18;
    uint256 internal constant CAP_COLLATERAL = 5e6;
    uint256 internal constant PREMIUM = 5e5; // capCollateral / 10

    function setUp() public {
        aqua = new Aqua();
        nvdax = new MockERC20("NVIDIA xStock", "NVDAx", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        app = new GapOptionsApp(IAqua(address(aqua)), IStateView(address(0x5)));
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

    function test_buyOption_endToEnd() public {
        GapOptionsApp.Strategy memory s = _strategy(bytes32(0));
        bytes32 hash = app.hashStrategy(s);

        // Maker ships USDC collateral.
        usdc.mint(maker, CAP_COLLATERAL);
        vm.prank(maker);
        usdc.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(app), abi.encode(s), _arr(address(usdc)), _amt(CAP_COLLATERAL));

        // Fund the taker stub with enough USDC for the premium.
        usdc.mint(address(stub), 1e6);

        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory takerData = abi.encode(maker, hash);

        // Expect the Aqua Pulled event (USDC collateral out of maker).
        vm.expectEmit(true, true, true, true, address(aqua));
        emit IAqua.Pulled(maker, address(app), hash, address(usdc), CAP_COLLATERAL);
        // Expect the Aqua Pushed event (premium into maker).
        vm.expectEmit(true, true, true, true, address(aqua));
        emit IAqua.Pushed(maker, address(app), hash, address(usdc), PREMIUM);

        vm.prank(address(stub));
        uint256 positionId =
            app.buyOption(s, 0 /*CALL*/, 100e18, CAP, expiry, SIZE, 1e6 /*maxPremium*/, buyerEOA, takerData);

        // ERC-1155 minted to buyer.
        assertEq(app.balanceOf(buyerEOA, positionId), SIZE, "position balance");

        // Stub paid the premium.
        assertEq(usdc.balanceOf(address(stub)), 1e6 - PREMIUM, "stub premium paid");

        // Maker's Aqua USDC balance: 5e6 shipped, pulled 5e6 -> 0, pushed 5e5 -> 5e5.
        (uint248 bal,) = aqua.rawBalances(maker, address(app), hash, address(usdc));
        assertEq(uint256(bal), PREMIUM, "maker aqua balance");

        // App now holds the full collateral.
        assertEq(usdc.balanceOf(address(app)), CAP_COLLATERAL, "app holds collateral");

        // Position record.
        _assertPosition(positionId, hash, expiry);
    }

    function _assertPosition(uint256 positionId, bytes32 hash, uint64 expiry) internal view {
        (
            bytes32 strategyHash,
            address pMaker,
            address underlying,
            address quote,
            uint8 kind,
            uint256 strike,
            uint256 cap,
            uint64 pExpiry,
            uint256 pSize,
            bool settled,
            uint256 capBacking
        ) = app.positions(positionId);
        assertEq(strategyHash, hash, "pos hash");
        assertEq(pMaker, maker, "pos maker");
        assertEq(underlying, address(nvdax), "pos underlying");
        assertEq(quote, address(usdc), "pos quote");
        assertEq(kind, 0, "pos kind");
        assertEq(strike, 100e18, "pos strike");
        assertEq(cap, CAP, "pos cap");
        assertEq(pExpiry, expiry, "pos expiry");
        assertEq(pSize, SIZE, "pos size");
        assertEq(settled, false, "pos settled");
        assertEq(capBacking, CAP_COLLATERAL, "pos capBacking");
    }

    function test_buyOption_revertsOnInsufficientCollateral() public {
        GapOptionsApp.Strategy memory s = _strategy(bytes32(uint256(1)));
        bytes32 hash = app.hashStrategy(s);

        // Maker ships too little: 1e6, but cap*size needs 5e6.
        usdc.mint(maker, 1e6);
        vm.prank(maker);
        usdc.approve(address(aqua), type(uint256).max);
        vm.prank(maker);
        aqua.ship(address(app), abi.encode(s), _arr(address(usdc)), _amt(1e6));

        usdc.mint(address(stub), 1e6);

        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes memory takerData = abi.encode(maker, hash);

        vm.prank(address(stub));
        vm.expectRevert(GapOptionsApp.InsufficientMakerCollateral.selector);
        app.buyOption(s, 0, 100e18, CAP, expiry, SIZE, 1e6, buyerEOA, takerData);
    }
}
