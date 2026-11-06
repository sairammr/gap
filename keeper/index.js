/**
 * Settlement keeper for Weekend Options.
 *
 * Nothing in this protocol settles itself, and every payout entry point is
 * permissionless, so this process needs no privileged key — only gas:
 *
 *   oracle.recordSettlement(asset, expiry)   one-shot, irrevocable
 *   weekendOptions.settle(seriesId)          snapshots the six payout fields
 *   weekendOptions.redeemFor(seriesId, h)    pays a holder, (0,0) if they hold nothing
 *   weekendOptions.claimFor(seriesId, w)     pays a writer, one-shot (`written` is zeroed)
 *
 * There is no indexer. Series come from `seriesCount()` + `getSeries(i)`, and
 * holders/writers from `OptionWritten` plus the option token's `Transfer` logs.
 *
 * Zero dependencies, same as `sdk/`: raw JSON-RPC over global `fetch`, hand-rolled
 * ABI head encoding (every call here takes and returns static words only), and
 * hardcoded 4-byte selectors (node has no keccak256 — `sha3-256` is a different
 * padding — so the signature string is kept in a comment next to each constant).
 *
 * Reads need nothing but an RPC URL. Broadcasting shells out to foundry's `cast`,
 * because signing a transaction needs keccak256 + secp256k1 recovery, which is not
 * something to hand-roll on a money path for the sake of a dependency count.
 *
 * Usage:
 *   node index.js                 # dry run, loop
 *   node index.js --once          # dry run, one pass
 *   node index.js --broadcast     # actually send (requires a key)
 */

import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, resolve } from 'node:path';

// ---------------------------------------------------------------- config

const HERE = dirname(fileURLToPath(import.meta.url));

export const DEFAULTS = {
  rpcUrl: 'https://base-sepolia-rpc.publicnode.com',
  intervalMs: 60_000,
  /** The current stack's deploy block (DeployDemo run-latest). Scanning from 0 is
   *  rejected by every provider; a redeploy only ever moves this forward. */
  fromBlock: 55_393_920,
  /** 0 = try the whole range in one call. The public Base Sepolia RPC caps
   *  `eth_getLogs` at 200 blocks; publicnode serves the lot. We try wide once and
   *  latch to 200-block chunks the first time a provider refuses. */
  logChunk: 0,
};

function config(env = process.env) {
  return {
    rpcUrl: env.RPC_URL || DEFAULTS.rpcUrl,
    intervalMs: Number(env.INTERVAL_MS || DEFAULTS.intervalMs),
    fromBlock: Number(env.FROM_BLOCK || DEFAULTS.fromBlock),
    logChunk: Number(env.LOG_CHUNK_BLOCKS || DEFAULTS.logChunk),
    deployment: env.DEPLOYMENT_FILE
      ? resolve(env.DEPLOYMENT_FILE)
      : resolve(HERE, '../contracts/deployments/base-sepolia.json'),
    castBin: env.CAST_BIN || 'cast',
  };
}

// ---------------------------------------------------------------- abi

// Selectors are `cast sig` of the signature in the comment. All args and returns
// below are static words, so encoding is "selector + one padded word per arg" and
// decoding is "slice 32-byte words".
export const SEL = {
  seriesCount: '0xd7f2c0ef', // seriesCount()
  getSeries: '0x1160da15', // getSeries(uint256)
  written: '0xef889a55', // written(uint256,address)
  balanceOf: '0x70a08231', // balanceOf(address)
  decimals: '0x313ce567', // decimals()
  recorded: '0x74a525b9', // recorded(address,uint64)
  recordSettlement: '0x2fda74e1', // recordSettlement(address,uint64)
  settle: '0x8df82800', // settle(uint256)
  redeemFor: '0x161c4e79', // redeemFor(uint256,address)
  claimFor: '0x10ee3f00', // claimFor(uint256,address)
};

export const TOPIC = {
  // OptionWritten(uint256 indexed seriesId, address indexed to, address indexed maker, uint256, uint256)
  optionWritten: '0x099fad1d7c5662c435194258336ac616012d996d05a98a18a80d2a252ce9f424',
  // Transfer(address indexed from, address indexed to, uint256)
  transfer: '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
};

