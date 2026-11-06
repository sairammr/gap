// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { WeekendOptions } from "../../src/WeekendOptions.sol";
import { IGapOptionCallback } from "../../src/interfaces/IGapOptionCallback.sol";

/// @notice The attacker in the zero-premium seizure test: a taker that calls `buyOption`
///         directly and pays nothing at all.
/// @dev `buyOption` has no caller restriction and `_safeCheckAquaPush` is a `>=` against
///      `balanceBefore + premium`, so when the premium prices to exactly 0 an empty callback
///      satisfies it. The maker's strategy bytes needed to get here are public — `Aqua.ship`
///      emits them in `Shipped`.
contract NoOpTaker is IGapOptionCallback {
    function buy(WeekendOptions app, WeekendOptions.Strategy calldata s, uint256 seriesId, uint256 amount, address to)
        external
        returns (uint256)
    {
        return app.buyOption(s, seriesId, amount, type(uint256).max, to, "");
    }

    /// @dev Pays nothing.
    function gapOptionCallback(address, address, uint256, bytes calldata) external override { }
}
