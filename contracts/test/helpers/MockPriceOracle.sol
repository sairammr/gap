// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPriceOracle } from "../../src/interfaces/IPriceOracle.sol";

/// @notice Test double for `IPriceOracle`: exact, settable `spot` and `settlementPrice`
///         returns, keyed by asset (and expiry for the settlement price).
/// @dev Ruling 2 (Task 7): `V4SpotOracle`'s sqrt round-trip is only accurate to roughly ±1e3
///      quote units, and that error moves `holderUnderlying` by ~4.6e13 wei — twelve orders of
///      magnitude past what the golden-vector settlement tests need. Every arithmetic/golden-
///      vector test is driven through this double instead; exactly one integration test keeps
///      the real `V4SpotOracle` wired end to end, with `assertApproxEqAbs` tolerances.
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public spotPrice;
    mapping(address => uint256) public spotUpdatedAt;
    mapping(address => mapping(uint64 => uint256)) public settlePriceOf;
    mapping(address => mapping(uint64 => bool)) public settleOkOf;

    function setSpot(address asset, uint256 price, uint256 updatedAt) external {
        spotPrice[asset] = price;
        spotUpdatedAt[asset] = updatedAt;
    }

    /// @notice Marks a settlement price ready (`ok = true`). There is deliberately no way to
    ///         un-set `ok` once true — matching the real oracle's "settle once" semantics isn't
    ///         required here, but tests that want `ok = false` simply never call this.
    function setSettlementPrice(address asset, uint64 expiry, uint256 price) external {
        settlePriceOf[asset][expiry] = price;
        settleOkOf[asset][expiry] = true;
    }

    function spot(address asset) external view returns (uint256 price, uint256 updatedAt) {
        return (spotPrice[asset], spotUpdatedAt[asset]);
    }

    function settlementPrice(address asset, uint64 expiry) external view returns (uint256 price, bool ok) {
        return (settlePriceOf[asset][expiry], settleOkOf[asset][expiry]);
    }
}
