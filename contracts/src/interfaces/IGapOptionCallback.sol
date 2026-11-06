// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Callback a taker contract implements to pay the option premium
///         during a Gap option purchase.
interface IGapOptionCallback {
    function gapOptionCallback(
        address taker,
        address quoteToken,
        uint256 premiumOwed,
        bytes calldata takerData
    ) external;
}
