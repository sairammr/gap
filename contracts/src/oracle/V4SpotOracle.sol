// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { FixedPointMathLib as F } from "solady/utils/FixedPointMathLib.sol";

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IStateView } from "../interfaces/IStateView.sol";
import { UniV4Spot } from "../lib/UniV4Spot.sol";

/// @title V4SpotOracle
/// @notice `IPriceOracle` backed by a Uniswap v4 pool's instantaneous spot price.
/// @dev The oracle is read exactly once per series, at settlement; exercise is physical and
///      oracle-free. That is what makes an instantaneous `slot0` read acceptable here.
///      `spot` and `settlementPrice` both return quote-token units (6 dp USDC) per 1e18 of
///      underlying; `UniV4Spot.spotWad` is WAD, so this contract rescales it.
contract V4SpotOracle is IPriceOracle, Ownable {
    error NotConfigured();
    error TooEarly();
    error AlreadyRecorded();

    struct PoolConfig {
        bytes32 poolId;
        uint8 assetDecimals;
        bool assetIsCurrency0;
        bool configured;
    }

    IStateView public immutable stateView;
    uint8 public immutable quoteDecimals;

    mapping(address => PoolConfig) public pools;
    mapping(address => mapping(uint64 => uint256)) public settlement;
    /// @dev Separate from `settlement != 0`: a recorded price of 0 must still stay recorded
    ///      (never re-recordable) while `settlementPrice` keeps reporting `ok = false` for it,
    ///      so Task 7's grace-period path can fall through.
    mapping(address => mapping(uint64 => bool)) public recorded;

    constructor(IStateView stateView_, uint8 quoteDecimals_) Ownable(msg.sender) {
        stateView = stateView_;
        quoteDecimals = quoteDecimals_;
    }

    function setPool(address asset, bytes32 poolId, uint8 assetDecimals, bool assetIsCurrency0) external onlyOwner {
        pools[asset] = PoolConfig(poolId, assetDecimals, assetIsCurrency0, true);
    }

    /// @notice Instantaneous spot, in quote-token units. Returns (0, 0) rather than reverting
    ///         when the asset has no pool configured or the configured pool is uninitialised.
    function spot(address asset) public view returns (uint256 price, uint256 updatedAt) {
        PoolConfig memory cfg = pools[asset];
        if (!cfg.configured) return (0, 0);

        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(cfg.poolId);
        if (sqrtPriceX96 == 0) return (0, 0);

        uint256 wad = UniV4Spot.fromSqrtPriceX96(
            sqrtPriceX96, cfg.poolId, cfg.assetDecimals, quoteDecimals, cfg.assetIsCurrency0
        );
        price = F.mulDiv(wad, 10 ** quoteDecimals, 1e18);
        updatedAt = block.timestamp;
    }

    function settlementPrice(address asset, uint64 expiry) external view returns (uint256 price, bool ok) {
        price = settlement[asset][expiry];
        ok = price != 0;
    }

    /// @notice Permissionless; records the spot price at or after `expiry`, exactly once.
    function recordSettlement(address asset, uint64 expiry) external {
        if (!pools[asset].configured) revert NotConfigured();
        if (block.timestamp < expiry) revert TooEarly();
        if (recorded[asset][expiry]) revert AlreadyRecorded();

        recorded[asset][expiry] = true;
        (uint256 price,) = spot(asset);
        settlement[asset][expiry] = price;
    }
}
