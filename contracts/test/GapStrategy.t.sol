// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {GapOptionsApp} from "../src/GapOptionsApp.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";

/// @dev Test-only harness exposing the internal `_validateStrategy`.
contract GapAppHarness is GapOptionsApp {
    constructor(IAqua a, IStateView sv) GapOptionsApp(a, sv) {}

    function validate(Strategy calldata s) external view {
        _validateStrategy(s);
    }
}

contract GapStrategyTest is Test {
    GapOptionsApp internal gapApp;
    GapAppHarness internal harness;

    IAqua internal constant DUMMY_AQUA = IAqua(address(0xA9));
    IStateView internal constant DUMMY_STATE = IStateView(address(0x5));

    function setUp() public {
        gapApp = new GapOptionsApp(DUMMY_AQUA, DUMMY_STATE);
        harness = new GapAppHarness(DUMMY_AQUA, DUMMY_STATE);
    }

    function _buildStrategy(address app) internal pure returns (GapOptionsApp.Strategy memory s) {
        s = GapOptionsApp.Strategy({
            app: app,
            maker: address(0xBEEF),
            underlying: address(0x1111),
            quote: address(0x2222),
            poolId: bytes32(uint256(0xABCD)),
            underlyingIsCurrency0: true,
            underlyingDecimals: 18,
            quoteDecimals: 6,
            volWad: 5e17,
            salt: bytes32(uint256(42))
        });
    }

    function test_hashStrategy_matchesAbiEncode() public view {
        GapOptionsApp.Strategy memory s = _buildStrategy(address(gapApp));
        assertEq(gapApp.hashStrategy(s), keccak256(abi.encode(s)));
    }

    function test_validateStrategy_passesWhenAppMatches() public view {
        GapOptionsApp.Strategy memory s = _buildStrategy(address(harness));
        harness.validate(s); // must not revert
    }

    function test_validateStrategy_revertsWhenAppMismatch() public {
        GapOptionsApp.Strategy memory s = _buildStrategy(address(0xdead));
        vm.expectRevert(GapOptionsApp.NotThisApp.selector);
        harness.validate(s);
    }
}
