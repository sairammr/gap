// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGapOptionCallback} from "../../src/interfaces/IGapOptionCallback.sol";

/// @notice Minimal taker that pays the option premium by pushing USDC into the
///         maker's Aqua balance during the buyOption callback.
contract TakerStub is IGapOptionCallback {
    IAqua public immutable aqua;
    address public immutable app;

    constructor(IAqua aqua_, address app_) {
        aqua = aqua_;
        app = app_;
    }

    /// @dev takerData = abi.encode(maker, strategyHash).
    function gapOptionCallback(
        address, /* taker */
        address quoteToken,
        uint256 premiumOwed,
        bytes calldata takerData
    ) external override {
        (address maker, bytes32 strategyHash) = abi.decode(takerData, (address, bytes32));
        IERC20(quoteToken).approve(address(aqua), premiumOwed);
        aqua.push(maker, app, strategyHash, quoteToken, premiumOwed);
    }
}
