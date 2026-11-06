// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";

import { CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { WeekendGap } from "../../contracts/instructions/WeekendGap.sol";
import { Opcode } from "../../contracts/libs/OpcodeList.sol";
import { Context } from "../../contracts/libs/VM.sol";

/// @title WeekendGapTest
/// @notice Exercises the WeekendGap opcode end-to-end through a minimal VM program, plus unit-level
///         checks of the capped-premium math. Shaped like FeeIndifferencyToSwap's lightweight harness:
///         a tiny in-test dispatcher runs the built program through ContextLib.runLoop so the opcode's
///         build()/parse()/exec() path is validated exactly as the real VM would drive it.
contract WeekendGapTest is Test {
    uint256 internal constant WAD = 1e18;

    /// @dev Test-only dispatcher: routes the WeekendGap opcode to its handler.
    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal {
        if (opcode == WeekendGap.opcode.asU8()) return WeekendGap.exec(ctx, args);
        revert("unexpected opcode");
    }

    /// @dev Runs a program through a fresh context. External so `program` is real calldata.
    function runProgram(bool exactIn, bytes calldata program)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        Context memory ctx;
        ctx.query.isExactIn = exactIn;
        ctx.swap.amountIn = exactIn ? 1e18 : 0;
        ctx.swap.amountOut = exactIn ? 0 : 1e18;

        ctx.vm.dispatch = _dispatch;
        ctx.vm.nextPC = 0;
        ctx.vm.isStaticContext = true;
        ctx.vm.programPtr = CalldataPtrLib.from(program);

        return ctx.runLoop();
    }

    // ------------------------------------------------------------------
    // Opcode identity
    // ------------------------------------------------------------------

    function test_WeekendGap_OpcodeIsFreeSwapCurveSlot_0x52() public pure {
        assertEq(uint8(Opcode.WeekendGap), 0x52, "WeekendGap must occupy swap-curve slot 0x52");
    }

    // ------------------------------------------------------------------
    // End-to-end: build a strategy program and run it through the VM loop
    // ------------------------------------------------------------------

    function test_WeekendGap_ExactIn_WritesPremiumIntoAmountOut() public {
        uint8 kind = WeekendGap.CALL;
        uint256 spot = 100e18;
        uint256 strike = 100e18; // at-the-money -> premium is pure (capped) time value
        uint256 cap = 10e18;
        uint64 ttl = 2 days;
        uint256 volWad = 0.5e18; // 50% IV, matches the Ship.s.sol strategy

        bytes memory program = WeekendGap.build(kind, spot, strike, cap, ttl, volWad);

        uint256 expected = WeekendGap.premium(kind, spot, strike, cap, ttl, volWad);

        (, uint256 amountOut) = this.runProgram(true, program);

        assertEq(amountOut, expected, "exactIn amountOut must equal the capped premium");
        assertGt(amountOut, 0, "ATM option with time + vol must carry a positive premium");
        assertLe(amountOut, cap, "premium can never exceed the cap (collateral) per unit");
    }

    function test_WeekendGap_ExactOut_WritesPremiumIntoAmountIn() public {
        uint8 kind = WeekendGap.PUT;
        uint256 spot = 90e18;
        uint256 strike = 100e18; // in-the-money put -> intrinsic 10, equals cap here
        uint256 cap = 10e18;
        uint64 ttl = 1 days;
        uint256 volWad = 0.5e18;

        bytes memory program = WeekendGap.build(kind, spot, strike, cap, ttl, volWad);

        uint256 expected = WeekendGap.premium(kind, spot, strike, cap, ttl, volWad);

        (uint256 amountIn,) = this.runProgram(false, program);

        assertEq(amountIn, expected, "exactOut amountIn must equal the capped premium");
        assertEq(amountIn, cap, "intrinsic already at the cap -> premium pinned to cap");
    }

    // ------------------------------------------------------------------
    // Capped-premium invariants (the economically load-bearing property)
    // ------------------------------------------------------------------

    function test_WeekendGap_PremiumNeverExceedsCap_Fuzz(
        uint8 kindSeed,
        uint256 spot,
        uint256 strike,
        uint256 cap,
        uint64 ttl,
        uint256 volWad
    ) public pure {
        uint8 kind = kindSeed % 2; // 0 = CALL, 1 = PUT
        spot = bound(spot, 0, 1_000_000e18);
        strike = bound(strike, 0, 1_000_000e18);
        cap = bound(cap, 0, 1_000_000e18);
        volWad = bound(volWad, 0, 5e18); // up to 500% IV

        uint256 p = WeekendGap.premium(kind, spot, strike, cap, ttl, volWad);
        assertLe(p, cap, "capped premium must never exceed the collateral cap");
    }

    function test_WeekendGap_DeepOTM_IsPurelyTimeValue() public pure {
        // Deep out-of-the-money call: zero intrinsic, so the whole premium is the time-value term.
        uint8 kind = WeekendGap.CALL;
        uint256 spot = 100e18;
        uint256 strike = 200e18;
        uint256 cap = 50e18;
        uint64 ttl = 2 days;
        uint256 volWad = 0.5e18;

        uint256 p = WeekendGap.premium(kind, spot, strike, cap, ttl, volWad);
        assertGt(p, 0, "nonzero vol + time -> positive time value even when OTM");
        assertLt(p, cap, "small time value stays well under the cap");
    }

    function test_WeekendGap_NoTimeNoVol_IsCappedIntrinsic() public pure {
        // Zero time to expiry collapses the premium to the capped intrinsic value.
        uint8 kind = WeekendGap.CALL;
        uint256 spot = 130e18;
        uint256 strike = 100e18; // intrinsic 30
        uint256 cap = 10e18; // but cap pins it to 10
        uint256 p = WeekendGap.premium(kind, spot, strike, cap, 0, 0);
        assertEq(p, cap, "no time/vol -> capped intrinsic == cap when intrinsic exceeds cap");

        uint256 p2 = WeekendGap.premium(kind, 105e18, strike, cap, 0, 0); // intrinsic 5 < cap
        assertEq(p2, 5e18, "no time/vol -> capped intrinsic when intrinsic below cap");
    }
}
