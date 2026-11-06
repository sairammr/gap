// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { OrderLib } from "./helpers/OrderLib.sol";

/*//////////////////////////////////////////////////////////////////////////////
                        GOLDEN VECTOR — CROSS-ENCODER CONTRACT

  This block is the contract between `test/helpers/OrderLib.sol` (Solidity) and
  `sdk/orders.ts` (TypeScript). Both encoders assert against THESE BYTES, never
  against each other, so neither has to run first and a drift in either one is
  caught by the vector rather than hidden by agreement.

  INPUTS (OrderLib.Params)
    desk          0xdddddddddddddddddddddddddddddddddddddddd   (maker)
    pricer        0x1111111111111111111111111111111111111111
    quote         0x2222222222222222222222222222222222222222
    optionToken   0x3333333333333333333333333333333333333333
    seriesId      1
    volWad        600000000000000000                           (0.6e18)
    minPremiumBps 50
    side          0                                            (ASK)
    deadline      100                                          (uint40, 0x0000000064)
    salt          0x0000000000000000000000000000000000000000000000000000000000000001
    minRateA      1
    minRateB      1

  LAYOUT  (instruction = [uint8 opcode][uint8 argsLength][args])
    2005 <uint40 deadline>                                  Deadline      5 args
    0220 <bytes32 salt>                                     Salt         32 args
    b010 <uint64 rateA><uint64 rateB>                       RequireMinRate 16 args
    0494 <address pricer><abi.encode(uint256,uint256,uint16,uint8)>
                                                            Extruction  148 args

  GOLDEN_PROGRAM   209 bytes
  GOLDEN_DATA      249 bytes = tokenA(20) || tokenB(20) || GOLDEN_PROGRAM
                   tokens sorted ascending, so tokenA = quote, tokenB = optionToken
  GOLDEN_TRAITS    0x4c00000000280028002800280000000000000000000000000000000000000000
                   = (1<<254) | (1<<251) | (1<<250) | (0x0028002800280028 << 160)
                     USE_AQUA   postTransferIn  preTransferOut   four slice indexes, all 40

  NOTE: the plan text (§12.10 and Task 1) says the Extruction args are
  `abi.encode(uint256 seriesId, uint256 volWad, uint8 side)` — 96 bytes, header 0x0474.
  The shipped `WeekendPricer.extruction` decodes FOUR fields, including
  `uint16 minPremiumBps`. The pricer wins: 128 bytes, header 0x0494.
//////////////////////////////////////////////////////////////////////////////*/

