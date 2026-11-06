// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CalldataParse } from "@1inch/solidity-utils/contracts/libraries/CalldataParse.sol";

import { Context } from "../libs/VM.sol";
import { Opcode } from "../libs/OpcodeList.sol";
import { MemoryPtr, MemoryPtrLib } from "../libs/MemoryPtr.sol";
import { InstructionBuilder } from "../libs/InstructionBuilder.sol";

/// @notice WeekendGap opcode — prices a *capped* overnight-gap option premium into the swap registers.
/// @dev Encoding: [uint8 kind, uint256 spot, uint256 strike, uint256 cap, uint64 secondsToExpiry, uint256 volWad]
///
/// This is the SwapVM-native analogue of the Gap platform's `GapPricing.premium`
/// (contracts/src/lib/GapPricing.sol): the on-VM capped-payout primitive for an overnight-gap option.
///
/// SCOPE DECISION (documented): the reference `GapPricing` prices a *full* Black-Scholes (r = 0) capped
/// vertical spread — `call(K) - call(K+cap)` / `put(K) - put(K-cap)` — using the Abramowitz-Stegun 26.2.17
/// normal CDF, which needs WAD `exp`/`ln`/`sqrt`. SwapVM ships neither solady's `FixedPointMathLib` nor any
/// WAD transcendental library (its only math is OpenZeppelin `Math` — integer `sqrt`/`mulDiv`/`ceilDiv`),
/// and vendoring a WAD `exp`/`ln` implementation into the VM purely to run a CDF inside one instruction is
/// both heavier than the VM's instruction model wants and pulls unaudited transcendental math into the
/// pricing path. So this opcode computes the **capped linearized premium**: the capped intrinsic value plus
/// a bounded Bachelier-style time-value term `~0.4 * sigma * sqrt(T) * spot`, the whole thing capped at the
/// collateral `cap`. This preserves the economically load-bearing property of the capped spread — the
/// premium is bounded by `cap`, so the writer is always fully collateralised by exactly `cap` per unit —
/// which is the invariant the on-chain settlement relies on. The *full* A&S Black-Scholes premium remains in
/// `GapOptionsApp.quotePremium` / `GapPricing` off the VM; this opcode is the on-VM capped-payout primitive.
///
/// The computed premium is written to `ctx.swap.amountOut`, the register the VM returns as the computed
/// amount for an exact-in quote (matching how `XYCSwap.exec` writes its result). For an exact-out quote the
/// premium is written to `ctx.swap.amountIn`.
library WeekendGap {
    using CalldataParse for bytes;
    using InstructionBuilder for MemoryPtr;

    using Math for uint256;

    Opcode constant opcode = Opcode.WeekendGap;

    uint8 internal constant CALL = 0;
    uint8 internal constant PUT = 1;

    /// @dev WAD scale (1e18)
    uint256 internal constant WAD = 1e18;
    /// @dev seconds in a 365-day year
    uint256 internal constant YEAR = 365 days;
    /// @dev 1 / sqrt(2 * pi) in WAD — the Bachelier at-the-money time-value coefficient (~0.3989)
    uint256 internal constant INV_SQRT_2PI = 398942280401432678;

    error WeekendGapUnknownKind(uint8 kind);

    function sizeOf() internal pure returns (uint256) {
        // header(2) + kind(1) + spot(32) + strike(32) + cap(32) + secondsToExpiry(8) + volWad(32)
        return InstructionBuilder.sizeOf() + 1 + 32 + 32 + 32 + 8 + 32;
    }

    /// @param kind `CALL` (0) or `PUT` (1)
    /// @param spot Spot price, WAD quote per underlying
    /// @param strike Strike price, WAD
    /// @param cap Maximum payoff per unit, WAD (also the collateral locked per unit)
    /// @param secondsToExpiry Time to expiry in seconds
    /// @param volWad Annualised implied volatility, WAD (1e18 == 100%)
    function build(
        uint8 kind,
        uint256 spot,
        uint256 strike,
        uint256 cap,
        uint64 secondsToExpiry,
        uint256 volWad
    ) internal pure returns (bytes memory) {
        return build(MemoryPtrLib.alloc(sizeOf()), kind, spot, strike, cap, secondsToExpiry, volWad).resolve();
    }

    function build(
        MemoryPtr ptrStart,
        uint8 kind,
        uint256 spot,
        uint256 strike,
        uint256 cap,
        uint64 secondsToExpiry,
        uint256 volWad
    ) internal pure returns (MemoryPtr ptr) {
        require(kind == CALL || kind == PUT, WeekendGapUnknownKind(kind));

        ptr = ptrStart.pushHeader(opcode);
        ptr = ptr
            .push(kind)
            .push(spot, 32)
            .push(strike, 32)
            .push(cap, 32)
            .push(uint256(secondsToExpiry), 8)
            .push(volWad, 32);
        ptrStart.patchLength(ptr);
    }

    function parse(bytes calldata args)
        internal
        pure
        returns (uint8 kind, uint256 spot, uint256 strike, uint256 cap, uint64 secondsToExpiry, uint256 volWad)
    {
        kind = args.at(0).asU8();
        spot = args.at(1).asU256();
        strike = args.at(33).asU256();
        cap = args.at(65).asU256();
        secondsToExpiry = args.at(97).asU64();
        volWad = args.at(105).asU256();
    }

    /// @notice Capped gap-option premium, WAD quote per 1 WAD of underlying.
    /// @dev Pure helper so tests (and the quoting path) can price without a VM context.
    function premium(
        uint8 kind,
        uint256 spot,
        uint256 strike,
        uint256 cap,
        uint256 secondsToExpiry,
        uint256 volWad
    ) internal pure returns (uint256) {
        // Capped intrinsic: the bounded payoff of the vertical spread at expiry.
        uint256 intrinsic;
        if (kind == CALL) {
            intrinsic = spot > strike ? spot - strike : 0;
        } else if (kind == PUT) {
            intrinsic = strike > spot ? strike - spot : 0;
        } else {
            revert WeekendGapUnknownKind(kind);
        }
        if (intrinsic > cap) intrinsic = cap;

        // Bachelier at-the-money time value: timeValue = INV_SQRT_2PI * (sigma * sqrt(T)) * spot.
        // sigmaRootT = volWad * sqrt(T_years), all WAD. sqrtWad(x) = sqrt(x * 1e18).
        uint256 timeValue;
        if (secondsToExpiry != 0 && volWad != 0 && spot != 0) {
            uint256 tWad = Math.mulDiv(secondsToExpiry, WAD, YEAR); // T in years, WAD
            uint256 sqrtTWad = Math.sqrt(tWad * WAD); // sqrt(T) in WAD
            uint256 sigmaRootT = Math.mulDiv(volWad, sqrtTWad, WAD); // sigma * sqrt(T), WAD
            uint256 stdMove = Math.mulDiv(sigmaRootT, spot, WAD); // absolute 1-sigma move, WAD
            timeValue = Math.mulDiv(INV_SQRT_2PI, stdMove, WAD); // ~0.3989 * stdMove
        }

        uint256 p = intrinsic + timeValue;
        // The capped spread's premium can never exceed the collateral locked per unit.
        return p > cap ? cap : p;
    }

    function exec(Context memory ctx, bytes calldata args) internal pure {
        (uint8 kind, uint256 spot, uint256 strike, uint256 cap, uint64 secondsToExpiry, uint256 volWad) = parse(args);

        uint256 p = premium(kind, spot, strike, cap, secondsToExpiry, volWad);

        // Write the computed premium into the register the VM returns downstream.
        // exactIn  -> the taker specified amountIn, the VM reports amountOut (the premium owed).
        // exactOut -> the taker specified amountOut, the VM reports amountIn (the premium owed).
        if (ctx.query.isExactIn) {
            ctx.swap.amountOut = p;
        } else {
            ctx.swap.amountIn = p;
        }
    }
}
