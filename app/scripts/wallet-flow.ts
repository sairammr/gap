/* Drive every write the UI performs, as a real wallet would, against a forked chain.

   Run:
     anvil --fork-url https://sepolia.base.org --silent &
     node --experimental-strip-types scripts/wallet-flow.ts

   WHY A FORK AND NOT A MOCK. The point is to catch the things that only break against
   real state: a quote that reverts inside Aqua, a taker-traits word the router rejects,
   an allowance the UI forgot, a hash gate that fails because the shipped strategy moved.
   So this imports the app's OWN encoders (`lib/orders.ts`) and replays the exact argument
   lists from `App.tsx` — `handleBuy`, `handleSell`, `actions.exercise` — as broadcast
   transactions. If a step here passes, that same call from a connected wallet passes.

   What it does NOT cover: the wallet connector itself (Privy's modal, signature prompts)
   and anything after expiry, which needs a time warp this script does not do.
*/
import assert from 'node:assert/strict'
import { createPublicClient, createWalletClient, formatUnits, http, parseUnits } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'
import { orderForQuote, takerTraits, type Hex } from '../src/lib/orders.ts'
import { erc20Abi, optionTokenAbi, routerAbi, weekendOptionsAbi } from '../src/lib/abi.ts'
import deployment from '../public/deployments/base-sepolia.json' with { type: 'json' }

const RPC = 'http://127.0.0.1:8545'
// anvil's first default account — funded with ETH on the fork, nothing else.
const TAKER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' as Hex

const account = privateKeyToAccount(TAKER_KEY)
const pub = createPublicClient({ chain: foundry, transport: http(RPC) })
const wallet = createWalletClient({ account, chain: foundry, transport: http(RPC) })

const d = deployment as unknown as Parameters<typeof orderForQuote>[0]
const ROUTER = d.swapVmRouter as Hex
const USDC = d.usdc as Hex
const APP = d.weekendOptions as Hex

const quotes = (deployment as { quotes: Record<string, string | number>[] }).quotes
const ask = quotes.find((q) => q.side === 'ask' && q.seriesId === 2)!
const bid = quotes.find((q) => q.side === 'bid' && q.seriesId === 2)!
assert.ok(ask && bid, 'series 2 needs both an ask and a bid to exercise both directions')

const results: [string, string][] = []
const ok = (step: string, detail: string) => {
  results.push([step, detail])
  console.log(`  ok   ${step.padEnd(28)} ${detail}`)
}

async function send(hash: Hex, label: string) {
  const r = await pub.waitForTransactionReceipt({ hash })
  assert.equal(r.status, 'success', `${label} reverted`)
  return r
}

// --- 1. Test USDC (the UI's `mintTestUsdc`) ---------------------------------
{
  const hash = await wallet.writeContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'mint',
    args: [account.address, parseUnits('10000', 6)],
  })
  await send(hash, 'mint')
  const bal = (await pub.readContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [account.address],
  })) as bigint
  assert.ok(bal >= parseUnits('10000', 6))
  ok('Test USDC', `${formatUnits(bal, 6)} USDC`)
}

// --- 2. The hash gate handleBuy refuses to send without --------------------
const askOrder = orderForQuote(d, ask as never)
{
  const onchain = (await pub.readContract({
    address: ROUTER,
    abi: routerAbi,
    functionName: 'hash',
    args: [askOrder],
  })) as Hex
  assert.equal(
    onchain.toLowerCase(),
    String(ask.strategyHash).toLowerCase(),
    'rebuilt ask does not hash to the shipped strategy',
  )
  ok('Order gate (ask)', onchain.slice(0, 18) + '…')
}

