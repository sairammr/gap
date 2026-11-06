// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Local mirror of `swapvm/interfaces/IMakerHooks.sol`.
///
/// @dev WHY A MIRROR. SwapVM does not compile under this repo's default Foundry profile (stack
/// too deep without `via_ir`, and it needs `evm_version = "prague"`). The desk itself compiles
/// fine there, and we want its unit tests on the fast default profile, so the four hook
/// selectors are copied here rather than imported from `../../../swap-vm-fork`.
///
/// This file is a VERBATIM selector-for-selector copy. If the fork's interface ever changes,
/// the integration suite under `[profile.swapvm]` is what catches the drift: the real router
/// calls the real selector, and a mismatched one lands in the desk's (absent) fallback.
interface IMakerHooks {
    /// @notice Called before tokenIn is transferred from taker to maker.
    function preTransferIn(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external;

    /// @notice Called after tokenIn is transferred from taker to maker.
    /// @param feeIn Fee charged from the maker in tokenIn, deducted from the amount.
    function postTransferIn(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeIn,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external;

    /// @notice Called before tokenOut is transferred from maker to taker.
    function preTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external;

    /// @notice Called after tokenOut is transferred from maker to taker.
    /// @param feeOut Fee charged from the maker in tokenOut, in addition to the amount.
    function postTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external;
}
