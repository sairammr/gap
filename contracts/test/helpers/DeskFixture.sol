// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/contracts/Aqua.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AquaSwapVMRouter } from "swapvm/routers/AquaSwapVMRouter.sol";
import { ISwapVM } from "swapvm/interfaces/ISwapVM.sol";
import { MakerTraits } from "swapvm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "swapvm/libs/TakerTraits.sol";

import { Kind, WeekendOptions } from "../../src/WeekendOptions.sol";
import { OptionTokenFactory } from "../../src/OptionToken.sol";
import { WeekendDesk } from "../../src/desk/WeekendDesk.sol";
import { WeekendPricer } from "../../src/desk/WeekendPricer.sol";
import { V4SpotOracle } from "../../src/oracle/V4SpotOracle.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { MockStateView } from "./MockStateView.sol";
import { OrderLib } from "./OrderLib.sol";

/// @title DeskFixture
/// @notice The shared wiring for every SwapVM integration test. Deploy once in `setUp`, ship a
///         quote, fill it through the real router.
///
/// @dev REAL CONTRACTS, per spec §13. The real `Aqua`, the real `AquaSwapVMRouter`, the real
///      `WeekendOptions` / `OptionToken` / `WeekendPricer` / `WeekendDesk`, real ERC-20s. The
///      only doubles are the v4 `StateView` lens (`MockStateView`) and — through it — the price
///      the real `V4SpotOracle` reports. Nothing else is simulated: every fill below is an
///      actual `router.swap(...)`.
///
/// @dev Build and run under the SwapVM profile; SwapVM does not compile under the default one.
///
///        FOUNDRY_PROFILE=swapvm ~/.foundry/bin/forge test --match-path 'test/integration/*'
///
/// @dev FIVE THINGS THIS FIXTURE EXISTS TO GET RIGHT. Each was paid for once already.
///
///      1. **The desk needs quote in its own wallet.** The ask mints just-in-time via
///         `buyOption`, whose premium leg is `AQUA.push` -> `safeTransferFrom(desk, desk, …)`.
///         ERC-20 checks the balance even on a self-transfer, so the desk is funded with quote
///         and its own strategy ships a (zero-amount) quote leg, or the push reverts
///         `PushToNonActiveStrategyPrevented`.
///      2. **One own-strategy means one underlying.** `buyOption` reverts `StrategyMismatch`
///         unless `strategy.underlying == series.underlying`. One desk, one underlying.
///      3. **`approveAqua` is mandatory** for every token that will ever be pulled out of the
///         desk — option token, underlying cover and quote.
///      4. **Both legs of every pair get shipped.** `AQUA.safeBalances` reverts unless both
///         tokens sit in an active, non-docked strategy. The zero leg is there for that lookup
///         and is never a budget.
///      5. **`Aqua.ship` is immutable.** A shipped amount is a permanent cumulative cap across
///         every fill of that order hash; re-offering needs a new salt, which is why every ship
///         helper has a salt-taking overload.
///
/// @dev `WeekendOptions.close` does not exist yet. The desk's bid path tolerates that (it
///      try/catches and keeps the options as inventory), so nothing here may assume it lands.
abstract contract DeskFixture is Test {
    // ------------------------------------------------------------------ constants

    /// @dev `WeekendPricer.SIDE_ASK` / `SIDE_BID`, inlined so reading them cannot consume a
    ///      pending `vm.expectRevert`.
    uint8 internal constant SIDE_ASK = 0;
    uint8 internal constant SIDE_BID = 1;

    /// @dev Spread is vol and nothing else: the ask quotes a higher vol than the bid.
    uint256 internal constant VOL_ASK = 0.6e18;
    uint256 internal constant VOL_BID = 0.4e18;
    /// @dev The vol the desk writes against itself at. Only sets how much quote has to sit idle
    ///      in the desk for the self-write round trip; never what a taker pays.
    uint256 internal constant VOL_SELF = 0.5e18;

    uint256 internal constant SERIES_CAP = 100e18;
    uint256 internal constant STRIKE = 205e6; // quote units per 1e18 — at the money
    /// @dev The order's own premium floor. Must be >= the own-strategy's (0), or `WeekendPricer`
    ///      would accept a premium `buyOption` then rejects mid-fill.
    uint16 internal constant MIN_PREMIUM_BPS = 1;

    /// @dev Fixed, so `shipAsk(cap)` twice is the same hash — which is how Task 8 proves
    ///      `StrategiesMustBeImmutable`. Use the salt-taking overload for a fresh offer.
    bytes32 internal constant ASK_SALT = bytes32(uint256(1));
    bytes32 internal constant BID_SALT = bytes32(uint256(2));

    /// @dev sqrtPriceX96 for an 18dp underlying / 6dp quote at spot = 205e6, currency0 = asset.
    uint160 internal constant SQRT_PRICE_205 = 1134374654051415993876480;
    bytes32 internal constant POOL_ID = bytes32(uint256(1));

    address internal constant TAKER = address(0xBEEF);

    /// @dev Cover and cash. Deliberately far more than any single test needs — the binding caps
    ///      in these tests are the shipped Aqua amounts and `maxShort`, never the wallet.
    uint256 internal constant DESK_COVER = 10_000e18;
    uint256 internal constant DESK_CASH = 1_000_000e6;
    uint256 internal constant TAKER_CASH = 1_000_000e6;

    // ------------------------------------------------------------------ deployed

    Aqua internal aqua;
    AquaSwapVMRouter internal router;
    WeekendOptions internal app;
    WeekendDesk internal desk;
    WeekendPricer internal pricer;
    V4SpotOracle internal oracle;
    MockStateView internal stateView;

    MockERC20 internal quote; // 6 dp, the USDC stand-in
    MockERC20 internal underlying; // 18 dp, the tokenized stock
    MockERC20 internal weth; // router plumbing only; never traded here

    uint256 internal callId;
    address internal optionToken;
    uint64 internal expiry;

    // ------------------------------------------------------------------ setUp

    function setUp() public virtual {
        aqua = new Aqua();
        quote = new MockERC20("USD Coin", "USDC", 6);
        underlying = new MockERC20("NVDA xStock", "NVDAx", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        router = new AquaSwapVMRouter(address(aqua), address(weth), address(this), "SwapVM", "1");

        stateView = new MockStateView(SQRT_PRICE_205);
        oracle = new V4SpotOracle(stateView, 6);
        oracle.setPool(address(underlying), POOL_ID, 18, true);

        app = new WeekendOptions(address(quote), new OptionTokenFactory(), IAqua(address(aqua)), oracle);
        pricer = new WeekendPricer(app, oracle, address(quote), 6);

        expiry = uint64(block.timestamp + 7 days);
        callId = app.createSeries(address(underlying), expiry, Kind.CALL, STRIKE);
        optionToken = address(app.getSeries(callId).token);

        desk = new WeekendDesk(app, IAqua(address(aqua)), address(router), address(quote));
        listSeries(SERIES_CAP);
        desk.setOwnStrategy(ownStrategy());

        // Cover to write against, and cash for the self-write premium (fact 1).
        underlying.mint(address(desk), DESK_COVER);
        quote.mint(address(desk), DESK_CASH);

        // Fact 3. `AQUA.pull` is a real `transferFrom` out of this wallet, for all three tokens:
        // the option token on an ask fill, the quote on a bid fill, the cover on a self-write.
        //
        // The desk pays out quote on a bid and pulls cover on an ask, so Aqua needs a standing
        // allowance for all three. `gapOptionCallback` tops this up only when it is short, and
        // tops up to max — approving exactly `premiumOwed` there would let `AQUA.push` spend the
        // allowance to zero and silently kill every later pull (fixed in 683b60d).
        desk.approveAqua(optionToken, type(uint256).max);
        desk.approveAqua(address(underlying), type(uint256).max);
        desk.approveAqua(address(quote), type(uint256).max);

        // The desk's own core-protocol strategy. Both legs, quote at zero (facts 1 and 4).
        _ship(address(app), abi.encode(ownStrategy()), address(underlying), DESK_COVER, address(quote), 0);

        // The taker pays through the router (`useTransferFromAndAquaPush`), so the router — not
        // Aqua — is what it approves.
        quote.mint(TAKER, TAKER_CASH);
        vm.startPrank(TAKER);
        quote.approve(address(router), type(uint256).max);
        IERC20(optionToken).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ desk admin

    /// @notice (Re-)list the one series with a short cap. The test contract owns the desk.
    function listSeries(uint256 cap) internal {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory caps = new uint256[](1);
        (ids[0], caps[0]) = (callId, cap);
        desk.listSeries(ids, caps);
    }

    /// @notice The desk's `WeekendOptions` strategy — it is maker and taker of its own write.
    function ownStrategy() internal view returns (WeekendOptions.Strategy memory) {
        return WeekendOptions.Strategy({
            app: address(app),
            maker: address(desk),
            underlying: address(underlying),
            quote: address(quote),
            volWad: VOL_SELF,
            minPremiumBps: 0,
            maxSecondsToExpiry: type(uint64).max,
            salt: bytes32(0)
        });
    }

    // ------------------------------------------------------------------ orders

    /// @notice The order parameters for one side. Mutate the returned struct and feed it to
    ///         `orderOf` / `ship` to test a variant (a repointed pricer, another vol, a
    ///         different series) without reaching for `OrderLib` directly.
    function params(uint8 side, bytes32 salt) internal view returns (OrderLib.Params memory) {
        return OrderLib.Params({
            desk: address(desk),
            pricer: address(pricer),
            quote: address(quote),
            optionToken: optionToken,
            seriesId: callId,
            volWad: side == SIDE_ASK ? VOL_ASK : VOL_BID,
            minPremiumBps: MIN_PREMIUM_BPS,
            side: side,
            // Far enough out that a test warping past the series expiry still trips
            // `SeriesExpired` rather than the `Deadline` opcode.
            deadline: uint40(block.timestamp + 365 days),
            salt: salt,
            // 0/0 disables `RequireMinRate`. The binding floor on this route is
            // `minPremiumBps` inside `WeekendPricer`; the rate guard is a blunt cross-decimal
            // ratio that a naive 1/1 would use to reject every sane 6dp-for-18dp fill.
            minRateA: 0,
            minRateB: 0
        });
    }

    /// @notice `OrderLib`'s order, wrapped for the router. Field-identical by construction.
    function orderOf(OrderLib.Params memory p) internal pure returns (ISwapVM.Order memory) {
        OrderLib.Order memory o = OrderLib.order(p);
        return ISwapVM.Order({ maker: o.maker, traits: MakerTraits.wrap(o.traits), data: o.data });
    }

    // ------------------------------------------------------------------ ships

    /// @notice Ship the ask: `[optionToken @ cap, quote @ 0]`. The cap is permanent (fact 5).
    function shipAsk(uint256 cap) internal returns (bytes32 strategyHash, ISwapVM.Order memory o) {
        return shipAsk(ASK_SALT, cap);
    }

    function shipAsk(bytes32 salt, uint256 cap) internal returns (bytes32 strategyHash, ISwapVM.Order memory o) {
        return ship(params(SIDE_ASK, salt), cap);
    }

    /// @notice Ship the bid: `[quote @ budget, optionToken @ 0]`. `budget` is in quote units.
    function shipBid(uint256 budget) internal returns (bytes32 strategyHash, ISwapVM.Order memory o) {
        return shipBid(BID_SALT, budget);
    }

    function shipBid(bytes32 salt, uint256 budget) internal returns (bytes32 strategyHash, ISwapVM.Order memory o) {
        return ship(params(SIDE_BID, salt), budget);
    }

    /// @notice Ship whatever `p` describes, with `amount` on the side the maker is selling.
    /// @return strategyHash What Aqua returns — equal to `router.hash(o)` by design.
    function ship(OrderLib.Params memory p, uint256 amount)
        internal
        returns (bytes32 strategyHash, ISwapVM.Order memory o)
    {
        o = orderOf(p);
        (address sell, address zero) =
            p.side == SIDE_ASK ? (p.optionToken, p.quote) : (p.quote, p.optionToken);
        strategyHash = _ship(address(router), abi.encode(o), sell, amount, zero, 0);
    }

    /// @dev Through `desk.ship`, not `aqua.ship`. `Aqua` keys balances by `msg.sender` and
    ///      `SwapVM` reads them back with `AQUA.safeBalances(order.maker, …)`, so the ship has
    ///      to come from the desk itself — which is also the only way it can happen on a live
    ///      chain. No prank: the fixture owns the desk.
    function _ship(address app_, bytes memory strategy, address token0, uint256 amount0, address token1, uint256 amount1)
        private
        returns (bytes32)
    {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (token0, amount0);
        (tokens[1], amounts[1]) = (token1, amount1);
        return desk.ship(app_, strategy, tokens, amounts);
    }

    // ------------------------------------------------------------------ fills

    /// @notice Build the taker's half of a `router.swap` call.
    ///
    /// @param o          The order being filled — only its token pair is read, to derive `isAToB`.
    /// @param tokenIn    What the TAKER pays. `address(quote)` buys options, `optionToken` sells
    ///                   them back. Passing the direction the order was not shipped for is how a
    ///                   test proves the pricer's direction gate.
    /// @param exactIn    True: `amount` is what the taker pays. False: what it receives.
    /// @param takerFirst `IS_FIRST_TRANSFER_FROM_TAKER` (`0x0020`). A TAKER trait — the maker
    ///                   cannot force it, so the hooks must be correct both ways (spec §12.7).
    ///                   Unset (the common case) means the desk ships before it is paid.
    /// @param threshold  `minOut` when `exactIn`, `maxIn` otherwise. **0 means no threshold at
    ///                   all**, not "min out of zero" — a literal 0 would make every exact-out
    ///                   fill revert on `amountIn <= 0`.
    ///
    /// @dev `useTransferFromAndAquaPush` is always on. The alternative Aqua in-leg expects the
    ///      taker to have pushed into the maker's ledger itself before calling, which is a
    ///      solver's job, not a test's.
    function takerTraits(ISwapVM.Order memory o, address tokenIn, bool exactIn, bool takerFirst, uint256 threshold)
        internal
        pure
        returns (bytes memory)
    {
        TakerTraitsLib.Args memory a;
        a.taker = TAKER;
        a.isExactIn = exactIn;
        a.isFirstTransferFromTaker = takerFirst;
        a.useTransferFromAndAquaPush = true;
        a.isAToB = tokenIn == _tokenA(o.data);
        if (threshold != 0) a.threshold = abi.encode(threshold);
        return TakerTraitsLib.build(a);
    }

    /// @notice Execute a real fill as `TAKER`.
    function fill(ISwapVM.Order memory o, uint256 amount, bytes memory tt)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        vm.prank(TAKER);
        (amountIn, amountOut,) = router.swap(o, amount, tt);
    }

    /// @notice The same program, priced without moving anything. `quote` is non-view on the
    ///         router (`Extruction` may be stateful in general), so it is pranked too.
    function previewFill(ISwapVM.Order memory o, uint256 amount, bytes memory tt)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        vm.prank(TAKER);
        (amountIn, amountOut,) = router.quote(o, amount, tt);
    }

    // ------------------------------------------------------------------ reads

    function written() internal view returns (uint256) {
        return app.written(callId, address(desk));
    }

    function inventory() internal view returns (uint256) {
        return IERC20(optionToken).balanceOf(address(desk));
    }

    /// @dev `order.data` is `tokenA || tokenB || program`, tokens sorted ascending by `OrderLib`.
    function _tokenA(bytes memory data) private pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(data, 0x20)))
        }
    }
}
