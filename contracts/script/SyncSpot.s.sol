// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IStateView} from "../src/interfaces/IStateView.sol";
import {UniV4Spot} from "../src/lib/UniV4Spot.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice The canonical v4-core `PoolSwapTest` helper deployed on Base Sepolia.
/// @dev Only the one entrypoint we need, so we do not pull v4-core's test tree into the build.
interface IPoolSwapTest {
    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(PoolKey memory key, SwapParams memory params, TestSettings memory settings, bytes memory hookData)
        external
        payable
        returns (int256 delta);
}

/// @title SyncSpot
/// @notice Off-chain keeper leg: moves the NVDAx/USDC v4 pool's spot to `TARGET_SPOT_WAD`.
/// @dev The whole trick is a single v4 swap with:
///        - `sqrtPriceLimitX96` = the sqrt price corresponding to the target spot
///        - `amountSpecified`   = an effectively unbounded exact-INPUT amount
///      v4's swap loop stops the instant the pool price reaches the limit, so the swap
///      self-sizes: it consumes exactly the tokens needed to walk the curve to the target
///      and not one wei more. Direction falls out of the comparison with the current price
///      (`zeroForOne == true` pushes price DOWN in v4, so we use it when the target is lower).
///
///      Run it with `script/sync-spot.sh`, which fetches the real NVDA share price first.
///
///        TARGET_SPOT_WAD=191500000000000000000 \
///          forge script script/SyncSpot.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
///
///      Read-only spot probe (used by the shell wrapper for before/after):
///
///        forge script script/SyncSpot.s.sol --sig "spot()" --rpc-url $BASE_SEPOLIA_RPC_URL
contract SyncSpot is Script {
    /// @dev v4-core PoolSwapTest, verified live on Base Sepolia and bound to POOL_MANAGER.
    IPoolSwapTest internal constant SWAP_ROUTER = IPoolSwapTest(0x8B5bcC363ddE2614281aD875bad385E0A785D3B9);
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    // Must match DeployGap.s.sol or the reconstructed PoolKey will not hash to the stored poolId.
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint8 internal constant UNDERLYING_DECIMALS = 18;
    uint8 internal constant QUOTE_DECIMALS = 6;

    /// @dev Exact-input sentinel. Far larger than any move this pool can need, and the price
    ///      limit — not this number — is what actually terminates the swap.
    int256 internal constant UNBOUNDED_IN = -1e30;

    /// @dev Below this many wei of sqrtPriceX96 difference the move is noise; v4 would revert
    ///      `PriceLimitAlreadyExceeded` if the limit is on the wrong side of the current price.
    uint160 internal constant MIN_SQRT_MOVE = 1e6;

    string internal constant DEPLOY_JSON = "./deployments/base-sepolia.json";

    struct Env {
        address nvdax;
        address usdc;
        address stateView;
        bytes32 poolId;
        bool underlyingIsCurrency0;
    }

    // ---------------------------------------------------------------------
    // read-only probe
    // ---------------------------------------------------------------------

    /// @notice Logs the pool's current spot through the exact same path the app prices with.
    function spot() external view returns (uint256 spotWad) {
        Env memory e = _readEnv();
        (uint160 sqrtPriceX96,,,) = IStateView(e.stateView).getSlot0(e.poolId);
        spotWad = UniV4Spot.spotWad(
            IStateView(e.stateView), e.poolId, UNDERLYING_DECIMALS, QUOTE_DECIMALS, e.underlyingIsCurrency0
        );
        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("spotWad", spotWad);
    }

    // ---------------------------------------------------------------------
    // keeper
    // ---------------------------------------------------------------------

    function run() external {
        uint256 targetSpotWad = vm.envUint("TARGET_SPOT_WAD");
        require(targetSpotWad > 0, "TARGET_SPOT_WAD unset or zero");

        Env memory e = _readEnv();
        PoolKey memory key = _poolKey(e);

        (uint160 current,,,) = IStateView(e.stateView).getSlot0(e.poolId);
        require(current != 0, "pool not initialised");
        uint160 target = _clamp(_sqrtPriceForSpot(targetSpotWad, e.underlyingIsCurrency0));

        uint256 before = UniV4Spot.fromSqrtPriceX96(
            current, e.poolId, UNDERLYING_DECIMALS, QUOTE_DECIMALS, e.underlyingIsCurrency0
        );
        console2.log("spot before (WAD)", before);
        console2.log("spot target (WAD)", targetSpotWad);
        console2.log("sqrt  now        ", current);
        console2.log("sqrt  target     ", target);

        if (_absDiff(current, target) < MIN_SQRT_MOVE) {
            console2.log("already at target (within sqrt dust) - no swap sent");
            return;
        }

        // v4: zeroForOne pushes the price of currency1-per-currency0 DOWN.
        _doSwap(key, target < current, target);

        // Post-state is only meaningful on a broadcast run; under plain simulation this
        // reads the forked copy, which is still a useful dry-run signal.
        (uint160 post,,,) = IStateView(e.stateView).getSlot0(e.poolId);
        console2.log(
            "spot after  (WAD)",
            UniV4Spot.fromSqrtPriceX96(post, e.poolId, UNDERLYING_DECIMALS, QUOTE_DECIMALS, e.underlyingIsCurrency0)
        );
    }

    /// @dev Funds + approves the input side, then fires the single price-limited swap.
    function _doSwap(PoolKey memory key, bool zeroForOne, uint160 target) internal {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address keeper = vm.addr(pk);
        // Input is whichever currency we are selling into the pool.
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        vm.startBroadcast(pk);

        // The mocks mint permissionlessly, which is the whole reason a large gap move is
        // affordable. Top up rather than compute the exact requirement: the swap self-sizes
        // and only pulls what it actually consumes.
        _ensureBalance(tokenIn, keeper);
        if (IERC20(tokenIn).allowance(keeper, address(SWAP_ROUTER)) < type(uint128).max) {
            IERC20(tokenIn).approve(address(SWAP_ROUTER), type(uint256).max);
        }

        SWAP_ROUTER.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: UNBOUNDED_IN, sqrtPriceLimitX96: target}),
            IPoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------------
    // internals
    // ---------------------------------------------------------------------

    /// @dev Mints mock tokens until the keeper holds an amount no single sync can exhaust.
    ///      `MockERC20.mint` is permissionless by design — these are demo tokens.
    function _ensureBalance(address token, address keeper) internal {
        uint256 floor = 10 ** uint256(IERC20Decimals(token).decimals()) * 1_000_000_000; // 1e9 whole tokens
        uint256 bal = IERC20(token).balanceOf(keeper);
        if (bal < floor) {
            MockERC20(token).mint(keeper, floor - bal);
            console2.log("minted mock tokens to fund the move:", floor - bal);
        }
    }

    /// @dev Exact inverse of `UniV4Spot.fromSqrtPriceX96` for this pool's orientation.
    ///      Mirrors `DeployGap._sqrtPriceForSpot`, with the target as a parameter.
    function _sqrtPriceForSpot(uint256 targetSpotWad, bool underlyingIsCurrency0) internal pure returns (uint160) {
        uint256 Q96 = 1 << 96;
        uint256 inner;
        if (underlyingIsCurrency0) {
            // p^2 = spotWad * Q96^2 * 10^quoteDec / (1e18 * 10^underlyingDec)
            inner = (targetSpotWad * Q96 / 1e18) * Q96 * (10 ** QUOTE_DECIMALS) / (10 ** UNDERLYING_DECIMALS);
        } else {
            // p^2 = Q96^2 * 1e18 * 10^underlyingDec / (spotWad * 10^quoteDec)
            inner = Q96 * Q96 / targetSpotWad * 1e18 / (10 ** QUOTE_DECIMALS) * (10 ** UNDERLYING_DECIMALS);
        }
        return uint160(_sqrt(inner));
    }

    /// @dev Babylonian integer sqrt (same as DeployGap's, so both land on the same tick).
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

    function _clamp(uint160 sqrtPriceX96) internal pure returns (uint160) {
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return sqrtPriceX96;
    }

    function _absDiff(uint160 a, uint160 b) internal pure returns (uint160) {
        return a > b ? a - b : b - a;
    }

    /// @dev Rebuilds the PoolKey from the deployment record and proves it hashes to the stored id.
    function _poolKey(Env memory e) internal pure returns (PoolKey memory key) {
        (address c0, address c1) = e.underlyingIsCurrency0 ? (e.nvdax, e.usdc) : (e.usdc, e.nvdax);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        require(keccak256(abi.encode(key)) == e.poolId, "reconstructed PoolKey != deployed poolId");
    }

    function _readEnv() internal view returns (Env memory e) {
        string memory json = vm.readFile(DEPLOY_JSON);
        e.nvdax = vm.parseJsonAddress(json, ".nvdax");
        e.usdc = vm.parseJsonAddress(json, ".usdc");
        e.stateView = vm.parseJsonAddress(json, ".stateView");
        e.poolId = vm.parseJsonBytes32(json, ".poolId");
        e.underlyingIsCurrency0 = vm.parseJsonBool(json, ".underlyingIsCurrency0");
    }
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
