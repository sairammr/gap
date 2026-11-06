// Minimal ABIs for the Gap options frontend, hand-written to match the real
// Solidity signatures in contracts/src/GapOptionsApp.sol, IStateView.sol, and
// the DemoTaker/GapTaker callback pattern in contracts/script/Demo.s.sol.
//
// These are `as const` so viem/wagmi infer argument and return types.

// The Strategy struct — field order is LOAD-BEARING. It must match
// GapOptionsApp.Strategy exactly, because hashStrategy = keccak256(abi.encode(s)).
export const strategyComponents = [
  { name: 'app', type: 'address' },
  { name: 'maker', type: 'address' },
  { name: 'underlying', type: 'address' },
  { name: 'quote', type: 'address' },
  { name: 'poolId', type: 'bytes32' },
  { name: 'underlyingIsCurrency0', type: 'bool' },
  { name: 'underlyingDecimals', type: 'uint8' },
  { name: 'quoteDecimals', type: 'uint8' },
  { name: 'volWad', type: 'uint256' },
  { name: 'salt', type: 'bytes32' },
] as const

const strategyArg = {
  name: 's',
  type: 'tuple',
  components: strategyComponents,
} as const

/** Param list for `encodeAbiParameters` — the bytes `AQUA.ship` wants for the
 *  strategy. Solidity's `abi.encode(strategy)` of this all-static struct is byte
 *  for byte the same, which is why Aqua's returned hash equals hashStrategy. */
export const strategyAbiParams = [strategyArg] as const

export const gapOptionsAppAbi = [
  {
    type: 'function',
    name: 'quotePremium',
    stateMutability: 'view',
    inputs: [
      strategyArg,
      { name: 'kind', type: 'uint8' },
      { name: 'strike', type: 'uint256' },
      { name: 'cap', type: 'uint256' },
      { name: 'expiry', type: 'uint64' },
      { name: 'size', type: 'uint256' },
    ],
    outputs: [{ name: 'premiumQuoteUnits', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'buyOption',
    stateMutability: 'nonpayable',
    inputs: [
      strategyArg,
      { name: 'kind', type: 'uint8' },
      { name: 'strike', type: 'uint256' },
      { name: 'cap', type: 'uint256' },
      { name: 'expiry', type: 'uint64' },
      { name: 'size', type: 'uint256' },
      { name: 'maxPremium', type: 'uint256' },
      { name: 'to', type: 'address' },
      { name: 'takerData', type: 'bytes' },
    ],
    outputs: [{ name: 'positionId', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'settle',
    stateMutability: 'nonpayable',
    inputs: [
      strategyArg,
      { name: 'positionId', type: 'uint256' },
      { name: 'holder', type: 'address' },
    ],
    outputs: [],
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
    name: 'positions',
    stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [
      { name: 'strategyHash', type: 'bytes32' },
      { name: 'maker', type: 'address' },
      { name: 'underlying', type: 'address' },
      { name: 'quote', type: 'address' },
      { name: 'kind', type: 'uint8' },
      { name: 'strike', type: 'uint256' },
      { name: 'cap', type: 'uint256' },
      { name: 'expiry', type: 'uint64' },
      { name: 'size', type: 'uint256' },
      { name: 'settled', type: 'bool' },
      { name: 'capBacking', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'optionNonce',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [
      { name: 'account', type: 'address' },
      { name: 'id', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'event',
    name: 'OptionBought',
    inputs: [
      { name: 'positionId', type: 'uint256', indexed: true },
      { name: 'to', type: 'address', indexed: true },
      { name: 'kind', type: 'uint8', indexed: false },
      { name: 'strike', type: 'uint256', indexed: false },
      { name: 'cap', type: 'uint256', indexed: false },
      { name: 'expiry', type: 'uint64', indexed: false },
      { name: 'size', type: 'uint256', indexed: false },
      { name: 'premium', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'OptionSettled',
    inputs: [
      { name: 'positionId', type: 'uint256', indexed: true },
      { name: 'holder', type: 'address', indexed: true },
      { name: 'spotWad', type: 'uint256', indexed: false },
      { name: 'payout', type: 'uint256', indexed: false },
      { name: 'remainder', type: 'uint256', indexed: false },
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
  // Testnet-only: the mock USDC/NVDAx expose a permissionless mint so a fresh
  // wallet can fund itself. Not present on real USDC.
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

// GapTaker: a small helper contract the UI calls so that msg.sender implements
// IGapOptionCallback (an EOA cannot call buyOption directly — see README). The
// helper pulls the premium with `quote.transferFrom(payer, ...)`, so the caller
// MUST approve it for at least maxPremium first. Address: deployment `gapTaker`.
export const gapTakerAbi = [
  {
    type: 'function',
    name: 'buy',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'gapApp', type: 'address' },
      strategyArg,
      { name: 'kind', type: 'uint8' },
      { name: 'strike', type: 'uint256' },
      { name: 'cap', type: 'uint256' },
      { name: 'expiry', type: 'uint64' },
      { name: 'size', type: 'uint256' },
      { name: 'maxPremium', type: 'uint256' },
      { name: 'to', type: 'address' },
      { name: 'takerData', type: 'bytes' },
    ],
    outputs: [{ name: 'positionId', type: 'uint256' }],
  },
] as const

// 1inch Aqua — the shared liquidity layer. Collateral never leaves the maker's
// wallet on `ship`; it is an accounting entry that `pull` later draws against.
// Signatures copied from @1inch/aqua/contracts/interfaces/IAqua.sol.
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
