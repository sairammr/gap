import { test } from "node:test";
import assert from "node:assert/strict";
import {
  OP,
  SIDE,
  USE_AQUA,
  PRE_TRANSFER_OUT_HOOK,
  POST_TRANSFER_IN_HOOK,
  program,
  order,
  type OrderParams,
} from "./orders.ts";

// ============================================================================
// GOLDEN VECTOR — pin these exact inputs in contracts/test/helpers/OrderLib.sol
// ============================================================================
//
// Inputs:
//   desk (maker)   0xdddddddddddddddddddddddddddddddddddddddd
//   pricer         0x1111111111111111111111111111111111111111
//   quote          0x2222222222222222222222222222222222222222
//   optionToken    0x3333333333333333333333333333333333333333
//   seriesId       1
//   volWad         600000000000000000          (0.6e18)
//   minPremiumBps  50
//   side           0                            (ASK)
//   deadline       100                          (uint40 0x0000000064)
//   salt           bytes32(uint256(1))
//   minRateA       1
//   minRateB       1
//   receiver       address(0)                   (defaults to maker)
//
// Layout (each instruction is [uint8 opcode][uint8 argsLength][args]):
//   "2005" + deadline(5)
//   "0220" + salt(32)
//   "b010" + rateA(8) + rateB(8)
//   "0494" + pricer(20) + abi.encode(seriesId, volWad, minPremiumBps, side)(128)
//   program = 209 bytes; order.data = tokenA(20) + tokenB(20) + program = 249 bytes.
//
// Tokens sort ascending: 0x2222... (quote) < 0x3333... (option), so tokenA = quote.
//
// STATUS: RECONCILED against contracts/test/OrderLib.t.sol — same inputs, byte-identical
// GOLDEN_PROGRAM, GOLDEN_DATA and GOLDEN_TRAITS. Derived independently from the on-disk encoders
// (swap-vm-fork/contracts/libs/{OpcodeList,InstructionBuilder,MakerTraits}.sol,
// instructions/{Controls,MinRate,Extruction}.sol, contracts/src/desk/WeekendPricer.sol).
// If the two ever disagree, this block's inputs are the referee, not either implementation.
// ============================================================================

const GOLDEN_PARAMS: OrderParams = {
  desk: "0xdddddddddddddddddddddddddddddddddddddddd",
  pricer: "0x1111111111111111111111111111111111111111",
  quote: "0x2222222222222222222222222222222222222222",
  optionToken: "0x3333333333333333333333333333333333333333",
  seriesId: 1n,
  volWad: 600000000000000000n,
  minPremiumBps: 50,
  side: SIDE.ASK,
  deadline: 100,
  salt: "0x0000000000000000000000000000000000000000000000000000000000000001",
  minRateA: 1n,
  minRateB: 1n,
};

const GOLDEN_PROGRAM =
  "0x" +
  "2005" + "0000000064" +
  "0220" + "0000000000000000000000000000000000000000000000000000000000000001" +
  "b010" + "0000000000000001" + "0000000000000001" +
  "0494" + "1111111111111111111111111111111111111111" +
  "0000000000000000000000000000000000000000000000000000000000000001" +
  "0000000000000000000000000000000000000000000000000853a0d2313c0000" +
  "0000000000000000000000000000000000000000000000000000000000000032" +
  "0000000000000000000000000000000000000000000000000000000000000000";

const GOLDEN_DATA =
  "0x" +
  "2222222222222222222222222222222222222222" +
  "3333333333333333333333333333333333333333" +
  GOLDEN_PROGRAM.slice(2);

// uint64(40,40,40,40) << 160, plus bits 254, 251, 250.
const GOLDEN_TRAITS =
  34375776492344700813033748947655233104578689726683795533574891463586837692416n;

test("program matches the golden vector byte for byte", () => {
  assert.equal(program(GOLDEN_PARAMS), GOLDEN_PROGRAM);
});

