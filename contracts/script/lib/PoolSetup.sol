// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title PoolSetup
/// @notice Shared helpers to create and seed a hookless Uniswap v4 pool.
/// @dev Consumed by the Task 8 deploy script and by `PoolFork.t.sol`. The PositionManager's
///      `modifyLiquidities` pulls tokens through Permit2, so the caller must have already
///      granted Permit2 an ERC20 allowance and had Permit2 approve the PositionManager as
///      spender (see the fork test's `_approveViaPermit2` for the exact two-step dance).
library PoolSetup {
    /// @notice Builds a hookless `PoolKey` and initialises the pool at `sqrtPriceX96`.
    /// @dev Currencies MUST already be sorted (`c0 < c1`); v4 reverts otherwise. Hooks = address(0).
    /// @return key The initialised pool key. `key.toId()` == `keccak256(abi.encode(key))`.
    function initPool(
        IPoolManager manager,
        Currency c0,
        Currency c1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, sqrtPriceX96);
    }

    /// @notice Mints a liquidity position over [`lower`, `upper`] to `recipient`.
    /// @dev Encodes a `MINT_POSITION` + `SETTLE_PAIR` plan. `amountMax` is set to
    ///      `type(uint128).max` for both currencies — the caller is expected to have
    ///      pre-funded and pre-approved (via Permit2) more than enough of each token.
    function seed(
        IPositionManager posm,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint256 liq,
        address recipient
    ) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        // MINT_POSITION: (PoolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        params[0] = abi.encode(
            key,
            lower,
            upper,
            liq,
            type(uint128).max,
            type(uint128).max,
            recipient,
            bytes("")
        );
        // SETTLE_PAIR: (currency0, currency1) — pulls owed amounts from the caller via Permit2.
        params[1] = abi.encode(key.currency0, key.currency1);

        // Deadline margin is load-bearing: under `forge script` `block.timestamp` is the
        // SIMULATION block's, but the tx is broadcast and mined minutes later. A
        // `block.timestamp + 1` deadline is already stale on arrival and the
        // PositionManager reverts `DeadlinePassed`. An hour covers simulate->mine drift.
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }
}
