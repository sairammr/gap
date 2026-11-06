// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice SwapVM's swap context, mirrored so this repo can implement an Extruction target
/// without building against the SwapVM tree. Field order is load-bearing: the router ABI-encodes
/// these structs, so any divergence silently decodes to garbage.
/// Source: `swap-vm-fork/contracts/libs/VM.sol:36` and `:51`.
struct SwapQuery {
    bytes32 orderHash;
    address maker;
    address taker;
    address tokenIn;
    address tokenOut;
    bool isExactIn;
}

/// @param balanceIn  Maker's available input balance (on the Aqua path, preloaded from `safeBalances`)
/// @param balanceOut Maker's available output balance (likewise)
/// @param amountIn   Input amount; the register to fill when the swap is exact-out
/// @param amountOut  Output amount; the register to fill when the swap is exact-in
/// @param surcharge  Intermediary balance modification accumulator
struct SwapRegisters {
    uint256 balanceIn;
    uint256 balanceOut;
    uint256 amountIn;
    uint256 amountOut;
    uint256 surcharge;
}

/// @notice The `Extruction` opcode (0x04) hands the swap registers to a maker-chosen contract.
/// @dev SwapVM calls `IStaticExtruction` in quote mode and `IExtruction` in swap mode. Both
/// selectors are identical, so a single `view` implementation satisfies both — which is also what
/// the opcode's own NatSpec asks for ("the extruction target is expected to be deterministic,
/// consistent across quote / swap modes ... centralization and upgradability avoided").
interface IStaticExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external view returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap);
}