test("order data is tokenA || tokenB || program, tokens ascending", () => {
  const o = order(GOLDEN_PARAMS);
  assert.equal(o.data, GOLDEN_DATA);
  assert.equal(o.maker, GOLDEN_PARAMS.desk);
  // Same order either way round — the caller must not have to sort.
  const flipped = order({
    ...GOLDEN_PARAMS,
    quote: GOLDEN_PARAMS.optionToken,
    optionToken: GOLDEN_PARAMS.quote,
  });
  assert.equal(flipped.data, GOLDEN_DATA);
});

test("traits match the golden vector", () => {
  assert.equal(order(GOLDEN_PARAMS).traits, GOLDEN_TRAITS);
});

test("traits set the Aqua flag and exactly two hook bits", () => {
  const t = order(GOLDEN_PARAMS).traits;
  assert.ok(t & USE_AQUA, "aqua flag");
  assert.ok(t & POST_TRANSFER_IN_HOOK, "postTransferIn");
  assert.ok(t & PRE_TRANSFER_OUT_HOOK, "preTransferOut");
  assert.equal(t & (1n << 252n), 0n, "preTransferIn must stay off");
  assert.equal(t & (1n << 249n), 0n, "postTransferOut must stay off");
  assert.equal(t & (1n << 255n), 0n, "unwrapWeth is incompatible with Aqua");
  assert.equal(t & (1n << 244n), 0n, "permit2 is incompatible with Aqua");
});

test("all four slice indexes are 40 and receiver defaults to zero", () => {
  const t = order(GOLDEN_PARAMS).traits;
  for (let i = 0n; i < 4n; i++) {
    assert.equal((t >> (160n + i * 16n)) & 0xffffn, 40n, `slice index ${i}`);
  }
  assert.equal(t & ((1n << 160n) - 1n), 0n, "receiver");
});

test("a custom receiver lands in the low 160 bits", () => {
  const t = order({ ...GOLDEN_PARAMS, receiver: "0x00000000000000000000000000000000000000aB" }).traits;
  assert.equal(t & ((1n << 160n) - 1n), 0xabn);
});

test("opcodes are the ones AquaOpcodes dispatches", () => {
  assert.deepEqual(OP, { salt: 0x02, extruction: 0x04, deadline: 0x20, requireMinRate: 0xb0 });
});

test("RequireMinRate precedes Extruction, which is last", () => {
  // RequireMinRate wraps the remainder via ctx.runLoop(); after Extruction it guards nothing.
  const p = program(GOLDEN_PARAMS).slice(2);
  const opcodes: number[] = [];
  for (let i = 0; i < p.length; ) {
    opcodes.push(parseInt(p.slice(i, i + 2), 16));
    i += 4 + parseInt(p.slice(i + 2, i + 4), 16) * 2;
  }
  assert.deepEqual(opcodes, [OP.deadline, OP.salt, OP.requireMinRate, OP.extruction]);
});

test("a bid differs from an ask only in the side word", () => {
  const ask = program(GOLDEN_PARAMS).slice(2);
  const bid = program({ ...GOLDEN_PARAMS, side: SIDE.BID }).slice(2);
  assert.equal(ask.length, bid.length);
  assert.equal(ask.slice(0, -2), bid.slice(0, -2));
  assert.equal(bid.slice(-2), "01");
});

test("rejects malformed addresses, oversized fields and an unknown side", () => {
  assert.throws(() => program({ ...GOLDEN_PARAMS, pricer: "0x1234" as never }), /address/);
  assert.throws(() => program({ ...GOLDEN_PARAMS, salt: "0x01" as never }), /32-byte/);
  assert.throws(() => program({ ...GOLDEN_PARAMS, deadline: 2n ** 40n }), /uint40/);
  assert.throws(() => program({ ...GOLDEN_PARAMS, minRateA: 2n ** 64n }), /uint64/);
  assert.throws(() => program({ ...GOLDEN_PARAMS, minPremiumBps: 65536 }), /uint16/);
  assert.throws(() => program({ ...GOLDEN_PARAMS, side: 2 }), /side/);
  assert.throws(() => order({ ...GOLDEN_PARAMS, quote: GOLDEN_PARAMS.optionToken }), /same token/);
});
