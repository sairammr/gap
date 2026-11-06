/**
 * SwapVM order encoder for Weekend Options on the Aqua path.
 *
 * An order IS a resting quote. The program is
 *   Deadline + Salt + RequireMinRate + Extruction(WeekendPricer, args)
 * and `data` is `tokenA || tokenB || <hook slices> || program`.
 *
 * No signature: the Aqua flag replaces it, so there is no signing path here.
 *
 * Zero dependencies on purpose — the whole job is byte concatenation plus four
 * ABI words. Reconciled byte-for-byte against `contracts/test/helpers/OrderLib.sol`
 * via the golden vector pinned in `orders.test.ts`.
 */

export type Hex = `0x${string}`;

/** Opcodes, read from `swap-vm-fork/contracts/libs/OpcodeList.sol`. All four are
 *  dispatched by `AquaOpcodes._runOpcode`, which is the router we target. */
export const OP = {
  salt: 0x02,
  extruction: 0x04,
  deadline: 0x20,
  requireMinRate: 0xb0,
} as const;

export const SIDE = { ASK: 0, BID: 1 } as const;

// MakerTraitsLib bit flags.
export const USE_AQUA = 1n << 254n;
export const POST_TRANSFER_IN_HOOK = 1n << 251n;
export const PRE_TRANSFER_OUT_HOOK = 1n << 250n;

const SLICES_BIT_OFFSET = 160n;
/** `data` opens with tokenA||tokenB, so every slice index starts at 40. */
const TOKENS_LEN = 40;

export interface OrderParams {
  /** The maker: WeekendDesk. */
  desk: Hex;
  /** Extruction target: WeekendPricer. */
  pricer: Hex;
  quote: Hex;
  optionToken: Hex;
  seriesId: bigint;
  /** Implied vol, 1e18. Spread is vol: ask vol > bid vol. */
  volWad: bigint;
  /** Ask-side premium floor in bps of notional. Ignored by the pricer on a bid. */
  minPremiumBps: number;
  /** SIDE.ASK | SIDE.BID */
  side: number;
  /** uint40 unix seconds. */
  deadline: number | bigint;
  /** bytes32. Re-offering an exhausted strategy needs a fresh one. */
  salt: Hex;
  minRateA: bigint;
  minRateB: bigint;
  /** Defaults to the maker. Aqua is incompatible with a custom receiver — leave it. */
  receiver?: Hex;
}

export interface Order {
  maker: Hex;
  traits: bigint;
  data: Hex;
}

// --- encoding primitives -----------------------------------------------------

const RE_ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const RE_BYTES32 = /^0x[0-9a-fA-F]{64}$/;

function addr(name: string, v: string): string {
  if (!RE_ADDRESS.test(v)) throw new Error(`${name}: not a 20-byte address: ${v}`);
  return v.slice(2).toLowerCase();
}

function bytes32(name: string, v: string): string {
  if (!RE_BYTES32.test(v)) throw new Error(`${name}: not a 32-byte value: ${v}`);
  return v.slice(2).toLowerCase();
}

/** Big-endian, zero-padded, fixed width. Throws rather than truncating. */
function uint(name: string, v: bigint | number, bytes: number): string {
  const n = BigInt(v);
  if (n < 0n) throw new Error(`${name}: negative`);
  const hex = n.toString(16);
  if (hex.length > bytes * 2) throw new Error(`${name}: does not fit in uint${bytes * 8}: ${n}`);
  return hex.padStart(bytes * 2, "0");
}

/** `[uint8 opcode][uint8 argsLength][args]` — InstructionBuilder's layout. */
function instruction(opcode: number, args: string): string {
  const len = args.length / 2;
  if (len > 255) throw new Error(`instruction ${opcode}: args ${len} > 255 bytes`);
  return uint("opcode", opcode, 1) + uint("argsLength", len, 1) + args;
}

/** abi.encode of static words only — every arg we pass is one 32-byte word. */
const word = (name: string, v: bigint | number) => uint(name, v, 32);

// --- order building ----------------------------------------------------------

/**
 * `args = abi.encode(uint256 seriesId, uint256 volWad, uint16 minPremiumBps, uint8 side)`,
 * matching `WeekendPricer._validateAndPrice`'s decode. Carried in the program bytes, so it
 * is covered by the order hash: a maker cannot repoint pricing after shipping.
 */
export function extructionArgs(p: OrderParams): string {
  if (p.side !== SIDE.ASK && p.side !== SIDE.BID) throw new Error(`side: ${p.side}`);
  // abi.encode pads these to a word, so the width check has to be explicit — otherwise a
  // too-wide value encodes fine here and reverts in abi.decode on chain.
  uint("minPremiumBps", p.minPremiumBps, 2);
  return (
    word("seriesId", p.seriesId) +
    word("volWad", p.volWad) +
    word("minPremiumBps", p.minPremiumBps) +
    word("side", p.side)
  );
}

/** Deadline + Salt + RequireMinRate + Extruction, in that order. */
export function program(p: OrderParams): Hex {
  // RequireMinRate wraps the remainder of the program via ctx.runLoop(), so it MUST
  // precede Extruction or it guards nothing.
  return ("0x" +
    instruction(OP.deadline, uint("deadline", p.deadline, 5)) +
    instruction(OP.salt, bytes32("salt", p.salt)) +
    instruction(OP.requireMinRate, uint("minRateA", p.minRateA, 8) + uint("minRateB", p.minRateB, 8)) +
    instruction(OP.extruction, addr("pricer", p.pricer) + extructionArgs(p))) as Hex;
}

/**
 * Traits + data, the way `MakerTraitsLib.build` packs them.
 *
 * Hook data is empty and both hook targets default to the maker: the desk resolves the
 * series from the token pair (`seriesOfToken`), so there is nothing to carry. That makes
 * all four slice indexes 40 — the end of tokenA||tokenB.
 */
export function order(p: OrderParams): Order {
  const quote = addr("quote", p.quote);
  const option = addr("optionToken", p.optionToken);
  if (quote === option) throw new Error("quote and optionToken are the same token");
  // build() reverts unless tokenA < tokenB; callers pass them in either order.
  const [tokenA, tokenB] = quote < option ? [quote, option] : [option, quote];

  const receiver = p.receiver === undefined ? 0n : BigInt(`0x${addr("receiver", p.receiver)}`);

  // uint64(index3 || index2 || index1 || index0), big-endian, then << 160.
  const idx = BigInt(TOKENS_LEN);
  const indexes = (idx << 48n) | (idx << 32n) | (idx << 16n) | idx;

  return {
    maker: p.desk,
    traits:
      USE_AQUA |
      POST_TRANSFER_IN_HOOK |
      PRE_TRANSFER_OUT_HOOK |
      (indexes << SLICES_BIT_OFFSET) |
      receiver,
    data: (`0x${tokenA}${tokenB}` + program(p).slice(2)) as Hex,
  };
}
