// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract MockERC20Test is Test {
    address internal alice = address(0xA11CE);

    function test_NVDAx() public {
        MockERC20 token = new MockERC20("NVIDIA xStock", "NVDAx", 18);
        assertEq(token.decimals(), 18);
        assertEq(keccak256(bytes(token.symbol())), keccak256("NVDAx"));
        token.mint(alice, 1e18);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_USDC() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        assertEq(usdc.decimals(), 6);
    }
}
