// Minimal ABIs for the WeekendOptions frontend, hand-written to match the Solidity
// signatures in contracts/src/WeekendOptions.sol, OptionToken.sol, IStateView.sol,
// @1inch/aqua IAqua, and the real AquaSwapVMRouter (hash/quote/swap).
//
// `as const` so viem/wagmi infer argument and return types.

// The Strategy struct — field order is LOAD-BEARING. It must match
// WeekendOptions.Strategy (WeekendOptions.sol:42) because
// hashStrategy = keccak256(abi.encode(s)).
export const strategyComponents = [
  { name: 'app', type: 'address' },
  { name: 'maker', type: 'address' },
  { name: 'underlying', type: 'address' },
  { name: 'quote', type: 'address' },
  { name: 'volWad', type: 'uint256' },
  { name: 'minPremiumBps', type: 'uint16' },
  { name: 'maxSecondsToExpiry', type: 'uint64' },
  { name: 'salt', type: 'bytes32' },
] as const

const strategyArg = {
  name: 's',
  type: 'tuple',
  components: strategyComponents,
} as const

/** Param list for `encodeAbiParameters` — the bytes `AQUA.ship` wants for the
 *  strategy. abi.encode of this all-static struct is byte-for-byte the same, which
 *  is why Aqua's returned hash equals hashStrategy. */
export const strategyAbiParams = [strategyArg] as const

// The Series tuple returned by getSeries — order matches WeekendOptions.sol:58.
const seriesComponents = [
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
  { name: 'writerUnderlying', type: 'uint256' },
  { name: 'writerCash', type: 'uint256' },
  { name: 'writtenAtSettle', type: 'uint256' },
] as const

