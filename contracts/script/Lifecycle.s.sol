// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import {WeekendOptions} from "../src/WeekendOptions.sol";
import {V4SpotOracle} from "../src/oracle/V4SpotOracle.sol";
import {OrderLib} from "../test/helpers/OrderLib.sol";

/// @dev Minimal `AquaSwapVMRouter` surface — see `DemoFill` for why it is redeclared rather
///      than imported (`swapvm/` only resolves under `[profile.swapvm]`).
interface IRouter {
    function hash(OrderLib.Order calldata order) external view returns (bytes32);
    function quote(OrderLib.Order calldata order, uint256 amount, bytes calldata tt)
        external
        view
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);
    function swap(OrderLib.Order calldata order, uint256 amount, bytes calldata tt)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);
}

/// @title Lifecycle
/// @notice The full protocol lifecycle on the SHORT-DATED series, one broadcast per step so
///         each one sees the chain state the previous one left:
///
///   1. buy()        fill the shipped ask through the real router
///   2. sellBack()   fill the shipped bid — 20% of the position back to the desk
///   3. exercisePart() physical exercise, reads NO oracle
///   -- wait for expiry --
///   4. settleIt()   oracle.recordSettlement + weekendOptions.settle
///   5. redeemHolder() redeemFor(series, taker) — the unexercised remainder
///   6. claimWriter()  claimFor(series, desk)   — the writer's proceeds
///
/// @dev Every order is rebuilt from `OrderLib` + the deployment JSON and gated against
///      `router.hash` BEFORE anything is broadcast: if the bytes drift by one bit, Aqua's
///      `safeBalances` lookup misses and the fill reverts before a single opcode runs.
contract Lifecycle is Script {
    string internal constant JSON = "./deployments/base-sepolia.json";

    uint8 internal constant SIDE_ASK = 0;
    uint8 internal constant SIDE_BID = 1;

    /// @dev Quote to spend on the opening buy, exact-in.
    uint256 internal constant PREMIUM_IN = 50e6;

    struct Cfg {
        address aqua;
        address desk;
        address nvdax;
        address optionToken;
        address oracle;
        address pricer;
        address router;
        address usdc;
        address weekendOptions;
        bytes32 askHash;
        bytes32 bidHash;
        bytes32 askSalt;
        bytes32 bidSalt;
        uint256 askVol;
        uint256 bidVol;
        uint256 deadline;
        uint256 expiry;
        uint256 minPremiumBps;
        uint256 seriesId;
        uint256 strike;
    }

    Cfg internal c;
    address internal taker;

    function _load() internal {
        string memory j = vm.readFile(JSON);
        c.aqua = vm.parseJsonAddress(j, ".aqua");
        c.desk = vm.parseJsonAddress(j, ".desk");
        c.nvdax = vm.parseJsonAddress(j, ".nvdax");
        c.optionToken = vm.parseJsonAddress(j, ".shortOptionToken");
        c.oracle = vm.parseJsonAddress(j, ".oracle");
        c.pricer = vm.parseJsonAddress(j, ".pricer");
        c.router = vm.parseJsonAddress(j, ".swapVmRouter");
        c.usdc = vm.parseJsonAddress(j, ".usdc");
        c.weekendOptions = vm.parseJsonAddress(j, ".weekendOptions");
        c.askHash = vm.parseJsonBytes32(j, ".shortAskStrategyHash");
        c.bidHash = vm.parseJsonBytes32(j, ".shortBidStrategyHash");
        c.askSalt = vm.parseJsonBytes32(j, ".shortAskSalt");
        c.bidSalt = vm.parseJsonBytes32(j, ".shortBidSalt");
        c.askVol = vm.parseJsonUint(j, ".shortAskVolWad");
        c.bidVol = vm.parseJsonUint(j, ".shortBidVolWad");
        c.deadline = vm.parseJsonUint(j, ".askDeadline");
        c.expiry = vm.parseJsonUint(j, ".shortExpiry");
        c.minPremiumBps = vm.parseJsonUint(j, ".shortMinPremiumBps");
        c.seriesId = vm.parseJsonUint(j, ".shortSeriesId");
        c.strike = vm.parseJsonUint(j, ".shortStrike");
        taker = vm.addr(vm.envUint("PRIVATE_KEY"));
    }

    // ------------------------------------------------------------------ order reconstruction

    function _order(uint8 side) internal view returns (OrderLib.Order memory) {
        return OrderLib.order(
            OrderLib.Params({
                desk: c.desk,
                pricer: c.pricer,
                quote: c.usdc,
                optionToken: c.optionToken,
                seriesId: c.seriesId,
                volWad: side == SIDE_ASK ? c.askVol : c.bidVol,
                minPremiumBps: uint16(c.minPremiumBps),
                side: side,
                deadline: uint40(c.deadline),
                salt: side == SIDE_ASK ? c.askSalt : c.bidSalt,
                minRateA: 0,
                minRateB: 0
            })
        );
    }

    /// @dev Byte-identity gate. Local hash, router hash and the shipped hash must all agree.
    function _gate(uint8 side) internal view returns (OrderLib.Order memory o) {
        o = _order(side);
        bytes32 shipped = side == SIDE_ASK ? c.askHash : c.bidHash;
        bytes32 local = OrderLib.hash(o);
        bytes32 onchain = IRouter(c.router).hash(o);
        console2.log(side == SIDE_ASK ? "-- ASK gate --" : "-- BID gate --");
        console2.log("shipped (json)   :", vm.toString(shipped));
        console2.log("OrderLib (local) :", vm.toString(local));
        console2.log("router  (onchain):", vm.toString(onchain));
        require(local == onchain, "local/router hash drift");
        require(onchain == shipped, "SHIPPED ORDER NOT REPRODUCED - stop");
    }

    /// @dev Ten 16-bit slice indexes (all 32 — the threshold is the only slice), the flags,
    ///      then the threshold word. `isAToB` is derived, not assumed: `OrderLib` sorts the
    ///      pair, so which token is "A" depends on the deployed addresses.
    function _tt(address tokenIn, uint256 minOut) internal view returns (bytes memory) {
        address tokenA = c.usdc < c.optionToken ? c.usdc : c.optionToken;
        uint16 flags = 0x0001 /* isExactIn */ | 0x0040 /* useTransferFromAndAquaPush */
            | (tokenIn == tokenA ? uint16(0x0080) : uint16(0)); /* isAToB */
        bytes memory idx = abi.encodePacked(
            uint16(32), uint16(32), uint16(32), uint16(32), uint16(32),
            uint16(32), uint16(32), uint16(32), uint16(32), uint16(32)
        );
        return abi.encodePacked(idx, flags, minOut);
    }

    // ------------------------------------------------------------------ reporting

    function _report(string memory tag) internal view {
        WeekendOptions app = WeekendOptions(c.weekendOptions);
        WeekendOptions.Series memory s = app.getSeries(c.seriesId);
        console2.log(string.concat("---- ", tag, " ----"));
        console2.log("block.timestamp     :", block.timestamp);
        console2.log("taker USDC          :", IERC20(c.usdc).balanceOf(taker));
        console2.log("taker NVDAx         :", IERC20(c.nvdax).balanceOf(taker));
        console2.log("taker options       :", IERC20(c.optionToken).balanceOf(taker));
        console2.log("desk  USDC          :", IERC20(c.usdc).balanceOf(c.desk));
        console2.log("desk  NVDAx         :", IERC20(c.nvdax).balanceOf(c.desk));
        console2.log("desk  options       :", IERC20(c.optionToken).balanceOf(c.desk));
        console2.log("app   USDC          :", IERC20(c.usdc).balanceOf(c.weekendOptions));
        console2.log("app   NVDAx         :", IERC20(c.nvdax).balanceOf(c.weekendOptions));
        console2.log("option supply       :", IERC20(c.optionToken).totalSupply());
        console2.log("written(desk)       :", app.written(c.seriesId, c.desk));
        console2.log("totalWritten        :", s.totalWritten);
        console2.log("poolUnderlying      :", s.poolUnderlying);
        console2.log("poolCash            :", s.poolCash);
        console2.log("settled             :", s.settled);
        if (s.settled) {
            console2.log("settlePrice         :", s.settlePrice);
            console2.log("supplyAtSettle      :", s.supplyAtSettle);
            console2.log("holderUnderlying    :", s.holderUnderlying);
            console2.log("holderCash          :", s.holderCash);
            console2.log("writerUnderlying    :", s.writerUnderlying);
            console2.log("writerCash          :", s.writerCash);
            console2.log("writtenAtSettle     :", s.writtenAtSettle);
        }
    }

    /// @notice Read-only snapshot. No broadcast.
    function report() external {
        _load();
        _report("SNAPSHOT");
    }

    // ------------------------------------------------------------------ 1. buy

    function buy() external {
        _load();
        OrderLib.Order memory o = _gate(SIDE_ASK);
        _report("PRE-BUY");

        vm.prank(taker);
        (, uint256 quoted,) = IRouter(c.router).quote(o, PREMIUM_IN, _tt(c.usdc, 1));
        uint256 minOut = quoted * 95 / 100;
        console2.log("quoted options out  :", quoted);
        console2.log("minOut              :", minOut);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IERC20(c.usdc).approve(c.router, PREMIUM_IN);
        (uint256 amountIn, uint256 amountOut,) = IRouter(c.router).swap(o, PREMIUM_IN, _tt(c.usdc, minOut));
        vm.stopBroadcast();

        console2.log("amountIn  (USDC)    :", amountIn);
        console2.log("amountOut (options) :", amountOut);
        _report("POST-BUY");
    }

    // ------------------------------------------------------------------ 2. sell part back

    /// @dev 20% of the position, back into the desk's shipped bid. `postTransferIn` ->
    ///      `_tryClose` unwinds the desk's own short against it.
    function sellBack() external {
        _load();
        OrderLib.Order memory o = _gate(SIDE_BID);
        _report("PRE-SELL");

        uint256 amount = IERC20(c.optionToken).balanceOf(taker) / 5;
        require(amount > 0, "nothing to sell");

        vm.prank(taker);
        (, uint256 quoted,) = IRouter(c.router).quote(o, amount, _tt(c.optionToken, 1));
        uint256 minOut = quoted * 95 / 100;
        console2.log("selling options     :", amount);
        console2.log("quoted USDC out     :", quoted);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IERC20(c.optionToken).approve(c.router, amount);
        (uint256 amountIn, uint256 amountOut,) = IRouter(c.router).swap(o, amount, _tt(c.optionToken, minOut));
        vm.stopBroadcast();

        console2.log("amountIn  (options) :", amountIn);
        console2.log("amountOut (USDC)    :", amountOut);
        _report("POST-SELL");
    }

    // ------------------------------------------------------------------ 3. exercise part

    /// @dev Reads NO oracle: pay `ceil(amount * strike / 1e18)` quote, take `amount` underlying.
    ///      Three eighths of what is left — the rest is the remainder that `redeemFor` collects.
    function exercisePart() external {
        _load();
        _report("PRE-EXERCISE");

        uint256 amount = IERC20(c.optionToken).balanceOf(taker) * 3 / 8;
        require(amount > 0, "nothing to exercise");
        uint256 pay = (amount * c.strike + 1e18 - 1) / 1e18;
        console2.log("exercising options  :", amount);
        console2.log("strike cash owed    :", pay);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IERC20(c.usdc).approve(c.weekendOptions, pay);
        WeekendOptions(c.weekendOptions).exercise(c.seriesId, amount);
        vm.stopBroadcast();

        _report("POST-EXERCISE");
    }

    // ------------------------------------------------------------------ 4. settle

    function settleIt() external {
        _load();
        _report("PRE-SETTLE");
        require(block.timestamp >= c.expiry, "not expired yet");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        V4SpotOracle(c.oracle).recordSettlement(c.nvdax, uint64(c.expiry));
        WeekendOptions(c.weekendOptions).settle(c.seriesId);
        vm.stopBroadcast();

        (uint256 p, bool ok) = V4SpotOracle(c.oracle).settlementPrice(c.nvdax, uint64(c.expiry));
        console2.log("recorded price      :", p);
        console2.log("settlementPrice ok  :", ok);
        _report("POST-SETTLE");
    }

    // ------------------------------------------------------------------ 5. redeem

    function redeemHolder() external {
        _load();
        _report("PRE-REDEEM");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        (uint256 outU, uint256 outC) = WeekendOptions(c.weekendOptions).redeemFor(c.seriesId, taker);
        vm.stopBroadcast();

        console2.log("redeem outU (NVDAx) :", outU);
        console2.log("redeem outC (USDC)  :", outC);
        _report("POST-REDEEM");
    }

    // ------------------------------------------------------------------ 6. claim

    function claimWriter() external {
        _load();
        _report("PRE-CLAIM");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        (uint256 outU, uint256 outC) = WeekendOptions(c.weekendOptions).claimFor(c.seriesId, c.desk);
        vm.stopBroadcast();

        console2.log("claim outU (NVDAx)  :", outU);
        console2.log("claim outC (USDC)   :", outC);
        _report("POST-CLAIM");
    }

    // ------------------------------------------------------------------ aqua ledger probe

    function ledger() external {
        _load();
        (uint256 askOpt, uint256 askCash) =
            IAqua(c.aqua).safeBalances(c.desk, c.router, c.askHash, c.optionToken, c.usdc);
        (uint256 bidCash, uint256 bidOpt) =
            IAqua(c.aqua).safeBalances(c.desk, c.router, c.bidHash, c.usdc, c.optionToken);
        console2.log("ask  option leg     :", askOpt);
        console2.log("ask  quote  leg     :", askCash);
        console2.log("bid  quote  leg     :", bidCash);
        console2.log("bid  option leg     :", bidOpt);
    }
}
