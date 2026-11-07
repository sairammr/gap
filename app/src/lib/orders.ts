// SwapVM order encoder for the GAP Aqua path, ported from sdk/orders.ts
// (which is byte-reconciled against contracts/test/helpers/OrderLib.sol) to run in the
// browser with viem types.
//
// An order IS a resting quote. The program is
//   Deadline + Salt + RequireMinRate + Extruction(WeekendPricer, args)
// and `data` is `tokenA || tokenB || program`. No signature — the Aqua flag replaces it.
//
// The bytes MUST reproduce the shipped strategyHash exactly, or Aqua's safeBalances
// lookup misses and the router reverts before a single opcode runs. The caller gates
// every fill against router.hash(order) == the shipped hash (see App handleBuy).

import type { MakerQuote, Deployment } from './deployment'

export type Hex = `0x${string}`

// Opcodes, from swap-vm-fork/contracts/libs/OpcodeList.sol.
const OP = { salt: 0x02, extruction: 0x04, deadline: 0x20, requireMinRate: 0xb0 } as const
export const SIDE = { ASK: 0, BID: 1 } as const

// MakerTraitsLib bit flags.
const USE_AQUA = 1n << 254n
const POST_TRANSFER_IN_HOOK = 1n << 251n
const PRE_TRANSFER_OUT_HOOK = 1n << 250n

const SLICES_BIT_OFFSET = 160n
// `data` opens with tokenA||tokenB, so every slice index starts at 40.
const TOKENS_LEN = 40

export interface Order {
  maker: Hex
  traits: bigint
  data: Hex
}

// --- encoding primitives (identical to sdk/orders.ts) ------------------------

const RE_ADDRESS = /^0x[0-9a-fA-F]{40}$/
const RE_BYTES32 = /^0x[0-9a-fA-F]{64}$/

function addr(name: string, v: string): string {
  if (!RE_ADDRESS.test(v)) throw new Error(`${name}: not a 20-byte address: ${v}`)
  return v.slice(2).toLowerCase()
}

function bytes32(name: string, v: string): string {
  if (!RE_BYTES32.test(v)) throw new Error(`${name}: not a 32-byte value: ${v}`)
  return v.slice(2).toLowerCase()
}

/** Big-endian, zero-padded, fixed width. Throws rather than truncating. */
function uint(name: string, v: bigint | number, bytes: number): string {
  const n = BigInt(v)
  if (n < 0n) throw new Error(`${name}: negative`)
  const hex = n.toString(16)
  if (hex.length > bytes * 2) throw new Error(`${name}: does not fit in uint${bytes * 8}: ${n}`)
  return hex.padStart(bytes * 2, '0')
}

/** `[uint8 opcode][uint8 argsLength][args]` — InstructionBuilder's layout. */
function instruction(opcode: number, args: string): string {
  const len = args.length / 2
  if (len > 255) throw new Error(`instruction ${opcode}: args ${len} > 255 bytes`)
  return uint('opcode', opcode, 1) + uint('argsLength', len, 1) + args
}

/** abi.encode of static words only — every arg we pass is one 32-byte word. */
const word = (name: string, v: bigint | number) => uint(name, v, 32)

export interface OrderParams {
  desk: Hex
  pricer: Hex
  quote: Hex
  optionToken: Hex
  seriesId: bigint
  volWad: bigint
  minPremiumBps: number
  side: number
  deadline: number | bigint
  salt: Hex
  minRateA: bigint
  minRateB: bigint
}

/** args = abi.encode(uint256 seriesId, uint256 volWad, uint16 minPremiumBps, uint8 side). */
function extructionArgs(p: OrderParams): string {
  if (p.side !== SIDE.ASK && p.side !== SIDE.BID) throw new Error(`side: ${p.side}`)
  uint('minPremiumBps', p.minPremiumBps, 2)
  return (
    word('seriesId', p.seriesId) +
    word('volWad', p.volWad) +
    word('minPremiumBps', p.minPremiumBps) +
    word('side', p.side)
  )
}

