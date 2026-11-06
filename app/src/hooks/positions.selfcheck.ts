/* Run: node --experimental-strip-types src/hooks/positions.selfcheck.ts
   The fixture is a REAL position on Base Sepolia — app 0x45bBb79E…094f,
   holder 0xa7cE477E…f759, positionId 0xc28de880…5740, bought in block 55311747.
   Read it back with:
     cast call 0x45bBb79Eb1FC30429eC110EEFeD36d6333e8094f \
       'positions(uint256)(bytes32,address,address,address,uint8,uint256,uint256,uint64,uint256,bool,uint256)' \
       0xc28de8809482f4dd761902b870e8b28f4cd6f8c4ec4e29b464762f910ab35740 \
       --rpc-url https://base-sepolia-rpc.publicnode.com                        */
import assert from 'node:assert/strict'
import { liveRows, toPosition, type PositionRecord } from './positions.ts'

const ID = 0xc28de8809482f4dd761902b870e8b28f4cd6f8c4ec4e29b464762f910ab35740n
const REAL: PositionRecord = [
  '0x5f400ac54278098470850da87b95422b32bb5015b4919b7aab2420ca86bf6699',
  '0x9673afB923d556979E4dfe6854d8C6e2D9994Eb4',
  '0xadcEcD2C7dAAFECF2ac72c9c876DFEFC8fbd458c',
  '0xC96239e52F2110D36198F5e1ac0DdE2116617f82',
  1, // PUT
  183000000000000000000n, // strike 183
  9500000000000000000n, // cap 9.5
  1794041798n, // expiry
  1000000000000000000n, // size 1
  false, // settled
  9500000n, // capBacking, 9.5 USDC
]

const p = toPosition(ID, REAL, 1000000000000000000n, 124666n)

// The id must round-trip: the table hands it straight back to BigInt() for settle().
assert.equal(p.positionId, '0xc28de8809482f4dd761902b870e8b28f4cd6f8c4ec4e29b464762f910ab35740')
assert.equal(BigInt(p.positionId), ID)
assert.equal(p.kind, 1) // KIND.PUT
assert.equal(p.strike, 183)
assert.equal(p.cap, 9.5)
assert.equal(p.size, 1)
assert.equal(p.expiry, 1794041798)
assert.equal(p.premium, 0.124666) // quote units are 6dp, NOT WAD
assert.equal(p.settled, false)
assert.equal(p.strategyHash, REAL[0])
assert.equal(p.onchain, true)
assert.equal(p.cap * p.size, 9.5) // max payout == the held capBacking

// kind 0 is a CALL; anything else must not silently read as one.
assert.equal(toPosition(1n, [...REAL.slice(0, 4), 0, ...REAL.slice(5)] as PositionRecord, 1n, 0n).kind, 0)

// A zero balance means settled or transferred away - it is not the holder's row.
const gone = toPosition(2n, REAL, 0n, 1n)
const soon = toPosition(3n, [...REAL.slice(0, 7), 1n, ...REAL.slice(8)] as PositionRecord, 5n, 1n)
assert.deepEqual(
  liveRows([p, gone, soon]).map((r) => r.positionId),
  [soon.positionId, p.positionId], // soonest expiry first, zero balance dropped
)

console.log('positions decode ok')
