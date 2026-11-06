// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { WeekendOptions } from "./WeekendOptions.sol";
import { IGapOptionCallback } from "./interfaces/IGapOptionCallback.sol";

/// @title WeekendTaker
/// @notice Stateless router that lets an EOA buy an option.
/// @dev `WeekendOptions.buyOption` calls `IGapOptionCallback` back on `msg.sender`, so an EOA can
///      never call it directly. This helper is that `msg.sender`: it forwards `buyOption`, and
///      when the app calls back it pulls exactly `premiumOwed` of the quote token from the
///      original caller and `push`es it into the maker's Aqua balance.
///
///      It holds no funds between transactions — the payer is remembered in transient storage for
///      the duration of the one `buy` call only (cleared by the EVM at end of tx), so a single
///      deployed instance is safe for every user.
contract WeekendTaker is IGapOptionCallback {
    IAqua public immutable AQUA;
    address public immutable APP;

    /// @dev The EOA whose quote tokens pay the premium for the in-flight `buy`.
    address transient payer;

    error OnlyApp();
    error NoBuyInFlight();
    error PremiumTransferFailed();

    constructor(IAqua aqua_, address app_) {
        AQUA = aqua_;
        APP = app_;
    }

    /// @notice Buy `amount` options of `seriesId` on behalf of `msg.sender`, who must have
    ///         approved this contract for at least the premium in the quote token.
    /// @dev `takerData` must be `abi.encode(maker, strategyHash)`.
    function buy(
        WeekendOptions app,
        WeekendOptions.Strategy calldata s,
        uint256 seriesId,
        uint256 amount,
        uint256 maxPremium,
        address to,
        bytes calldata takerData
    ) external returns (uint256 premium) {
        payer = msg.sender;
        premium = app.buyOption(s, seriesId, amount, maxPremium, to, takerData);
        payer = address(0);
    }

    /// @inheritdoc IGapOptionCallback
    /// @dev `takerData = abi.encode(maker, strategyHash)`.
    function gapOptionCallback(address, address quoteToken, uint256 premiumOwed, bytes calldata takerData)
        external
        override
    {
        require(msg.sender == APP, OnlyApp());
        address from = payer;
        require(from != address(0), NoBuyInFlight());

        (address maker, bytes32 strategyHash) = abi.decode(takerData, (address, bytes32));

        // Pull the premium from the buyer, then push it into the maker's Aqua balance.
        require(IERC20(quoteToken).transferFrom(from, address(this), premiumOwed), PremiumTransferFailed());
        IERC20(quoteToken).approve(address(AQUA), premiumOwed);
        AQUA.push(maker, APP, strategyHash, quoteToken, premiumOwed);
    }
}
