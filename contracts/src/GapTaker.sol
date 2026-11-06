// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GapOptionsApp} from "./GapOptionsApp.sol";
import {IGapOptionCallback} from "./interfaces/IGapOptionCallback.sol";

/// @title GapTaker
/// @notice Stateless router that lets an EOA buy a Gap option.
/// @dev `GapOptionsApp.buyOption` calls `IGapOptionCallback` on `msg.sender`, so an EOA can
///      never call it directly. This helper is that `msg.sender`: it forwards `buyOption`,
///      and when the app calls back it pulls exactly `premiumOwed` of the quote token from
///      the original caller and `push`es it into the maker's Aqua balance.
///
///      It holds no funds between transactions — the payer is remembered in transient storage
///      for the duration of the one `buy` call only (cleared at end of tx by the EVM), so a
///      single deployed instance is safe for every user. This is the deployable form of
///      `DemoTaker` in `script/Demo.s.sol`.
contract GapTaker is IGapOptionCallback {
    IAqua public immutable AQUA;
    address public immutable APP;

    /// @dev The EOA whose quote tokens pay the premium for the in-flight `buy`.
    address transient payer;

    error OnlyApp();
    error NoBuyInFlight();

    constructor(IAqua aqua_, address app_) {
        AQUA = aqua_;
        APP = app_;
    }

    /// @notice Buy an option on behalf of `msg.sender`, who must have approved this
    ///         contract for at least the premium in the strategy's quote token.
    /// @dev Args mirror `GapOptionsApp.buyOption` one-for-one.
    ///      `takerData` must be `abi.encode(maker, strategyHash)`.
    function buy(
        GapOptionsApp gapApp,
        GapOptionsApp.Strategy calldata s,
        uint8 kind,
        uint256 strike,
        uint256 cap,
        uint64 expiry,
        uint256 size,
        uint256 maxPremium,
        address to,
        bytes calldata takerData
    ) external returns (uint256 positionId) {
        payer = msg.sender;
        positionId = gapApp.buyOption(s, kind, strike, cap, expiry, size, maxPremium, to, takerData);
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
        require(IERC20(quoteToken).transferFrom(from, address(this), premiumOwed), "premium transferFrom failed");
        IERC20(quoteToken).approve(address(AQUA), premiumOwed);
        AQUA.push(maker, APP, strategyHash, quoteToken, premiumOwed);
    }
}
