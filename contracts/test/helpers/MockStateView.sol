// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStateView} from "../../src/interfaces/IStateView.sol";

/// @notice Test double for the v4 StateView lens. Lets a test pin a pool's
///         spot (via a settable sqrtPriceX96) without deploying a real pool.
contract MockStateView is IStateView {
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    constructor(uint160 sqrtPriceX96_) {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function setSqrtPriceX96(uint160 sqrtPriceX96_) external {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    function getSlot0(bytes32)
        external
        view
        override
        returns (uint160, int24, uint24, uint24)
    {
        return (sqrtPriceX96, int24(0), uint24(0), uint24(0));
    }

    function getLiquidity(bytes32) external view override returns (uint128) {
        return liquidity;
    }
}
