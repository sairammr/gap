// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPyth } from "../interfaces/IPyth.sol";

/// @notice Test Pyth. Each update is
///         `abi.encode(bytes32 id, int64 price, uint64 conf, int32 expo, uint64 publishTime)`.
/// @dev Real Pyth verifies Wormhole signatures over the update blob; this one trusts its input.
///      That is the ONLY thing simulated — the oracle's window, confidence and averaging logic
///      run against it unchanged.
contract MockPyth is IPyth {
    uint256 public feePerUpdate = 1;
    mapping(bytes32 => Price) internal _prices;

    error InsufficientFee();

    function getUpdateFee(bytes[] calldata updateData) public view returns (uint256) {
        return updateData.length * feePerUpdate;
    }

    function setFeePerUpdate(uint256 fee) external {
        feePerUpdate = fee;
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        if (msg.value < getUpdateFee(updateData)) revert InsufficientFee();
        for (uint256 i; i < updateData.length; ++i) {
            (bytes32 id, int64 price, uint64 conf, int32 expo, uint64 t) =
                abi.decode(updateData[i], (bytes32, int64, uint64, int32, uint64));
            // Mirrors real Pyth: an update older than what is stored is a no-op, not a revert.
            if (t >= _prices[id].publishTime) _prices[id] = Price(price, conf, expo, t);
        }
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory) {
        return _prices[id];
    }
}