/** Deadline + Salt + RequireMinRate + Extruction, in that order. */
function program(p: OrderParams): Hex {
  return ('0x' +
    instruction(OP.deadline, uint('deadline', p.deadline, 5)) +
    instruction(OP.salt, bytes32('salt', p.salt)) +
    instruction(OP.requireMinRate, uint('minRateA', p.minRateA, 8) + uint('minRateB', p.minRateB, 8)) +
    instruction(OP.extruction, addr('pricer', p.pricer) + extructionArgs(p))) as Hex
}

export function buildOrder(p: OrderParams): Order {
  const quote = addr('quote', p.quote)
  const option = addr('optionToken', p.optionToken)
  if (quote === option) throw new Error('quote and optionToken are the same token')
  const [tokenA, tokenB] = quote < option ? [quote, option] : [option, quote]

  const idx = BigInt(TOKENS_LEN)
  const indexes = (idx << 48n) | (idx << 32n) | (idx << 16n) | idx

  return {
    maker: p.desk,
    traits:
      USE_AQUA |
      POST_TRANSFER_IN_HOOK |
      PRE_TRANSFER_OUT_HOOK |
      (indexes << SLICES_BIT_OFFSET),
    data: (`0x${tokenA}${tokenB}` + program(p).slice(2)) as Hex,
  }
}

/**
 * Build the Order for a shipped maker quote, straight from the deployment. The quote
 * already carries side, series, vol, salt and deadline, so this is just plumbing.
 */
export function orderForQuote(d: Deployment, q: MakerQuote): Order {
  return buildOrder({
    desk: q.maker as Hex,
    pricer: d.pricer as Hex,
    quote: d.usdc as Hex,
    optionToken: q.optionToken as Hex,
    seriesId: BigInt(q.seriesId),
    volWad: BigInt(q.volWad),
    minPremiumBps: q.minPremiumBps,
    side: q.side === 'ask' ? SIDE.ASK : SIDE.BID,
    deadline: q.deadline,
    salt: q.salt as Hex,
    minRateA: 0n,
    minRateB: 0n,
  })
}

// --- taker traits (from Lifecycle.s.sol `_tt`) -------------------------------

const F_IS_EXACT_IN = 0x0001
const F_USE_TRANSFER_FROM_AND_AQUA_PUSH = 0x0040
const F_IS_A_TO_B = 0x0080

/**
 * takerTraits = abi.encodePacked(10×uint16(32), uint16 flags, uint256 threshold).
 *
 * The ten 16-bit slice indexes are all 32 (the threshold word is the only slice).
 * `isAToB` is derived from the sorted pair — which token is "A" depends on the deployed
 * addresses — exactly as `Lifecycle._tt` does it. `tokenIn` is USDC for a buy, the
 * option token for a sell.
 *
 * `exactIn` picks which amount the taker is naming, and that flips what `threshold`
 * means — `minOut` when exact-in, `maxIn` when exact-out. Getting the pairing wrong
 * does not revert; it silently constrains the wrong leg.
 *
 * A threshold of 0 means NO THRESHOLD AT ALL, not "accept zero out". On an exact-out
 * fill a literal 0 maxIn would reject every fill, so pass a real ceiling there.
 */
export function takerTraits(
  usdc: string,
  optionToken: string,
  tokenIn: string,
  threshold: bigint,
  exactIn = true,
): Hex {
  const u = usdc.toLowerCase()
  const o = optionToken.toLowerCase()
  const tokenA = u < o ? u : o
  const isAToB = tokenIn.toLowerCase() === tokenA
  const flags =
    (exactIn ? F_IS_EXACT_IN : 0) |
    F_USE_TRANSFER_FROM_AND_AQUA_PUSH |
    (isAToB ? F_IS_A_TO_B : 0)

  const idx = uint('idx', 32, 2).repeat(10)
  return ('0x' + idx + uint('flags', flags, 2) + uint('threshold', threshold, 32)) as Hex
}
