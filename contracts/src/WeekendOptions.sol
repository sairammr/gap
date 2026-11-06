// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib as F } from "solady/utils/FixedPointMathLib.sol";
import { LibString } from "solady/utils/LibString.sol";

import { OptionToken, OptionTokenFactory } from "./OptionToken.sol";

/// @notice CALL (writer locks underlying) or PUT (writer locks quote). Order matches
/// `GapPricing.CALL` (0) / `GapPricing.PUT` (1).
enum Kind {
    CALL,
    PUT
}

/// @title WeekendOptions
/// @notice Fully collateralized, physically-settled options on tokenized stocks, priced in one
/// quote token (USDC). This file holds the series registry; write/exercise/close/settlement/
/// payout/quoting surfaces are added by later tasks on top of the same contract.
///
/// Units: underlying and option amounts are 18 decimals. `strike` and every oracle price are
/// quote-token units (6 dp USDC) per 1e18 of underlying.
contract WeekendOptions {
    // ---------------------------------------------------------------- types

    struct Series {
        address underlying;
        uint64 expiry;
        Kind kind;
        uint256 strike;
        OptionToken token;
        uint256 totalWritten;
        uint256 poolUnderlying;
        uint256 poolCash;
        bool settled;
        uint256 settlePrice;
        uint256 supplyAtSettle;
        uint256 holderUnderlying;
        uint256 holderCash;
        uint256 writerUnderlying;
        uint256 writerCash;
        uint256 writtenAtSettle;
    }

    // ---------------------------------------------------------------- constants

    uint256 public constant SETTLEMENT_GRACE = 7 days;

    // ---------------------------------------------------------------- immutables & state

    /// @notice The single quote asset every series' PUT side locks (the USDC-equivalent).
    address public immutable quote;
    OptionTokenFactory public immutable tokenFactory;

    Series[] internal _series;
    mapping(bytes32 => uint256) public seriesIdOf; // key => id + 1
    mapping(uint256 => mapping(address => uint256)) public written;

    // ---------------------------------------------------------------- events

    event SeriesCreated(
        uint256 indexed seriesId, address indexed underlying, uint64 expiry, Kind kind, uint256 strike, address token
    );

    // ---------------------------------------------------------------- errors

    error BadSeries();
    error Expired();
    error NotExpired();
    error AlreadySettled();
    error BadAmount();

    constructor(address quote_, OptionTokenFactory factory_) {
        quote = quote_;
        tokenFactory = factory_;
        tokenFactory.bind(address(this));
    }

    // ---------------------------------------------------------------- series registry

    /// @notice Permissionless. Opens the series for this (underlying, expiry, kind, strike) key,
    /// or returns the existing id if one was already opened.
    function createSeries(address underlying, uint64 expiry, Kind kind, uint256 strike)
        external
        returns (uint256 id)
    {
        if (expiry <= block.timestamp || expiry > block.timestamp + 400 days || strike == 0) revert BadSeries();

        bytes32 key = keccak256(abi.encode(underlying, expiry, kind, strike));
        uint256 existing = seriesIdOf[key];
        if (existing != 0) return existing - 1;

        id = _series.length;
        string memory tag = kind == Kind.CALL ? "UP" : "FLOOR";
        string memory idStr = LibString.toString(id);
        OptionToken token =
            tokenFactory.deploy(string.concat("Weekend ", tag, " #", idStr), string.concat(tag, "-", idStr), id);

        Series storage s = _series.push();
        s.underlying = underlying;
        s.expiry = expiry;
        s.kind = kind;
        s.strike = strike;
        s.token = token;

        seriesIdOf[key] = id + 1;
        emit SeriesCreated(id, underlying, expiry, kind, strike, address(token));
    }

    function seriesCount() external view returns (uint256) {
        return _series.length;
    }

    function getSeries(uint256 id) external view returns (Series memory) {
        return _series[id];
    }

    /// @notice Token and amount a writer must lock for `amount` options.
    /// @dev The only Ceil in the protocol: the writer's obligation rounds up against them.
    function collateralFor(uint256 id, uint256 amount) public view returns (address token, uint256 need) {
        Series storage s = _series[id];
        if (s.kind == Kind.CALL) return (s.underlying, amount);
        return (quote, F.fullMulDivUp(amount, s.strike, 1e18));
    }
}
