/* Rebuild the seeded book's quote rows for the deployment JSON — and prove, against the
   chain, that the browser's order encoder produces the hash Aqua actually recorded.

   Run: node --experimental-strip-types scripts/seed-quotes.ts

   The ladder below mirrors `contracts/script/SeedBook.s.sol` exactly: same salts (derived,
   not stored), same vols, same tenors. For each row we build the order with the APP's
   encoder (src/lib/orders.ts), hash it, and then ask Aqua whether that hash carries the
   balance the script shipped. A non-zero balance is the proof: if the browser encoder had
   drifted from the Solidity one by a single byte, the hash would miss and the lookup would
   come back zero. That makes this both a generator and the regression test the ship panel
   never had.
*/
import assert from 'node:assert/strict'
import { writeFileSync } from 'node:fs'
import { createPublicClient, encodeAbiParameters, http, keccak256 } from 'viem'
import { baseSepolia } from 'viem/chains'
import { buildOrder, SIDE, type Hex } from '../src/lib/orders.ts'

const RPC = 'https://sepolia.base.org'

const APP = '0x7031B0eD0Cf2Dc85eC157696B91f3985bD7BCe4f' as Hex
const DESK = '0xc05D7b0069DCAF627a94d77e535c3f7b802A1B0C' as Hex
const PRICER = '0xE4C03419fc2C4A1BDf283e260d1Cb0B224ce19C9' as Hex
const ROUTER = '0x09235bE12Ab393C8B4343Db8d329F5B29B5F3B72' as Hex
const AQUA = '0x1E522b17600Aa9eE58C7633C528cCC19fdcFcd1f' as Hex
const QUOTE = '0x7b7900fd08aA2b70f9595B3CCE0621baaad54463' as Hex

/** SeedBook's RUN counter — part of the salt preimage. */
const RUN = 1n
/** The two deadlines the broadcast stamped, 7d and 21d from the seeding block. */
const D7 = 1794618805
const D21 = 1795828405

const VOL_BODY = 550000000000000000n
const VOL_WING = 700000000000000000n
const VOL_BID = 400000000000000000n

interface Leg {
  id: number
  strike: number // 6dp, for the vol smile only
  deadline: number
  withBid: boolean
}

// Mirrors SeedBook._ladder(), in the order it created the series.
const LADDER: Leg[] = [
  { id: 2, strike: 170e6, deadline: D7, withBid: true },
  { id: 3, strike: 180e6, deadline: D7, withBid: true },
  { id: 4, strike: 190e6, deadline: D7, withBid: false },
  { id: 5, strike: 200e6, deadline: D7, withBid: false },
  { id: 6, strike: 190e6, deadline: D21, withBid: false },
  { id: 7, strike: 160e6, deadline: D7, withBid: false },
  { id: 8, strike: 175e6, deadline: D7, withBid: true },
  { id: 9, strike: 185e6, deadline: D7, withBid: true },
  { id: 10, strike: 185e6, deadline: D21, withBid: false },
]

/** SeedBook._vol: the body is quoted tighter than the wings. */
const askVol = (strike: number) => (strike >= 180e6 && strike <= 200e6 ? VOL_BODY : VOL_WING)

/** SeedBook._salt: keccak256(abi.encode("gap.seed", RUN, id, side)). */
function salt(id: number, side: number): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'string' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint8' }],
      ['gap.seed', RUN, BigInt(id), side],
    ),
  )
}

const orderParam = {
  name: 'order',
  type: 'tuple',
  components: [
    { name: 'maker', type: 'address' },
    { name: 'traits', type: 'uint256' },
    { name: 'data', type: 'bytes' },
  ],
} as const

const client = createPublicClient({ chain: baseSepolia, transport: http(RPC) })

const seriesAbi = [
  {
    type: 'function',
    name: 'getSeries',
    stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'underlying', type: 'address' },
          { name: 'expiry', type: 'uint64' },
          { name: 'kind', type: 'uint8' },
          { name: 'strike', type: 'uint256' },
          { name: 'token', type: 'address' },
          { name: 'totalWritten', type: 'uint256' },
          { name: 'poolUnderlying', type: 'uint256' },
          { name: 'poolCash', type: 'uint256' },
          { name: 'settled', type: 'bool' },
          { name: 'settlePrice', type: 'uint256' },
          { name: 'supplyAtSettle', type: 'uint256' },
          { name: 'holderUnderlying', type: 'uint256' },
          { name: 'holderCash', type: 'uint256' },
        ],
      },
    ],
  },
] as const

const aquaAbi = [
  {
    type: 'function',
    name: 'rawBalances',
    stateMutability: 'view',
    inputs: [
      { name: 'maker', type: 'address' },
      { name: 'app', type: 'address' },
      { name: 'strategyHash', type: 'bytes32' },
      { name: 'token', type: 'address' },
    ],
    outputs: [
      { name: 'balance', type: 'uint248' },
      { name: 'tokensCount', type: 'uint8' },
    ],
  },
] as const

const rows: unknown[] = []
let checked = 0

for (const leg of LADDER) {
  const series = (await client.readContract({
    address: APP,
    abi: seriesAbi,
    functionName: 'getSeries',
    args: [BigInt(leg.id)],
  })) as { token: Hex; strike: bigint; kind: number }

  const optionToken = series.token

  for (const side of leg.withBid ? ['ask', 'bid'] : ['ask']) {
    const isAsk = side === 'ask'
    const volWad = isAsk ? askVol(leg.strike) : VOL_BID
    const minPremiumBps = isAsk ? 25 : 1
    const s = salt(leg.id, isAsk ? SIDE.ASK : SIDE.BID)

    const order = buildOrder({
      desk: DESK,
      pricer: PRICER,
      quote: QUOTE,
      optionToken,
      seriesId: BigInt(leg.id),
      volWad,
      minPremiumBps,
      side: isAsk ? SIDE.ASK : SIDE.BID,
      deadline: leg.deadline,
      salt: s,
      minRateA: 0n,
      minRateB: 0n,
    })
    const strategyHash = keccak256(encodeAbiParameters([orderParam], [order]))

    // THE PROOF. The funded leg is the option token for an ask, USDC for a bid. If the
    // browser encoder disagreed with SeedBook's Solidity encoder by one byte, this hash
    // would key nothing and the balance would be zero.
    const funded = isAsk ? optionToken : QUOTE
    const [balance] = (await client.readContract({
      address: AQUA,
      abi: aquaAbi,
      functionName: 'rawBalances',
      args: [DESK, ROUTER, strategyHash, funded],
    })) as [bigint, number]

    assert.ok(
      balance > 0n,
      `series ${leg.id} ${side}: Aqua has no balance on ${strategyHash} — the browser encoder ` +
        `does not reproduce what SeedBook shipped`,
    )
    checked++

    rows.push({
      key: `${side}-${leg.id}`,
      side,
      seriesId: leg.id,
      maker: DESK,
      optionToken,
      volWad: volWad.toString(),
      minPremiumBps,
      deadline: leg.deadline,
      salt: s,
      strategyHash,
    })
  }
}

writeFileSync(new URL('./seeded-quotes.json', import.meta.url), JSON.stringify(rows, null, 2))
console.log(`${checked} quotes verified against Aqua, written to scripts/seeded-quotes.json`)
