/** The pure bits: ABI head encoding, the 16-word Series decode, and the pro-rata
 *  arithmetic that decides whether a payout is worth a transaction. Chain access
 *  is not mocked — `--once --dry-run` against the live RPC is that check. */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encode, decodeSeries, proRata, fmt, SEL, addr } from './index.js';

test('encode packs a selector plus one padded word per arg', () => {
  assert.equal(
    encode(SEL.claimFor, 1, '0x9673afB923d556979E4dfe6854d8C6e2D9994Eb4'),
    '0x10ee3f00' +
      '0000000000000000000000000000000000000000000000000000000000000001' +
      '0000000000000000000000009673afb923d556979e4dfe6854d8c6e2d9994eb4',
  );
});

test('decodeSeries reads the live series 1 return verbatim', () => {
  // `cast call 0x7031…Ce4f "getSeries(uint256)" 1` on Base Sepolia, 2026-11-06.
  const hex =
    '0x' +
    '00000000000000000000000011dd00c731f27793bd9426b8ef22d7971aa2052b' + // underlying
    '000000000000000000000000000000000000000000000000000000006aee4a7f' + // expiry
    '0000000000000000000000000000000000000000000000000000000000000000' + // CALL
    '0000000000000000000000000000000000000000000000000000000005a995bf' + // strike
    '0000000000000000000000008203b2746d95c3a661478996463d695408611f9e' + // token
    '0000000000000000000000000000000000000000000000006f05b59d3b200000' + // totalWritten
    '0000000000000000000000000000000000000000000000004563918244f40000' + // poolUnderlying
    '0000000000000000000000000000000000000000000000000000000010fcc13d' + // poolCash
    '0000000000000000000000000000000000000000000000000000000000000001' + // settled
    '0000000000000000000000000000000000000000000000000000000005f5e0ff' + // settlePrice
    '0000000000000000000000000000000000000000000000004563918244f40000' + // supplyAtSettle
    '00000000000000000000000000000000000000000000000003782dad7edbf919' + // holderUnderlying
    '0000000000000000000000000000000000000000000000000000000000000000' + // holderCash
    '00000000000000000000000000000000000000000000000041eb63d4c61806e7' + // writerUnderlying
    '0000000000000000000000000000000000000000000000000000000010fcc13d' + // writerCash
    '0000000000000000000000000000000000000000000000006f05b59d3b200000'; // writtenAtSettle
  const s = decodeSeries(hex);
  assert.equal(s.settled, true);
  assert.equal(s.kind, 'CALL');
  assert.equal(s.expiry, 1794001535n);
  assert.equal(s.token, '0x8203b2746d95c3a661478996463d695408611f9e');
  assert.equal(s.supplyAtSettle, 5000000000000000000n);
  // poolUnderlying = holderUnderlying + writerUnderlying, exactly (spec §10).
  assert.equal(s.holderUnderlying + s.writerUnderlying, s.poolUnderlying);
});

test('decodeSeries refuses a short return rather than guessing', () => {
  assert.throws(() => decodeSeries('0x' + '00'.repeat(32)), /expected 16/);
});

test('proRata floors, and a zero denominator is zero not NaN', () => {
  assert.equal(proRata(10n ** 18n, 1n, 3n), 333333333333333333n);
  assert.equal(proRata(5n, 1n, 0n), 0n);
});

test('fmt renders quote and underlying scales', () => {
  assert.equal(fmt(285000509n, 6), '285.000509');
  assert.equal(fmt(5000000000000000000n, 18), '5');
  assert.equal(fmt(0n, 18), '0');
});

test('addr lowercases and trims a topic to 20 bytes', () => {
  assert.equal(
    addr('0x0000000000000000000000009673afb923d556979e4dfe6854d8c6e2d9994eb4'),
    '0x9673afb923d556979e4dfe6854d8c6e2d9994eb4',
  );
});