/** Expected states, not failures. Anything not in here is a real surprise. */
export const ERRORS = {
  '0x6e155fc6': 'OracleNotReady', // still inside the 7-day grace window
  '0xd0404f85': 'NotExpired',
  '0x560ff900': 'AlreadySettled',
  '0x103b4afe': 'AlreadyRecorded',
  '0x085de625': 'TooEarly',
  '0xd311bc39': 'NotConfigured', // oracle has no pool for this asset
  '0xb45e12a8': 'BadSeries',
};

export const word = (v) => BigInt(v).toString(16).padStart(64, '0');
export const encode = (sel, ...args) => sel + args.map(word).join('');
export const words = (hex) => {
  const b = hex.slice(2);
  return Array.from({ length: b.length / 64 }, (_, i) => BigInt('0x' + b.slice(i * 64, i * 64 + 64)));
};
export const addr = (w) => '0x' + (typeof w === 'bigint' ? word(w) : w.slice(2)).slice(24);

/** `Series` has no dynamic members, so it is a static tuple: 16 words, no offset. */
export function decodeSeries(hex) {
  const w = words(hex);
  if (w.length !== 16) throw new Error(`getSeries returned ${w.length} words, expected 16`);
  return {
    underlying: addr(w[0]),
    expiry: w[1],
    kind: w[2] === 0n ? 'CALL' : 'PUT',
    strike: w[3],
    token: addr(w[4]),
    totalWritten: w[5],
    poolUnderlying: w[6],
    poolCash: w[7],
    settled: w[8] === 1n,
    settlePrice: w[9],
    supplyAtSettle: w[10],
    holderUnderlying: w[11],
    holderCash: w[12],
    writerUnderlying: w[13],
    writerCash: w[14],
    writtenAtSettle: w[15],
  };
}

/** Mirrors `_redeem` / `_claim`: floor division against the frozen denominator. */
export const proRata = (pool, part, total) => (total === 0n ? 0n : (pool * part) / total);

export const fmt = (v, decimals) => {
  const d = BigInt(decimals);
  const s = v.toString().padStart(Number(d) + 1, '0');
  const i = s.slice(0, s.length - Number(d));
  const f = s.slice(s.length - Number(d)).replace(/0+$/, '');
  return f ? `${i}.${f}` : i;
};

// ---------------------------------------------------------------- rpc

export function makeRpc(url, fetchImpl = fetch) {
  let id = 0;
  return async function rpc(method, params) {
    const res = await fetchImpl(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }),
    });
    if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);
    const json = await res.json();
    if (json.error) {
      const e = new Error(`${method}: ${json.error.message}`);
      e.data = json.error.data;
      throw e;
    }
    return json.result;
  };
}

class Chain {
  constructor(rpc, cfg) {
    this.rpc = rpc;
    this.cfg = cfg;
    this.chunk = cfg.logChunk;
    this.decimalsCache = new Map();
  }

  /** `from` is left off: all four entry points are permissionless, so a simulation
   *  needs no account and a dry run needs no key. */
  call(to, data) {
    return this.rpc('eth_call', [{ to, data }, 'latest']);
  }

  /** eth_call used as a simulation: resolves to null when it would succeed, or to
   *  the revert's name when it would not. Skip, don't crash. */
  async simulate(to, data) {
    try {
      await this.call(to, data);
      return null;
    } catch (e) {
      const sel = typeof e.data === 'string' ? e.data.slice(0, 10) : '';
      return ERRORS[sel] || e.message;
    }
  }

  async decimals(token) {
    if (!this.decimalsCache.has(token))
      this.decimalsCache.set(token, Number(words(await this.call(token, SEL.decimals))[0]));
    return this.decimalsCache.get(token);
  }

  async latest() {
    const b = await this.rpc('eth_getBlockByNumber', ['latest', false]);
    return { number: Number(BigInt(b.number)), timestamp: BigInt(b.timestamp) };
  }

  /** The public Base Sepolia RPC caps eth_getLogs at a 200-block range. Try the
   *  whole span once; latch to chunks the first time a provider refuses. */
  async logs(address, topics, fromBlock, toBlock) {
    const one = (a, b) =>
      this.rpc('eth_getLogs', [
        { address, topics, fromBlock: '0x' + a.toString(16), toBlock: '0x' + b.toString(16) },
      ]);
    if (this.chunk === 0) {
      try {
        return await one(fromBlock, toBlock);
      } catch (e) {
        log(`  wide eth_getLogs refused (${e.message}) — chunking at 200 blocks`);
        this.chunk = 200;
      }
    }
    const out = [];
    for (let b = fromBlock; b <= toBlock; b += this.chunk)
      out.push(...(await one(b, Math.min(b + this.chunk - 1, toBlock))));
    return out;
  }
}

