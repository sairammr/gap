// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployDemo} from "./DeployDemo.s.sol";
import {WeekendOptions} from "../src/WeekendOptions.sol";
import {OrderLib} from "../test/helpers/OrderLib.sol";

interface IRouter {
    function swap(OrderLib.Order calldata order, uint256 amount, bytes calldata tt)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);
}

/// @title FullCycle
/// @notice The whole lifecycle — deploy, buy, sell back, exercise, settle, redeem, claim — in
///         ONE forked run, with `vm.warp` standing in for the fifteen-minute wait.
///
///         ~/.foundry/bin/forge script script/FullCycle.s.sol --sig 'cycle()' \
///           --fork-url base_sepolia -vv
///
/// @dev FORK ONLY. It warps the clock and asserts its way through settlement, neither of which
///      means anything against a real chain, so `cycle()` refuses to run under `--broadcast`.
///      It is the no-wait regression check for the sequence that `Lifecycle.s.sol` performs for
///      real; `Lifecycle` remains the only thing that touches mainnet-sepolia state.
///
/// @dev It deliberately does NOT call `DeployDemo.run()` — that would rewrite
///      `deployments/base-sepolia.json` with throwaway fork addresses. It drives the same
///      internal steps and leaves the file alone.
/// @dev KNOWN QUIRK: `forge script` exits 1 on this even when every assertion passes.
///      After the body runs, forge replays the transactions it recorded against the
///      UN-warped chain state, where the series has not expired and `claimFor` reverts
///      `NotExpired()`. The printed step values and the assertions above them are the
///      real result -- read those, not the exit code. Converting this to a fork test
///      would fix the exit code; it is left as a script because that is how the rest of
///      the deploy tooling is shaped.
contract FullCycle is DeployDemo {
    uint256 internal constant PREMIUM_IN = 50e6;

    error RefusingToBroadcast();

    function cycle() external {
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) revert RefusingToBroadcast();

        uint256 pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        _loadReused();
        _deployTokensAndPool();
        _deployCore();
        _createSeries();
        _wireDesk();
        _shipBoth();

        IERC20(address(usdc)).approve(router, type(uint256).max);
        IERC20(shortOptionToken).approve(router, type(uint256).max);

        uint256 bought = _buy();
        uint256 sold = _sellBack(bought / 5);
        uint256 exercised = _exercise((bought - sold) * 3 / 8);

        vm.stopBroadcast();

        // The fifteen minutes, skipped. +1 so `block.timestamp >= expiry` strictly holds.
        vm.warp(shortExpiry + 1);

        vm.startBroadcast(pk);
        _settleRedeemClaim(bought - sold - exercised);
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------ legs

    function _buy() internal returns (uint256 out) {
        uint256 cashBefore = usdc.balanceOf(deployer);
        (uint256 amountIn, uint256 amountOut,) =
            IRouter(router).swap(_shortOrder(SIDE_ASK, SHORT_ASK_SALT), PREMIUM_IN, _tt(address(usdc), 1));

        require(amountIn == PREMIUM_IN, "buy: not exact-in");
        require(amountOut > 0, "buy: no options out");
        require(cashBefore - usdc.balanceOf(deployer) == PREMIUM_IN, "buy: quote delta");
        require(IERC20(shortOptionToken).balanceOf(deployer) == amountOut, "buy: option delta");
        require(app.written(shortSeriesId, address(desk)) == amountOut, "buy: desk short");

        console2.log("1. BUY       in(USDC)/out(opts):", amountIn, amountOut);
        return amountOut;
    }

    function _sellBack(uint256 amount) internal returns (uint256) {
        uint256 writtenBefore = app.written(shortSeriesId, address(desk));
        uint256 coverBefore = nvdax.balanceOf(address(desk));

        (uint256 amountIn, uint256 amountOut,) =
            IRouter(router).swap(_shortOrder(SIDE_BID, SHORT_BID_SALT), amount, _tt(shortOptionToken, 1));

        require(amountIn == amount, "sell: not exact-in");
        require(amountOut > 0, "sell: no quote out");
        // `postTransferIn` -> `_tryClose` -> `close`. Nothing has exercised yet, so the CALL's
        // `poolCash` is still empty and the RULING 13 guard lets the close through.
        require(writtenBefore - app.written(shortSeriesId, address(desk)) == amount, "sell: short not unwound");
        require(nvdax.balanceOf(address(desk)) - coverBefore == amount, "sell: cover not released");

        console2.log("2. SELLBACK  in(opts)/out(USDC):", amountIn, amountOut);
        return amountIn;
    }

    function _exercise(uint256 amount) internal returns (uint256) {
        uint256 pay = (amount * shortStrike + 1e18 - 1) / 1e18;
        uint256 stockBefore = nvdax.balanceOf(deployer);

        usdc.approve(address(app), pay);
        app.exercise(shortSeriesId, amount);

        require(nvdax.balanceOf(deployer) - stockBefore == amount, "exercise: stock not delivered");
        require(app.getSeries(shortSeriesId).poolCash == pay, "exercise: strike cash not banked");

        console2.log("3. EXERCISE  opts/strike cash  :", amount, pay);
        return amount;
    }

    function _settleRedeemClaim(uint256 remainder) internal {
        oracle.recordSettlement(address(nvdax), shortExpiry);
        app.settle(shortSeriesId);

        WeekendOptions.Series memory s = app.getSeries(shortSeriesId);
        require(s.settled, "settle: not settled");
        require(s.settlePrice > s.strike, "settle: expected to finish in the money");
        require(s.supplyAtSettle == remainder, "settle: supply drifted");
        console2.log("4. SETTLE    price/supply      :", s.settlePrice, s.supplyAtSettle);

        (uint256 hU, uint256 hC) = app.redeemFor(shortSeriesId, deployer);
        require(hU == s.holderUnderlying && hC == s.holderCash, "redeem: not the whole holder leg");
        require(IERC20(shortOptionToken).totalSupply() == 0, "redeem: options left outstanding");
        console2.log("5. REDEEM    outU/outC         :", hU, hC);

        (uint256 wU, uint256 wC) = app.claimFor(shortSeriesId, address(desk));
        require(wU == s.writerUnderlying && wC == s.writerCash, "claim: not the whole writer leg");
        // The one this exists to prove: nothing is left behind in the protocol.
        require(usdc.balanceOf(address(app)) == 0, "claim: QUOTE STRANDED IN WeekendOptions");
        require(nvdax.balanceOf(address(app)) == 0, "claim: underlying stranded in WeekendOptions");
        console2.log("6. CLAIM     outU/outC         :", wU, wC);
        console2.log("   app USDC / app NVDAx        :", usdc.balanceOf(address(app)), nvdax.balanceOf(address(app)));
    }

    // ------------------------------------------------------------------ taker traits

    /// @dev Ten 16-bit slice indexes (all 32 — the threshold is the only slice), flags, then
    ///      the threshold word. `isAToB` is derived: `OrderLib` sorts the pair by address.
    function _tt(address tokenIn, uint256 minOut) internal view returns (bytes memory) {
        address tokenA = address(usdc) < shortOptionToken ? address(usdc) : shortOptionToken;
        uint16 flags = 0x0001 | 0x0040 | (tokenIn == tokenA ? uint16(0x0080) : uint16(0));
        bytes memory idx = abi.encodePacked(
            uint16(32), uint16(32), uint16(32), uint16(32), uint16(32),
            uint16(32), uint16(32), uint16(32), uint16(32), uint16(32)
        );
        return abi.encodePacked(idx, flags, minOut);
    }
}
