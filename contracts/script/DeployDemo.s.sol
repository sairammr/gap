// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {PoolSetup} from "./lib/PoolSetup.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {Kind, WeekendOptions} from "../src/WeekendOptions.sol";
import {OptionTokenFactory} from "../src/OptionToken.sol";
import {WeekendDesk} from "../src/desk/WeekendDesk.sol";
import {WeekendPricer} from "../src/desk/WeekendPricer.sol";
import {V4SpotOracle} from "../src/oracle/V4SpotOracle.sol";
import {OrderLib} from "../test/helpers/OrderLib.sol";

/// @notice Minimal Permit2 surface needed to let the PositionManager pull tokens.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @title DeployDemo
/// @notice One-shot Base Sepolia demo stack: mock USDC + mock NVDAx, a seeded Uniswap v4 pool,
///         the whole Weekend Options core, and a fully wired, fully shipped `WeekendDesk`.
///
/// @dev Reuses what is already on chain (`aqua`, `swapVmRouter`, `poolManager`,
///      `positionManager`, `stateView`) from `deployments/base-sepolia.json`; everything else is
///      fresh. Rewrites that file at the end, dropping the keys belonging to the deleted
///      product.
///
/// @dev The wiring ORDER mirrors `test/helpers/DeskFixture.sol`, which is the known-good recipe
///      proven against the real router. Five things it exists to get right (each paid for once
///      already — spec §12.4-§12.6):
///
///      1. The desk needs QUOTE IN ITS OWN WALLET. The ask mints just-in-time via `buyOption`,
///         whose premium leg is `AQUA.push` -> `safeTransferFrom(desk, desk, premium)`. ERC-20
///         balance-checks even a self-transfer.
///      2. ONE OWN-STRATEGY MEANS ONE UNDERLYING (`buyOption` reverts `StrategyMismatch`).
///      3. `approveAqua` IS MANDATORY for all three tokens: option token (ask fill), underlying
///         (self-write cover) and quote (bid fill / premium push).
///      4. BOTH LEGS OF EVERY PAIR GET SHIPPED. `AQUA.safeBalances` reverts unless both tokens
///         sit in an active strategy. The zero leg is for that lookup and is never a budget.
///      5. `Aqua.ship` IS IMMUTABLE. The amounts here are a permanent cumulative cap on
///         everything the order can ever sell. Restocking needs a new salt.
///
///      Plus: the ship must come from the DESK (`desk.ship`, owner-only), because Aqua keys
///      balances by `msg.sender` and SwapVM reads them back with `safeBalances(order.maker,..)`.
///      The SwapVM ship's `app` is the ROUTER, not `WeekendOptions`.
///
/// @dev Run (dry):      forge script script/DeployDemo.s.sol --fork-url $BASE_SEPOLIA_RPC_URL -vvv
///      Run (for real): ... --broadcast
contract DeployDemo is Script {
    // ------------------------------------------------------------------ constants

    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant CIRCLE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    string internal constant JSON_PATH = "./deployments/base-sepolia.json";

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    /// @dev Pool spot target: 100 USDC per NVDAx. The strike is read back off the oracle after
    ///      the pool is live, so the series is at-the-money by construction, not by arithmetic.
    uint256 internal constant TARGET_SPOT_WAD = 100e18;

    uint256 internal constant NVDAX_POOL_BUDGET = 1_000_000e18;
    uint256 internal constant USDC_POOL_BUDGET = 100_000_000e6;
    uint256 internal constant NVDAX_WALLET_BUDGET = 100_000e18;
    uint256 internal constant USDC_WALLET_BUDGET = 10_000_000e6;

    /// @dev Cover the desk holds and ships as its own-strategy collateral budget. Permanent cap.
    uint256 internal constant DESK_COVER = 10_000e18;
    /// @dev Quote the desk holds for the self-write round trip (fact 1). Never leaves on a net
    ///      basis; it only has to BE there while `AQUA.push` runs.
    uint256 internal constant DESK_CASH = 1_000_000e6;

    /// @dev The ask's permanent cumulative cap, and the desk's per-series short cap.
    uint256 internal constant SERIES_CAP = 100e18;

    uint64 internal constant TENOR = 7 days;

    /// @dev The SHORT-DATED series. `vm.warp` does not exist on a live chain, so the only way to
    ///      reach settlement is to actually wait — which means the series has to be short enough
    ///      to wait out. 15 minutes leaves room for the deploy sequence plus buy/sell/exercise.
    uint64 internal constant SHORT_TENOR = 15 minutes;
    /// @dev Struck 5% BELOW spot, so the series settles genuinely in the money. An ATM strike
    ///      would settle at `p == strike`, where `holderUnderlying` is exactly 0 and both the
    ///      redeem and claim legs degenerate into proving nothing.
    uint256 internal constant SHORT_STRIKE_BPS = 9_500;

    /// @dev Spread is vol and nothing else. The self-write vol only sets how much quote has to
    ///      sit idle in the desk; it is never what a taker pays.
    uint256 internal constant VOL_ASK = 0.6e18;
    uint256 internal constant VOL_SELF = 0.5e18;
    /// @dev Must stay BELOW `VOL_ASK` or the desk can be round-tripped flat. Spread is vol.
    uint256 internal constant VOL_BID = 0.4e18;

    /// @dev The order's own floor, >= the own-strategy's 0 (see `ShipBase.PremiumFloorInversion`).
    uint16 internal constant ASK_MIN_PREMIUM_BPS = 25;
    bytes32 internal constant ASK_SALT = bytes32(uint256(1));

    /// @dev 25 bps of the strike notional is 0.25 quote per option. A 15-minute option's whole
    ///      TIME value is a fraction of that, so the 7-day floor would reject the short series'
    ///      own quote. 1 bp is the fixture's number and is still above dust.
    uint16 internal constant SHORT_MIN_PREMIUM_BPS = 1;
    bytes32 internal constant SHORT_ASK_SALT = bytes32(uint256(3));
    bytes32 internal constant SHORT_BID_SALT = bytes32(uint256(4));
    /// @dev Quote the bid may ever spend, cumulative and permanent (fact 5).
    uint256 internal constant BID_BUDGET = 100_000e6;

    uint8 internal constant SIDE_ASK = 0;
    uint8 internal constant SIDE_BID = 1;

    // ------------------------------------------------------------------ reused

    IAqua internal aqua;
    address internal router;
    IPoolManager internal poolManager;
    IPositionManager internal posm;
    IStateView internal stateView;

    // ------------------------------------------------------------------ deployed

    address internal deployer;

    MockERC20 internal usdc;
    MockERC20 internal nvdax;
    OptionTokenFactory internal factory;
    WeekendOptions internal app;
    V4SpotOracle internal oracle;
    WeekendPricer internal pricer;
    WeekendDesk internal desk;

    bool internal underlyingIsCurrency0;
    bytes32 internal poolId;
    uint256 internal seriesId;
    address internal optionToken;
    uint64 internal expiry;
    uint256 internal strike;
    bytes32 internal askStrategyHash;

    uint256 internal shortSeriesId;
    address internal shortOptionToken;
    uint64 internal shortExpiry;
    uint256 internal shortStrike;
    bytes32 internal shortAskStrategyHash;
    bytes32 internal shortBidStrategyHash;

    /// @dev Recorded, not inferred. Every shipped order carries this deadline in bytes that are
    ///      covered by the order hash, so a filler that guesses it wrong cannot reproduce the
    ///      shipped order at all.
    uint40 internal askDeadline;

    // ------------------------------------------------------------------ run

    function run() external {
        _loadReused();

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            deployer = vm.addr(pk);
            vm.startBroadcast(pk);
        } else {
            deployer = msg.sender;
            vm.startBroadcast();
        }

        _deployTokensAndPool();
        _deployCore();
        _createSeries();
        _wireDesk();
        _shipBoth();

        vm.stopBroadcast();

        _writeJson();
        _logSummary();
    }

    // ------------------------------------------------------------------ steps

    /// @dev Everything already on chain. Hard-fail rather than silently deploying a second one.
    function _loadReused() internal {
        string memory json = vm.readFile(JSON_PATH);
        aqua = IAqua(vm.parseJsonAddress(json, ".aqua"));
        router = vm.parseJsonAddress(json, ".swapVmRouter");
        poolManager = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        posm = IPositionManager(vm.parseJsonAddress(json, ".positionManager"));
        stateView = IStateView(vm.parseJsonAddress(json, ".stateView"));
        require(
            address(aqua) != address(0) && router != address(0) && address(stateView) != address(0),
            "DeployDemo: reused addresses missing from deployments/base-sepolia.json"
        );
    }

    function _deployTokensAndPool() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvdax = new MockERC20("NVIDIA xStock", "NVDAx", 18);

        // Pool budget LEAVES the wallet as liquidity; the wallet budget is what stays behind for
        // the demo. Minting only the pool budget is how you get a maker that looks collateralised
        // on Aqua's books and reverts `ERC20InsufficientBalance` on the first pull.
        nvdax.mint(deployer, NVDAX_POOL_BUDGET + NVDAX_WALLET_BUDGET);
        usdc.mint(deployer, USDC_POOL_BUDGET + USDC_WALLET_BUDGET);

        underlyingIsCurrency0 = address(nvdax) < address(usdc);
        uint160 sqrtPriceX96 = _sqrtPriceForSpot(underlyingIsCurrency0);

        PoolKey memory key = PoolSetup.initPool(
            poolManager,
            underlyingIsCurrency0 ? Currency.wrap(address(nvdax)) : Currency.wrap(address(usdc)),
            underlyingIsCurrency0 ? Currency.wrap(address(usdc)) : Currency.wrap(address(nvdax)),
            FEE,
            TICK_SPACING,
            sqrtPriceX96
        );
        poolId = keccak256(abi.encode(key));

        _seedPool(key, sqrtPriceX96);
    }

    function _seedPool(PoolKey memory key, uint160 sqrtPriceX96) internal {
        int24 lower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 upper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;

        _approveViaPermit2(address(nvdax));
        _approveViaPermit2(address(usdc));

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            underlyingIsCurrency0 ? NVDAX_POOL_BUDGET : USDC_POOL_BUDGET,
            underlyingIsCurrency0 ? USDC_POOL_BUDGET : NVDAX_POOL_BUDGET
        );
        require(liq > 0, "zero liquidity");

        PoolSetup.seed(posm, key, lower, upper, liq, deployer);
    }

    function _deployCore() internal {
        // The oracle must be configured BEFORE `WeekendPricer` is ever read, and before the desk
        // ships: the ask's quoted premium is a function of this spot.
        oracle = new V4SpotOracle(stateView, 6);
        oracle.setPool(address(nvdax), poolId, 18, underlyingIsCurrency0);

        // `WeekendOptions`' constructor calls `factory.bind(address(this))` itself — `bind` is
        // one-shot, so a second call here would revert `OnlyProtocol()`. The factory is therefore
        // deployed fresh, immediately, and handed straight over.
        factory = new OptionTokenFactory();
        app = new WeekendOptions(address(usdc), factory, aqua, oracle);
        require(factory.protocol() == address(app), "factory not bound to app");

        pricer = new WeekendPricer(app, oracle, address(usdc), 6);
    }

    function _createSeries() internal {
        // At the money BY CONSTRUCTION: read the live pool back through the very oracle the
        // pricer will use, instead of re-deriving 100e6 and hoping the roundings agree.
        (uint256 spot,) = oracle.spot(address(nvdax));
        require(spot != 0, "oracle reports no spot - pool not initialised?");
        strike = spot;

        askDeadline = uint40(block.timestamp + 365 days);

        expiry = uint64(block.timestamp + TENOR);
        seriesId = app.createSeries(address(nvdax), expiry, Kind.CALL, strike);
        optionToken = address(app.getSeries(seriesId).token);

        // The short-dated twin. Different expiry AND different strike, so `seriesIdOf`'s key
        // cannot collide with the 7-day one.
        shortExpiry = uint64(block.timestamp + SHORT_TENOR);
        shortStrike = strike * SHORT_STRIKE_BPS / 10_000;
        shortSeriesId = app.createSeries(address(nvdax), shortExpiry, Kind.CALL, shortStrike);
        shortOptionToken = address(app.getSeries(shortSeriesId).token);
    }

    function _wireDesk() internal {
        desk = new WeekendDesk(app, aqua, router, address(usdc));

        uint256[] memory ids = new uint256[](2);
        uint256[] memory caps = new uint256[](2);
        (ids[0], caps[0]) = (seriesId, SERIES_CAP);
        (ids[1], caps[1]) = (shortSeriesId, SERIES_CAP);
        desk.listSeries(ids, caps);

        desk.setOwnStrategy(_ownStrategy());

        // Cover to write against, and cash for the self-write premium (fact 1).
        nvdax.mint(address(desk), DESK_COVER);
        usdc.mint(address(desk), DESK_CASH);

        // Fact 3. `AQUA.pull` is a real `transferFrom` out of the desk for all three tokens.
        // Max, not exact: `gapOptionCallback`'s push spends the quote allowance to zero, and an
        // exact approval there silently kills every later pull.
        desk.approveAqua(optionToken, type(uint256).max);
        desk.approveAqua(shortOptionToken, type(uint256).max);
        desk.approveAqua(address(nvdax), type(uint256).max);
        desk.approveAqua(address(usdc), type(uint256).max);
    }

    function _shipBoth() internal {
        // 1. The desk's own CORE-PROTOCOL strategy, shipped under `app`. Both legs; quote at
        //    zero so `AQUA.push` of the premium lands on an active strategy (facts 1 and 4).
        _ship(address(app), abi.encode(_ownStrategy()), address(nvdax), DESK_COVER, address(usdc), 0);

        // 2. The ASK, shipped under the ROUTER, because on the SwapVM path the shipped bytes are
        //    `abi.encode(order)` and Aqua's strategyHash is deliberately `SwapVM.hash(order)`.
        OrderLib.Order memory o = _askOrder();
        askStrategyHash = _ship(router, abi.encode(o), optionToken, SERIES_CAP, address(usdc), 0);
        require(askStrategyHash == OrderLib.hash(o), "ask strategyHash drift");

        // 3. The SHORT series' ask — same shape, its own salt and its own (much lower) floor.
        OrderLib.Order memory sa = _shortOrder(SIDE_ASK, SHORT_ASK_SALT);
        shortAskStrategyHash = _ship(router, abi.encode(sa), shortOptionToken, SERIES_CAP, address(usdc), 0);
        require(shortAskStrategyHash == OrderLib.hash(sa), "short ask strategyHash drift");

        // 4. The SHORT series' bid: the sell leg is QUOTE, the zero leg the option token. This
        //    is what lets step 2 of the lifecycle (sell part of the position back) happen at all.
        OrderLib.Order memory sb = _shortOrder(SIDE_BID, SHORT_BID_SALT);
        shortBidStrategyHash = _ship(router, abi.encode(sb), address(usdc), BID_BUDGET, shortOptionToken, 0);
        require(shortBidStrategyHash == OrderLib.hash(sb), "short bid strategyHash drift");
    }

    // ------------------------------------------------------------------ pieces

    function _ownStrategy() internal view returns (WeekendOptions.Strategy memory) {
        return WeekendOptions.Strategy({
            app: address(app),
            maker: address(desk),
            underlying: address(nvdax),
            quote: address(usdc),
            volWad: VOL_SELF,
            minPremiumBps: 0,
            // Rider D (Task 7): no particular bound is meaningful for a one-off demo deploy.
            maxSecondsToExpiry: type(uint64).max,
            salt: bytes32(0)
        });
    }

    function _askOrder() internal view returns (OrderLib.Order memory) {
        return OrderLib.order(
            OrderLib.Params({
                desk: address(desk),
                pricer: address(pricer),
                quote: address(usdc),
                optionToken: optionToken,
                seriesId: seriesId,
                volWad: VOL_ASK,
                minPremiumBps: ASK_MIN_PREMIUM_BPS,
                side: SIDE_ASK,
                // Well past the series expiry, so a late fill trips `SeriesExpired` (which names
                // the cause) rather than the `Deadline` opcode (which does not).
                deadline: askDeadline,
                salt: ASK_SALT,
                // 0/0 disables `RequireMinRate`. The binding floor is `minPremiumBps` inside the
                // pricer; the rate guard is a blunt cross-decimal ratio that would reject every
                // sane 6dp-for-18dp fill.
                minRateA: 0,
                minRateB: 0
            })
        );
    }

    function _shortOrder(uint8 side, bytes32 salt) internal view returns (OrderLib.Order memory) {
        return OrderLib.order(
            OrderLib.Params({
                desk: address(desk),
                pricer: address(pricer),
                quote: address(usdc),
                optionToken: shortOptionToken,
                seriesId: shortSeriesId,
                volWad: side == SIDE_ASK ? VOL_ASK : VOL_BID,
                minPremiumBps: SHORT_MIN_PREMIUM_BPS,
                side: side,
                deadline: askDeadline,
                salt: salt,
                minRateA: 0,
                minRateB: 0
            })
        );
    }

    /// @dev Through `desk.ship`, never `aqua.ship`: Aqua keys balances by `msg.sender`.
    function _ship(address app_, bytes memory strategy, address sell, uint256 amount, address zeroLeg, uint256 zero)
        internal
        returns (bytes32)
    {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tokens[0], amounts[0]) = (sell, amount);
        (tokens[1], amounts[1]) = (zeroLeg, zero);
        return desk.ship(app_, strategy, tokens, amounts);
    }

    // ------------------------------------------------------------------ pool math

    /// @dev Inverts `UniV4Spot.fromSqrtPriceX96` for underlying 18dp / quote 6dp.
    function _sqrtPriceForSpot(bool c0) internal pure returns (uint160) {
        uint256 Q96 = 1 << 96;
        uint256 inner = c0
            ? (TARGET_SPOT_WAD * Q96 / 1e18) * Q96 * (10 ** 6) / (10 ** 18)
            : Q96 * Q96 / TARGET_SPOT_WAD * 1e18 / (10 ** 6) * (10 ** 18);
        return uint160(_sqrt(inner));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /// @dev Two-step Permit2 grant: ERC20 -> Permit2 (infinite), then Permit2 -> PositionManager.
    function _approveViaPermit2(address token) internal {
        IERC20(token).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token, address(posm), type(uint160).max, uint48(block.timestamp + 365 days));
    }

    // ------------------------------------------------------------------ output

    /// @dev Total rewrite. The reused keys are carried across explicitly; `gapOptionsApp`,
    ///      `gapTaker` and the `makers` array belonged to a deleted product and are dropped.
    function _writeJson() internal {
        string memory obj = "weekend";
        vm.serializeAddress(obj, "aqua", address(aqua));
        vm.serializeAddress(obj, "swapVmRouter", router);
        vm.serializeAddress(obj, "poolManager", address(poolManager));
        vm.serializeAddress(obj, "positionManager", address(posm));
        vm.serializeAddress(obj, "stateView", address(stateView));
        vm.serializeAddress(obj, "circleUsdc", CIRCLE_USDC);

        vm.serializeAddress(obj, "maker", deployer);
        vm.serializeAddress(obj, "usdc", address(usdc));
        vm.serializeAddress(obj, "nvdax", address(nvdax));
        vm.serializeAddress(obj, "weekendOptions", address(app));
        vm.serializeAddress(obj, "optionTokenFactory", address(factory));
        vm.serializeAddress(obj, "oracle", address(oracle));
        vm.serializeAddress(obj, "pricer", address(pricer));
        vm.serializeAddress(obj, "desk", address(desk));
        vm.serializeAddress(obj, "optionToken", optionToken);

        vm.serializeBytes32(obj, "poolId", poolId);
        vm.serializeBool(obj, "underlyingIsCurrency0", underlyingIsCurrency0);
        vm.serializeUint(obj, "seriesId", seriesId);
        vm.serializeUint(obj, "expiry", uint256(expiry));
        vm.serializeUint(obj, "strike", strike);
        vm.serializeBytes32(obj, "ownStrategyHash", desk.ownStrategyHash());
        vm.serializeBytes32(obj, "askSalt", ASK_SALT);
        vm.serializeUint(obj, "askVolWad", VOL_ASK);
        vm.serializeUint(obj, "askMinPremiumBps", uint256(ASK_MIN_PREMIUM_BPS));
        vm.serializeUint(obj, "askDeadline", uint256(askDeadline));
        vm.serializeBytes32(obj, "askStrategyHash", askStrategyHash);

        vm.serializeAddress(obj, "shortOptionToken", shortOptionToken);
        vm.serializeUint(obj, "shortSeriesId", shortSeriesId);
        vm.serializeUint(obj, "shortExpiry", uint256(shortExpiry));
        vm.serializeUint(obj, "shortStrike", shortStrike);
        vm.serializeUint(obj, "shortMinPremiumBps", uint256(SHORT_MIN_PREMIUM_BPS));
        vm.serializeUint(obj, "shortAskVolWad", VOL_ASK);
        vm.serializeUint(obj, "shortBidVolWad", VOL_BID);
        vm.serializeBytes32(obj, "shortAskSalt", SHORT_ASK_SALT);
        vm.serializeBytes32(obj, "shortBidSalt", SHORT_BID_SALT);
        vm.serializeUint(obj, "shortBidBudget", BID_BUDGET);
        vm.serializeBytes32(obj, "shortAskStrategyHash", shortAskStrategyHash);
        string memory json = vm.serializeBytes32(obj, "shortBidStrategyHash", shortBidStrategyHash);

        vm.writeJson(json, JSON_PATH);
    }

    function _logSummary() internal view {
        console2.log("---- Weekend Options demo stack ----");
        console2.log("deployer          :", deployer);
        console2.log("usdc              :", address(usdc));
        console2.log("nvdax             :", address(nvdax));
        console2.log("poolId            :", vm.toString(poolId));
        console2.log("underlyingIsCcy0  :", underlyingIsCurrency0);
        console2.log("optionTokenFactory:", address(factory));
        console2.log("weekendOptions    :", address(app));
        console2.log("oracle            :", address(oracle));
        console2.log("pricer            :", address(pricer));
        console2.log("desk              :", address(desk));
        console2.log("optionToken       :", optionToken);
        console2.log("seriesId          :", seriesId);
        console2.log("strike (6dp)      :", strike);
        console2.log("expiry            :", uint256(expiry));
        console2.log("ownStrategyHash   :", vm.toString(desk.ownStrategyHash()));
        console2.log("askStrategyHash   :", vm.toString(askStrategyHash));
        console2.log("premium/option @ask:", pricer.premiumPerOption(seriesId, VOL_ASK));
        console2.log("-- short-dated series --");
        console2.log("shortSeriesId     :", shortSeriesId);
        console2.log("shortOptionToken  :", shortOptionToken);
        console2.log("shortStrike (6dp) :", shortStrike);
        console2.log("shortExpiry       :", uint256(shortExpiry));
        console2.log("askDeadline       :", uint256(askDeadline));
        console2.log("shortAskHash      :", vm.toString(shortAskStrategyHash));
        console2.log("shortBidHash      :", vm.toString(shortBidStrategyHash));
        console2.log("short prem @ask   :", pricer.premiumPerOption(shortSeriesId, VOL_ASK));
        console2.log("short prem @bid   :", pricer.premiumPerOption(shortSeriesId, VOL_BID));
    }
}
