// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/contracts/Aqua.sol";
import { IAqua } from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import { Kind, WeekendOptions } from "../src/WeekendOptions.sol";
import { WeekendTaker } from "../src/WeekendTaker.sol";
import { OptionTokenFactory } from "../src/OptionToken.sol";
import { V4SpotOracle } from "../src/oracle/V4SpotOracle.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockStateView } from "./helpers/MockStateView.sol";
import { NoOpTaker } from "./helpers/NoOpTaker.sol";
import { FeeOnTransferERC20 } from "./helpers/FeeOnTransferERC20.sol";

/// @notice The Aqua write path: a maker ships cover, a buyer writes options against it.
/// @dev Runs against the real `Aqua` contract, not a double. That matters: `ship` moves no
///      tokens, so the maker's wallet and Aqua's books are independent numbers that the app
///      has to reconcile at `pull` time.
contract WriteTest is Test {
    // sqrtPriceX96 constants for the 18dp underlying / 6dp quote, underlyingIsCurrency0 = true
    // base `spot = 100e18 -> 792281625142643375935439`, scaled by sqrt(P/100).
    uint160 internal constant SQRT_PRICE_205 = 1134374654051415993876480;
    uint160 internal constant SQRT_PRICE_300 = 1372272028650298020986880;

    bytes32 internal constant POOL_ID = bytes32(uint256(1));
    uint256 internal constant STRIKE = 205e6;
    uint256 internal constant VOL = 0.5e18;

    Aqua internal aqua;
    WeekendOptions internal app;
    WeekendTaker internal taker;
    V4SpotOracle internal oracle;
    MockStateView internal stateView;
    MockERC20 internal nvdax;
    MockERC20 internal usdc;

    address internal maker = address(0xBEEF);
    address internal buyer = address(0xB0B);

    uint64 internal expiry;
    /// @dev The maker's premium floor for the strategy under test. 0 unless a test sets it.
    uint16 internal floorBps;

    function setUp() public {
        aqua = new Aqua();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvdax = new MockERC20("NVDA xStock", "NVDAx", 18);

        stateView = new MockStateView(SQRT_PRICE_205);
        oracle = new V4SpotOracle(stateView, 6);
        oracle.setPool(address(nvdax), POOL_ID, 18, true);

        OptionTokenFactory factory = new OptionTokenFactory();
        app = new WeekendOptions(address(usdc), factory, IAqua(address(aqua)), oracle);
        taker = new WeekendTaker(IAqua(address(aqua)), address(app));

        expiry = uint64(block.timestamp + 7 days);

        // The buyer is funded and approved once, so `_buy` is a single external call and
        // `vm.expectRevert` lands on the call under test.
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(taker), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _strategy() internal view returns (WeekendOptions.Strategy memory) {
        return WeekendOptions.Strategy({
            app: address(app),
            maker: maker,
            underlying: address(nvdax),
            quote: address(usdc),
            volWad: VOL,
            minPremiumBps: floorBps,
            maxSecondsToExpiry: 30 days,
            salt: bytes32(0)
        });
    }

    /// @dev Local hash, so no external call stands between `expectRevert` and the call it guards.
    function _hash() internal view returns (bytes32) {
        return keccak256(abi.encode(_strategy()));
    }

    function _callSeries() internal returns (uint256) {
        return app.createSeries(address(nvdax), expiry, Kind.CALL, STRIKE);
    }

    function _putSeries() internal returns (uint256) {
        return app.createSeries(address(nvdax), expiry, Kind.PUT, STRIKE);
    }

    /// @dev Mint `amount` of `token` to `who` and commit it on Aqua's books. The quote token is
    ///      always part of the strategy so the premium `push` has an active balance to land in.
    function _ship(address who, address token, uint256 amount) internal {
        MockERC20(token).mint(who, amount);

        bool quoteIsCover = token == address(usdc);
        address[] memory tokens = new address[](quoteIsCover ? 1 : 2);
        uint256[] memory amounts = new uint256[](quoteIsCover ? 1 : 2);
        tokens[0] = token;
        amounts[0] = amount;
        if (!quoteIsCover) {
            tokens[1] = address(usdc);
            amounts[1] = 0;
        }

        vm.startPrank(who);
        MockERC20(token).approve(address(aqua), type(uint256).max);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.ship(address(app), abi.encode(_strategy()), tokens, amounts);
        vm.stopPrank();
    }

    function _buy(uint256 id, uint256 amount, address to) internal returns (uint256) {
        return _buyWithMax(id, amount, to, type(uint256).max);
    }

    function _buyWithMax(uint256 id, uint256 amount, address to, uint256 maxPremium)
        internal
        returns (uint256)
    {
        vm.prank(buyer);
        return taker.buy(app, _strategy(), id, amount, maxPremium, to, abi.encode(maker, _hash()));
    }

    function _shipAndBuy(uint256 id, uint256 amount, address to) internal returns (uint256) {
        _ship(maker, address(nvdax), amount);
        return _buy(id, amount, to);
    }

    // ------------------------------------------------------------------ tests

    function test_buy_pullsCoverIntoPoolAndPushesPremiumToMakerWallet() public {
        uint256 id = _callSeries();
        _ship(maker, address(nvdax), 10e18);
        uint256 makerUsdc0 = usdc.balanceOf(maker);

        uint256 prem = _buy(id, 10e18, buyer);

        assertEq(nvdax.balanceOf(maker), 0); // cover left the wallet
        assertEq(nvdax.balanceOf(address(app)), 10e18); // ...into the pool
        assertEq(app.getSeries(id).poolUnderlying, 10e18);
        assertEq(app.getSeries(id).totalWritten, 10e18);
        assertEq(app.written(id, maker), 10e18);
        assertEq(app.getSeries(id).token.balanceOf(buyer), 10e18);
        assertEq(usdc.balanceOf(maker) - makerUsdc0, prem); // premium to the wallet
    }

    function test_ship_movesNoTokens() public {
        _ship(maker, address(nvdax), 10e18);
        assertEq(nvdax.balanceOf(maker), 10e18);
    }

    // Review Focus 3
    function test_buy_revertsLegiblyWhenMakerWalletDrainedDespiteAquaBooks() public {
        uint256 id = _callSeries();
        _ship(maker, address(nvdax), 10e18);
        vm.prank(maker);
        nvdax.transfer(address(0xDEAD), 10e18);
        (,, uint256 backable) = app.makerCapacity(_strategy(), address(nvdax));
        assertEq(backable, 0);
        vm.expectRevert(WeekendOptions.InsufficientMakerCollateral.selector);
        _buy(id, 10e18, buyer);
    }

    function test_buy_revertsOverMaxPremiumAndAfterExpiry() public {
        uint256 id = _callSeries();
        _ship(maker, address(nvdax), 10e18);

        uint256 prem = app.quotePremium(_strategy(), id, 10e18);
        assertGt(prem, 0);

        // A taker who will not pay the quoted price is turned away, not silently overcharged.
        vm.expectRevert(WeekendOptions.PremiumTooHigh.selector);
        _buyWithMax(id, 10e18, buyer, prem - 1);
        // Nothing was written on the way out.
        assertEq(app.getSeries(id).totalWritten, 0);
        assertEq(nvdax.balanceOf(address(app)), 0);

        // ...and once the series expires there is no writing at any price.
        vm.warp(expiry);
        vm.expectRevert(WeekendOptions.Expired.selector);
        _buy(id, 10e18, buyer);
    }

    // Spec §6.2 — the product's headline claim: a violent move changes nothing
    function test_adversePriceMove_leavesThePositionUntouched() public {
        uint256 id = _callSeries();
        _shipAndBuy(id, 10e18, buyer);
        WeekendOptions.Series memory before = app.getSeries(id);

        stateView.setSqrtPriceX96(SQRT_PRICE_300); // +46% overnight gap against the writer

        WeekendOptions.Series memory afterMove = app.getSeries(id);
        assertEq(afterMove.poolUnderlying, before.poolUnderlying);
        assertEq(afterMove.totalWritten, before.totalWritten);
        assertEq(app.written(id, maker), 10e18);
        assertEq(nvdax.balanceOf(address(app)), 10e18);
        // there is no liquidate() to call, and no price-triggered path into the contract
    }

    function test_quotePremium_callIsWorthMoreThanIntrinsic() public {
        // ATM 205 strike, spot 205, 7d to expiry, 50% IV -> strictly positive, well under spot.
        uint256 id = _callSeries();
        uint256 prem = app.quotePremium(_strategy(), id, 1e18);

        assertGt(prem, 0, "ATM time value is not free");
        assertLt(prem, 205e6, "a call can never be worth more than the underlying");
        // Closed form for an ATM call at r = 0: S * (2*N(s*sqrt(T)/2) - 1) ~= S * 0.3989 * s*sqrt(T)
        // = 205 * 0.3989 * 0.5 * sqrt(7/365) ~= 5.66 USDC.
        assertApproxEqRel(prem, 5.66e6, 0.05e18);
    }

    /// @dev A deep-OTM call prices to EXACTLY zero: `GapPricing.normalCdf` returns 0 beyond
    ///      -8 sigma, so at spot 205 / 7d / 50% vol any strike above ~1.76x spot is free. A
    ///      taker paying nothing would otherwise seize 100% of the maker's shipped cover into a
    ///      worthless series and lock it until expiry. The strategy bytes to mount this are
    ///      public: `Aqua.ship` emits them.
    function test_buy_zeroPremiumCannotSeizeTheMakersCover() public {
        uint256 id = app.createSeries(address(nvdax), expiry, Kind.CALL, 500e6); // ~2.4x spot
        _ship(maker, address(nvdax), 10e18);
        assertEq(app.quotePremium(_strategy(), id, 10e18), 0, "8-sigma call really does price at 0");

        NoOpTaker attacker = new NoOpTaker();
        vm.expectRevert(WeekendOptions.ZeroPremium.selector);
        attacker.buy(app, _strategy(), id, 10e18, address(attacker));

        // Nothing moved: the cover is still the maker's.
        assertEq(nvdax.balanceOf(maker), 10e18);
        assertEq(nvdax.balanceOf(address(app)), 0);
        assertEq(app.getSeries(id).poolUnderlying, 0);
        assertEq(app.getSeries(id).totalWritten, 0);
        assertEq(app.written(id, maker), 0);
    }

    /// @dev The symmetric PUT: `put = call - S + K` collapses to exactly 0 once `d2 >= +8`, so
    ///      at spot 205 / 7d / 50% vol any strike below ~0.57x spot is free — and a PUT's cover
    ///      is cash, so the seizure is of the maker's USDC.
    function test_buy_zeroPremiumPutCannotSeizeTheMakersCash() public {
        uint256 id = app.createSeries(address(nvdax), expiry, Kind.PUT, 50e6); // ~0.24x spot
        _ship(maker, address(usdc), 500e6);
        assertEq(app.quotePremium(_strategy(), id, 10e18), 0, "8-sigma put really does price at 0");

        NoOpTaker attacker = new NoOpTaker();
        vm.expectRevert(WeekendOptions.ZeroPremium.selector);
        attacker.buy(app, _strategy(), id, 10e18, address(attacker));

        assertEq(usdc.balanceOf(maker), 500e6);
        assertEq(app.getSeries(id).poolCash, 0);
        assertEq(app.written(id, maker), 0);
    }

    /// @dev Above the hard 8-sigma cliff sits a wide band of real-but-dust premiums. The floor
    ///      is where the maker, not the protocol, says how little is worth locking cover for.
    function test_buy_respectsTheMakersPremiumFloor() public {
        // ATM 205 / 7d / 50% vol prices 10 options at ~56.6 USDC against a 2050 USDC strike
        // notional — about 276 bps.
        floorBps = 400; // ...so a 400 bps maker will not write this.
        uint256 id = _callSeries();
        _ship(maker, address(nvdax), 10e18);

        uint256 prem = app.quotePremium(_strategy(), id, 10e18);
        assertGt(prem, 0, "the premium is real, just below this maker's floor");
        assertLt(prem, (2050e6 * 400) / 10_000, "below the 400 bps floor");

        vm.expectRevert(WeekendOptions.PremiumBelowFloor.selector);
        _buy(id, 10e18, buyer);
        assertEq(app.getSeries(id).totalWritten, 0);

        // A different floor is a different strategy hash, so the same maker can ship both.
        // The identical trade clears once the floor is one this premium clears.
        floorBps = 200;
        _ship(maker, address(nvdax), 10e18);
        _buy(id, 10e18, buyer);
        assertEq(app.written(id, maker), 10e18);
    }

    /// @dev Finding 3: the router pins the app it forwards to. It holds a standing approval
    ///      from every user, so the trust boundary is checked on the way in, not only on the
    ///      way back.
    function test_taker_refusesAForeignApp() public {
        OptionTokenFactory otherFactory = new OptionTokenFactory();
        WeekendOptions other = new WeekendOptions(address(usdc), otherFactory, IAqua(address(aqua)), oracle);
        vm.prank(buyer);
        vm.expectRevert(WeekendTaker.OnlyApp.selector);
        taker.buy(other, _strategy(), 0, 1e18, type(uint256).max, buyer, "");
    }

    /// @dev A silent oracle must not price options at zero. `spot` answers (0, 0) for an
    ///      uninitialised pool instead of reverting, which would otherwise make every call free
    ///      and lock the maker's cover for nothing.
    function test_buy_revertsWhenTheOracleHasNoPrice() public {
        uint256 id = _callSeries();
        _ship(maker, address(nvdax), 10e18);
        stateView.setSqrtPriceX96(0);

        assertEq(app.quotePremium(_strategy(), id, 10e18), 0, "a silent oracle prices at zero");
        vm.expectRevert(WeekendOptions.NoPrice.selector);
        _buy(id, 10e18, buyer);

        // The PUT half: without the guard this probe would answer `strike * amount` — a
        // confidently absurd number rather than an honest "unpriceable".
        uint256 putId = _putSeries();
        assertEq(app.quotePremium(_strategy(), putId, 10e18), 0, "0 means unpriceable, not free");
        vm.expectRevert(WeekendOptions.NoPrice.selector);
        _buy(putId, 10e18, buyer); // refused before any collateral is touched
    }

    /// @dev The PUT leg of the write path: cash cover, `poolCash`, and `collateralFor`'s Ceil.
    function test_buy_putLocksQuoteCashInThePool() public {
        uint256 id = _putSeries();
        _ship(maker, address(usdc), 2050e6);

        uint256 prem = _buy(id, 10e18, buyer);

        assertEq(app.getSeries(id).poolCash, 2050e6);
        assertEq(app.getSeries(id).poolUnderlying, 0);
        assertEq(usdc.balanceOf(address(app)), 2050e6);
        // Cover left the wallet; only the premium came back.
        assertEq(usdc.balanceOf(maker), prem);
        assertEq(app.written(id, maker), 10e18);
    }

    /// @dev Rider B: `AQUA.pull` moves `safeTransferFrom(maker, app, need)` but never measures
    ///      what actually landed. A fee-on-transfer underlying delivers less than `need`, which
    ///      would silently under-collateralize the series unless `_buyOption` snapshots its own
    ///      balance before and after the pull and refuses the fill on a shortfall.
    function test_buyOption_revertsOnShortfallFromFeeOnTransferUnderlying() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20("Fee NVDA", "fNVDAx", 18, 100); // 1% fee
        oracle.setPool(address(feeToken), bytes32(uint256(2)), 18, true); // same stateView price

        WeekendOptions.Strategy memory s = WeekendOptions.Strategy({
            app: address(app),
            maker: maker,
            underlying: address(feeToken),
            quote: address(usdc),
            volWad: VOL,
            minPremiumBps: 0,
            maxSecondsToExpiry: 30 days,
            salt: bytes32(0)
        });
        uint256 id = app.createSeries(address(feeToken), expiry, Kind.CALL, STRIKE);

        feeToken.mint(maker, 10e18);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = address(feeToken);
        amounts[0] = 10e18;
        tokens[1] = address(usdc);
        amounts[1] = 0;
        vm.startPrank(maker);
        feeToken.approve(address(aqua), type(uint256).max);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.ship(address(app), abi.encode(s), tokens, amounts);
        vm.stopPrank();

        bytes32 hash = keccak256(abi.encode(s));
        vm.prank(buyer);
        vm.expectRevert(WeekendOptions.ShortPull.selector);
        taker.buy(app, s, id, 10e18, type(uint256).max, buyer, abi.encode(maker, hash));

        // Refused before anything was booked: the pull itself reverted the whole fill.
        assertEq(app.getSeries(id).totalWritten, 0);
        assertEq(app.getSeries(id).poolUnderlying, 0);
        assertEq(app.written(id, maker), 0);
    }
}
