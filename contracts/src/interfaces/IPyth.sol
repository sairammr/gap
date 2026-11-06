// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The subset of Pyth's on-chain pull-oracle interface this protocol uses.
/// @dev Mirrored rather than imported: `@pythnetwork/pyth-sdk-solidity` is a dependency for
///      four function signatures and one struct, and pulling it in would also pull its own
///      OpenZeppelin pin. Verified against `IPyth`/`PythStructs` in that SDK — if the ABI ever
///      moves, this file is the one place to re-check.
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice The latest price for `id` with NO staleness check. The caller does that itself.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory);

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);

    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

/// @notice Tokenized stocks that track corporate actions with a balance multiplier.
/// @dev The raw token balance never changes; value per raw token is
///      `sharePrice * multiplier / 1e18`. Pyth quotes the SHARE, not the wrapper, so without
///      this the oracle would misprice every series on a token that has ever paid a dividend
///      or split. Match this selector against the issuer's contract before going live; leave
///      `multiplierSource` at zero for a 1:1 wrapper.
interface IMultiplierToken {
    function multiplier() external view returns (uint256);
}