// --- 3. Buy: quote, approve, swap exact-out -------------------------------
const optionToken = ask.optionToken as Hex
const optionsOut = parseUnits('1', 18)
{
  const MAX = (1n << 256n) - 1n
  const ttQuote = takerTraits(USDC, optionToken, USDC, MAX, false)
  const [quotedIn] = (await pub.readContract({
    address: ROUTER,
    abi: routerAbi,
    functionName: 'quote',
    args: [askOrder, optionsOut, ttQuote],
  })) as readonly [bigint, bigint, Hex]
  assert.ok(quotedIn > 0n, 'router quoted zero')
  const maxIn = (quotedIn * 102n) / 100n

  await send(
    await wallet.writeContract({
      address: USDC,
      abi: erc20Abi,
      functionName: 'approve',
      args: [ROUTER, maxIn],
    }),
    'approve USDC',
  )

  const optsBefore = (await pub.readContract({
    address: optionToken,
    abi: optionTokenAbi,
    functionName: 'balanceOf',
    args: [account.address],
  })) as bigint

  const ttSwap = takerTraits(USDC, optionToken, USDC, maxIn, false)
  await send(
    await wallet.writeContract({
      address: ROUTER,
      abi: routerAbi,
      functionName: 'swap',
      args: [askOrder, optionsOut, ttSwap],
    }),
    'buy swap',
  )

  const opts = (await pub.readContract({
    address: optionToken,
    abi: optionTokenAbi,
    functionName: 'balanceOf',
    args: [account.address],
  })) as bigint
  assert.equal(opts - optsBefore, optionsOut, 'bought count != the count the ticket named')
  ok('Buy (exact-out)', `paid ${formatUnits(quotedIn, 6)} USDC for 1.0 option`)
}

// --- 4. Sell half back into the maker's bid -------------------------------
const bidOrder = orderForQuote(d, bid as never)
{
  const onchain = (await pub.readContract({
    address: ROUTER,
    abi: routerAbi,
    functionName: 'hash',
    args: [bidOrder],
  })) as Hex
  assert.equal(onchain.toLowerCase(), String(bid.strategyHash).toLowerCase())
  ok('Order gate (bid)', onchain.slice(0, 18) + '…')

  const sellAmount = parseUnits('0.5', 18)
  await send(
    await wallet.writeContract({
      address: optionToken,
      abi: erc20Abi,
      functionName: 'approve',
      args: [ROUTER, sellAmount],
    }),
    'approve options',
  )

  const before = (await pub.readContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [account.address],
  })) as bigint

  const tt = takerTraits(USDC, optionToken, optionToken, 0n)  // exact-in, as handleSell does
  await send(
    await wallet.writeContract({
      address: ROUTER,
      abi: routerAbi,
      functionName: 'swap',
      args: [bidOrder, sellAmount, tt],
    }),
    'sell swap',
  )

  const after = (await pub.readContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [account.address],
  })) as bigint
  assert.ok(after > before, 'sell-back paid nothing')
  ok('Sell back into bid', `received ${formatUnits(after - before, 6)} USDC for 0.5`)
}

// --- 5. Exercise: physical, reads no oracle -------------------------------
{
  const amount = parseUnits('0.5', 18)
  const series = (await pub.readContract({
    address: APP,
    abi: weekendOptionsAbi,
    functionName: 'getSeries',
    args: [2n],
  })) as { strike: bigint }
  // A CALL holder pays the strike in USDC, so the app needs the allowance.
  const cash = (series.strike * amount) / 10n ** 18n
  await send(
    await wallet.writeContract({
      address: USDC,
      abi: erc20Abi,
      functionName: 'approve',
      args: [APP, cash * 2n],
    }),
    'approve strike cash',
  )

  const nvdaxBefore = (await pub.readContract({
    address: d.nvdax as Hex,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [account.address],
  })) as bigint

  await send(
    await wallet.writeContract({
      address: APP,
      abi: weekendOptionsAbi,
      functionName: 'exercise',
      args: [2n, amount],
    }),
    'exercise',
  )

  const nvdaxAfter = (await pub.readContract({
    address: d.nvdax as Hex,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [account.address],
  })) as bigint
  assert.equal(nvdaxAfter - nvdaxBefore, amount, 'exercise did not deliver the stock')
  ok('Exercise (no oracle)', `paid ${formatUnits(cash, 6)} USDC, took 0.5 NVDAx`)
}

console.log(`\n${results.length} wallet flows passed against the fork.`)
