// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AquaApp} from "@1inch/aqua/contracts/AquaApp.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IStateView} from "./interfaces/IStateView.sol";

/// @title GapOptionsApp
/// @notice Aqua app for Gap options. Skeleton: strategy struct, hashing, and
///         app-binding validation. Trading/settlement bodies land in later tasks.
contract GapOptionsApp is AquaApp, ERC1155 {
    /// @notice Uniswap v4 StateView lens used for on-chain pricing (Task 5).
    IStateView public immutable STATE_VIEW;

    /// @notice A maker's option-writing strategy. Field order is load-bearing:
    ///         `hashStrategy` depends on it and must match the bytes the maker
    ///         `abi.encode`s when calling `AQUA.ship`.
    struct Strategy {
        address app;
        address maker;
        address underlying;
        address quote;
        bytes32 poolId;
        bool underlyingIsCurrency0;
        uint8 underlyingDecimals;
        uint8 quoteDecimals;
        uint256 volWad;
        bytes32 salt;
    }

    /// @notice Thrown when a strategy is not bound to this app contract.
    error NotThisApp();

    constructor(IAqua aqua, IStateView stateView) AquaApp(aqua) ERC1155("") {
        STATE_VIEW = stateView;
    }

    /// @notice Strategy hash == the raw bytes Aqua hashes in `ship`.
    function hashStrategy(Strategy calldata s) public pure returns (bytes32) {
        return keccak256(abi.encode(s));
    }

    /// @dev Reverts unless the strategy is bound to this app.
    function _validateStrategy(Strategy calldata s) internal view {
        if (s.app != address(this)) revert NotThisApp();
    }
}
