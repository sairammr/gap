// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AquaApp} from "@1inch/aqua/contracts/AquaApp.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {FixedPointMathLib as F} from "solady/utils/FixedPointMathLib.sol";
import {IStateView} from "./interfaces/IStateView.sol";
import {IGapOptionCallback} from "./interfaces/IGapOptionCallback.sol";

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

    /// @notice An option position minted on buy. Field order is load-bearing:
    ///         Task 7 (settle) reads these positionally.
    struct Position {
        bytes32 strategyHash;
        address maker;
        address underlying;
        address quote;
        uint8 kind;
        uint256 strike;
        uint256 cap;
        uint64 expiry;
        uint256 size;
        bool settled;
        uint256 capBacking;
    }

    /// @notice positionId => Position record.
    mapping(uint256 => Position) public positions;

    /// @notice Monotonic nonce mixed into positionId derivation.
    uint256 public optionNonce;

    /// @notice Thrown when a strategy is not bound to this app contract.
    error NotThisApp();
    /// @notice Thrown when the quoted premium exceeds the taker's max.
    error PremiumTooHigh();
    /// @notice Thrown when the maker's Aqua collateral is below capCollateral.
    error InsufficientMakerCollateral();
    /// @notice Thrown when buying an already-expired option.
    error OptionExpired();

    /// @notice Emitted when a taker buys an option and the position is minted.
    event OptionBought(
        uint256 indexed positionId,
        address indexed to,
        uint8 kind,
        uint256 strike,
        uint256 cap,
        uint64 expiry,
        uint256 size,
        uint256 premium
    );

    constructor(IAqua aqua, IStateView stateView) AquaApp(aqua) ERC1155("") {
        STATE_VIEW = stateView;
    }

    /// @dev Option economic terms, packed to keep `buyOption`'s stack shallow
    ///      (the external signature keeps them flat for Tasks 5/7).
    struct OptionTerms {
        uint8 kind;
        uint256 strike;
        uint256 cap;
        uint64 expiry;
        uint256 size;
        uint256 maxPremium;
        address to;
    }

    /// @notice Buy a cash-settled (USDC) capped option against a maker's shipped
    ///         USDC collateral. The taker pays the premium in the callback.
    /// @dev Premium is FIXED at capCollateral/10 for this task.
    function buyOption(
        Strategy calldata s,
        uint8 kind,
        uint256 strike,
        uint256 cap,
        uint64 expiry,
        uint256 size,
        uint256 maxPremium,
        address to,
        bytes calldata takerData
    ) external nonReentrantStrategy(s.maker, hashStrategy(s)) returns (uint256 positionId) {
        OptionTerms memory t = OptionTerms({
            kind: kind,
            strike: strike,
            cap: cap,
            expiry: expiry,
            size: size,
            maxPremium: maxPremium,
            to: to
        });
        return _buyOption(s, t, takerData);
    }

    function _buyOption(Strategy calldata s, OptionTerms memory t, bytes calldata takerData)
        internal
        returns (uint256 positionId)
    {
        _validateStrategy(s);
        require(t.expiry > block.timestamp, OptionExpired());

        bytes32 hash = hashStrategy(s);

        // capCollateral (USDC 6dp) = cap * size / 1e30 (WAD*WAD -> 6dp).
        uint256 capCollateral = F.fullMulDiv(t.cap, t.size, 1e30);
        uint256 premium = capCollateral / 10;
        require(premium <= t.maxPremium, PremiumTooHigh());

        // Pull the collateral into the app (with a legible solvency pre-check).
        _pullCollateral(s.maker, hash, s.quote, capCollateral);

        // Mint the position to the buyer and store its record.
        positionId = uint256(keccak256(abi.encode(hash, t.kind, t.strike, t.cap, t.expiry, t.to, optionNonce++)));
        _mintPosition(s, positionId, t, capCollateral);

        // Taker pushes the premium into the maker's Aqua balance; verify it.
        _collectPremium(s.maker, hash, s.quote, premium, t.to, takerData);

        emit OptionBought(positionId, t.to, t.kind, t.strike, t.cap, t.expiry, t.size, premium);
    }

    /// @dev Mint the ERC-1155 position and persist its record.
    function _mintPosition(Strategy calldata s, uint256 positionId, OptionTerms memory t, uint256 capCollateral)
        internal
    {
        _mint(t.to, positionId, t.size, "");
        positions[positionId] = Position({
            strategyHash: hashStrategy(s),
            maker: s.maker,
            underlying: s.underlying,
            quote: s.quote,
            kind: t.kind,
            strike: t.strike,
            cap: t.cap,
            expiry: t.expiry,
            size: t.size,
            settled: false,
            capBacking: capCollateral
        });
    }

    /// @dev Invoke the taker callback to push the premium, then verify the push.
    function _collectPremium(
        address maker,
        bytes32 hash,
        address quote,
        uint256 premium,
        address to,
        bytes calldata takerData
    ) internal {
        (uint256 quoteBalBeforePush,) = AQUA.rawBalances(maker, address(this), hash, quote);
        IGapOptionCallback(msg.sender).gapOptionCallback(to, quote, premium, takerData);
        _safeCheckAquaPush(maker, hash, quote, quoteBalBeforePush + premium);
    }

    /// @dev Legible solvency pre-check + pull of `amount` collateral into this app.
    ///      The require avoids the raw uint248 underflow panic inside `AQUA.pull`.
    function _pullCollateral(address maker, bytes32 hash, address quote, uint256 amount) internal {
        (uint256 bal,) = AQUA.rawBalances(maker, address(this), hash, quote);
        require(bal >= amount, InsufficientMakerCollateral());
        AQUA.pull(maker, hash, quote, amount, address(this));
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
