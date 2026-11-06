// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/contracts/interfaces/IAqua.sol";

import {WeekendOptions} from "../src/WeekendOptions.sol";
import {OrderLib} from "../test/helpers/OrderLib.sol";

/// @dev Minimal `AquaSwapVMRouter` surface. `OrderLib.Order` is field-identical to
///      `ISwapVM.Order` (`MakerTraits` is a value type over `uint256`), so the selectors and
///      calldata match byte for byte. Declared here rather than imported because `swapvm/` only
///      resolves under `[profile.swapvm]` (stack-too-deep under the default profile).
///      `quote` is non-view on the router but is documented static-callable; declaring it `view`
///      makes solc emit STATICCALL, which is what we want for a price probe.
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

/// @title DemoFill
/// @notice The first live fill: buy options off the shipped ask through the real
///         `AquaSwapVMRouter`, then exercise them. Two entry points so each broadcast sees the
///         chain state the previous one left:
///
///         forge script script/DemoFill.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
///         forge script script/DemoFill.s.sol --sig 'exerciseAll()' --rpc-url ... --broadcast
///
/// @dev The order must hash to the `askStrategyHash` already shipped into Aqua or
///      `safeBalances` reverts before a single opcode runs. `_order()` rebuilds it from
///      `OrderLib` + the deployment JSON and `_gate()` checks it against the live router.
contract DemoFill is Script {
    string internal constant JSON = "./deployments/base-sepolia.json";

    // Shipped-order constants, mirrored from `DeployDemo`. Anything wrong here fails `_gate()`.
    uint64 internal constant TENOR = 7 days;
    uint16 internal constant ASK_MIN_PREMIUM_BPS = 25;
    uint8 internal constant SIDE_ASK = 0;

    /// @dev Premium to spend on the demo fill, exact-in.
    uint256 internal constant PREMIUM_IN = 50e6;

    struct Cfg {
        address aqua;
        address desk;
        address optionToken;
        address nvdax;
        address pricer;
        address router;
        address usdc;
        address weekendOptions;
        bytes32 askSalt;
        bytes32 askStrategyHash;
        uint256 askVolWad;
        uint256 expiry;
        uint256 seriesId;
        uint256 strike;
    }

    Cfg internal c;
    address internal taker;

    function _load() internal {
        string memory j = vm.readFile(JSON);
        c.aqua = vm.parseJsonAddress(j, ".aqua");
        c.desk = vm.parseJsonAddress(j, ".desk");
        c.optionToken = vm.parseJsonAddress(j, ".optionToken");
        c.nvdax = vm.parseJsonAddress(j, ".nvdax");
        c.pricer = vm.parseJsonAddress(j, ".pricer");
        c.router = vm.parseJsonAddress(j, ".swapVmRouter");
        c.usdc = vm.parseJsonAddress(j, ".usdc");
        c.weekendOptions = vm.parseJsonAddress(j, ".weekendOptions");
        c.askSalt = vm.parseJsonBytes32(j, ".askSalt");
        c.askStrategyHash = vm.parseJsonBytes32(j, ".askStrategyHash");
        c.askVolWad = vm.parseJsonUint(j, ".askVolWad");
        c.expiry = vm.parseJsonUint(j, ".expiry");
        c.seriesId = vm.parseJsonUint(j, ".seriesId");
        c.strike = vm.parseJsonUint(j, ".strike");
        taker = vm.addr(vm.envUint("PRIVATE_KEY"));
    }

    /// @dev `DeployDemo` built both the series expiry and the order deadline off the SAME
    ///      `block.timestamp`: `expiry = t + 7 days`, `deadline = t + 365 days`. So the shipped
    ///      deadline is recoverable from the recorded expiry; `_gate()` proves it.
    function _order() internal view returns (OrderLib.Order memory) {
        uint256 deployTs = c.expiry - TENOR;
        return OrderLib.order(
            OrderLib.Params({
                desk: c.desk,
                pricer: c.pricer,
                quote: c.usdc,
                optionToken: c.optionToken,
                seriesId: c.seriesId,
                volWad: c.askVolWad,
                minPremiumBps: ASK_MIN_PREMIUM_BPS,
                side: SIDE_ASK,
                deadline: uint40(deployTs + 365 days),
                salt: c.askSalt,
                minRateA: 0,
                minRateB: 0
            })
        );
    }

    function _gate() internal view returns (OrderLib.Order memory o) {
        o = _order();
        bytes32 local = OrderLib.hash(o);
        bytes32 onchain = IRouter(c.router).hash(o);
        console2.log("askStrategyHash (json)   :", vm.toString(c.askStrategyHash));
        console2.log("OrderLib.hash   (local)  :", vm.toString(local));
        console2.log("router.hash     (onchain):", vm.toString(onchain));
        require(local == onchain, "local/router hash drift");
        require(onchain == c.askStrategyHash, "SHIPPED ORDER NOT REPRODUCED - stop");
    }

    /// @dev Exact-in, `useTransferFromAndAquaPush`, taker pays the quote token. The quote token
    ///      is the HIGHER address of the pair here, so `isAToB` is false. Ten 16-bit slice
    ///      indexes, all 32 (the threshold is the only slice), then the flags, then `minOut`.
    function _takerTraits(uint256 minOut) internal pure returns (bytes memory) {
        uint16 flags = 0x0001 /* isExactIn */ | 0x0040 /* useTransferFromAndAquaPush */;
        bytes memory idx = abi.encodePacked(
            uint16(32), uint16(32), uint16(32), uint16(32), uint16(32),
            uint16(32), uint16(32), uint16(32), uint16(32), uint16(32)
        );
        return abi.encodePacked(idx, flags, minOut);
    }

    function _report(string memory tag) internal view {
        (uint256 optLeg, uint256 cashLeg) = IAqua(c.aqua).safeBalances(
            c.desk, c.router, c.askStrategyHash, c.optionToken, c.usdc
        );
        console2.log(string.concat("---- ", tag, " ----"));
        console2.log("taker USDC          :", IERC20(c.usdc).balanceOf(taker));
        console2.log("taker options       :", IERC20(c.optionToken).balanceOf(taker));
        console2.log("taker NVDAx         :", IERC20(c.nvdax).balanceOf(taker));
        console2.log("desk NVDAx (cover)  :", IERC20(c.nvdax).balanceOf(c.desk));
        console2.log("desk USDC           :", IERC20(c.usdc).balanceOf(c.desk));
        console2.log("written(0, desk)    :", WeekendOptions(c.weekendOptions).written(c.seriesId, c.desk));
        console2.log("aqua option leg     :", optLeg);
        console2.log("aqua quote leg      :", cashLeg);
        console2.log("optionToken supply  :", IERC20(c.optionToken).totalSupply());
    }

    // ------------------------------------------------------------------ step 1: buy

    function run() external {
        _load();
        OrderLib.Order memory o = _gate();
        _report("PRE-FILL");

        // Quote immediately before filling; `premiumPerOption` decays with time.
        bytes memory probe = _takerTraits(1);
        vm.prank(taker);
        (, uint256 quoted,) = IRouter(c.router).quote(o, PREMIUM_IN, probe);
        console2.log("quoted options out  :", quoted);

        // 2% band. Exact-in decay only ever buys MORE options, so this guards a spot move.
        uint256 minOut = quoted * 98 / 100;
        console2.log("minOut              :", minOut);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IERC20(c.usdc).approve(c.router, PREMIUM_IN);
        (uint256 amountIn, uint256 amountOut,) = IRouter(c.router).swap(o, PREMIUM_IN, _takerTraits(minOut));
        vm.stopBroadcast();

        console2.log("amountIn  (USDC)    :", amountIn);
        console2.log("amountOut (options) :", amountOut);
        _report("POST-FILL");
    }

    // ------------------------------------------------------------------ step 2: exercise

    /// @dev Reads NO oracle. Pays `ceil(amount * strike / 1e18)` quote, receives `amount`
    ///      underlying out of the collateral the desk locked when it wrote.
    function exerciseAll() external {
        _load();
        _report("PRE-EXERCISE");

        uint256 amount = IERC20(c.optionToken).balanceOf(taker);
        require(amount > 0, "nothing to exercise");
        // Ceil, matching `WeekendOptions.exercise`.
        uint256 pay = (amount * c.strike + 1e18 - 1) / 1e18;
        console2.log("exercising options  :", amount);
        console2.log("strike cash owed    :", pay);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IERC20(c.usdc).approve(c.weekendOptions, pay);
        WeekendOptions(c.weekendOptions).exercise(c.seriesId, amount);
        vm.stopBroadcast();

        _report("POST-EXERCISE");
    }
}
