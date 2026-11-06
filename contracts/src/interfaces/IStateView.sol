// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal view of the deployed Uniswap v4 `StateView` lens.
/// @dev Only the two getters we need, so the app does not drag in v4-periphery.
///      Base Sepolia: 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4
interface IStateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}