// ---------------------------------------------------------------- planning

/**
 * One pass over every series. Returns `{ actions, notes }` — `actions` are the
 * calls that would be (or are about to be) sent, `notes` are the skips.
 *
 * Deliberately eventually-consistent: when `recordSettlement` has not landed yet,
 * `settle` is left for the next tick rather than chained inside this one. The loop
 * is idempotent, so a tick's worth of latency costs nothing.
 */
export async function plan(chain, d, now, toBlock) {
  const actions = [];
  const notes = [];
  const wo = d.weekendOptions;
  const count = Number(words(await chain.call(wo, SEL.seriesCount))[0]);
  notes.push(`${count} series, chain time ${new Date(Number(now) * 1000).toISOString()}`);

  // One scan for every series' writers and original holders.
  const written = await chain.logs(wo, [TOPIC.optionWritten], d.fromBlock, toBlock);

  for (let id = 0; id < count; id++) {
    const s = decodeSeries(await chain.call(wo, encode(SEL.getSeries, id)));
    const tag = `series ${id} (${s.kind} ${s.underlying.slice(0, 8)}… strike ${s.strike})`;

    if (now < s.expiry) {
      notes.push(`${tag}: not expired, expires ${new Date(Number(s.expiry) * 1000).toISOString()}`);
      continue;
    }

    // 1. Oracle. One-shot per (asset, expiry) and shared across series, so check the
    //    `recorded` flag rather than relying on the AlreadyRecorded revert.
    const isRecorded = words(await chain.call(d.oracle, encode(SEL.recorded, s.underlying, s.expiry)))[0] === 1n;
    if (!isRecorded) {
      const data = encode(SEL.recordSettlement, s.underlying, s.expiry);
      const why = await chain.simulate(d.oracle, data);
      if (why) notes.push(`${tag}: recordSettlement skipped — ${why}`);
      else actions.push({ label: `${tag}: oracle.recordSettlement`, to: d.oracle, data });
    }

    // 2. Settle.
    if (!s.settled) {
      const data = encode(SEL.settle, id);
      const why = await chain.simulate(wo, data);
      if (why) notes.push(`${tag}: settle skipped — ${why}`);
      else actions.push({ label: `${tag}: settle`, to: wo, data });
      // Payouts read the snapshot fields, which do not exist yet. Next tick.
      continue;
    }

    // 3. Payouts. Both sides pay pro-rata out of the frozen snapshot, so a zero
    //    share means there is genuinely nothing to collect — and redeeming it
    //    anyway would burn a holder's tokens for no payout.
    const before = actions.length;
    const uDec = await chain.decimals(s.underlying);
    const qDec = await chain.decimals(d.usdc);
    const money = (u, c) => `${fmt(u, uDec)} underlying + ${fmt(c, qDec)} quote`;
    // Writers and original holders from OptionWritten; later holders from the
    // option token's own Transfer log.
    const holders = new Set();
    const writers = new Set();
    for (const l of written) {
      if (BigInt(l.topics[1]) !== BigInt(id)) continue;
      holders.add(addr(l.topics[2]).toLowerCase());
      writers.add(addr(l.topics[3]).toLowerCase());
    }
    for (const l of await chain.logs(s.token, [TOPIC.transfer], d.fromBlock, toBlock)) {
      holders.add(addr(l.topics[1]).toLowerCase());
      holders.add(addr(l.topics[2]).toLowerCase());
    }
    holders.delete('0x0000000000000000000000000000000000000000');

    for (const h of holders) {
      const bal = words(await chain.call(s.token, encode(SEL.balanceOf, h)))[0];
      if (bal === 0n) continue;
      const outU = proRata(s.holderUnderlying, bal, s.supplyAtSettle);
      const outC = proRata(s.holderCash, bal, s.supplyAtSettle);
      if (outU === 0n && outC === 0n) {
        notes.push(`${tag}: holder ${h} holds ${fmt(bal, 18)} but settled worthless — not burning it`);
        continue;
      }
      const data = encode(SEL.redeemFor, id, h);
      const why = await chain.simulate(wo, data);
      if (why) notes.push(`${tag}: redeemFor ${h} skipped — ${why}`);
      else actions.push({ label: `${tag}: redeemFor ${h} → ${money(outU, outC)}`, to: wo, data });
    }

    for (const w of writers) {
      const owed = words(await chain.call(wo, encode(SEL.written, id, w)))[0];
      if (owed === 0n) continue;
      const outU = proRata(s.writerUnderlying, owed, s.writtenAtSettle);
      const outC = proRata(s.writerCash, owed, s.writtenAtSettle);
      if (outU === 0n && outC === 0n) {
        notes.push(`${tag}: writer ${w} wrote ${fmt(owed, 18)} but is owed nothing — leaving it`);
        continue;
      }
      const data = encode(SEL.claimFor, id, w);
      const why = await chain.simulate(wo, data);
      if (why) notes.push(`${tag}: claimFor ${w} skipped — ${why}`);
      else actions.push({ label: `${tag}: claimFor ${w} → ${money(outU, outC)}`, to: wo, data });
    }

    if (actions.length === before)
      notes.push(
        `${tag}: settled at ${s.settlePrice}, ${holders.size} holder(s) / ${writers.size} writer(s) scanned — all paid out`,
      );
  }

  return { actions, notes };
}