contract OrderLibTest is Test {
    address internal constant DESK = 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd;
    address internal constant PRICER = 0x1111111111111111111111111111111111111111;
    address internal constant QUOTE = 0x2222222222222222222222222222222222222222;
    address internal constant OPTION = 0x3333333333333333333333333333333333333333;

    bytes internal constant GOLDEN_PROGRAM =
        hex"2005"
        hex"0000000064"
        hex"0220"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"b010"
        hex"00000000000000010000000000000001"
        hex"0494"
        hex"1111111111111111111111111111111111111111"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000853a0d2313c0000"
        hex"0000000000000000000000000000000000000000000000000000000000000032"
        hex"0000000000000000000000000000000000000000000000000000000000000000";

    bytes internal constant GOLDEN_DATA =
        hex"2222222222222222222222222222222222222222"
        hex"3333333333333333333333333333333333333333"
        hex"2005"
        hex"0000000064"
        hex"0220"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"b010"
        hex"00000000000000010000000000000001"
        hex"0494"
        hex"1111111111111111111111111111111111111111"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000853a0d2313c0000"
        hex"0000000000000000000000000000000000000000000000000000000000000032"
        hex"0000000000000000000000000000000000000000000000000000000000000000";

    uint256 internal constant GOLDEN_TRAITS =
        0x4c00000000280028002800280000000000000000000000000000000000000000;

    function _goldenParams() internal pure returns (OrderLib.Params memory p) {
        p = OrderLib.Params({
            desk: DESK,
            pricer: PRICER,
            quote: QUOTE,
            optionToken: OPTION,
            seriesId: 1,
            volWad: 0.6e18,
            minPremiumBps: 50,
            side: 0,
            deadline: 100,
            salt: bytes32(uint256(1)),
            minRateA: 1,
            minRateB: 1
        });
    }

    /// @dev Walk the instruction stream using only the length bytes. Reverts if the framing is
    /// inconsistent, so this doubles as a check that `argsLength` is right everywhere.
    function _opcodes(bytes memory p) internal pure returns (uint8[] memory ops) {
        uint8[] memory buf = new uint8[](p.length);
        uint256 n;
        uint256 i;
        while (i < p.length) {
            buf[n++] = uint8(p[i]);
            i += 2 + uint256(uint8(p[i + 1]));
        }
        assertEq(i, p.length, "instruction framing overruns the program");
        ops = new uint8[](n);
        for (uint256 j; j < n; ++j) {
            ops[j] = buf[j];
        }
    }

    function test_program_ordersInstructionsDeadlineSaltMinRateExtruction() public pure {
        // RequireMinRate wraps the remainder via ctx.runLoop(), so it MUST precede Extruction.
        uint8[] memory ops = _opcodes(OrderLib.program(_goldenParams()));
        assertEq(ops.length, 4, "four instructions");
        assertEq(ops[0], 0x20, "Deadline first");
        assertEq(ops[1], 0x02, "Salt second");
        assertEq(ops[2], 0xb0, "RequireMinRate third");
        assertEq(ops[3], 0x04, "Extruction last");
    }

    function test_program_matchesGoldenVector() public pure {
        assertEq(OrderLib.program(_goldenParams()), GOLDEN_PROGRAM);
    }

    function test_program_emitsNoBannedOpcodes() public pure {
        // AquaOpcodes has no StaticBalances (0x10), LimitSwap (0x52) or invalidators (0x30/0x31).
        uint8[] memory ops = _opcodes(OrderLib.program(_goldenParams()));
        for (uint256 i; i < ops.length; ++i) {
            assertTrue(
                ops[i] == 0x20 || ops[i] == 0x02 || ops[i] == 0xb0 || ops[i] == 0x04, "unknown opcode for Aqua"
            );
        }
    }

    function test_order_matchesGoldenVector() public pure {
        OrderLib.Order memory o = OrderLib.order(_goldenParams());
        assertEq(o.maker, DESK, "maker is the desk");
        assertEq(o.traits, GOLDEN_TRAITS, "traits");
        assertEq(o.data, GOLDEN_DATA, "data");
    }

    function test_order_setsAquaFlagAndExactlyTwoHookBits() public pure {
        uint256 t = OrderLib.order(_goldenParams()).traits;
        assertTrue(t & (1 << 254) != 0, "aqua flag");
        assertTrue(t & (1 << 250) != 0, "preTransferOut");
        assertTrue(t & (1 << 251) != 0, "postTransferIn");
        assertTrue(t & (1 << 252) == 0, "preTransferIn must stay off");
        assertTrue(t & (1 << 249) == 0, "postTransferOut must stay off");
        // Aqua is incompatible with a custom receiver, Permit2 and WETH unwrap.
        assertEq(t & type(uint160).max, 0, "receiver defaults to maker");
        assertTrue(t & (1 << 255) == 0, "no weth unwrap");
        assertTrue(t & (1 << 244) == 0, "no permit2");
        // No *_HAS_TARGET bit: every hook target falls back to order.maker.
        assertEq((t >> 245) & 0xf, 0, "hook targets default to maker");
    }

    function test_order_sliceIndexesAllPointAtProgramStart() public pure {
        // Four 16-bit cumulative END offsets at bit 160. With no hook data they all equal 40,
        // the length of tokenA||tokenB, so `program` is data[40:].
        uint256 t = OrderLib.order(_goldenParams()).traits;
        for (uint256 i; i < 4; ++i) {
            assertEq((t >> (160 + 16 * i)) & 0xffff, 40, "slice index");
        }
        bytes memory data = OrderLib.order(_goldenParams()).data;
        bytes memory prog = new bytes(data.length - 40);
        for (uint256 i; i < prog.length; ++i) {
            prog[i] = data[40 + i];
        }
        assertEq(prog, GOLDEN_PROGRAM, "data[40:] is the program");
    }

    function test_order_sortsTokensAscending() public pure {
        // MakerTraitsLib.build reverts unless tokenA < tokenB; the caller must not have to care.
        OrderLib.Params memory below = _goldenParams(); // quote 0x22.. < option 0x33..
        OrderLib.Params memory above = _goldenParams();
        above.quote = 0x4444444444444444444444444444444444444444; // > option 0x33..

        bytes memory dBelow = OrderLib.order(below).data;
        bytes memory dAbove = OrderLib.order(above).data;
        assertEq(address(bytes20(dBelow)), below.quote, "tokenA = quote when quote is lower");
        assertEq(address(bytes20(dAbove)), above.optionToken, "tokenA = option when quote is higher");
        assertTrue(address(bytes20(dBelow)) < OPTION, "sorted ascending");
        assertTrue(address(bytes20(dAbove)) < above.quote, "sorted ascending");
    }

    function test_hash_changesWhenPricerIsRepointed() public pure {
        // The Extruction target lives in the program bytes, so it is covered by the order hash.
        // A maker cannot repoint pricing after shipping: the Aqua ledger key no longer exists.
        OrderLib.Params memory p = _goldenParams();
        bytes32 before = OrderLib.hash(OrderLib.order(p));
        p.pricer = address(0xBEEF);
        assertTrue(OrderLib.hash(OrderLib.order(p)) != before, "hash must follow the pricer");
    }

    function test_instruction_revertsWhenArgsExceedOneByteLength() public {
        vm.expectPartialRevert(OrderLib.ArgsLengthExceeded.selector);
        this.callInstruction(0x04, new bytes(256));
    }

    function callInstruction(uint8 op, bytes calldata args) external pure returns (bytes memory) {
        return OrderLib.instruction(op, args);
    }
}
