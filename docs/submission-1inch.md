# 1inch — Build an Aqua App

## How are you using this Protocol / API?

GAP is a fully-collateralised options desk with no exchange of its own: a maker's resting
option quote **is** a SwapVM order — `Deadline + Salt + RequireMinRate + Extruction(pricer,
args)` — filled through the official `AquaSwapVMRouter`, and that fill is what writes the
option. `Aqua.ship` commits the collateral while moving **zero tokens**, leaving it in the
maker's own wallet; `Aqua.pull` is the first token movement in the system and happens inside
the taker's transaction; `Aqua.push` returns the premium, which the app verifies landed
before the mint completes. Because `Aqua.strategyHash == keccak256(abi.encode(order)) ==
router.hash(order)`, the SwapVM order *is* the Aqua strategy, and
`USE_AQUA_INSTEAD_OF_SIGNATURE` means **no signature is ever read** — shipping on chain is
the authorisation. Our Abramowitz-Stegun Black-Scholes pricer implements
`IStaticExtruction`, so pricing executes **on-path inside the swap program** against live
Uniswap v4 spot, filling the amount register the taker did not name and gating swap
direction; the desk implements `IMakerHooks`, **minting the option mid-fill** in
`preTransferOut` against collateral still sitting in the maker's wallet, with
`postTransferIn` closing its own short on the bid side. Aqua's ledger is the depth, the
maker's wallet is the custody, the router is the matching engine — none of it reimplemented.
Proven by 207 tests, **53 against the real `Aqua` and real `AquaSwapVMRouter`** with the
venue never mocked, a live UI gated on `router.hash(order) == the shipped strategyHash`, and
a full lifecycle on Base Sepolia: seven transactions, all confirmed, exact conservation.

## Link to the line of code

```
https://github.com/sairammr/gap/blob/0fdbcf729ff93c174b5c450a12798f6ae02cea22/contracts/src/desk/WeekendPricer.sol#L127-L146
```

## Ease — 9

`ship` / `pull` / `push` is small enough to hold in your head, and `strategyHash` being
`keccak256` of the shipped bytes makes the SwapVM order and the Aqua strategy the same
object — that identity deleted an entire authorisation layer. Not a 10 only because nothing
in the SwapVM repo pairs maker hooks with an Aqua-authorised order (its own helper hardcodes
all four hook flags off), so that combination came from the specs rather than an example.
