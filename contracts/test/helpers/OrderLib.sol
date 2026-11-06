// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title OrderLib — builds the SwapVM order that *is* a resting option quote.
///
/// @dev Self-contained on purpose. SwapVM does not compile under this repo's default Foundry
/// profile (stack too deep) and `swapvm/` is only remapped under `[profile.swapvm]`, so this
/// library mirrors the handful of encodings it needs instead of importing the fork. Every
/// mirrored rule is cited to its source line below; the fork stays read-only.
///
/// Mirrored from:
///   `swap-vm-fork/contracts/libs/InstructionBuilder.sol` — instruction header
///   `swap-vm-fork/contracts/instructions/Controls.sol`   — `Deadline`, `Salt`
///   `swap-vm-fork/contracts/instructions/MinRate.sol`    — `RequireMinRate`
///   `swap-vm-fork/contracts/instructions/Extruction.sol` — `Extruction`
///   `swap-vm-fork/contracts/libs/MakerTraits.sol`        — `MakerTraitsLib.build`
///
/// Verified byte-identical to those builders (program, traits, data and `keccak256(abi.encode(o))`)
/// by a throwaway test compiled under `FOUNDRY_PROFILE=swapvm`. Re-run that check if the fork moves.
library OrderLib {
    /// @notice Field-identical to `ISwapVM.Order`; `traits` is the `uint256` under `MakerTraits`,
    /// which ABI-encodes the same, so `hash()` here equals the router's order hash.
    struct Order {
        address maker;
        uint256 traits;
        bytes data;
    }

    /// @param desk        the maker — the `WeekendDesk` that implements `IMakerHooks`
    /// @param pricer      the `Extruction` target (`WeekendPricer`)
    /// @param quote       quote token (6 dp)
    /// @param optionToken the ERC-20 option token for `seriesId`
    /// @param side        `0` = ASK (maker writes), `1` = BID (maker buys back)
    /// @param minRateA    `RequireMinRate` rate for the lower-addressed token
    /// @param minRateB    `RequireMinRate` rate for the higher-addressed token
    struct Params {
        address desk;
        address pricer;
        address quote;
        address optionToken;
        uint256 seriesId;
        uint256 volWad;
        uint16 minPremiumBps;
        uint8 side;
        uint40 deadline;
        bytes32 salt;
        uint64 minRateA;
        uint64 minRateB;
    }

    // `libs/OpcodeList.sol`
    uint8 internal constant OP_SALT = 0x02;
    uint8 internal constant OP_EXTRUCTION = 0x04;
    uint8 internal constant OP_DEADLINE = 0x20;
    uint8 internal constant OP_REQUIRE_MIN_RATE = 0xb0;

    // `libs/MakerTraits.sol`
    uint256 internal constant USE_AQUA_INSTEAD_OF_SIGNATURE = 1 << 254;
    uint256 internal constant HAS_PRE_TRANSFER_IN_HOOK = 1 << 252;
    uint256 internal constant HAS_POST_TRANSFER_IN_HOOK = 1 << 251;
    uint256 internal constant HAS_PRE_TRANSFER_OUT_HOOK = 1 << 250;
    uint256 internal constant HAS_POST_TRANSFER_OUT_HOOK = 1 << 249;
    uint256 internal constant ORDER_DATA_SLICES_INDEXES_BIT_OFFSET = 160;

    error ArgsLengthExceeded(uint256 length);

    /// @notice `[uint8 opcode][uint8 argsLength][args]`, args < 256 bytes.
    function instruction(uint8 opcode, bytes memory args) internal pure returns (bytes memory) {
        require(args.length < 256, ArgsLengthExceeded(args.length));
        return bytes.concat(bytes1(opcode), bytes1(uint8(args.length)), args);
    }

    /// @notice `abi.encode(uint256 seriesId, uint256 volWad, uint16 minPremiumBps, uint8 side)` —
    /// what `WeekendPricer.extruction` decodes. Carried in the program bytes, so it is covered by
    /// the order hash: a maker cannot repoint pricing after shipping.
    function extructionArgs(Params memory p) internal pure returns (bytes memory) {
        return abi.encode(p.seriesId, p.volWad, p.minPremiumBps, p.side);
    }

    /// @notice `Deadline + Salt + RequireMinRate + Extruction(pricer, args)`.
    /// @dev Order is load-bearing: `RequireMinRate` wraps the remainder of the program via
    /// `ctx.runLoop()`, so it must precede `Extruction` to guard the price it computes.
    /// No `StaticBalances` / `LimitSwap` / invalidators — `AquaOpcodes` ships none of them
    /// (spec §12.3); the Aqua ledger is the only cumulative cap.
    function program(Params memory p) internal pure returns (bytes memory) {
        return bytes.concat(
            instruction(OP_DEADLINE, abi.encodePacked(p.deadline)),
            instruction(OP_SALT, abi.encodePacked(p.salt)),
            instruction(OP_REQUIRE_MIN_RATE, abi.encodePacked(p.minRateA, p.minRateB)),
            instruction(OP_EXTRUCTION, abi.encodePacked(p.pricer, extructionArgs(p)))
        );
    }

    /// @notice The maker order. Aqua-backed, with the two hooks the desk needs.
    /// @dev Mirrors `MakerTraitsLib.build` for the no-hook-data, no-hook-target, no-receiver case:
    /// all four slice indexes collapse to 40 (the two token addresses) and every hook target
    /// defaults to `order.maker`. Tokens are sorted here so callers need not care — `build`
    /// reverts with `MakerTraitsTokensNotSorted` otherwise.
    function order(Params memory p) internal pure returns (Order memory) {
        (address tokenA, address tokenB) =
            p.quote < p.optionToken ? (p.quote, p.optionToken) : (p.optionToken, p.quote);

        // index0..index3 — cumulative END offsets of the four hook-data slices. With no hook
        // targets and no hook data every slice is empty and starts where the tokens end.
        uint64 sliceIndexes = uint64(bytes8(abi.encodePacked(uint16(40), uint16(40), uint16(40), uint16(40))));

        uint256 traits = USE_AQUA_INSTEAD_OF_SIGNATURE | HAS_PRE_TRANSFER_OUT_HOOK | HAS_POST_TRANSFER_IN_HOOK
            | (uint256(sliceIndexes) << ORDER_DATA_SLICES_INDEXES_BIT_OFFSET);

        return Order({
            maker: p.desk,
            traits: traits,
            data: bytes.concat(abi.encodePacked(tokenA, tokenB), program(p))
        });
    }

    /// @notice On the Aqua path `hash(order)` is `keccak256(abi.encode(order))`, and that is also
    /// the Aqua strategy hash the maker must ship under.
    function hash(Order memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(o));
    }
}
