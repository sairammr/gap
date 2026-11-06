// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test double for a fee-on-transfer / deflationary ERC-20: every transfer (mint and
///         burn excluded) delivers less than `value` to `to`. Used to prove `AQUA.pull`'s
///         accounting -- which trusts the amount it asked for, not what arrived -- can
///         under-collateralize a series unless the receiver measures its own balance delta
///         (Rider B's `ShortPull` guard).
contract FeeOnTransferERC20 is ERC20 {
    uint8 private immutable _dec;
    uint256 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        ERC20(name_, symbol_)
    {
        _dec = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