// ---------------------------------------------------------------- broadcast

/**
 * Signing needs keccak256 + secp256k1 recovery; node's crypto has neither
 * (`sha3-256` is a different padding), so hand it to foundry rather than
 * hand-roll crypto on a payout path.
 *
 * Prefer ETH_KEYSTORE/ETH_PASSWORD — `cast` reads those from the environment, so
 * the key never reaches argv. A raw KEEPER_PRIVATE_KEY has to go through
 * `--private-key`, where it is visible in `ps` to anyone on the box. Never logged
 * either way: errors from `cast` are reported by exit status only.
 */
function send(cfg, action, env = process.env) {
  const args = ['send', action.to, action.data, '--rpc-url', cfg.rpcUrl, '--json'];
  if (!env.ETH_KEYSTORE) {
    if (!env.KEEPER_PRIVATE_KEY) throw new Error('set KEEPER_PRIVATE_KEY or ETH_KEYSTORE to broadcast');
    args.push('--private-key', env.KEEPER_PRIVATE_KEY);
  }
  try {
    const out = execFileSync(cfg.castBin, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return JSON.parse(out).transactionHash;
  } catch {
    // `cast`'s stderr can echo back the arguments it was given. Never surface it.
    throw new Error('cast send failed (output suppressed — it can contain the key)');
  }
}

// ---------------------------------------------------------------- loop

const log = (...a) => console.log(...a);

export async function tick(chain, cfg, d, broadcast) {
  const { number, timestamp } = await chain.latest();
  log(`\n[${new Date().toISOString()}] block ${number} — ${broadcast ? 'BROADCAST' : 'dry run'}`);
  const { actions, notes } = await plan(chain, d, timestamp, number);
  for (const n of notes) log(`  · ${n}`);
  if (actions.length === 0) {
    log('  nothing to do');
    return 0;
  }
  for (const a of actions) {
    if (!broadcast) log(`  WOULD SEND  ${a.label}`);
    else log(`  SENT ${send(cfg, a)}  ${a.label}`);
  }
  return actions.length;
}

async function main(argv) {
  const broadcast = argv.includes('--broadcast');
  const once = argv.includes('--once');
  const cfg = config();
  const file = JSON.parse(readFileSync(cfg.deployment, 'utf8'));
  // Addresses are read at runtime, never hardcoded — a redeploy already moved them once.
  const d = {
    weekendOptions: file.weekendOptions,
    oracle: file.oracle,
    usdc: file.usdc,
    fromBlock: cfg.fromBlock,
  };
  for (const [k, v] of Object.entries(d))
    if (v === undefined) throw new Error(`${cfg.deployment} is missing "${k}"`);

  log(`weekend-options keeper — ${cfg.rpcUrl}`);
  log(`deployment ${cfg.deployment}`);
  log(`weekendOptions ${d.weekendOptions}  oracle ${d.oracle}`);
  if (!broadcast) log('dry run (default). pass --broadcast to actually send.');

  const chain = new Chain(makeRpc(cfg.rpcUrl), cfg);
  for (;;) {
    try {
      await tick(chain, cfg, d, broadcast);
    } catch (e) {
      log(`  pass failed: ${e.message}`); // skip, don't crash — try again next tick
    }
    if (once) return;
    await new Promise((r) => setTimeout(r, cfg.intervalMs));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  main(process.argv.slice(2)).catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
