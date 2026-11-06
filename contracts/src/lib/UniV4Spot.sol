// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib as F } from "solady/utils/FixedPointMathLib.sol";

import { IStateView } from "../interfaces/IStateView.sol";

/// @title UniV4Spot
/// @notice Reads a Uniswap v4 pool's spot price and normalises it to WAD quote-per-underlying.
/// @dev v4 core exposes no TWAP accumulator (that is a hook's job), so this is the instantaneous
///      `sqrtPriceX96` from slot0. Callers needing manipulation resistance must layer their own
///      observation window on top — `GapOptionsApp` does exactly that for settlement.
library UniV4Spot {
    error PoolNotInitialized(bytes32 poolId);

    uint256 private constant Q96 = 1 << 96;

    /// @notice Spot price of `underlying` denominated in `quote`, scaled to WAD.
    /// @param stateView The v4 StateView lens
    /// @param poolId The v4 pool id (keccak256 of the PoolKey)
    /// @param underlyingDecimals Decimals of the underlying token
    /// @param quoteDecimals Decimals of the quote token
    /// @param underlyingIsCurrency0 True when the underlying sorts below the quote token address
    function spotWad(
        IStateView stateView,
        bytes32 poolId,
        uint8 underlyingDecimals,
        uint8 quoteDecimals,
        bool underlyingIsCurrency0
    ) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        return fromSqrtPriceX96(sqrtPriceX96, poolId, underlyingDecimals, quoteDecimals, underlyingIsCurrency0);
    }

    /// @notice Pure form of `spotWad`, so a tick observation can be converted without a pool read.
    function fromSqrtPriceX96(
        uint160 sqrtPriceX96,
        bytes32 poolId,
        uint8 underlyingDecimals,
        uint8 quoteDecimals,
        bool underlyingIsCurrency0
    ) internal pure returns (uint256) {
        require(sqrtPriceX96 != 0, PoolNotInitialized(poolId));

        uint256 p = uint256(sqrtPriceX96);
        // price1Per0 in Q96: raw currency1 units per raw currency0 unit, times 2^96.
        uint256 num = F.fullMulDiv(p, p, Q96);

        if (underlyingIsCurrency0) {
            // quote (= currency1) per underlying (= currency0): rescale raw ratio to WAD.
            return F.fullMulDiv(num, 1e18 * (10 ** underlyingDecimals), Q96 * (10 ** quoteDecimals));
        }
        // quote (= currency0) per underlying (= currency1): invert first.
        return F.fullMulDiv(Q96, 1e18 * (10 ** underlyingDecimals), num) / (10 ** quoteDecimals);
    }
}