export const weekendOptionsAbi = [
  {
    type: 'function',
    name: 'createSeries',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'underlying', type: 'address' },
      { name: 'expiry', type: 'uint64' },
      { name: 'kind', type: 'uint8' },
      { name: 'strike', type: 'uint256' },
    ],
    outputs: [{ name: 'id', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'seriesCount',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getSeries',
    stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [{ name: '', type: 'tuple', components: seriesComponents }],
  },
  {
    type: 'function',
    name: 'quotePremium',
    stateMutability: 'view',
    inputs: [
      strategyArg,
      { name: 'seriesId', type: 'uint256' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'makerCapacity',
    stateMutability: 'view',
    inputs: [strategyArg, { name: 'token', type: 'address' }],
    outputs: [
      { name: 'committed', type: 'uint256' },
      { name: 'wallet', type: 'uint256' },
      { name: 'backable', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'collateralFor',
    stateMutability: 'view',
    inputs: [
      { name: 'id', type: 'uint256' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [
      { name: 'token', type: 'address' },
      { name: 'need', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'hashStrategy',
    stateMutability: 'pure',
    inputs: [strategyArg],
    outputs: [{ name: '', type: 'bytes32' }],
  },
  {
    type: 'function',
    name: 'written',
    stateMutability: 'view',
    inputs: [
      { name: 'seriesId', type: 'uint256' },
      { name: 'user', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'exercise',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'id', type: 'uint256' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'close',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'id', type: 'uint256' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'settle',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'redeem',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'id', type: 'uint256' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [
      { name: 'outU', type: 'uint256' },
      { name: 'outC', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'redeemFor',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'id', type: 'uint256' },
      { name: 'holder', type: 'address' },
    ],
    outputs: [
      { name: 'outU', type: 'uint256' },
      { name: 'outC', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'claim',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [
      { name: 'outU', type: 'uint256' },
      { name: 'outC', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'claimFor',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'id', type: 'uint256' },
      { name: 'writer', type: 'address' },
    ],
    outputs: [
      { name: 'outU', type: 'uint256' },
      { name: 'outC', type: 'uint256' },
    ],
  },
  {
    type: 'event',
    name: 'SeriesCreated',
    inputs: [
      { name: 'seriesId', type: 'uint256', indexed: true },
      { name: 'underlying', type: 'address', indexed: true },
      { name: 'expiry', type: 'uint64', indexed: false },
      { name: 'kind', type: 'uint8', indexed: false },
      { name: 'strike', type: 'uint256', indexed: false },
      { name: 'token', type: 'address', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'OptionWritten',
    inputs: [
      { name: 'seriesId', type: 'uint256', indexed: true },
      { name: 'to', type: 'address', indexed: true },
      { name: 'maker', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
      { name: 'premium', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Exercised',
    inputs: [
      { name: 'seriesId', type: 'uint256', indexed: true },
      { name: 'holder', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Settled',
    inputs: [
      { name: 'seriesId', type: 'uint256', indexed: true },
      { name: 'price', type: 'uint256', indexed: false },
      { name: 'holderUnderlying', type: 'uint256', indexed: false },
      { name: 'holderCash', type: 'uint256', indexed: false },
    ],
  },
] as const

// The AquaSwapVMRouter surface we fill through. `Order` is field-identical to
// test/helpers/OrderLib.Order and sdk/orders.ts `Order`. See contracts/script/
// Lifecycle.s.sol `IRouter` for the exact signatures.
const orderComponents = [
  { name: 'maker', type: 'address' },
  { name: 'traits', type: 'uint256' },
  { name: 'data', type: 'bytes' },
] as const

const orderArg = { name: 'order', type: 'tuple', components: orderComponents } as const

export const routerAbi = [
  {
    type: 'function',
    name: 'hash',
    stateMutability: 'view',
    inputs: [orderArg],
    outputs: [{ name: '', type: 'bytes32' }],
  },
  {
    type: 'function',
    name: 'quote',
    stateMutability: 'view',
    inputs: [orderArg, { name: 'amount', type: 'uint256' }, { name: 'tt', type: 'bytes' }],
    outputs: [
      { name: 'amountIn', type: 'uint256' },
      { name: 'amountOut', type: 'uint256' },
      { name: 'orderHash', type: 'bytes32' },
    ],
  },
  {
    type: 'function',
    name: 'swap',
    stateMutability: 'payable',
    inputs: [orderArg, { name: 'amount', type: 'uint256' }, { name: 'tt', type: 'bytes' }],
    outputs: [
      { name: 'amountIn', type: 'uint256' },
      { name: 'amountOut', type: 'uint256' },
      { name: 'orderHash', type: 'bytes32' },
    ],
  },
] as const

// Uniswap v4 StateView lens — only getSlot0, used to build the candle series.
export const stateViewAbi = [
  {
    type: 'function',
    name: 'getSlot0',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [
      { name: 'sqrtPriceX96', type: 'uint160' },
      { name: 'tick', type: 'int24' },
      { name: 'protocolFee', type: 'uint24' },
      { name: 'lpFee', type: 'uint24' },
    ],
  },
] as const

// OptionToken is a plain ERC-20 (one contract per series). Plus the ERC-20 reads the
// positions view needs. `symbol`/`name` label the series in the UI (UP-0 / FLOOR-1).
export const optionTokenAbi = [
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'totalSupply',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'symbol',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'string' }],
  },
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
] as const

export const erc20Abi = [
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'decimals',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint8' }],
  },
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  // Testnet-only: the mock USDC/NVDAx expose a permissionless mint so a fresh wallet
  // can fund itself. Not present on real USDC.
  {
    type: 'function',
    name: 'mint',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [],
  },
] as const

// 1inch Aqua — the shared liquidity layer. Collateral never leaves the maker's wallet
// on `ship`; it is an accounting entry that `pull` later draws against. Signatures from
// @1inch/aqua/contracts/interfaces/IAqua.sol.
export const aquaAbi = [
  {
    type: 'function',
    name: 'ship',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'app', type: 'address' },
      { name: 'strategy', type: 'bytes' },
      { name: 'tokens', type: 'address[]' },
      { name: 'amounts', type: 'uint256[]' },
    ],
    outputs: [{ name: 'strategyHash', type: 'bytes32' }],
  },
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
  {
    type: 'event',
    name: 'Shipped',
    inputs: [
      { name: 'maker', type: 'address', indexed: false },
      { name: 'app', type: 'address', indexed: false },
      { name: 'strategyHash', type: 'bytes32', indexed: false },
      { name: 'strategy', type: 'bytes', indexed: false },
    ],
  },
] as const
